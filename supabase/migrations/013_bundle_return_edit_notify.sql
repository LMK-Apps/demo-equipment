-- =====================================================================
-- 마이그레이션 013 · 묶음 반납, 예약 수정, 연장·취소 알림
--   1) 묶음 반납: 같은 신청번호의 출고 장비 여러 대를 한 번에 반납 신청한다.
--      장소·방법·회수 정보는 한 번, 자가점검은 장비마다. Teams 알림도 1건.
--   2) 예약 수정: 출고 전(예약 상태)이면 기간, 장비, 사용 정보, 배송 정보를 고친다.
--      빠진 장비는 취소, 새 장비는 추가. 겹치는 예약은 DB가 다시 막는다.
--   3) 연장·취소 알림: 반납 예정일 연장과 예약 취소를 Teams로 알린다.
-- 실행 위치: Supabase SQL Editor (012 실행 후 1회)
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 0. 함수 안에서만 켜는 표시 (트랜잭션이 끝나면 저절로 꺼진다)
--    app.loan_edit   = '1' : 예약 수정 중. 출납 변경 규칙과 신청·연장·취소 알림을 건너뛴다.
--    app.bulk_return = '1' : 묶음 반납 중. 장비별 반납 알림을 건너뛴다 (묶음 알림 1건만).
-- ---------------------------------------------------------------------
create or replace function private.flag(p_name text)
returns boolean language sql stable set search_path = ''
as $$ select coalesce(current_setting(p_name, true), '') = '1' $$;

-- ---------------------------------------------------------------------
-- 1. 출납 변경 규칙: 예약 수정 함수 안에서는 함수가 직접 검사하므로 건너뛴다
-- ---------------------------------------------------------------------
create or replace function private.guard_loan_update()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare
  v_free text[] := array['status', 'due_date', 'returned_at', 'extension_count', 'updated_at',
                         'return_method', 'return_self_check', 'return_self_note', 'return_place'];
begin
  new.updated_at := now();

  if auth.uid() is null then
    return new;
  end if;

  -- 예약 수정 함수(update_reservation)가 권한과 값을 이미 검사했다
  if private.flag('app.loan_edit') then
    new.extension_count := old.extension_count;
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

-- ---------------------------------------------------------------------
-- 2. 알림: 새 신청은 예약 수정 중에 장비를 더해도 다시 보내지 않는다
-- ---------------------------------------------------------------------
create or replace function private.notify_new_loan()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare
  v_first uuid;
  v_items text;
  v_cnt   int;
  v_ship  public.shipments%rowtype;
begin
  if private.flag('app.loan_edit') then
    return null;
  end if;
  select id into v_first from public.loans where loan_no = new.loan_no order by id limit 1;
  if v_first is distinct from new.id then
    return null;                              -- 묶음의 첫 행에서만 보낸다
  end if;

  select string_agg(e.name || ' (' || e.internal_id || ')', ', ' order by e.internal_id), count(*)
    into v_items, v_cnt
    from public.loans l join public.equipment e on e.id = l.equipment_id
   where l.loan_no = new.loan_no;
  select * into v_ship from public.shipments where loan_no = new.loan_no and direction = 'outbound';

  perform private.teams_send(
    '📦 새 데모 신청 ' || new.loan_no,
    array_remove(array[
      '**' || coalesce((select display_name from public.profiles where id = new.requester_id), '?') || '** · 장비 ' || v_cnt || '대',
      v_items,
      '기간 ' || to_char(new.start_date, 'MM/DD') || ' ~ ' || to_char(new.due_date, 'MM/DD') || ' · ' || new.purpose
        || case when new.customer <> '' then ' · ' || new.customer else '' end,
      case when new.internal_requester <> '' or new.external_requester <> ''
           then '요청자 ' || concat_ws(' · ', nullif('내부 ' || new.internal_requester, '내부 '), nullif('외부 ' || new.external_requester, '외부 '))
      end,
      case when v_ship.id is not null
           then '🚚 배송 필요 · ' || to_char(v_ship.requested_date, 'MM/DD') || ' 도착 희망 · 물류사 요청 메일을 보내 주세요'
           else '직접 수령' end
    ], null),
    'ledger'
  );
  return null;
