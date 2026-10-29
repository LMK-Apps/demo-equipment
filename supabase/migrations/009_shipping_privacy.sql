-- =====================================================================
-- 마이그레이션 009 · 배송 정보(이름·연락처·주소) 보호
--   1) 보는 사람 줄이기: 배송·회수 정보는 장비 관리자와 그 신청을 한 본인만 읽는다.
--   2) 끝난 건 가리기: 신청번호의 모든 장비가 반납 완료(또는 취소)된 지 90일이 지나면
--      담당자·연락처·주소·메모를 지운다. 이력(activity_log)에 남은 같은 값도 지운다.
--      매일 04:00(한국 시간)에 자동으로 실행한다.
--   신청번호, 날짜, 상태, 물류사, 운송장 번호는 남긴다 (출납 기록 확인용).
-- 실행 위치: Supabase SQL Editor (008 실행 후 1회)
-- =====================================================================

-- 1. 읽기 권한: 관리자 + 신청한 본인
drop policy if exists shipments_select on public.shipments;
create policy shipments_select on public.shipments for select to authenticated
  using (
    (select private.is_admin())
    or ((select private.is_active()) and exists (
          select 1 from public.loans l
           where l.loan_no = shipments.loan_no
             and l.requester_id = (select auth.uid())))
  );

-- 2. 지난 배송 정보 지우기
create or replace function private.purge_shipping_contacts(p_days int default 90)
returns int
language plpgsql security definer set search_path = ''
as $$
declare
  v_ids uuid[];
begin
  select coalesce(array_agg(s.id), '{}') into v_ids
    from public.shipments s
   where s.recipient <> '(삭제됨)'
     and not exists (            -- 아직 끝나지 않은 장비가 있으면 그대로 둔다
           select 1 from public.loans l
            where l.loan_no = s.loan_no and l.status not in ('done', 'cancelled'))
     and (select max(l.updated_at) from public.loans l where l.loan_no = s.loan_no)
           < now() - make_interval(days => greatest(p_days, 1));

  if cardinality(v_ids) = 0 then
    return 0;
  end if;

  update public.shipments
     set recipient = '(삭제됨)', phone = '', address = '(삭제됨)', memo = ''
   where id = any(v_ids);

  update public.activity_log
     set detail = detail - 'recipient' - 'phone' - 'address' - 'memo'
   where table_name = 'shipments' and row_id = any(v_ids);

  return cardinality(v_ids);
end;
$$;

revoke all on function private.purge_shipping_contacts(int) from public, anon, authenticated;

select cron.unschedule(jobid) from cron.job where jobname = 'demo-purge-contacts';
select cron.schedule('demo-purge-contacts', '0 19 * * *', 'select private.purge_shipping_contacts(90)');
