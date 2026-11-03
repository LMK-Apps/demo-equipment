-- =====================================================================
-- 마이그레이션 018 · 출고된 신청에 장비 추가 / 잘못 등록한 장비 등록 취소
--   1) add_to_checkout: 장비 관리자가 출고 상태인 신청번호에 장비를 더한다.
--      같은 신청번호·신청자·기간·사용 정보로 넣고, 바로 '출고'로 바꾼다.
--      출고 시각은 그 신청의 첫 출고 시각을 따른다. 장비는 '대여 중'이 된다.
--   2) void_checkout_item: 장비 관리자가 출고 상태인 장비 1대를 '취소'로 바꾼다.
--      잘못 등록한 경우용이다. 장비는 '보관'으로 돌아가고, 메모에 사유가 남는다.
--      신청번호의 장비가 모두 취소되면 남은 배송·회수 요청도 취소한다.
--   3) 두 경우 모두 Teams 알림을 1건 보낸다.
-- 실행 위치: Supabase SQL Editor (017 실행 후 1회)
-- =====================================================================

begin;

-- 1. 출고된 신청에 장비 추가
create or replace function public.add_to_checkout(
  p_loan_no       text,
  p_equipment_ids uuid[]
)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid   uuid := auth.uid();
  v_first public.loans%rowtype;
  v_ids   uuid[];
  v_eq    uuid;
  v_names text;
begin
  if not private.is_admin() then
    raise exception '출고된 신청에 장비를 더하는 건 장비 관리자만 할 수 있어요.' using errcode = '42501';
  end if;

  perform 1 from public.loans where loan_no = p_loan_no for update;
  select * into v_first from public.loans
   where loan_no = p_loan_no and status = 'out'
   order by checkout_at nulls last, created_at, id limit 1;
  if not found then
    raise exception '출고 상태인 장비가 있는 신청에만 더할 수 있어요.' using errcode = '22023';
  end if;

  select array_agg(distinct x) into v_ids from unnest(p_equipment_ids) x where x is not null;
  if v_ids is null then
    raise exception '더할 장비를 1대 이상 골라 주세요.' using errcode = '22023';
  end if;
  if cardinality(v_ids) + (select count(*) from public.loans where loan_no = p_loan_no and status <> 'cancelled') > 20 then
    raise exception '한 신청에는 20대까지 넣을 수 있어요.' using errcode = '22023';
  end if;
  if exists (select 1 from public.loans where loan_no = p_loan_no and status <> 'cancelled' and equipment_id = any(v_ids)) then
    raise exception '이미 이 신청에 들어 있는 장비가 있어요.' using errcode = '22023';
  end if;
  if exists (
    select 1 from unnest(v_ids) i(id)
      left join public.equipment e on e.id = i.id
     where e.id is null or e.status in ('inspect', 'repair', 'retired')
  ) then
    raise exception '점검·수리 중이거나 없는 장비가 들어 있어요.' using errcode = '22023';
  end if;
  if exists (select 1 from public.equipment where id = any(v_ids) and status = 'onloan') then
    raise exception '이미 출고 중인 장비가 들어 있어요. 그 장비의 반납을 먼저 처리해 주세요.' using errcode = '22023';
  end if;

  -- 새 신청 알림·예약 수정 알림은 끄고, 아래에서 따로 1건 보낸다
  perform set_config('app.loan_edit', '1', true);
  begin
    foreach v_eq in array v_ids loop
      insert into public.loans (
        loan_no, equipment_id, requester_id, internal_requester, external_requester,
        purpose, customer, note, start_date, due_date, delivery, created_by
      ) values (
        p_loan_no, v_eq, v_first.requester_id, v_first.internal_requester, v_first.external_requester,
        v_first.purpose, v_first.customer, v_first.note, v_first.start_date, v_first.due_date, v_first.delivery, v_uid
      );
    end loop;
  exception when exclusion_violation then
    raise exception '같은 기간에 이미 예약된 장비가 있어요. 그 예약을 먼저 정리해 주세요.' using errcode = '23P01';
  end;

  update public.loans
     set status = 'out',
         checkout_at = coalesce(v_first.checkout_at, now())
   where loan_no = p_loan_no and equipment_id = any(v_ids) and status = 'reserved';
  -- app.loan_edit는 트랜잭션 끝까지 켜 둔다 (새 신청 알림은 커밋할 때 돌기 때문)

  select string_agg(e.name || ' (' || e.internal_id || ')', ', ' order by e.internal_id)
    into v_names from public.equipment e where e.id = any(v_ids);

  perform private.teams_send(
    '➕ 출고 장비 추가 ' || p_loan_no,
    array[
      '**' || coalesce((select display_name from public.profiles where id = v_first.requester_id), '?') || '** · '
        || cardinality(v_ids) || '대 추가 (처리: ' || coalesce((select display_name from public.profiles where id = v_uid), '?') || ')',
      v_names,
      '기간 ' || to_char(v_first.start_date, 'MM/DD') || ' ~ ' || to_char(v_first.due_date, 'MM/DD') || ' · 출고 상태로 바로 등록'
    ],
    'ledger'
  );