end;
$$;

-- 장비별 반납 알림: 묶음 반납 중에는 건너뛴다 (묶음 함수가 1건으로 보낸다)
create or replace function private.notify_return()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare
  e public.equipment%rowtype;
begin
  if not (old.status = 'out' and new.status = 'checking') or private.flag('app.bulk_return') then
    return null;
  end if;
  select * into e from public.equipment where id = new.equipment_id;
  perform private.teams_send(
    '↩️ 반납 신청 ' || new.loan_no,
    array_remove(array[
      '**' || e.name || '** (' || e.internal_id || ') · ' || coalesce((select display_name from public.profiles where id = new.requester_id), '?'),
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

-- 연장·취소 알림
create or replace function private.notify_extend_cancel()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare
  e     public.equipment%rowtype;
  v_who text;
  v_by  text;
begin
  if private.flag('app.loan_edit') then
    return null;
  end if;
  select * into e from public.equipment where id = new.equipment_id;
  v_who := coalesce((select display_name from public.profiles where id = new.requester_id), '?');
  v_by  := case when auth.uid() is not null and auth.uid() <> new.requester_id
                then ' (처리: ' || coalesce((select display_name from public.profiles where id = auth.uid()), '?') || ')' else '' end;

  if old.status = 'reserved' and new.status = 'cancelled' then
    perform private.teams_send(
      '🚫 예약 취소 ' || new.loan_no,
      array[
        '**' || e.name || '** (' || e.internal_id || ') · ' || v_who || v_by,
        '기간 ' || to_char(new.start_date, 'MM/DD') || ' ~ ' || to_char(new.due_date, 'MM/DD')
          || case when new.delivery then ' · 🚚 배송 건이에요. 물류사 요청을 했다면 취소해 주세요' else '' end
      ],
      'ledger');
  elsif new.due_date > old.due_date and new.status = old.status and new.status in ('reserved', 'out') then
    perform private.teams_send(
      '⏩ 반납 예정일 연장 ' || new.loan_no,
      array[
        '**' || e.name || '** (' || e.internal_id || ') · ' || v_who || v_by,
        to_char(old.due_date, 'MM/DD') || ' → **' || to_char(new.due_date, 'MM/DD') || '** (' || (new.due_date - old.due_date) || '일 연장, '
          || new.extension_count || '번째)'
          || case when new.status = 'out' then '' else ' · 출고 전' end
      ],
      'ledger');
  end if;
  return null;
end;
$$;

drop trigger if exists loans_notify_extend_cancel on public.loans;
create trigger loans_notify_extend_cancel
  after update of status, due_date on public.loans
  for each row execute function private.notify_extend_cancel();

-- ---------------------------------------------------------------------
-- 3. 묶음 반납
--    p_items: [{"loan_id": "...", "self_check": "ok|minor|broken|missing", "self_note": "..."}]
--    모두 같은 신청번호, 출고 상태여야 한다. 하나라도 실패하면 전부 취소된다.
-- ---------------------------------------------------------------------
create or replace function public.request_return_bulk(
  p_items  jsonb,
  p_method text,
  p_pickup jsonb default null,
  p_place  text  default null
)
returns int
language plpgsql security definer set search_path = ''
as $$
declare
  v_ids   uuid[];
  v_nos   text[];
  v_item  jsonb;
  v_lines text[] := '{}';
  v_late  int;
  r       record;
begin
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception '반납할 장비를 1대 이상 골라 주세요.' using errcode = '22023';
  end if;
  if jsonb_array_length(p_items) > 20 then
    raise exception '한 번에 20대까지 반납할 수 있어요.' using errcode = '22023';
  end if;

  select array_agg((x ->> 'loan_id')::uuid) into v_ids from jsonb_array_elements(p_items) x;
  if (select count(distinct i) from unnest(v_ids) i) <> cardinality(v_ids) then
    raise exception '같은 장비가 두 번 들어 있어요.' using errcode = '22023';
  end if;
  select array_agg(distinct loan_no) into v_nos from public.loans where id = any(v_ids);
  if v_nos is null or cardinality(v_nos) <> 1 then
    raise exception '같은 신청번호의 장비만 함께 반납할 수 있어요.' using errcode = '22023';
  end if;

  perform set_config('app.bulk_return', '1', true);
  for v_item in select * from jsonb_array_elements(p_items) loop
    perform public.request_return(
      (v_item ->> 'loan_id')::uuid, p_method, v_item ->> 'self_check',
      coalesce(v_item ->> 'self_note', ''), p_pickup, p_place);
  end loop;
  perform set_config('app.bulk_return', '', true);

  -- Teams 알림 1건
  for r in select l.*, e.name, e.internal_id
             from public.loans l join public.equipment e on e.id = l.equipment_id
            where l.id = any(v_ids) order by e.internal_id loop
    v_lines := v_lines || ('- **' || r.name || '** (' || r.internal_id || ') · ' ||
      case r.return_self_check when 'ok' then '정상' when 'minor' then '경미한 손상'
        when 'broken' then '⚠️ 파손 또는 수리 필요' when 'missing' then '⚠️ 구성품 누락' else '기록 없음' end
      || case when coalesce(r.return_self_note, '') <> '' then ' · ' || r.return_self_note else '' end);
    v_late := greatest(coalesce(v_late, 0), (r.returned_at at time zone 'Asia/Seoul')::date - r.due_date);
  end loop;

  select * into r from public.loans where id = v_ids[1];
  perform private.teams_send(
    '↩️ 반납 신청 ' || r.loan_no || case when cardinality(v_ids) > 1 then ' · 장비 ' || cardinality(v_ids) || '대' else '' end,
    array_remove(array[
      '**' || coalesce((select display_name from public.profiles where id = r.requester_id), '?') || '**',
      case p_method
        when 'drop_uiwang'   then '직접 반납 – 의왕'
        when 'drop_munjeong' then '직접 반납 – 문정'
        when 'pickup'        then '🚚 물류사 회수 요청 → ' || coalesce(r.return_place, '장소 미정') || ' · 회수 요청 메일을 보내 주세요'
        end,
      '자가점검' || chr(10) || array_to_string(v_lines, chr(10)),
      case when v_late > 0 then '연체 반납 (' || v_late || '일)' end,
      '장비 관리자는 반납 확인을 해 주세요'
    ], null),
    'ledger');

  return cardinality(v_ids);
end;
$$;

revoke all on function public.request_return_bulk(jsonb, text, jsonb, text) from public, anon;
grant execute on function public.request_return_bulk(jsonb, text, jsonb, text) to authenticated;

-- ---------------------------------------------------------------------
-- 4. 예약 수정
--    출고 전(취소되지 않은 장비가 모두 '예약' 상태)일 때만 고칠 수 있다.
--    p_shipment: create_loan_request와 같다. null이면 배송을 없앤다.
--    물류사에 이미 배송을 요청했다면 배송 정보는 바꿀 수 없다 (관리자에게 요청).
-- ---------------------------------------------------------------------
create or replace function public.update_reservation(
  p_loan_no       text,
  p_equipment_ids uuid[],
  p_start         date,
  p_due           date,
  p_purpose       text,
  p_customer      text  default '',
  p_internal      text  default '',
  p_external      text  default '',
  p_note          text  default '',
  p_shipment      jsonb default null
)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid   uuid := auth.uid();
  v_admin boolean := private.is_admin();
  v_today date := (now() at time zone 'Asia/Seoul')::date;
  v_req   uuid;
  v_ids   uuid[];
  v_old   uuid[];
  v_out   public.shipments%rowtype;
  v_pick  public.shipments%rowtype;
  v_ship_locked boolean;
  v_eq    uuid;
  v_first public.loans%rowtype;
  v_changes text[] := '{}';
  v_names text;
begin
  if not private.is_active() then
    raise exception '승인된 사용자만 예약을 고칠 수 있어요.' using errcode = '42501';
  end if;

  -- 이 신청번호의 행을 잠그고 확인
  perform 1 from public.loans where loan_no = p_loan_no for update;
  select * into v_first from public.loans where loan_no = p_loan_no and status <> 'cancelled' order by created_at, id limit 1;
  if not found then
    raise exception '고칠 예약을 찾지 못했어요.' using errcode = '22023';
  end if;
  v_req := v_first.requester_id;
  if v_req <> v_uid and not v_admin then
    raise exception '본인 예약만 고칠 수 있어요.' using errcode = '42501';
  end if;
  if exists (select 1 from public.loans where loan_no = p_loan_no and status not in ('reserved', 'cancelled')) then
    raise exception '이미 출고된 장비가 있어서 예약을 고칠 수 없어요. 연장이나 반납 신청을 이용해 주세요.' using errcode = '22023';
  end if;

  -- 값 확인 (신청할 때와 같은 규칙)
  select array_agg(distinct x) into v_ids from unnest(p_equipment_ids) x where x is not null;
  if v_ids is null then
    raise exception '빌릴 장비를 1대 이상 골라 주세요. 모두 빼려면 예약 취소를 해 주세요.' using errcode = '22023';
  end if;
  if cardinality(v_ids) > 20 then
    raise exception '한 번에 20대까지 신청할 수 있어요.' using errcode = '22023';
  end if;
  if p_start is null or p_due is null or p_due < p_start then
    raise exception '반납 예정일은 사용 시작일과 같거나 그 뒤여야 해요.' using errcode = '22023';
  end if;
  if not v_admin then
    if p_start < v_today then
      raise exception '사용 시작일은 오늘이나 그 뒤로 정해 주세요.' using errcode = '22023';
    end if;
    if p_start > v_today + 365 then
      raise exception '사용 시작일은 오늘부터 1년 안으로 정해 주세요.' using errcode = '22023';
    end if;
    if p_due > (p_start + interval '1 month')::date then
      raise exception '대여 기간은 최대 1달이에요. 반납 예정일을 %까지로 정해 주세요.',
        to_char((p_start + interval '1 month')::date, 'YYYY.MM.DD') using errcode = '22023';
    end if;
  end if;
  if p_purpose is null or p_purpose not in ('고객 데모', '전시회', '교육·워크숍', '학회', '내부 교육', '기타') then
    raise exception '목적을 골라 주세요.' using errcode = '22023';
  end if;

  select array_agg(equipment_id) into v_old from public.loans where loan_no = p_loan_no and status = 'reserved';
  if exists (
    select 1 from unnest(v_ids) i(id)
      left join public.equipment e on e.id = i.id
     where e.id is null or (e.status in ('inspect', 'repair', 'retired') and not (i.id = any(v_old)))
  ) then
    raise exception '점검·수리 중이거나 없는 장비가 들어 있어요.' using errcode = '22023';
  end if;

  -- 배송 정보 확인
  select * into v_out  from public.shipments where loan_no = p_loan_no and direction = 'outbound' for update;
  select * into v_pick from public.shipments where loan_no = p_loan_no and direction = 'pickup' for update;
  v_ship_locked := v_out.id is not null and v_out.status <> 'pending';
  if p_shipment is not null and (
       coalesce(trim(p_shipment ->> 'recipient'), '') = ''
    or coalesce(trim(p_shipment ->> 'phone'), '') = ''
    or coalesce(trim(p_shipment ->> 'address'), '') = ''
    or (p_shipment ->> 'date') is null
  ) then
    raise exception '배송이 필요하면 수령인, 연락처, 주소, 도착 희망일을 모두 입력해 주세요.' using errcode = '22023';
  end if;
  if v_ship_locked and (
       p_shipment is null
    or trim(p_shipment ->> 'recipient') <> v_out.recipient
    or trim(p_shipment ->> 'phone') <> v_out.phone
    or trim(p_shipment ->> 'address') <> v_out.address
    or (p_shipment ->> 'date')::date <> v_out.requested_date
  ) then
    raise exception '물류사에 이미 배송을 요청해서 배송 정보는 여기서 바꿀 수 없어요. 장비 관리자에게 말해 주세요.' using errcode = '22023';
  end if;

  -- 바뀐 내용 (알림용)
  if v_first.start_date <> p_start or v_first.due_date <> p_due then
    v_changes := v_changes || ('기간 ' || to_char(v_first.start_date, 'MM/DD') || '~' || to_char(v_first.due_date, 'MM/DD')
                               || ' → **' || to_char(p_start, 'MM/DD') || '~' || to_char(p_due, 'MM/DD') || '**');
  end if;
  select string_agg(e.name || ' (' || e.internal_id || ')', ', ' order by e.internal_id) into v_names
    from public.equipment e where e.id = any(v_ids) and not (e.id = any(v_old));
  if v_names is not null then v_changes := v_changes || ('➕ ' || v_names); end if;
  select string_agg(e.name || ' (' || e.internal_id || ')', ', ' order by e.internal_id) into v_names
    from public.equipment e where e.id = any(v_old) and not (e.id = any(v_ids));
  if v_names is not null then v_changes := v_changes || ('➖ ' || v_names); end if;
  if v_first.purpose <> p_purpose or v_first.customer <> coalesce(trim(p_customer), '')
     or v_first.internal_requester <> coalesce(trim(p_internal), '') or v_first.external_requester <> coalesce(trim(p_external), '')
     or v_first.note <> coalesce(trim(p_note), '') then
    v_changes := v_changes || ('사용 정보: ' || p_purpose || case when coalesce(trim(p_customer), '') <> '' then ' · ' || trim(p_customer) else '' end);
  end if;
  if (v_out.id is not null) <> (p_shipment is not null) then
    v_changes := v_changes || case when p_shipment is null then '🚚 배송 없음으로 변경 (직접 수령)' else '🚚 배송 추가 · ' || to_char((p_shipment ->> 'date')::date, 'MM/DD') || ' 도착 희망' end;
  elsif v_out.id is not null and not v_ship_locked and (
       trim(p_shipment ->> 'recipient') <> v_out.recipient or trim(p_shipment ->> 'phone') <> v_out.phone
    or trim(p_shipment ->> 'address') <> v_out.address or (p_shipment ->> 'date')::date <> v_out.requested_date
    or coalesce(p_shipment ->> 'memo', '') <> v_out.memo) then
    v_changes := v_changes || ('🚚 배송 정보 변경 · ' || to_char((p_shipment ->> 'date')::date, 'MM/DD') || ' 도착 희망');
  end if;

  perform set_config('app.loan_edit', '1', true);
  begin
    -- 빠진 장비는 취소
    update public.loans set status = 'cancelled'
     where loan_no = p_loan_no and status = 'reserved' and not (equipment_id = any(v_ids));
    -- 남은 장비는 새 값으로
    update public.loans
       set start_date = p_start, due_date = p_due, purpose = p_purpose,
           customer = coalesce(trim(p_customer), ''), internal_requester = coalesce(trim(p_internal), ''),
           external_requester = coalesce(trim(p_external), ''), note = coalesce(trim(p_note), ''),
           delivery = p_shipment is not null
     where loan_no = p_loan_no and status = 'reserved';
    -- 새 장비는 추가
    foreach v_eq in array v_ids loop
      if not (v_eq = any(coalesce(v_old, '{}'))) then
        insert into public.loans (
          loan_no, equipment_id, requester_id, internal_requester, external_requester,
          purpose, customer, note, start_date, due_date, delivery
        ) values (
          p_loan_no, v_eq, v_req, coalesce(trim(p_internal), ''), coalesce(trim(p_external), ''),
          p_purpose, coalesce(trim(p_customer), ''), coalesce(trim(p_note), ''), p_start, p_due, p_shipment is not null
        );
      end if;
    end loop;
  exception when exclusion_violation then
    raise exception '같은 기간에 이미 예약된 장비가 있어요. 장비나 기간을 바꿔 주세요.' using errcode = '23P01';
  end;

  -- 배송
  if not v_ship_locked then
    if p_shipment is null then
      delete from public.shipments where loan_no = p_loan_no and direction = 'outbound';
      delete from public.shipments where loan_no = p_loan_no and direction = 'pickup' and status = 'scheduled';
    else
      insert into public.shipments (loan_no, direction, recipient, phone, address, requested_date, memo, status, created_by)
      values (p_loan_no, 'outbound', trim(p_shipment ->> 'recipient'), trim(p_shipment ->> 'phone'),
              trim(p_shipment ->> 'address'), (p_shipment ->> 'date')::date, coalesce(p_shipment ->> 'memo', ''), 'pending', v_uid)
      on conflict (loan_no, direction) do update
        set recipient = excluded.recipient, phone = excluded.phone, address = excluded.address,
            requested_date = excluded.requested_date, memo = excluded.memo, updated_at = now();
    end if;
  end if;
  if p_shipment is not null then
    if (p_shipment ->> 'pickup_date') is not null then
      if v_pick.id is null then
        insert into public.shipments (loan_no, direction, recipient, phone, address, requested_date, memo, status, created_by)
        values (p_loan_no, 'pickup', trim(p_shipment ->> 'recipient'), trim(p_shipment ->> 'phone'),
                trim(p_shipment ->> 'address'), (p_shipment ->> 'pickup_date')::date, coalesce(p_shipment ->> 'memo', ''), 'scheduled', v_uid);
      elsif v_pick.status = 'scheduled' then
        update public.shipments
           set recipient = trim(p_shipment ->> 'recipient'), phone = trim(p_shipment ->> 'phone'),
               address = trim(p_shipment ->> 'address'), requested_date = (p_shipment ->> 'pickup_date')::date,
               memo = coalesce(p_shipment ->> 'memo', ''), updated_at = now()
         where id = v_pick.id;
      end if;
    elsif v_pick.id is not null and v_pick.status = 'scheduled' then
      delete from public.shipments where id = v_pick.id;
    end if;
  end if;
  -- app.loan_edit 표시는 끄지 않는다: 새 신청 알림(커밋 때 실행)도 건너뛰어야 해서. 트랜잭션이 끝나면 저절로 꺼진다.

  if cardinality(v_changes) > 0 then
    perform private.teams_send(
      '✏️ 예약 수정 ' || p_loan_no,
      array['**' || coalesce((select display_name from public.profiles where id = v_req), '?') || '**'
              || case when v_uid <> v_req then ' (처리: ' || coalesce((select display_name from public.profiles where id = v_uid), '?') || ')' else '' end]
        || v_changes
        || case when v_ship_locked then array[]::text[]
                when v_out.id is not null or p_shipment is not null then array['물류사 요청 전이라면 바뀐 내용으로 요청해 주세요']
                else array[]::text[] end,
      'ledger');
  end if;
end;
$$;

revoke all on function public.update_reservation(text, uuid[], date, date, text, text, text, text, text, jsonb) from public, anon;
grant execute on function public.update_reservation(text, uuid[], date, date, text, text, text, text, text, jsonb) to authenticated;

commit;
