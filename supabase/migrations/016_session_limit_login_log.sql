-- =====================================================================
-- 마이그레이션 016 · 기기 2대까지 로그인 + 관리자용 로그인 기록
--   1) 한 계정은 동시에 2대까지 로그인한다. 3번째 기기로 로그인하면 가장 오래된 로그인을 끊는다.
--      끊긴 기기는 앱을 열거나 1분마다 확인할 때 로그아웃된다.
--   2) 로그인할 때마다 시각과 기기 정보(브라우저가 알려 주는 기기·브라우저 이름)를 남긴다.
--      IP 주소는 남기지 않는다. 기록은 장비 관리자만 보고, 90일이 지나면 지운다.
--   앱이 로그인 직후 public.session_check()를 부른다. 로그인 시스템(auth) 표에는 트리거를 달지 않는다.
-- 실행 위치: Supabase SQL Editor (015 실행 후 1회)
-- =====================================================================

begin;

-- 1. 로그인 기록
create table if not exists public.login_log (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references public.profiles(id) on delete cascade,
  session_id uuid not null unique,
  at         timestamptz not null default now(),
  user_agent text not null default '',
  kicked     int  not null default 0          -- 이 로그인 때문에 끊긴 다른 로그인 수
);
create index if not exists login_log_user_at_idx on public.login_log (user_id, at desc);

alter table public.login_log enable row level security;
revoke all on public.login_log from anon, authenticated;
grant select on public.login_log to authenticated;
drop policy if exists login_log_select on public.login_log;
create policy login_log_select on public.login_log for select to authenticated
  using ((select private.is_admin()));

-- 2. 로그인 확인
--    'revoked' : 이 로그인은 끊겼다 (다른 기기 때문). 앱은 로그아웃한다.
--    'new'     : 새 로그인. 기록을 남기고 2대를 넘는 오래된 로그인을 끊었다.
--    'ok'      : 이미 확인한 로그인.
create or replace function public.session_check()
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid    uuid := auth.uid();
  v_sid    uuid := nullif(auth.jwt() ->> 'session_id', '')::uuid;
  v_ua     text;
  v_kicked int := 0;
begin
  if v_uid is null or v_sid is null then
    return jsonb_build_object('status', 'ok');        -- 확인할 수 없는 경우는 막지 않는다
  end if;

  select coalesce(user_agent, '') into v_ua from auth.sessions where id = v_sid and user_id = v_uid;
  if not found then
    return jsonb_build_object('status', 'revoked');
  end if;

  if exists (select 1 from public.login_log where session_id = v_sid) then
    return jsonb_build_object('status', 'ok');
  end if;

  -- 지금 로그인과 가장 최근 로그인 1개만 남기고 끊는다 (refresh token은 함께 지워진다)
  with keep as (
    select id from auth.sessions
     where user_id = v_uid
     order by (id = v_sid) desc, created_at desc
     limit 2
  ), gone as (
    delete from auth.sessions s
     where s.user_id = v_uid and s.id not in (select id from keep)
    returning 1
  )
  select count(*) into v_kicked from gone;

  if exists (select 1 from public.profiles where id = v_uid) then
    insert into public.login_log (user_id, session_id, user_agent, kicked)
    values (v_uid, v_sid, left(v_ua, 300), v_kicked)
    on conflict (session_id) do nothing;
  end if;

  return jsonb_build_object('status', 'new', 'kicked', v_kicked);
end;
$$;

revoke all on function public.session_check() from public, anon;
grant execute on function public.session_check() to authenticated;

-- 3. 90일 지난 로그인 기록 지우기 (매일 04:10 한국 시간)
create or replace function private.purge_login_log(p_days int default 90)
returns int language sql security definer set search_path = ''
as $$
  with d as (delete from public.login_log where at < now() - make_interval(days => greatest(p_days, 1)) returning 1)
  select count(*)::int from d
$$;
revoke all on function private.purge_login_log(int) from public, anon, authenticated;

select cron.unschedule(jobid) from cron.job where jobname = 'demo-purge-login-log';
select cron.schedule('demo-purge-login-log', '10 19 * * *', 'select private.purge_login_log(90)');

commit;

-- 확인: 아래 값이 true여야 다른 기기 로그인을 끊을 수 있어요. false면 결과를 알려 주세요.
select has_table_privilege('auth.sessions', 'DELETE') as can_end_other_sessions;
