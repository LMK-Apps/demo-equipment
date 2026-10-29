-- =====================================================================
-- 마이그레이션 005 · 장비 이력 조회 함수
-- 이력 표(activity_log)는 관리자만 읽을 수 있다. 이 함수는 승인된 사용자에게
-- 장비 1대의 이력(장비 변경 + 그 장비의 출납 변경)만 골라서 보여 준다.
-- 실행 위치: Supabase SQL Editor (004 실행 후 1회)
-- =====================================================================

create or replace function public.equipment_history(p_equipment_id uuid, p_limit int default 200)
returns table (
  at          timestamptz,
  actor_name  text,
  table_name  text,
  action      text,
  loan_no     text,
  detail      jsonb
)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not private.is_active() then
    raise exception '승인된 사용자만 이력을 볼 수 있어요.' using errcode = '42501';
  end if;

  return query
    select a.at,
           coalesce(nullif(p.display_name, ''), case when a.actor is null then '시스템' else '알 수 없음' end),
           a.table_name,
           a.action,
           l.loan_no,
           -- 출납 신청 행 전체에는 고객 연락처 같은 배송 정보가 없지만, 필요한 열만 남긴다
           case when a.table_name = 'loans' and a.action = 'insert'
                then jsonb_build_object('start_date', a.detail -> 'start_date', 'due_date', a.detail -> 'due_date',
                                        'purpose', a.detail -> 'purpose', 'customer', a.detail -> 'customer',
                                        'requester_id', a.detail -> 'requester_id')
                else a.detail - 'updated_at' - 'history'
           end
      from public.activity_log a
      left join public.profiles p on p.id = a.actor
      left join public.loans l on a.table_name = 'loans' and l.id = a.row_id
     where (a.table_name = 'equipment' and a.row_id = p_equipment_id)
        or (a.table_name = 'loans' and l.equipment_id = p_equipment_id)
     order by a.at desc, a.id desc
     limit greatest(1, least(coalesce(p_limit, 200), 500));
end;
$$;

revoke all on function public.equipment_history(uuid, int) from public, anon;
grant execute on function public.equipment_history(uuid, int) to authenticated;
