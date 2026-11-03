-- =====================================================================
-- 마이그레이션 023 · 연체 장비 보호
--   1) 출고 차단: 같은 장비의 앞 신청이 '출고' 또는 '반납 확인 중'이면
--      뒤 예약을 '출고'로 바꿀 수 없다. (앞 건 반납 확인 전에 장비가 이중 출고되는 것을 막음)
--   2) 신청 차단: 연체 중인 장비(출고 상태이고 반납 예정일이 지남)는
--      오늘 이후 기간으로 새로 예약·등록할 수 없다.
--   기존 함수는 고치지 않고 트리거 2개만 더한다.
-- 실행 위치: Supabase SQL Editor (022 실행 후 1회)
-- =====================================================================

begin;

-- 1. 앞 신청이 끝나지 않은 장비는 출고 불가
create or replace function private.block_checkout_if_busy()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if exists (
    select 1 from public.loans x
     where x.equipment_id = new.equipment_id
       and x.id <> new.id
       and x.status in ('out', 'checking')
  ) then
    raise exception '앞 신청이 아직 반납 확인 전이에요. 그 신청의 반납을 먼저 처리해 주세요.' using errcode = '22023';
  end if;
  return new;
end $$;

drop trigger if exists loans_block_checkout_busy on public.loans;
create trigger loans_block_checkout_busy
  before update of status on public.loans
  for each row
  when (old.status = 'reserved' and new.status = 'out')
  execute function private.block_checkout_if_busy();

-- 2. 연체 중인 장비는 새로 신청 불가
create or replace function private.block_request_if_overdue()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_today date := (now() at time zone 'Asia/Seoul')::date;
begin
  if new.status in ('reserved', 'out') and new.due_date >= v_today and exists (
    select 1 from public.loans x
     where x.equipment_id = new.equipment_id
       and x.id <> new.id
       and x.status = 'out'
       and x.due_date < v_today
  ) then
    raise exception '이 장비는 연체 중이라 아직 신청할 수 없어요. 같은 모델의 다른 장비를 골라 주세요.' using errcode = '22023';
  end if;
  return new;
end $$;

drop trigger if exists loans_block_request_overdue on public.loans;
create trigger loans_block_request_overdue
  before insert on public.loans
  for each row
  execute function private.block_request_if_overdue();

commit;

-- 확인: 트리거 2개가 보이면 정상
select tgname from pg_trigger
 where tgrelid = 'public.loans'::regclass and tgname in ('loans_block_checkout_busy', 'loans_block_request_overdue');
