-- =====================================================================
-- 마이그레이션 019 · 장비 모델(묶음 이름)
--   장비 목록과 신청 화면은 같은 모델을 한 줄로 묶어 보여 준다.
--   모델 칸이 비어 있으면 제품명으로 묶는다. 제품명이 달라도 같은 모델로
--   묶고 싶으면 모델 칸에 같은 이름을 넣는다 (예: 토르소·AED 버전).
--   RA1~RA4는 'Resusci Anne QCPR'로 묶는다.
-- 실행 위치: Supabase SQL Editor (018 실행 후 1회)
-- =====================================================================

begin;

alter table public.equipment add column if not exists model text not null default '';

update public.equipment
   set model = 'Resusci Anne QCPR'
 where internal_id in ('EQ-0016', 'EQ-0017', 'EQ-0018', 'EQ-0019')
   and model = '';

commit;

-- 확인: 아래 값이 4여야 해요 (RA1~RA4).
select count(*) as ok from public.equipment where model = 'Resusci Anne QCPR';
