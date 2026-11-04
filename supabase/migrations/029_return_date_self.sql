-- =====================================================================
-- 마이그레이션 029 · 반납 신청 때 실제 반납일 입력
--   request_return_bulk에 p_returned_on(date, 선택)을 더한다.
--   비우거나 오늘이면 지금처럼 '지금 시각'이 반납일이다.
--   오늘보다 앞 날짜면 그 날짜(지금 시각의 시:분)로 실제 반납일을 기록한다.
--   앱에 기록한 시각(return_recorded_at)은 그대로 남아 차이를 볼 수 있다.
--   기존 함수 본문을 읽어 머리(인자)와 알림 앞부분만 바꾼다. 못 찾으면 멈춘다.
-- 실행 위치: Supabase SQL Editor (028 실행 후 1회)
-- =====================================================================

begin;

do $$
declare
  d text;
  head_old constant text := 'p_place text DEFAULT NULL::text)';
  mark constant text := '-- Teams 알림 1건';
  block constant text :=
'-- 실제 반납일 (앞 날짜로 반납한 경우)
  if p_returned_on is not null and p_returned_on <> (now() at time zone ''Asia/Seoul'')::date then
    if p_returned_on > (now() at time zone ''Asia/Seoul'')::date then
      raise exception ''실제 반납일은 오늘이나 그 전 날짜로 정해 주세요.'' using errcode = ''22023'';
    end if;
    if exists (select 1 from public.loans where id = any(v_ids) and start_date > p_returned_on) then
      raise exception ''실제 반납일은 사용 시작일과 같거나 그 뒤여야 해요.'' using errcode = ''22023'';
    end if;
    perform set_config(''app.loan_edit'', ''1'', true);
    update public.loans
       set returned_at = least(now(), (p_returned_on + (now() at time zone ''Asia/Seoul'')::time) at time zone ''Asia/Seoul'')
     where id = any(v_ids);
    perform set_config(''app.loan_edit'', '''', true);
  end if;

  ';
begin
  d := pg_get_functiondef('public.request_return_bulk(jsonb,text,jsonb,text)'::regprocedure);
  if position(head_old in d) = 0 or position(mark in d) = 0 then
    raise exception '029: request_return_bulk에서 바꿀 곳을 찾지 못했어요.';
  end if;
  d := replace(d, head_old, 'p_place text DEFAULT NULL::text, p_returned_on date DEFAULT NULL::date)');
  d := replace(d, mark, block || mark);
  drop function public.request_return_bulk(jsonb, text, jsonb, text);
  execute d;
end $$;

revoke all on function public.request_return_bulk(jsonb, text, jsonb, text, date) from public, anon;
grant execute on function public.request_return_bulk(jsonb, text, jsonb, text, date) to authenticated;

commit;

-- 확인: 인자가 5개(p_returned_on 포함)로 보이면 정상
select pg_get_function_identity_arguments(p.oid) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname = 'request_return_bulk';
