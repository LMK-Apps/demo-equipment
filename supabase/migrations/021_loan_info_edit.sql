-- =====================================================================
-- 마이그레이션 021 · 출고 뒤 신청 정보 수정 (장비 관리자)
--   예약 수정은 출고 전에만 된다. 출고·반납 확인 중·반납 완료인 신청도
--   장비 관리자는 신청 정보를 고칠 수 있게 한다.
--   고칠 수 있는 값: 신청자, 사용 기간(시작일·반납 예정일), 목적, 고객사,
--   내부·외부 요청자, 메모. 같은 신청번호의 장비(취소 제외)에 모두 적용한다.
--   장비 구성은 [장비 추가]·[등록 취소]로, 배송 정보는 물류사 흐름으로 바꾼다.
--   바뀐 내용은 Teams로 1건 알린다.
-- 실행 위치: Supabase SQL Editor (020 실행 후 1회)
-- =====================================================================

begin;

create or replace function public.update_loan_info(
  p_loan_no   text,
  p_requester uuid,
  p_start     date,
  p_due       date,
  p_purpose   text,
  p_customer  text default '',
  p_internal  text default '',
  p_external  text default '',
  p_note      text default ''
)
returns int
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid     uuid := auth.uid();
  v_today   date := (now() at time zone 'Asia/Seoul')::date;
  v_first   public.loans%rowtype;
  v_changes text[] := '{}';
  v_n       int;
  v_name    text;
begin
  if not private.is_admin() then
    raise exception '출고된 신청의 정보는 장비 관리자만 고칠 수 있어요.' using errcode = '42501';
  end if;

  perform 1 from public.loans where loan_no = p_loan_no for update;
  select * into v_first from public.loans
   where loan_no = p_loan_no and status <> 'cancelled'
   order by created_at, id limit 1;
  if not found then
    raise exception '고칠 신청을 찾지 못했어요.' using errcode = '22023';
  end if;

  if p_requester is null or not exists (select 1 from public.profiles where id = p_requester and status = 'active') then
    raise exception '신청자는 사용 중인 사용자 중에서 골라 주세요.' using errcode = '22023';
  end if;
  if p_start is null or p_due is null or p_due < p_start then
    raise exception '반납 예정일은 사용 시작일과 같거나 그 뒤여야 해요.' using errcode = '22023';
  end if;
  if p_start < v_today - 365 or p_start > v_today + 365 then
    raise exception '사용 시작일은 오늘 기준 1년 안으로 정해 주세요.' using errcode = '22023';
  end if;
  if exists (select 1 from public.loans where loan_no = p_loan_no and status in ('out', 'checking', 'done')) and p_start > v_today then
    raise exception '이미 출고된 신청이라 사용 시작일을 오늘 뒤로 정할 수 없어요.' using errcode = '22023';
  end if;
  if p_purpose is null or p_purpose not in ('고객 데모', '전시회', '교육·워크숍', '학회', '내부 교육', '기타') then
    raise exception '목적을 골라 주세요.' using errcode = '22023';
  end if;

  -- 바뀐 내용 (알림용)
  if v_first.requester_id <> p_requester then
    select display_name into v_name from public.profiles where id = p_requester;
    v_changes := v_changes || ('신청자 → **' || coalesce(v_name, '?') || '**');
  end if;
  if v_first.start_date <> p_start or v_first.due_date <> p_due then
    v_changes := v_changes || ('기간 ' || to_char(v_first.start_date, 'MM/DD') || '~' || to_char(v_first.due_date, 'MM/DD')
                               || ' → **' || to_char(p_start, 'MM/DD') || '~' || to_char(p_due, 'MM/DD') || '**');
  end if;
  if v_first.purpose <> p_purpose or v_first.customer <> coalesce(trim(p_customer), '')
     or v_first.internal_requester <> coalesce(trim(p_internal), '') or v_first.external_requester <> coalesce(trim(p_external), '')
     or v_first.note <> coalesce(trim(p_note), '') then
    v_changes := v_changes || ('사용 정보: ' || p_purpose || case when coalesce(trim(p_customer), '') <> '' then ' · ' || trim(p_customer) else '' end);
  end if;
  if cardinality(v_changes) = 0 then
    return 0;
  end if;

  -- 권한·값은 위에서 검사했다. 연장 알림과 연장 횟수 계산은 건너뛴다.
  perform set_config('app.loan_edit', '1', true);
  begin
    update public.loans
       set requester_id = p_requester, start_date = p_start, due_date = p_due, purpose = p_purpose,
           customer = coalesce(trim(p_customer), ''), internal_requester = coalesce(trim(p_internal), ''),
           external_requester = coalesce(trim(p_external), ''), note = coalesce(trim(p_note), '')
     where loan_no = p_loan_no and status <> 'cancelled';
    get diagnostics v_n = row_count;
  exception when exclusion_violation then
    raise exception '바꾼 기간에 같은 장비의 다른 예약이 있어요. 기간을 바꾸거나 그 예약을 먼저 정리해 주세요.' using errcode = '23P01';
  end;

  perform private.teams_send(
    '✏️ 신청 정보 수정 ' || p_loan_no,
    array['처리: ' || coalesce((select display_name from public.profiles where id = v_uid), '?') || ' · 장비 ' || v_n || '대'] || v_changes,
    'ledger'
  );
  return v_n;
end;
$$;

revoke all on function public.update_loan_info(text, uuid, date, date, text, text, text, text, text) from public, anon;
grant execute on function public.update_loan_info(text, uuid, date, date, text, text, text, text, text) to authenticated;

commit;

-- 확인: 아래 값이 1이어야 해요.
select count(*) as ok from pg_proc where proname = 'update_loan_info';
