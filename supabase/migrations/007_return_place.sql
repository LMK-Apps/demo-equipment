-- =====================================================================
-- 마이그레이션 007 · 반납 장소
--   - 반납 신청을 '장소(의왕/문정) → 방법(직접 반납/물류사 회수)' 2단계로 받는다
--   - loans.return_place: 반납자가 고른 장소. 물류사 회수도 어디로 들어올지 남는다
--   - request_return에 p_place 추가 (직접 반납은 방법에서 장소가 정해짐)
--   - Teams 반납 알림에 회수 입고지 표시, '파손' 표시를 '파손 또는 수리 필요'로 변경
-- 이미 저장된 기록은 바꾸지 않는다 (직접 반납 기록의 장소만 채운다).
-- 실행 위치: Supabase SQL Editor (006 실행 후 1회)
-- =====================================================================

-- 1. 열 추가
alter table public.loans
  add column if not exists return_place text check (return_place in ('의왕', '문정'));

update public.loans
   set return_place = case return_method when 'drop_uiwang' then '의왕' when 'drop_munjeong' then '문정' end
 where return_place is null and return_method in ('drop_uiwang', 'drop_munjeong');

-- 2. 출납 변경 규칙: return_place는 반납 신청 때만 적을 수 있다
create or replace function private.guard_loan_update()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare
  v_free text[] := array['status', 'due_date', 'returned_at', 'extension_count', 'updated_at',
                         'return_method', 'return_self_check', 'return_self_note', 'return_place'];
begin
  new.updated_at := now();

  -- RLS를 통과한 행만 여기에 온다. auth.uid()가 없으면 대시보드·서비스 키 작업이다.
  if auth.uid() is null then
    return new;
  end if;

  if new.due_date is distinct from old.due_date then
    if old.status not in ('reserved', 'out') or new.status <> old.status then
      raise exception '연장은 예약 또는 출고 상태에서만 할 수 있어요.' using errcode = '22023';
    end if;
    if new.due_date <= old.due_date then
      raise exception '연장은 지금 반납 예정일보다 뒤 날짜로만 할 수 있어요.' using errcode = '22023';
    end if;
    new.extension_count := old.extension_count + 1;
  end if;

  -- 반납 신청서 항목은 '출고 → 반납 확인 중'으로 바뀔 때만 적을 수 있다
  if not (old.status = 'out' and new.status = 'checking') then
    new.return_method     := old.return_method;
    new.return_self_check := old.return_self_check;
    new.return_self_note  := old.return_self_note;
    new.return_place      := old.return_place;
  else
    new.return_self_note := coalesce(trim(new.return_self_note), '');
    if new.return_method is null or new.return_self_check is null then
      raise exception '반납 방법과 상태 자가점검을 골라 주세요.' using errcode = '22023';
    end if;
    if new.return_self_check <> 'ok' and new.return_self_note = '' then
      raise exception '손상이나 누락이 있으면 내용을 메모에 적어 주세요.' using errcode = '22023';
    end if;
  end if;

  if private.is_admin() then
    if new.status is distinct from old.status then
      if new.status = 'out' then
        new.checkout_at := coalesce(new.checkout_at, now());
      elsif new.status = 'checking' then
        new.returned_at := coalesce(new.returned_at, now());
      elsif new.status = 'done' then
        if new.return_condition is null then
          raise exception '반납 점검 결과를 골라 주세요.' using errcode = '22023';
        end if;
        if new.return_condition <> 'ok' and coalesce(trim(new.return_note), '') = '' then
          raise exception '손상이나 누락이 있으면 점검 메모를 적어 주세요.' using errcode = '22023';
        end if;
        new.checked_by  := auth.uid();
        new.returned_at := coalesce(new.returned_at, now());
      end if;
    end if;
    return new;
  end if;

  -- 여기부터 신청자
  if (to_jsonb(new) - v_free) is distinct from (to_jsonb(old) - v_free) then
    raise exception '신청자는 반납 예정일 연장, 예약 취소, 반납 신청만 할 수 있어요.' using errcode = '42501';
  end if;

  if new.status is distinct from old.status then
    if old.status = 'reserved' and new.status = 'cancelled' then
      null;
    elsif old.status = 'out' and new.status = 'checking' then
      new.returned_at := now();
    else
      raise exception '이 상태 변경은 장비 관리자만 할 수 있어요.' using errcode = '42501';
    end if;
  end if;

  if new.status = old.status then
    new.returned_at := old.returned_at;
  end if;
  if new.due_date = old.due_date then
    new.extension_count := old.extension_count;
  end if;
  return new;
end;
$$;

-- 3. 반납 신청 함수 (p_place 추가). 이전 형태는 지운다.
drop function if exists public.request_return(uuid, text, text, text, jsonb);

