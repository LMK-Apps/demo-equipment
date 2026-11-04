-- =====================================================================
-- 마이그레이션 027 · 분류 정리: MBL → 시뮬레이터로 합치고 '비품' 추가
--   분류는 5개: 시뮬레이터 → BLS → Skill T. → 기타 → 비품
--   1) MBL 장비(Monitor by Laerdal 2대)를 '시뮬레이터'로 옮긴다
--   2) 행사·전시용 물품(LED부스, 접이식테이블, LG스탠바이미)을 '기타'에서 '비품'으로 옮긴다
--      (Servo-air ventilator는 의료기기라 '기타'에 둔다. 옮기지 않으려면 2번 update 문을 지우고 실행해 주세요)
--   3) 분류 허용 값을 새 5개로 바꾼다
-- 실행 위치: Supabase SQL Editor (026 실행 후 1회)
-- =====================================================================

begin;

alter table public.equipment drop constraint if exists equipment_category_check;

-- 1. MBL → 시뮬레이터
update public.equipment set category = '시뮬레이터' where category = 'MBL';

-- 2. 행사·전시용 물품 → 비품
update public.equipment set category = '비품'
 where category = '기타'
   and (name like 'LED부스%' or name like '접이식테이블%' or name like 'LG스탠바이미%');

-- 3. 분류 허용 값
alter table public.equipment add constraint equipment_category_check
  check (category in ('시뮬레이터', 'BLS', 'Skill T.', '기타', '비품'));

commit;

-- 확인: 분류별 장비 수 (MBL이 없고 비품이 보이면 정상)
select category, count(*) from public.equipment where status <> 'retired' group by category order by category;
