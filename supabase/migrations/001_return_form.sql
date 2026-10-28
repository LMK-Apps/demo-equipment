-- =====================================================================
-- 마이그레이션 001 · 반납 신청서 (반납 방법 + 상태 자가점검)
-- 실행 위치: Supabase SQL Editor (schema.sql 실행 후 1회)
-- =====================================================================

-- 1. 열 추가
alter table public.loans
  add column if not exists return_method     text check (return_method in ('drop_munjeong', 'drop_uiwang', 'pickup')),
  add column if not exists return_self_check text check (return_self_check in ('ok', 'minor', 'broken', 'missing')),
  add column if not exists return_self_note  text not null default '';

-- 회수가 필요 없어진 경우를 위해 배송 상태에 'cancelled' 추가
alter table public.shipments drop constraint if exists shipments_status_check;
alter table public.shipments add constraint shipments_status_check
  check (status in ('scheduled', 'pending', 'requested', 'in_transit', 'delivered', 'done', 'cancelled'));

-- 2. 출납 변경 규칙: 반납 신청서 항목 반영
create or replace function private.guard_loan_update()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare
  v_free text[] := array['status', 'due_date', 'returned_at', 'extension_count', 'updated_at',
                         'return_method', 'return_self_check', 'return_self_note'];
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

-- 3. 반납 후 처리: 장비 상태·위치, 회수 요청
create or replace function private.after_loan_change()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if tg_op = 'UPDATE' and new.status is distinct from old.status then
    if new.status = 'out' then
      update public.equipment set status = 'onloan', updated_at = now() where id = new.equipment_id;

    elsif new.status = 'checking' then
      update public.equipment
         set status = 'inspect',
             location = case new.return_method
                          when 'drop_munjeong' then '문정'
                          when 'drop_uiwang'   then '의왕'
                          else location end,
             updated_at = now()
       where id = new.equipment_id;

      if new.return_method = 'pickup' or (new.return_method is null and new.delivery) then
        -- 회수 필요: 예정된 회수를 '요청 전'으로
        update public.shipments set status = 'pending', updated_at = now()
         where loan_no = new.loan_no and direction = 'pickup' and status = 'scheduled';
      elsif not exists (
        select 1 from public.loans
         where loan_no = new.loan_no
           and (status = 'out' or return_method = 'pickup')
      ) then
        -- 묶음 전체가 직접 반납으로 끝났으면 예정된 회수는 취소
        update public.shipments set status = 'cancelled', updated_at = now()
         where loan_no = new.loan_no and direction = 'pickup' and status = 'scheduled';
      end if;

    elsif new.status = 'done' then
      update public.equipment
         set status = case when new.return_condition in ('ok', 'minor') then 'available' else 'repair' end,
             updated_at = now()
       where id = new.equipment_id;
    end if;
  end if;
  return null;
end;
$$;

-- 4. 반납 신청 함수
--    p_pickup: 물류사 회수일 때만. {recipient, phone, address, date, memo?}
--    같은 신청번호에 회수 요청이 이미 있으면 그것을 쓰고, 없으면 새로 만든다.
create or replace function public.request_return(
  p_loan_id    uuid,
  p_method     text,
  p_self_check text,
  p_self_note  text  default '',
  p_pickup     jsonb default null
)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid  uuid := auth.uid();
  v_loan public.loans%rowtype;
  v_ship public.shipments%rowtype;
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
         return_self_note = coalesce(p_self_note, '')
   where id = p_loan_id;
end;
$$;

revoke all on function public.request_return(uuid, text, text, text, jsonb) from public, anon;
grant execute on function public.request_return(uuid, text, text, text, jsonb) to authenticated;