create or replace function public.request_return(
  p_loan_id    uuid,
  p_method     text,
  p_self_check text,
  p_self_note  text  default '',
  p_pickup     jsonb default null,
  p_place      text  default null
)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid  uuid := auth.uid();
  v_loan public.loans%rowtype;
  v_ship public.shipments%rowtype;
  v_place text;
begin
  if not private.is_active() then
    raise exception '승인된 사용자만 반납을 신청할 수 있어요.' using errcode = '42501';
  end if;

  select * into v_loan from public.loans where id = p_loan_id for update;
  if not found then
    raise exception '신청 기록을 찾지 못했어요.' using errcode = '22023';
  end if;
  if v_loan.requester_id <> v_uid and not private.is_admin() then
    raise exception '본인 신청만 반납할 수 있어요.' using errcode = '42501';
  end if;
  if v_loan.status <> 'out' then
    raise exception '출고된 장비만 반납할 수 있어요.' using errcode = '22023';
  end if;
  if p_method is null or p_method not in ('drop_munjeong', 'drop_uiwang', 'pickup') then
    raise exception '반납 방법을 골라 주세요.' using errcode = '22023';
  end if;

  -- 반납 장소: 직접 반납은 방법에서 정해지고, 물류사 회수는 p_place로 받는다
  v_place := case p_method when 'drop_uiwang' then '의왕' when 'drop_munjeong' then '문정' else p_place end;
  if v_place is null or v_place not in ('의왕', '문정') then
    raise exception '반납 장소(의왕 또는 문정)를 골라 주세요.' using errcode = '22023';
  end if;

  if p_method = 'pickup' then
    select * into v_ship from public.shipments
     where loan_no = v_loan.loan_no and direction = 'pickup' for update;
    if found then
      if v_ship.status in ('scheduled', 'cancelled') then
        update public.shipments
           set status = 'pending',
               requested_date = coalesce((p_pickup ->> 'date')::date, requested_date),
               updated_at = now()
         where id = v_ship.id;
      end if;
    else
      if p_pickup is null
         or coalesce(trim(p_pickup ->> 'recipient'), '') = ''
         or coalesce(trim(p_pickup ->> 'phone'), '') = ''
         or coalesce(trim(p_pickup ->> 'address'), '') = ''
         or (p_pickup ->> 'date') is null then
        raise exception '회수를 요청하려면 담당자, 연락처, 회수 주소, 회수 희망일을 입력해 주세요.' using errcode = '22023';
      end if;
      insert into public.shipments (loan_no, direction, recipient, phone, address, requested_date, memo, status, created_by)
      values (v_loan.loan_no, 'pickup', trim(p_pickup ->> 'recipient'), trim(p_pickup ->> 'phone'),
              trim(p_pickup ->> 'address'), (p_pickup ->> 'date')::date,
              coalesce(p_pickup ->> 'memo', ''), 'pending', v_uid);
    end if;
  end if;

  update public.loans
     set status = 'checking',
         return_method = p_method,
         return_self_check = p_self_check,
         return_self_note = coalesce(p_self_note, ''),
         return_place = v_place
   where id = p_loan_id;
end;
$$;

revoke all on function public.request_return(uuid, text, text, text, jsonb, text) from public, anon;
grant execute on function public.request_return(uuid, text, text, text, jsonb, text) to authenticated;

-- 4. Teams 반납 알림
create or replace function private.notify_return()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare
  e public.equipment%rowtype;
begin
  if not (old.status = 'out' and new.status = 'checking') then
    return null;
  end if;
  select * into e from public.equipment where id = new.equipment_id;
  perform private.teams_send(
    '↩️ 반납 신청 ' || new.loan_no,
    array_remove(array[
      '**' || e.name || '** (' || e.asset_no || ') · ' || coalesce((select display_name from public.profiles where id = new.requester_id), '?'),
      case new.return_method
        when 'drop_uiwang'   then '직접 반납 – 의왕'
        when 'drop_munjeong' then '직접 반납 – 문정'
        when 'pickup'        then '🚚 물류사 회수 요청 → ' || coalesce(new.return_place, '장소 미정') || ' · 회수 요청 메일을 보내 주세요'
        else '반납 방법 기록 없음' end,
      '자가점검: ' || case new.return_self_check
        when 'ok' then '정상' when 'minor' then '경미한 손상'
        when 'broken' then '⚠️ 파손 또는 수리 필요' when 'missing' then '⚠️ 구성품 누락' else '기록 없음' end
        || case when coalesce(new.return_self_note, '') <> '' then ' · ' || new.return_self_note else '' end,
      case when (new.returned_at at time zone 'Asia/Seoul')::date > new.due_date
           then '연체 반납 (' || ((new.returned_at at time zone 'Asia/Seoul')::date - new.due_date) || '일)' end,
      '장비 관리자는 반납 확인을 해 주세요'
    ], null),
    'ledger'
  );
  return null;
end;
$$;