end;
$$;

revoke all on function public.add_to_checkout(text, uuid[]) from public, anon;
grant execute on function public.add_to_checkout(text, uuid[]) to authenticated;

-- 2. 잘못 등록한 출고 장비 등록 취소
create or replace function public.void_checkout_item(
  p_loan_id uuid,
  p_reason  text
)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid  uuid := auth.uid();
  v_l    public.loans%rowtype;
  v_e    public.equipment%rowtype;
  v_why  text := coalesce(trim(p_reason), '');
  v_left int;
begin
  if not private.is_admin() then
    raise exception '출고된 장비의 등록 취소는 장비 관리자만 할 수 있어요.' using errcode = '42501';
  end if;
  if v_why = '' then
    raise exception '등록 취소 사유를 적어 주세요.' using errcode = '22023';
  end if;

  select * into v_l from public.loans where id = p_loan_id for update;
  if not found then
    raise exception '대상을 찾지 못했어요.' using errcode = '22023';
  end if;
  if v_l.status <> 'out' then
    raise exception '출고 상태인 장비만 등록 취소할 수 있어요. 출고 전이면 예약 수정이나 예약 취소를 이용해 주세요.' using errcode = '22023';
  end if;

  perform set_config('app.loan_edit', '1', true);
  update public.loans
     set status = 'cancelled',
         note = concat_ws(E'\n', nullif(note, ''),
                '[등록 취소 ' || to_char(now() at time zone 'Asia/Seoul', 'YYYY.MM.DD') || ' · '
                || coalesce((select display_name from public.profiles where id = v_uid), '?') || '] ' || v_why)
   where id = p_loan_id;

  -- 장비는 다시 '보관'으로 (다른 출고 건이 없을 때만)
  update public.equipment set status = 'available', updated_at = now()
   where id = v_l.equipment_id and status = 'onloan'
     and not exists (select 1 from public.loans where equipment_id = v_l.equipment_id and status = 'out');

  -- 신청번호에 남은 장비가 없으면 남은 배송·회수 요청도 취소
  select count(*) into v_left from public.loans where loan_no = v_l.loan_no and status <> 'cancelled';
  if v_left = 0 then
    update public.shipments set status = 'cancelled', updated_at = now()
     where loan_no = v_l.loan_no and status in ('pending', 'scheduled');
  end if;

  select * into v_e from public.equipment where id = v_l.equipment_id;
  perform private.teams_send(
    '↩️ 출고 등록 취소 ' || v_l.loan_no,
    array[
      '**' || v_e.name || '** (' || v_e.internal_id || ') · '
        || coalesce((select display_name from public.profiles where id = v_l.requester_id), '?')
        || ' (처리: ' || coalesce((select display_name from public.profiles where id = v_uid), '?') || ')',
      '사유: ' || v_why,
      case when v_left = 0 then '이 신청의 장비가 모두 취소됐어요' else '같은 신청에 장비 ' || v_left || '대가 남아 있어요' end
    ],
    'ledger'
  );
end;
$$;

revoke all on function public.void_checkout_item(uuid, text) from public, anon;
grant execute on function public.void_checkout_item(uuid, text) to authenticated;

commit;

-- 확인: 아래 값이 2여야 해요 (장비 추가 함수 1 + 등록 취소 함수 1).
select (select count(*) from pg_proc where proname = 'add_to_checkout')
     + (select count(*) from pg_proc where proname = 'void_checkout_item') as ok;
