-- =====================================================================
-- 마이그레이션 031 · 장비 상태 '구성품 누락'(partial) 추가
--   - equipment.status 에 'partial' 추가. 신청·출고는 막지 않는다 (화면에서 경고만).
--   - 반납 확인(done) 때 장비 상태:
--       수리 필요 판정(repair_needed)      → repair (화면 이름: 사용불가)
--       점검 결과 '구성품 누락'(missing)   → partial
--       그 밖                               → available
--   - 출고 취소(void_checkout_item) 때 최근 점검이 '구성품 누락'이면 partial 로 되돌린다.
--   - 'repair' 값은 그대로 두고, 화면 이름만 '사용불가'로 바꾼다 (DB 변경 없음).
-- 실행 위치: Supabase SQL Editor (030 실행 후 1회)
-- =====================================================================

begin;

alter table public.equipment drop constraint if exists equipment_status_check;
alter table public.equipment add constraint equipment_status_check
  check (status in ('available', 'onloan', 'inspect', 'repair', 'partial', 'retired'));

-- 반납 확인 때 판정 (대상 글자가 없으면 멈춘다)
do $$
declare d text;
begin
  select pg_get_functiondef('private.after_loan_change()'::regprocedure) into d;
  if (select count(*) from regexp_matches(d, 'else ''available'' end,', 'g')) <> 1 then
    raise exception 'after_loan_change 에서 판정 문장을 찾지 못했어요. 멈춥니다.';
  end if;
  execute replace(d, 'else ''available'' end,',
    'when new.return_condition = ''missing'' then ''partial'' else ''available'' end,');
end $$;

-- 출고 취소 때 원래 상태로 (대상 글자가 없으면 멈춘다)
do $$
declare d text;
begin
  select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'void_checkout_item';
  if (select count(*) from regexp_matches(d, 'update public.equipment set status = ''available'', updated_at = now\(\)', 'g')) <> 1 then
    raise exception 'void_checkout_item 에서 상태 문장을 찾지 못했어요. 멈춥니다.';
  end if;
  execute replace(d, 'update public.equipment set status = ''available'', updated_at = now()',
    'update public.equipment set status = case when last_check = ''missing'' then ''partial'' else ''available'' end, updated_at = now()');
end $$;

commit;

-- 확인: 3줄 모두 true 이면 정상
select 'status check' as item, (select pg_get_constraintdef(oid) like '%partial%' from pg_constraint where conname = 'equipment_status_check') as ok
union all select 'after_loan_change', (select pg_get_functiondef('private.after_loan_change()'::regprocedure) like '%then ''partial''%')
union all select 'void_checkout_item', (select pg_get_functiondef(oid) like '%then ''partial''%' from pg_proc where proname = 'void_checkout_item');
