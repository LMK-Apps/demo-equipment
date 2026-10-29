-- =====================================================================
-- 마이그레이션 006 · 신청 날짜 제한
--   - 사용 시작일: 오늘(한국 시간)부터 1년 이내
--   - 대여 기간: 시작일부터 최대 1달 (예: 10/28 시작 → 11/28까지)
--   - 연장: 신청자는 시작일부터 1달까지, 관리자는 1달을 넘겨도 됨
--   - 대시보드(SQL Editor) 작업은 제한하지 않음
-- 이미 저장된 기록은 바꾸지 않는다.
-- 실행 위치: Supabase SQL Editor (005 실행 후 1회)
-- =====================================================================

create or replace function private.guard_loan_dates()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare
  v_today date := (now() at time zone 'Asia/Seoul')::date;
  v_limit date := (new.start_date + interval '1 month')::date;
begin
  if auth.uid() is null then                 -- 대시보드·서비스 키 작업
    return new;
  end if;

  if tg_op = 'INSERT' then
    if new.start_date > v_today + 365 then
      raise exception '사용 시작일은 오늘부터 1년 안으로 정해 주세요. (입력한 날짜: %)', to_char(new.start_date, 'YYYY.MM.DD')
        using errcode = '22023';
    end if;
    if new.due_date > v_limit then
      raise exception '대여 기간은 최대 1달이에요. 반납 예정일을 %까지로 정해 주세요.', to_char(v_limit, 'YYYY.MM.DD')
        using errcode = '22023';
    end if;
  elsif new.due_date is distinct from old.due_date and new.due_date > v_limit and not private.is_admin() then
    raise exception '연장은 시작일부터 1달(%)까지 할 수 있어요. 더 길게 쓰려면 장비 관리자에게 요청해 주세요.', to_char(v_limit, 'YYYY.MM.DD')
      using errcode = '22023';
  end if;
  return new;
end;
$$;

drop trigger if exists loans_date_limits on public.loans;
create trigger loans_date_limits
  before insert or update of start_date, due_date on public.loans
  for each row execute function private.guard_loan_dates();
