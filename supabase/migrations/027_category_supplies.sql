-- =====================================================================
-- 마이그레이션 027 · 분류 '비품' 추가
--   1) equipment.category에 '비품'을 허용한다. 순서: 시뮬레이터 → BLS → MBL → Skill T. → 비품 → 기타
--   2) 지금 '기타'에 있는 행사·전시용 물품을 '비품'으로 옮긴다.
--      (LED부스, 접이식테이블, LG스탠바이미. Servo-air ventilator는 의료기기라 '기타'에 둔다)
--      옮기지 않으려면 2번 update 문을 지우고 실행해 주세요.
-- 실행 위치: Supabase SQL Editor (026 실행 후 1회)
-- =====================================================================

begin;

-- 1. 분류 허용 값
alter table public.equipment drop constraint if exists equipment_category_check;
alter table public.equipment add constraint equipment_category_check
  check (category in ('시뮬레이터', 'BLS', 'MBL', 'Skill T.', '비품', '기타'));

-- 2. 행사·전시용 물품을 비품으로
update public.equipment set category = '비품'
 where category = '기타'
   and (name like 'LED부스%' or name like '접이식테이블%' or name like 'LG스탠바이미%');

commit;

-- 확인: 분류별 장비 수
select category, count(*) from public.equipment where status <> 'retired' group by category order by category;
