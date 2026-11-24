-- =====================================================================
-- 마이그레이션 032 · 공지사항
--   현황(메인) 화면 위쪽에 공지를 보여 준다. 장비 관리자만 쓰고 고치고 지운다.
--   - level: info(공지) / important(중요, 빨간 배지)
--   - pinned: 맨 위 고정
--   - starts_on ~ ends_on: 게시 기간 (ends_on 이 비면 계속 게시)
-- 실행 위치: Supabase SQL Editor (031 실행 후 1회)
-- =====================================================================

begin;

create table if not exists public.notices (
  id          uuid primary key default gen_random_uuid(),
  title       text not null check (length(trim(title)) between 1 and 100),
  body        text not null default '' check (length(body) <= 2000),
  level       text not null default 'info' check (level in ('info', 'important')),
  pinned      boolean not null default false,
  starts_on   date not null default ((now() at time zone 'Asia/Seoul')::date),
  ends_on     date,
  created_by  uuid references public.profiles(id) default auth.uid(),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  check (ends_on is null or ends_on >= starts_on)
);

alter table public.notices enable row level security;

drop policy if exists notices_select on public.notices;
create policy notices_select on public.notices for select to authenticated
  using ((select private.is_admin()) or (select private.is_active()));

drop policy if exists notices_insert on public.notices;
create policy notices_insert on public.notices for insert to authenticated
  with check ((select private.is_admin()));

drop policy if exists notices_update on public.notices;
create policy notices_update on public.notices for update to authenticated
  using ((select private.is_admin())) with check ((select private.is_admin()));

drop policy if exists notices_delete on public.notices;
create policy notices_delete on public.notices for delete to authenticated
  using ((select private.is_admin()));

grant select, insert, update, delete on public.notices to authenticated;

drop trigger if exists notices_touch on public.notices;
create trigger notices_touch before update on public.notices
  for each row execute function private.touch_updated_at();

drop trigger if exists notices_log on public.notices;
create trigger notices_log after insert or update or delete on public.notices
  for each row execute function private.log_change();

commit;

-- 확인: 2줄 모두 true 이면 정상
select 'notices table' as item, exists (select 1 from information_schema.tables where table_schema = 'public' and table_name = 'notices') as ok
union all select 'rls on', (select relrowsecurity from pg_class where oid = 'public.notices'::regclass);
