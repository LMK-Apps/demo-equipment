-- =====================================================================
-- 마이그레이션 003 · 카카오 닉네임을 표시 이름과 따로 보관
-- 실행 위치: Supabase SQL Editor (002 실행 후 1회)
-- =====================================================================

-- 1. 열 추가와 기존 사용자 채우기
alter table public.profiles
  add column if not exists kakao_name text not null default '';

update public.profiles p
   set kakao_name = coalesce(u.raw_user_meta_data ->> 'name',
                             u.raw_user_meta_data ->> 'full_name',
                             u.raw_user_meta_data ->> 'preferred_username',
                             u.raw_user_meta_data ->> 'user_name',
                             '')
  from auth.users u
 where u.id = p.id;

-- 2. 첫 로그인: 표시 이름과 카카오 이름을 같이 저장
create or replace function private.handle_new_user()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare
  v_name text := coalesce(new.raw_user_meta_data ->> 'name',
                          new.raw_user_meta_data ->> 'full_name',
                          new.raw_user_meta_data ->> 'preferred_username',
                          new.raw_user_meta_data ->> 'user_name',
                          '');
begin
  insert into public.profiles (id, display_name, kakao_name) values (new.id, v_name, v_name);
  return new;
end;
$$;

-- 3. 다시 로그인할 때 카카오 닉네임이 바뀌었으면 갱신 (표시 이름은 그대로)
create or replace function private.sync_kakao_name()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare
  v_name text := coalesce(new.raw_user_meta_data ->> 'name',
                          new.raw_user_meta_data ->> 'full_name',
                          new.raw_user_meta_data ->> 'preferred_username',
                          new.raw_user_meta_data ->> 'user_name',
                          '');
begin
  update public.profiles set kakao_name = v_name
   where id = new.id and kakao_name is distinct from v_name;
  return new;
end;
$$;

drop trigger if exists on_auth_user_updated on auth.users;
create trigger on_auth_user_updated
  after update of raw_user_meta_data on auth.users
  for each row execute function private.sync_kakao_name();

-- 4. 앱에서는 카카오 이름을 고칠 수 없게 (관리자 포함)
create or replace function private.guard_profile_update()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if auth.uid() is null then          -- 로그인 처리, 대시보드, 서비스 키 작업
    return new;
  end if;
  new.kakao_name := old.kakao_name;
  if new.id <> old.id then
    raise exception '사용자 ID는 바꿀 수 없어요.' using errcode = '42501';
  end if;
  if new.id = auth.uid() and (new.role <> old.role or new.status <> old.status) then
    raise exception '본인의 역할이나 상태는 바꿀 수 없어요. 다른 관리자에게 요청해 주세요.' using errcode = '42501';
  end if;
  if new.status = 'active' and old.status <> 'active' then
    new.approved_by := auth.uid();
    new.approved_at := now();
  end if;
  return new;
end;
$$;

-- 확인용: 이름 두 개가 같이 보이면 성공
select display_name as 표시_이름, kakao_name as 카카오_이름, role, status from public.profiles order by created_at;
