-- =====================================================================
-- 마이그레이션 024 · 출고 메모
--   장비 관리자가 출고할 때 남기는 메모(선택) 칸을 loans에 더한다.
--   예: "충전기 빠짐", "외관 흠집 사진 찍어 둠"
--   신청자는 이 칸을 바꿀 수 없다 (기존 guard_loan_update가 막음).
-- 실행 위치: Supabase SQL Editor (023 실행 후 1회)
-- =====================================================================

begin;

alter table public.loans add column if not exists checkout_note text;

commit;

-- 확인: checkout_note 한 줄이 보이면 정상
select column_name, data_type from information_schema.columns
 where table_schema = 'public' and table_name = 'loans' and column_name = 'checkout_note';
