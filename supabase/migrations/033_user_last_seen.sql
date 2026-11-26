-- =====================================================================
-- 마이그레이션 033 · 사용자 최근 접속
--   [사용자] 화면의 '최근 접속' 열에 쓴다. 장비 관리자만 부를 수 있다.
--   최근 접속 = 아래 둘 중 늦은 시각
--     - 로그인 세션이 마지막으로 갱신된 시각 (앱이 열려 있으면 약 1시간마다 갱신)
--     - 마지막 로그인 시각 (login_log)
--   세션은 로그아웃하면 지워지므로 login_log 를 함께 본다.
-- 실행 위치: Supabase SQL Editor (032 실행 후 1회)
-- =====================================================================

create or replace function public.user_last_seen()
returns table (user_id uuid, last_seen timestamptz)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not private.is_admin() then
    raise exception '장비 관리자만 볼 수 있어요.' using errcode = '42501';
  end if;
  return query
    select p.id,
           greatest(
             (select max(greatest(s.updated_at, s.created_at)) from auth.sessions s where s.user_id = p.id),
             (select max(l.at) from public.login_log l where l.user_id = p.id)
           )
      from public.profiles p;
end $$;

revoke all on function public.user_last_seen() from public;
grant execute on function public.user_last_seen() to authenticated;

-- 확인: true 이면 정상
select 'user_last_seen' as item, exists (select 1 from pg_proc where proname = 'user_last_seen') as ok;
