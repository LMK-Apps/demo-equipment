-- =====================================================================
-- 마이그레이션 017 · 관리자 대신 신청 + 지난 날짜·출고됨으로 등록
--   1) 장비 관리자는 다른 사용자 이름으로 신청할 수 있다 (사용 중인 사용자만).
--      실제로 등록한 사람은 loans.created_by에 남는다.
--   2) 장비 관리자는 지난 날짜(1년 전까지)를 사용 시작일로 정할 수 있다.
--   3) 장비 관리자는 '출고됨'으로 바로 등록할 수 있다 (이미 들고 나간 장비).
--      이때는 반납 예정일이 지났어도 된다 (바로 연체로 보인다).
--      출고 시각은 시작일 09:00(오늘이면 지금), 배송 건은 출고 배송을 '도착'으로 기록한다.
--   4) 관리자는 신청할 때도 대여 기간 1달 제한을 받지 않는다 (연장과 같은 규칙).
--   5) Teams 새 신청 알림에 '(등록: 관리자)'를 붙이고, 출고됨으로 등록하면 제목을 '출고 등록'으로 바꾼다.
--   예전 앱(v0.053 이하)도 그대로 신청할 수 있다 (새 값은 모두 기본값이 있다).
-- 실행 위치: Supabase SQL Editor (016 실행 후 1회)
-- =====================================================================

begin;

-- 1. 실제로 등록한 사람 (예전 신청과 본인 신청은 비어 있을 수 있다)
alter table public.loans add column if not exists created_by uuid references public.profiles(id);

-- 등록한 사람은 나중에 바꿀 수 없다
create or replace function private.keep_loan_created_by()
returns trigger language plpgsql set search_path = ''
as $$
begin
  new.created_by := old.created_by;
  return new;
end;
$$;
drop trigger if exists loans_keep_created_by on public.loans;
create trigger loans_keep_created_by
  before update of created_by on public.loans
  for each row execute function private.keep_loan_created_by();

-- 2. 날짜 규칙: 관리자는 신청할 때도 1달 제한을 받지 않는다
create or replace function private.guard_loan_dates()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare
  v_today date := (now() at time zone 'Asia/Seoul')::date;
  v_limit date := (new.start_date + interval '1 month')::date;
begin
  if auth.uid() is null then                 -- 대시보드·서비스 키 작업
    return new;
  end if;

  if tg_op = 'INSERT' then
    if new.start_date > v_today + 365 then
      raise exception '사용 시작일은 오늘부터 1년 안으로 정해 주세요. (입력한 날짜: %)', to_char(new.start_date, 'YYYY.MM.DD')
        using errcode = '22023';
    end if;
    if new.due_date > v_limit and not private.is_admin() then
      raise exception '대여 기간은 최대 1달이에요. 반납 예정일을 %까지로 정해 주세요.', to_char(v_limit, 'YYYY.MM.DD')
        using errcode = '22023';
    end if;
  elsif new.due_date is distinct from old.due_date and new.due_date > v_limit and not private.is_admin() then
    raise exception '연장은 시작일부터 1달(%)까지 할 수 있어요. 더 길게 쓰려면 장비 관리자에게 요청해 주세요.', to_char(v_limit, 'YYYY.MM.DD')
      using errcode = '22023';
  end if;
  return new;
end;
$$;

-- 3. 신청 함수: 신청자 지정, 출고됨으로 등록
--    인자 개수가 바뀌므로 예전 함수를 지우고 새로 만든다 (같은 이름이 두 개면 호출이 헷갈린다)
drop function if exists public.create_loan_request(uuid[], date, date, text, text, text, text, text, jsonb);

create or replace function public.create_loan_request(
  p_equipment_ids uuid[],
  p_start         date,
  p_due           date,
  p_purpose       text,
  p_customer      text    default '',
  p_internal      text    default '',
  p_external      text    default '',
  p_note          text    default '',
  p_shipment      jsonb   default null,   -- {recipient, phone, address, date, pickup_date?, memo?}
  p_requester     uuid    default null,   -- 관리자만: 다른 사용자 이름으로 신청
  p_checked_out   boolean default false   -- 관리자만: 출고됨으로 바로 등록
)
returns text
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid   uuid := auth.uid();
  v_admin boolean := private.is_admin();
  v_req   uuid := coalesce(p_requester, auth.uid());
  v_out   boolean := coalesce(p_checked_out, false);
  v_today date := (now() at time zone 'Asia/Seoul')::date;
  v_ids   uuid[];
  v_ym    text;
  v_n     int;
  v_no    text;
  v_eq    uuid;
