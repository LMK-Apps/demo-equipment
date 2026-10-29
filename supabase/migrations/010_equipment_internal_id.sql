-- =====================================================================
-- 마이그레이션 010 · 장비 내부 ID
--   - 장비마다 바뀌지 않는 내부 ID(EQ-0001 형식)를 붙인다.
--   - 자산번호·제품명·위치 등 다른 정보가 바뀌어도 내부 ID는 그대로다.
--   - 새 장비는 등록할 때 자동으로 다음 번호를 받는다. 누구도(관리자 포함) 바꿀 수 없다.
--   - 기존 장비는 등록 순서대로 EQ-0001부터 붙인다.
--   - 장비를 지워도 그 번호는 다시 쓰지 않는다.
-- 실행 위치: Supabase SQL Editor (009 실행 후 1회)
-- =====================================================================

create sequence if not exists private.equipment_internal_seq;

alter table public.equipment add column if not exists internal_id text;

-- 기존 장비: 등록 순서대로 번호 붙이기
with ordered as (
  select id, row_number() over (order by created_at, asset_no) as n
    from public.equipment
   where internal_id is null
)
update public.equipment e
   set internal_id = 'EQ-' || lpad((o.n + coalesce((select max(substr(internal_id, 4)::int) from public.equipment where internal_id ~ '^EQ-[0-9]+$'), 0))::text, 4, '0')
  from ordered o
 where e.id = o.id;

select setval('private.equipment_internal_seq',
              greatest(coalesce((select max(substr(internal_id, 4)::int) from public.equipment where internal_id ~ '^EQ-[0-9]+$'), 0), 1),
              (select count(*) > 0 from public.equipment));

alter table public.equipment alter column internal_id set not null;
alter table public.equipment drop constraint if exists equipment_internal_id_key;
alter table public.equipment add constraint equipment_internal_id_key unique (internal_id);

-- 등록 때 자동 발급, 수정 때 원래 값 유지
create or replace function private.guard_equipment_internal_id()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    new.internal_id := 'EQ-' || lpad(nextval('private.equipment_internal_seq')::text, 4, '0');
  else
    new.internal_id := old.internal_id;
  end if;
  return new;
end;
$$;

drop trigger if exists equipment_internal_id on public.equipment;
create trigger equipment_internal_id
  before insert or update on public.equipment
  for each row execute function private.guard_equipment_internal_id();
