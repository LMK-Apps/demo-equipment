-- =====================================================================
-- 마이그레이션 025 · 화물 배차 정보
--   shipments에 배차 정보(dispatch, jsonb)를 더한다. 장비 관리자가 [물류] 탭과 출고 창에서 입력한다.
--   키: depart_time(출발 시간), office(사무실 이름), office_name(사무실 담당자), office_phone(담당자 연락처),
--       arrive_time(도착 시간), extra_items(추가 물품), vehicle(차량 정보), handler(출고·입고자 확인)
--   배송(outbound)은 사무실 → 고객, 회수(pickup)는 고객 → 사무실이다.
-- 실행 위치: Supabase SQL Editor (024 실행 후 1회)
-- =====================================================================

begin;

alter table public.shipments add column if not exists dispatch jsonb not null default '{}'::jsonb;

commit;

-- 확인: dispatch 한 줄이 보이면 정상
select column_name, data_type, column_default from information_schema.columns
 where table_schema = 'public' and table_name = 'shipments' and column_name = 'dispatch';
