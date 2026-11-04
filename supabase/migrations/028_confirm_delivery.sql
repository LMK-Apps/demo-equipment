-- =====================================================================
-- 마이그레이션 028 · 신청자 도착 확인
--   confirm_delivery(p_shipment_id): 배송(outbound)이 '배송 중'일 때 신청한 본인(또는 장비 관리자)이
--   '도착'으로 바꾼다. 신청자는 이 함수로만 바꿀 수 있고, 다른 단계는 그대로 장비 관리자만 바꾼다.
--   바꾸면 Teams 알림을 1건 보낸다.
-- 실행 위치: Supabase SQL Editor (027 실행 후 1회)
-- =====================================================================

begin;

create or replace function public.confirm_delivery(p_shipment_id uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid  uuid := auth.uid();
  v_ship public.shipments%rowtype;
  v_req  uuid;
  v_cust text;
begin
  if not private.is_active() then
    raise exception '승인된 사용자만 도착을 확인할 수 있어요.' using errcode = '42501';
  end if;
  select * into v_ship from public.shipments where id = p_shipment_id for update;
  if not found or v_ship.direction <> 'outbound' then
    raise exception '배송 기록을 찾지 못했어요.' using errcode = '22023';
  end if;
  select requester_id, coalesce(nullif(customer, ''), purpose) into v_req, v_cust
    from public.loans where loan_no = v_ship.loan_no and status <> 'cancelled' order by created_at, id limit 1;
  if v_req is distinct from v_uid and not private.is_admin() then
    raise exception '본인 신청의 배송만 도착 확인할 수 있어요.' using errcode = '42501';
  end if;
  if v_ship.status <> 'in_transit' then
    raise exception '배송 중인 건만 도착 확인할 수 있어요.' using errcode = '22023';
  end if;

  update public.shipments set status = 'delivered', updated_at = now() where id = p_shipment_id;

  perform private.teams_send(
    '📬 도착 확인 ' || v_ship.loan_no,
    array['**' || coalesce((select display_name from public.profiles where id = v_uid), '?') || '** 님이 장비를 받았어요',
          coalesce(v_cust, '') || case when v_ship.address <> '' then ' · ' || v_ship.address else '' end],
    'ship');
end $$;

revoke all on function public.confirm_delivery(uuid) from public;
grant execute on function public.confirm_delivery(uuid) to authenticated;

commit;

-- 확인: confirm_delivery 한 줄이 보이면 정상
select proname from pg_proc where proname = 'confirm_delivery';
