-- =====================================================================
-- 마이그레이션 030 · 사용 중 이동 배차 요청
--   대여 중(출고 상태)인 장비를 반납 전에 다른 곳으로 옮길 때 물류 배차를 요청한다.
--   - shipments.direction 에 'move' 추가. 한 신청번호에 이동은 여러 번 가능.
--     (배송 outbound·회수 pickup 은 지금처럼 신청번호마다 1건)
--   - 출발지 칸 3개 추가: origin_name, origin_phone, origin_address
--     (도착지는 기존 recipient, phone, address 를 그대로 쓴다)
--   - request_move(): 신청한 본인 또는 장비 관리자가 이동을 요청한다. Teams 알림 1건.
--   - cancel_move(): 본인은 '요청 전' 단계에서만, 장비 관리자는 도착 전까지 취소한다.
--   - confirm_delivery(): 이동도 도착 확인할 수 있게 한다.
--   - purge_shipping_contacts(): 출발지 연락처도 함께 지운다.
--   - update_reservation 의 on conflict 를 새 고유 인덱스에 맞춘다.
-- 실행 위치: Supabase SQL Editor (029 실행 후 1회)
-- =====================================================================

begin;

-- 1) 칸과 제약
alter table public.shipments
  add column if not exists origin_name    text not null default '',
  add column if not exists origin_phone   text not null default '',
  add column if not exists origin_address text not null default '';

alter table public.shipments drop constraint if exists shipments_direction_check;
alter table public.shipments add constraint shipments_direction_check
  check (direction in ('outbound', 'pickup', 'move'));

-- 2) 기존 함수의 on conflict 를 부분 고유 인덱스에 맞춘다 (대상 글자가 없으면 멈춘다)
do $$
declare
  f text; d text; n int;
begin
  foreach f in array array['update_reservation'] loop
    select count(*) into n from pg_proc p join pg_namespace s on s.oid = p.pronamespace
     where s.nspname = 'public' and p.proname = f;
    if n <> 1 then raise exception '% 함수가 % 개 있어요. 멈춥니다.', f, n; end if;
    select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace s on s.oid = p.pronamespace
     where s.nspname = 'public' and p.proname = f;
    if position('on conflict (loan_no, direction) do' in d) = 0 then
      raise exception '% 에서 on conflict 문장을 찾지 못했어요. 멈춥니다.', f;
    end if;
    execute replace(d, 'on conflict (loan_no, direction) do', 'on conflict (loan_no, direction) where direction <> ''move'' do');
  end loop;
end $$;

alter table public.shipments drop constraint if exists shipments_loan_no_direction_key;
create unique index if not exists shipments_loan_dir_one
  on public.shipments (loan_no, direction) where direction <> 'move';

-- 3) 이동 요청
create or replace function public.request_move(
  p_loan_no text, p_origin_name text, p_origin_phone text, p_origin_address text,
  p_recipient text, p_phone text, p_address text, p_date date, p_memo text default '')
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid  uuid := auth.uid();
  v_req  uuid;
  v_cust text;
  v_id   uuid;
begin
  if not private.is_active() then
    raise exception '승인된 사용자만 이동을 요청할 수 있어요.' using errcode = '42501';
  end if;
  select requester_id, coalesce(nullif(customer, ''), purpose) into v_req, v_cust
    from public.loans where loan_no = p_loan_no and status = 'out' order by created_at, id limit 1;
  if not found then
    raise exception '사용 중인 장비가 있는 신청만 이동을 요청할 수 있어요.' using errcode = '22023';
  end if;
  if v_req is distinct from v_uid and not private.is_admin() then
    raise exception '본인 신청만 이동을 요청할 수 있어요.' using errcode = '42501';
  end if;
  if coalesce(trim(p_origin_address), '') = '' or coalesce(trim(p_address), '') = ''
     or coalesce(trim(p_recipient), '') = '' or coalesce(trim(p_phone), '') = '' or p_date is null then
    raise exception '출발지, 도착지, 받는 사람, 연락처, 희망일을 모두 입력해 주세요.' using errcode = '22023';
  end if;
  if p_date < (now() at time zone 'Asia/Seoul')::date then
    raise exception '이동 희망일은 오늘 이후로 골라 주세요.' using errcode = '22023';
  end if;

  insert into public.shipments (loan_no, direction, origin_name, origin_phone, origin_address,
                                recipient, phone, address, requested_date, memo, status, created_by)
  values (p_loan_no, 'move', trim(coalesce(p_origin_name, '')), trim(coalesce(p_origin_phone, '')), trim(p_origin_address),
          trim(p_recipient), trim(p_phone), trim(p_address), p_date, left(trim(coalesce(p_memo, '')), 500), 'pending', v_uid)
  returning id into v_id;

  perform private.teams_send(
    '🚚 이동 요청 ' || p_loan_no,
    array['**' || coalesce((select display_name from public.profiles where id = v_uid), '?') || '** 님이 이동 배차를 요청했어요',
          coalesce(v_cust, '') || ' · ' || to_char(p_date, 'MM/DD'),
          trim(p_origin_address) || ' → ' || trim(p_address)],
    'ship');
  return v_id;
