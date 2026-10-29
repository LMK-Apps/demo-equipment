-- =====================================================================
-- 마이그레이션 008 · 반납 신청 때 회수 정보 수정
--   - 같은 신청번호에 회수 정보가 이미 있어도(배송 신청 때 만든 것 등),
--     물류사에 요청하기 전(회수 예정·회수 요청 전·회수 취소)이면 반납자가
--     담당자, 연락처, 회수 주소, 희망일, 메모를 고칠 수 있다.
--   - 물류사에 이미 요청했거나 회수가 끝났으면 바꾸지 않는다.
-- 실행 위치: Supabase SQL Editor (007 실행 후 1회)
-- =====================================================================

create or replace function public.request_return(
  p_loan_id    uuid,
  p_method     text,
  p_self_check text,
  p_self_note  text  default '',
  p_pickup     jsonb default null,
  p_place      text  default null
)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid  uuid := auth.uid();
  v_loan public.loans%rowtype;
  v_ship public.shipments%rowtype;
  v_place text;
begin
  if not private.is_active() then
    raise exception '승인된 사용자만 반납을 신청할 수 있어요.' using errcode = '42501';
  end if;

  select * into v_loan from public.loans where id = p_loan_id for update;
  if not found then
    raise exception '신청 기록을 찾지 못했어요.' using errcode = '22023';
  end if;
  if v_loan.requester_id <> v_uid and not private.is_admin() then
    raise exception '본인 신청만 반납할 수 있어요.' using errcode = '42501';
  end if;
  if v_loan.status <> 'out' then
    raise exception '출고된 장비만 반납할 수 있어요.' using errcode = '22023';
  end if;
  if p_method is null or p_method not in ('drop_munjeong', 'drop_uiwang', 'pickup') then
    raise exception '반납 방법을 골라 주세요.' using errcode = '22023';
  end if;

  -- 반납 장소: 직접 반납은 방법에서 정해지고, 물류사 회수는 p_place로 받는다
  v_place := case p_method when 'drop_uiwang' then '의왕' when 'drop_munjeong' then '문정' else p_place end;
  if v_place is null or v_place not in ('의왕', '문정') then
    raise exception '반납 장소(의왕 또는 문정)를 골라 주세요.' using errcode = '22023';
  end if;

  if p_method = 'pickup' then
    select * into v_ship from public.shipments
     where loan_no = v_loan.loan_no and direction = 'pickup' for update;
    if found then
      -- 물류사에 아직 요청하기 전이면 회수 정보(담당자, 연락처, 주소, 희망일, 메모)를 고칠 수 있다.
      -- 빈 값으로 보내면 기존 값을 그대로 둔다.
      if v_ship.status in ('scheduled', 'cancelled', 'pending') then
        update public.shipments
           set status = 'pending',
               recipient = coalesce(nullif(trim(p_pickup ->> 'recipient'), ''), recipient),
               phone     = coalesce(nullif(trim(p_pickup ->> 'phone'), ''), phone),
               address   = coalesce(nullif(trim(p_pickup ->> 'address'), ''), address),
               memo      = case when p_pickup ? 'memo' then coalesce(trim(p_pickup ->> 'memo'), '') else memo end,
               requested_date = coalesce((p_pickup ->> 'date')::date, requested_date),
               updated_at = now()
         where id = v_ship.id;
      end if;
    else
      if p_pickup is null
         or coalesce(trim(p_pickup ->> 'recipient'), '') = ''
         or coalesce(trim(p_pickup ->> 'phone'), '') = ''
         or coalesce(trim(p_pickup ->> 'address'), '') = ''
         or (p_pickup ->> 'date') is null then
        raise exception '회수를 요청하려면 담당자, 연락처, 회수 주소, 회수 희망일을 입력해 주세요.' using errcode = '22023';
      end if;
      insert into public.shipments (loan_no, direction, recipient, phone, address, requested_date, memo, status, created_by)
      values (v_loan.loan_no, 'pickup', trim(p_pickup ->> 'recipient'), trim(p_pickup ->> 'phone'),
              trim(p_pickup ->> 'address'), (p_pickup ->> 'date')::date,
              coalesce(p_pickup ->> 'memo', ''), 'pending', v_uid);
    end if;
  end if;

  update public.loans
     set status = 'checking',
         return_method = p_method,
         return_self_check = p_self_check,
         return_self_note = coalesce(p_self_note, ''),
         return_place = v_place
   where id = p_loan_id;
end;
$$;

revoke all on function public.request_return(uuid, text, text, text, jsonb, text) from public, anon;
grant execute on function public.request_return(uuid, text, text, text, jsonb, text) to authenticated;
