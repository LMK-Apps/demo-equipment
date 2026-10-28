-- =====================================================================
-- 마이그레이션 002 · 보관 위치 확정 + 최근 점검 결과를 장비 목록에 반영
-- 실행 위치: Supabase SQL Editor (migration_001 실행 후 1회)
-- =====================================================================

-- 1. 장비: 최근 점검 결과
alter table public.equipment
  add column if not exists last_check        text check (last_check in ('ok', 'minor', 'broken', 'missing')),
  add column if not exists last_check_note   text not null default '',
  add column if not exists last_check_source text check (last_check_source in ('self', 'admin')),
  add column if not exists last_check_by     uuid references public.profiles(id),
  add column if not exists last_check_at     timestamptz;

-- 2. 출납: 관리자 점검 때 정하는 판정과 보관 위치
alter table public.loans
  add column if not exists repair_needed   boolean,   -- 관리자 판정. 비어 있으면 점검 결과로 자동 판정
  add column if not exists return_location text;      -- 관리자가 확정한 보관 위치

-- 3. 반납·점검 결과를 장비에 반영
create or replace function private.after_loan_change()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if tg_op = 'UPDATE' and new.status is distinct from old.status then
    if new.status = 'out' then
      update public.equipment set status = 'onloan', updated_at = now() where id = new.equipment_id;

    elsif new.status = 'checking' then
      -- 반납자 자가점검과 직접 반납 위치
      update public.equipment
         set status = 'inspect',
             location = case new.return_method
                          when 'drop_munjeong' then '문정'
                          when 'drop_uiwang'   then '의왕'
                          else location end,
             last_check        = coalesce(new.return_self_check, last_check),
             last_check_note   = case when new.return_self_check is not null then new.return_self_note else last_check_note end,
             last_check_source = case when new.return_self_check is not null then 'self' else last_check_source end,
             last_check_by     = case when new.return_self_check is not null then new.requester_id else last_check_by end,
             last_check_at     = case when new.return_self_check is not null then now() else last_check_at end,
             updated_at = now()
       where id = new.equipment_id;

      if new.return_method = 'pickup' or (new.return_method is null and new.delivery) then
        update public.shipments set status = 'pending', updated_at = now()
         where loan_no = new.loan_no and direction = 'pickup' and status = 'scheduled';
      elsif not exists (
        select 1 from public.loans
         where loan_no = new.loan_no and (status = 'out' or return_method = 'pickup')
      ) then
        update public.shipments set status = 'cancelled', updated_at = now()
         where loan_no = new.loan_no and direction = 'pickup' and status = 'scheduled';
      end if;

    elsif new.status = 'done' then
      -- 관리자 확인 점검: 판정, 보관 위치, 최근 점검
      update public.equipment
         set status = case
                        when coalesce(new.repair_needed, new.return_condition in ('broken', 'missing')) then 'repair'
                        else 'available' end,
             location          = coalesce(nullif(trim(new.return_location), ''), location),
             last_check        = new.return_condition,
             last_check_note   = new.return_note,
             last_check_source = 'admin',
             last_check_by     = new.checked_by,
             last_check_at     = now(),
             updated_at = now()
       where id = new.equipment_id;
    end if;
  end if;
  return null;
end;
$$;