end $$;

-- 4) 이동 취소
create or replace function public.cancel_move(p_shipment_id uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid  uuid := auth.uid();
  v_ship public.shipments%rowtype;
  v_req  uuid;
begin
  if not private.is_active() then
    raise exception '승인된 사용자만 취소할 수 있어요.' using errcode = '42501';
  end if;
  select * into v_ship from public.shipments where id = p_shipment_id for update;
  if not found or v_ship.direction <> 'move' then
    raise exception '이동 요청을 찾지 못했어요.' using errcode = '22023';
  end if;
  if private.is_admin() then
    if v_ship.status in ('delivered', 'cancelled') then
      raise exception '도착했거나 이미 취소된 이동이에요.' using errcode = '22023';
    end if;
  else
    select requester_id into v_req from public.loans
     where loan_no = v_ship.loan_no and status <> 'cancelled' order by created_at, id limit 1;
    if v_req is distinct from v_uid then
      raise exception '본인 신청의 이동만 취소할 수 있어요.' using errcode = '42501';
    end if;
    if v_ship.status <> 'pending' then
      raise exception '물류사에 이미 요청했어요. 장비 관리자에게 취소를 부탁해 주세요.' using errcode = '22023';
    end if;
  end if;
  update public.shipments set status = 'cancelled', updated_at = now() where id = p_shipment_id;
end $$;

revoke all on function public.request_move(text, text, text, text, text, text, text, date, text) from public;
grant execute on function public.request_move(text, text, text, text, text, text, text, date, text) to authenticated;
revoke all on function public.cancel_move(uuid) from public;
grant execute on function public.cancel_move(uuid) to authenticated;

-- 5) 도착 확인: 이동도 허용 (대상 글자가 없으면 멈춘다)
do $$
declare d text;
begin
  select pg_get_functiondef('public.confirm_delivery(uuid)'::regprocedure) into d;
  if position('v_ship.direction <> ''outbound''' in d) = 0 then
    raise exception 'confirm_delivery 에서 direction 검사를 찾지 못했어요. 멈춥니다.';
  end if;
  execute replace(d, 'v_ship.direction <> ''outbound''', 'v_ship.direction not in (''outbound'', ''move'')');
end $$;

-- 6) 개인정보 정리: 출발지 연락처도 지운다
do $$
declare d text;
begin
  select pg_get_functiondef('private.purge_shipping_contacts(integer)'::regprocedure) into d;
  if position('set recipient = ''(삭제됨)'', phone = '''', address = ''(삭제됨)'', memo = ''''' in d) = 0 then
    raise exception 'purge_shipping_contacts 에서 update 문장을 찾지 못했어요. 멈춥니다.';
  end if;
  execute replace(d,
    'set recipient = ''(삭제됨)'', phone = '''', address = ''(삭제됨)'', memo = ''''',
    'set recipient = ''(삭제됨)'', phone = '''', address = ''(삭제됨)'', memo = '''', origin_name = '''', origin_phone = '''', origin_address = ''''');
  -- activity_log 의 출발지 값도 지운다
  select pg_get_functiondef('private.purge_shipping_contacts(integer)'::regprocedure) into d;
  if position('detail - ''recipient'' - ''phone'' - ''address'' - ''memo''' in d) = 0 then
    raise exception 'purge_shipping_contacts 에서 activity_log 문장을 찾지 못했어요. 멈춥니다.';
  end if;
  execute replace(d, 'detail - ''recipient'' - ''phone'' - ''address'' - ''memo''',
    'detail - ''recipient'' - ''phone'' - ''address'' - ''memo'' - ''origin_name'' - ''origin_phone'' - ''origin_address''');
end $$;

commit;

-- 확인: 아래 4줄이 모두 true 이면 정상
select 'request_move' as item, exists (select 1 from pg_proc where proname = 'request_move') as ok
union all select 'cancel_move', exists (select 1 from pg_proc where proname = 'cancel_move')
union all select 'unique index', exists (select 1 from pg_indexes where indexname = 'shipments_loan_dir_one')
union all select 'on conflict patched', (select bool_and(pg_get_functiondef(p.oid) like '%where direction <> ''move'' do%')
  from pg_proc p join pg_namespace s on s.oid = p.pronamespace
  where s.nspname = 'public' and p.proname = 'update_reservation');