begin
  if not private.is_active() then
    raise exception '승인된 사용자만 신청할 수 있어요.' using errcode = '42501';
  end if;

  if v_req <> v_uid or v_out then
    if not v_admin then
      raise exception '다른 사람 이름으로 신청하거나 출고됨으로 등록하는 건 장비 관리자만 할 수 있어요.' using errcode = '42501';
    end if;
    if not exists (select 1 from public.profiles where id = v_req and status = 'active') then
      raise exception '신청자는 사용 중인 사용자 중에서 골라 주세요.' using errcode = '22023';
    end if;
  end if;

  select array_agg(distinct x) into v_ids from unnest(p_equipment_ids) x where x is not null;
  if v_ids is null then
    raise exception '빌릴 장비를 1대 이상 골라 주세요.' using errcode = '22023';
  end if;
  if cardinality(v_ids) > 20 then
    raise exception '한 번에 20대까지 신청할 수 있어요.' using errcode = '22023';
  end if;
  if p_start is null or p_due is null or p_due < p_start then
    raise exception '반납 예정일은 사용 시작일과 같거나 그 뒤여야 해요.' using errcode = '22023';
  end if;
  if p_start < v_today then
    if not v_admin then
      raise exception '사용 시작일은 오늘이나 그 뒤로 정해 주세요.' using errcode = '22023';
    end if;
    if p_start < v_today - 365 then
      raise exception '사용 시작일은 1년 전까지만 정할 수 있어요.' using errcode = '22023';
    end if;
  end if;
  if v_out and p_start > v_today then
    raise exception '출고됨으로 등록하려면 사용 시작일이 오늘이나 그 전이어야 해요.' using errcode = '22023';
  end if;
  if not v_out and p_due < v_today then
    raise exception '반납 예정일이 이미 지났어요. 장비를 이미 가져갔다면 ‘출고됨으로 등록’을 켜 주세요.' using errcode = '22023';
  end if;
  if exists (
    select 1 from unnest(v_ids) i(id)
      left join public.equipment e on e.id = i.id
     where e.id is null or e.status in ('inspect', 'repair', 'retired')
  ) then
    raise exception '점검·수리 중이거나 없는 장비가 들어 있어요.' using errcode = '22023';
  end if;
  if v_out and exists (select 1 from public.equipment where id = any(v_ids) and status = 'onloan') then
    raise exception '이미 출고 중인 장비가 들어 있어요. 그 장비의 반납을 먼저 처리해 주세요.' using errcode = '22023';
  end if;
  if p_shipment is not null and (
       coalesce(trim(p_shipment ->> 'recipient'), '') = ''
    or coalesce(trim(p_shipment ->> 'phone'), '') = ''
    or coalesce(trim(p_shipment ->> 'address'), '') = ''
    or (p_shipment ->> 'date') is null
  ) then
    raise exception '배송이 필요하면 수령인, 연락처, 주소, 도착 희망일을 모두 입력해 주세요.' using errcode = '22023';
  end if;

  v_ym := to_char(now() at time zone 'Asia/Seoul', 'YYMM');
  insert into private.loan_counters (ym, last_no) values (v_ym, 1)
  on conflict (ym) do update set last_no = private.loan_counters.last_no + 1
  returning last_no into v_n;
  v_no := 'D-LMK-' || v_ym || '-' || lpad(v_n::text, 3, '0');

  begin
    foreach v_eq in array v_ids loop
      insert into public.loans (
        loan_no, equipment_id, requester_id, internal_requester, external_requester,
        purpose, customer, note, start_date, due_date, delivery, created_by
      ) values (
        v_no, v_eq, v_req, coalesce(trim(p_internal), ''), coalesce(trim(p_external), ''),
        p_purpose, coalesce(trim(p_customer), ''), coalesce(trim(p_note), ''), p_start, p_due, p_shipment is not null, v_uid
      );
    end loop;
  exception when exclusion_violation then
    raise exception '같은 기간에 이미 예약된 장비가 있어요. 장비나 기간을 바꿔 주세요.' using errcode = '23P01';
  end;

  if p_shipment is not null then
    insert into public.shipments (loan_no, direction, recipient, phone, address, requested_date, memo, status, created_by)
    values (v_no, 'outbound', trim(p_shipment ->> 'recipient'), trim(p_shipment ->> 'phone'),
            trim(p_shipment ->> 'address'), (p_shipment ->> 'date')::date,
            coalesce(p_shipment ->> 'memo', ''), case when v_out then 'delivered' else 'pending' end, v_uid);
    if (p_shipment ->> 'pickup_date') is not null then
      insert into public.shipments (loan_no, direction, recipient, phone, address, requested_date, memo, status, created_by)
      values (v_no, 'pickup', trim(p_shipment ->> 'recipient'), trim(p_shipment ->> 'phone'),
              trim(p_shipment ->> 'address'), (p_shipment ->> 'pickup_date')::date,
              coalesce(p_shipment ->> 'memo', ''), 'scheduled', v_uid);
    end if;
  end if;

  -- 출고됨으로 등록: 관리자 출고 처리와 같은 길로 바꾼다 (장비는 '대여 중'이 된다)
  if v_out then
    update public.loans
       set status = 'out',
           checkout_at = case when p_start < v_today
                              then (p_start + time '09:00') at time zone 'Asia/Seoul'
                              else now() end
     where loan_no = v_no;
  end if;

  return v_no;
