-- =====================================================================
-- 마이그레이션 022 · 신청 목적 정리 (2026-11-03 결정)
--   새 목적: 영업 데모 · 고객 교육·지원 · 학회·전시 · 장기 대여 · 내부 사용 · 기타
--   기존 값 옮기기:
--     고객 데모 → 영업 데모        교육·워크숍 → 고객 교육·지원
--     학회, 전시회 → 학회·전시     내부 교육 → 내부 사용
--     기타 → 메모를 보고 신청번호별로 옮김 (아래 3. 참고, 나머지는 기타 그대로)
--   예약 수정(update_reservation)·신청 정보 수정(update_loan_info) 함수의
--   목적 목록도 새 목록으로 바꾼다. (함수 본문은 그대로 두고 목록만 바꾼다)
-- 실행 위치: Supabase SQL Editor (021 실행 후 1회)
-- =====================================================================

begin;

-- 1. 옛 제약을 먼저 푼다
alter table public.loans drop constraint if exists loans_purpose_check;

-- 2. 기존 값 옮기기 (취소된 건 포함). 트리거(권한 검사·알림)는 대시보드 실행이라 건너뛴다.
update public.loans set purpose = '영업 데모'       where purpose = '고객 데모';
update public.loans set purpose = '고객 교육·지원'  where purpose = '교육·워크숍';
update public.loans set purpose = '학회·전시'       where purpose in ('학회', '전시회');
update public.loans set purpose = '내부 사용'       where purpose = '내부 교육';

-- 3. '기타' 건 중 메모로 용도가 분명한 건
update public.loans set purpose = '영업 데모'      where loan_no = 'D-LMK-2611-006' and purpose = '기타';  -- 국시원 장비평가
update public.loans set purpose = '고객 교육·지원' where loan_no = 'D-LMK-2611-008' and purpose = '기타';  -- 을지대 수리 지연 대체품
update public.loans set purpose = '고객 교육·지원' where loan_no = 'D-LMK-2611-011' and purpose = '기타';  -- 연세의료원 PALS 과정

-- 4. 새 제약
alter table public.loans add constraint loans_purpose_check
  check (purpose in ('영업 데모', '고객 교육·지원', '학회·전시', '장기 대여', '내부 사용', '기타'));

-- 5. 함수 안의 목적 목록 바꾸기
do $$
declare
  v_old text := '(''고객 데모'', ''전시회'', ''교육·워크숍'', ''학회'', ''내부 교육'', ''기타'')';
  v_new text := '(''영업 데모'', ''고객 교육·지원'', ''학회·전시'', ''장기 대여'', ''내부 사용'', ''기타'')';
  v_fn  text;
  v_def text;
begin
  foreach v_fn in array array['update_reservation', 'update_loan_info'] loop
    select pg_get_functiondef(p.oid) into v_def
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = v_fn;
    if v_def is null then
      raise exception '함수 %을(를) 찾지 못했어요.', v_fn;
    end if;
    if position(v_old in v_def) = 0 then
      raise exception '함수 %에서 옛 목적 목록을 찾지 못했어요.', v_fn;
    end if;
    execute replace(v_def, v_old, v_new);
  end loop;
end;
$$;

commit;

-- 확인: 옛 목적이 남은 기록 0건, 새 목록을 쓰는 함수 2개여야 해요.
select (select count(*) from public.loans where purpose not in ('영업 데모', '고객 교육·지원', '학회·전시', '장기 대여', '내부 사용', '기타')) as old_left,
       (select count(*) from pg_proc where proname in ('update_reservation', 'update_loan_info') and prosrc like '%장기 대여%') as fn_ok;
