-- =====================================================================
-- 마이그레이션 020 · 실제 반납일 수정 (장비 관리자)
--   1) loans.return_recorded_at: 반납 신청을 앱에 기록한 시각. 처음 한 번만
--      정해지고 이후에는 바뀌지 않는다. 기존 기록은 지금의 반납 시각으로 채운다.
--   2) loans.returned_at은 '실제 반납일'로 쓴다. 장비 관리자가 set_return_date로
--      고칠 수 있다 (과거 기록을 나중에 넣어서 연체로 잡힌 경우 등).
--      시각(시:분)은 기존 값을 유지하고 날짜만 바꾼다. 미래 시각이 되면 지금으로 둔다.
--      같은 신청번호의 반납된 장비에 한 번에 적용할 수 있다.
-- 실행 위치: Supabase SQL Editor (019 실행 후 1회)
-- =====================================================================

begin;

-- 1. 기록 시각
alter table public.loans add column if not exists return_recorded_at timestamptz;

update public.loans
   set return_recorded_at = returned_at
 where returned_at is not null and return_recorded_at is null;

-- 기록 시각은 반납일이 처음 생길 때 정하고, 그 뒤로는 바꾸지 않는다
create or replace function private.keep_return_recorded()
returns trigger language plpgsql set search_path = ''
as $$
begin
  if old.return_recorded_at is not null then
    new.return_recorded_at := old.return_recorded_at;
  elsif new.returned_at is not null and old.returned_at is null then
    new.return_recorded_at := now();
  else
    new.return_recorded_at := null;
  end if;
  return new;
end;
$$;
drop trigger if exists loans_keep_return_recorded on public.loans;
-- 이름 순서상 loans_guard(반납 시각을 정함) 다음에 돈다
create trigger loans_keep_return_recorded
  before update on public.loans
  for each row execute function private.keep_return_recorded();

-- 2. 실제 반납일 수정
create or replace function public.set_return_date(
  p_loan_id uuid,
  p_date    date,
  p_all     boolean default false   -- 같은 신청번호의 반납된 장비에도 적용
)
returns int
language plpgsql security definer set search_path = ''
as $$
declare
  v_l     public.loans%rowtype;
  v_today date := (now() at time zone 'Asia/Seoul')::date;
  v_n     int;
begin
  if not private.is_admin() then
    raise exception '실제 반납일은 장비 관리자만 고칠 수 있어요.' using errcode = '42501';
  end if;

  select * into v_l from public.loans where id = p_loan_id for update;
  if not found then
    raise exception '대상을 찾지 못했어요.' using errcode = '22023';
  end if;
  if v_l.status not in ('checking', 'done') or v_l.returned_at is null then
    raise exception '반납 신청을 한 장비만 반납일을 고칠 수 있어요.' using errcode = '22023';
  end if;
  if p_date is null or p_date > v_today then
    raise exception '실제 반납일은 오늘이나 그 전 날짜로 정해 주세요.' using errcode = '22023';
  end if;
  if p_date < v_l.start_date then
    raise exception '실제 반납일은 사용 시작일(%)과 같거나 그 뒤여야 해요.', to_char(v_l.start_date, 'YYYY.MM.DD') using errcode = '22023';
  end if;

  update public.loans x
     set returned_at = least(now(), (p_date + (x.returned_at at time zone 'Asia/Seoul')::time) at time zone 'Asia/Seoul')
   where (x.id = p_loan_id
          or (coalesce(p_all, false) and x.loan_no = v_l.loan_no and x.status in ('checking', 'done') and x.returned_at is not null))
     and p_date >= x.start_date;
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

revoke all on function public.set_return_date(uuid, date, boolean) from public, anon;
grant execute on function public.set_return_date(uuid, date, boolean) to authenticated;

commit;

-- 확인: 아래 값이 3이어야 해요 (기록 시각 칸 1 + 트리거 1 + 함수 1).
select (select count(*) from information_schema.columns where table_schema = 'public' and table_name = 'loans' and column_name = 'return_recorded_at')
     + (select count(*) from pg_trigger where tgname = 'loans_keep_return_recorded')
     + (select count(*) from pg_proc where proname = 'set_return_date') as ok;