end;
$$;

revoke all on function public.create_loan_request(uuid[], date, date, text, text, text, text, text, jsonb, uuid, boolean) from public, anon;
grant execute on function public.create_loan_request(uuid[], date, date, text, text, text, text, text, jsonb, uuid, boolean) to authenticated;

-- 4. 새 신청 알림: 대신 등록한 사람, 출고됨으로 등록
create or replace function private.notify_new_loan()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare
  v_first uuid;
  v_items text;
  v_cnt   int;
  v_out   boolean;
  v_ship  public.shipments%rowtype;
  v_by    text;
begin
  if private.flag('app.loan_edit') then
    return null;
  end if;
  select id into v_first from public.loans where loan_no = new.loan_no order by id limit 1;
  if v_first is distinct from new.id then
    return null;                              -- 묶음의 첫 행에서만 보낸다
  end if;

  select string_agg(e.name || ' (' || e.internal_id || ')', ', ' order by e.internal_id), count(*),
         bool_or(l.status = 'out')
    into v_items, v_cnt, v_out
    from public.loans l join public.equipment e on e.id = l.equipment_id
   where l.loan_no = new.loan_no;
  select * into v_ship from public.shipments where loan_no = new.loan_no and direction = 'outbound';
  v_by := case when new.created_by is not null and new.created_by <> new.requester_id
               then ' (등록: ' || coalesce((select display_name from public.profiles where id = new.created_by), '?') || ')' else '' end;

  perform private.teams_send(
    case when v_out then '📝 출고 등록 ' else '📦 새 데모 신청 ' end || new.loan_no,
    array_remove(array[
      '**' || coalesce((select display_name from public.profiles where id = new.requester_id), '?') || '** · 장비 ' || v_cnt || '대' || v_by,
      v_items,
      '기간 ' || to_char(new.start_date, 'MM/DD') || ' ~ ' || to_char(new.due_date, 'MM/DD') || ' · ' || new.purpose
        || case when new.customer <> '' then ' · ' || new.customer else '' end,
      case when new.internal_requester <> '' or new.external_requester <> ''
           then '요청자 ' || concat_ws(' · ', nullif('내부 ' || new.internal_requester, '내부 '), nullif('외부 ' || new.external_requester, '외부 '))
      end,
      case when v_out
           then '이미 가져간 장비를 출고됨으로 등록했어요' || case when v_ship.id is not null then ' · 🚚 배송 건 (배송은 도착으로 기록)' else '' end
           when v_ship.id is not null
           then '🚚 배송 필요 · ' || to_char(v_ship.requested_date, 'MM/DD') || ' 도착 희망 · 물류사 요청 메일을 보내 주세요'
           else '직접 수령' end
    ], null),
    'ledger'
  );
  return null;
end;
$$;

commit;

-- 확인: 아래 값이 2여야 해요 (등록자 칸 1 + 새 신청 함수 1).
select (select count(*) from information_schema.columns where table_schema = 'public' and table_name = 'loans' and column_name = 'created_by')
     + (select count(*) from pg_proc where proname = 'create_loan_request' and pronargs = 11) as ok;
