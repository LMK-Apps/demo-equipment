-- =====================================================================
-- 마이그레이션 012 · Teams 알림 문구: '새 출납 신청' → '새 데모 신청'
--   - 앱 메뉴 이름(데모 신청)과 알림 제목을 맞춘다.
--   - 알림 함수 notify_new_loan 하나만 바꾼다. 나머지는 011과 같다.
-- 실행 위치: Supabase SQL Editor (011 실행 후 1회)
-- =====================================================================

create or replace function private.notify_new_loan()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare
  v_first uuid;
  v_items text;
  v_cnt   int;
  v_ship  public.shipments%rowtype;
begin
  select id into v_first from public.loans where loan_no = new.loan_no order by id limit 1;
  if v_first is distinct from new.id then
    return null;                              -- 묶음의 첫 행에서만 보낸다
  end if;

  select string_agg(e.name || ' (' || e.internal_id || ')', ', ' order by e.internal_id), count(*)
    into v_items, v_cnt
    from public.loans l join public.equipment e on e.id = l.equipment_id
   where l.loan_no = new.loan_no;
  select * into v_ship from public.shipments where loan_no = new.loan_no and direction = 'outbound';

  perform private.teams_send(
    '📦 새 데모 신청 ' || new.loan_no,
    array_remove(array[
      '**' || coalesce((select display_name from public.profiles where id = new.requester_id), '?') || '** · 장비 ' || v_cnt || '대',
      v_items,
      '기간 ' || to_char(new.start_date, 'MM/DD') || ' ~ ' || to_char(new.due_date, 'MM/DD') || ' · ' || new.purpose
        || case when new.customer <> '' then ' · ' || new.customer else '' end,
      case when new.internal_requester <> '' or new.external_requester <> ''
           then '요청자 ' || concat_ws(' · ', nullif('내부 ' || new.internal_requester, '내부 '), nullif('외부 ' || new.external_requester, '외부 '))
      end,
      case when v_ship.id is not null
           then '🚚 배송 필요 · ' || to_char(v_ship.requested_date, 'MM/DD') || ' 도착 희망 · 물류사 요청 메일을 보내 주세요'
           else '직접 수령' end
    ], null),
    'ledger'
  );
  return null;
end;
$$;
