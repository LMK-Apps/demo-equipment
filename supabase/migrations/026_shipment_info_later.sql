-- =====================================================================
-- 마이그레이션 026 · 배송 정보 나중에 입력
--   신청할 때 '외부 물류사 배송'만 정하고 수령인·연락처·주소·도착 희망일은 나중에 넣을 수 있게 한다.
--   1) shipments.requested_date 빈 값 허용 (수령인·연락처·주소는 원래 빈 문자열 가능)
--   2) create_loan_request, update_reservation: p_shipment에 "later": true가 있으면 필수 칸 검사를 건너뛴다.
--      빈 칸은 '' 로 저장한다. 날짜 비교는 is distinct from 으로 바꿔 빈 값에도 맞게 한다.
--   3) notify_new_loan: 도착 희망일이 없으면 '배송 정보 나중에 입력'으로 알린다.
--   기존 함수 본문을 그대로 읽어 필요한 줄만 바꾼다(replace). 바꿀 곳을 못 찾으면 멈춘다.
-- 실행 위치: Supabase SQL Editor (025 실행 후 1회)
-- =====================================================================

begin;

alter table public.shipments alter column requested_date drop not null;

do $$
declare
  d text;
  n int;
  later constant text := 'if p_shipment is not null and not coalesce((p_shipment ->> ''later'')::boolean, false) and (';
begin
  -- 1. create_loan_request
  d := pg_get_functiondef('public.create_loan_request(uuid[],date,date,text,text,text,text,text,jsonb,uuid,boolean)'::regprocedure);
  if position('if p_shipment is not null and (' in d) = 0 then raise exception '026: create_loan_request 검사 줄을 찾지 못했어요.'; end if;
  d := replace(d, 'if p_shipment is not null and (', later);
  d := replace(d, 'trim(p_shipment ->> ''recipient'')', 'coalesce(trim(p_shipment ->> ''recipient''), '''')');
  d := replace(d, 'trim(p_shipment ->> ''phone'')',     'coalesce(trim(p_shipment ->> ''phone''), '''')');
  d := replace(d, 'trim(p_shipment ->> ''address'')',   'coalesce(trim(p_shipment ->> ''address''), '''')');
  execute d;

  -- 2. update_reservation
  d := pg_get_functiondef('public.update_reservation(text,uuid[],date,date,text,text,text,text,text,jsonb)'::regprocedure);
  if position('if p_shipment is not null and (' in d) = 0 then raise exception '026: update_reservation 검사 줄을 찾지 못했어요.'; end if;
  d := replace(d, 'if p_shipment is not null and (', later);
  d := replace(d, 'trim(p_shipment ->> ''recipient'')', 'coalesce(trim(p_shipment ->> ''recipient''), '''')');
  d := replace(d, 'trim(p_shipment ->> ''phone'')',     'coalesce(trim(p_shipment ->> ''phone''), '''')');
  d := replace(d, 'trim(p_shipment ->> ''address'')',   'coalesce(trim(p_shipment ->> ''address''), '''')');
  d := replace(d, '<> v_out.recipient', 'is distinct from v_out.recipient');
  d := replace(d, '<> v_out.phone', 'is distinct from v_out.phone');
  d := replace(d, '<> v_out.address', 'is distinct from v_out.address');
  d := replace(d, '<> v_out.requested_date', 'is distinct from v_out.requested_date');
  d := replace(d, 'to_char((p_shipment ->> ''date'')::date, ''MM/DD'') || '' 도착 희망''',
                  'coalesce(to_char((p_shipment ->> ''date'')::date, ''MM/DD'') || '' 도착 희망'', ''배송 정보 나중에 입력'')');
  execute d;

  -- 3. notify_new_loan
  d := pg_get_functiondef('private.notify_new_loan()'::regprocedure);
  n := position('to_char(v_ship.requested_date, ''MM/DD'') || '' 도착 희망 · 물류사 요청 메일을 보내 주세요''' in d);
  if n = 0 then raise exception '026: notify_new_loan 알림 줄을 찾지 못했어요.'; end if;
  d := replace(d, 'to_char(v_ship.requested_date, ''MM/DD'') || '' 도착 희망 · 물류사 요청 메일을 보내 주세요''',
                  'coalesce(to_char(v_ship.requested_date, ''MM/DD'') || '' 도착 희망'', ''배송 정보 나중에 입력'') || '' · 물류 요청 메시지를 보내 주세요''');
  execute d;
end $$;

commit;

-- 확인: later 검사가 들어간 함수 2개와 YES 한 줄이 보이면 정상
select p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname in ('create_loan_request', 'update_reservation') and p.prosrc like '%''later''%';
select is_nullable from information_schema.columns
 where table_schema = 'public' and table_name = 'shipments' and column_name = 'requested_date';
