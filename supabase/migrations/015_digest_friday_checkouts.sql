-- =====================================================================
-- 마이그레이션 015 · 아침 요약 '출고 예정'도 금요일에는 월요일까지
--   - 지금까지 출고 예정은 오늘·내일만 봐서 금요일 요약에 월요일 출고가 빠졌다.
--   - 금요일에는 토·일·월 출고를 날짜와 함께 보여 준다. 다른 요일은 오늘·내일 그대로.
--   - 나머지 항목은 014와 같다.
-- 실행 위치: Supabase SQL Editor (014 실행 후 1회)
-- =====================================================================

create or replace function private.notify_daily_digest()
returns void language plpgsql security definer set search_path = ''
as $$
declare
  v_today date := (now() at time zone 'Asia/Seoul')::date;
  v_lines text[] := '{}';
  r record;
  v_sec text;
  -- 다음 근무일: 금요일이면 월요일(주말 포함), 그 밖에는 내일
  v_next date := (now() at time zone 'Asia/Seoul')::date + case extract(isodow from (now() at time zone 'Asia/Seoul')::date) when 5 then 3 when 6 then 2 else 1 end;
begin
  -- 연체
  v_sec := null;
  for r in select l.loan_no, e.name, e.internal_id, p.display_name, l.due_date
             from public.loans l join public.equipment e on e.id = l.equipment_id
             left join public.profiles p on p.id = l.requester_id
            where l.status = 'out' and l.due_date < v_today order by l.due_date loop
    v_sec := coalesce(v_sec || chr(10), '') || '- ' || r.name || ' (' || r.internal_id || ') · ' || coalesce(r.display_name, '?')
             || ' · ' || (v_today - r.due_date) || '일 지남';
  end loop;
  if v_sec is not null then v_lines := v_lines || ('**🔴 연체**' || chr(10) || v_sec); end if;

  -- 출고 예정 (오늘·내일, 금요일에는 주말과 월요일까지)
  v_sec := null;
  for r in select l.loan_no, l.start_date, string_agg(e.name, ', ' order by e.internal_id) names,
                  min(p.display_name) who, bool_or(l.delivery) delivery
             from public.loans l join public.equipment e on e.id = l.equipment_id
             left join public.profiles p on p.id = l.requester_id
            where l.status = 'reserved' and l.start_date between v_today and v_next
            group by l.loan_no, l.start_date order by l.start_date, l.loan_no loop
    v_sec := coalesce(v_sec || chr(10), '') || '- '
             || case when r.start_date = v_today then '오늘'
                     when v_next - v_today = 1 then '내일'
                     else to_char(r.start_date, 'MM/DD') || '(' || (array['월','화','수','목','금','토','일'])[extract(isodow from r.start_date)::int] || ')' end
             || ' · ' || r.loan_no || ' · ' || coalesce(r.who, '?') || ' · ' || r.names || case when r.delivery then ' · 배송' else '' end;
  end loop;
  if v_sec is not null then v_lines := v_lines || ('**📤 출고 예정**' || chr(10) || v_sec); end if;

  -- 오늘 반납 예정
  v_sec := null;
  for r in select e.name, e.internal_id, p.display_name
             from public.loans l join public.equipment e on e.id = l.equipment_id
             left join public.profiles p on p.id = l.requester_id
            where l.status = 'out' and l.due_date = v_today order by e.internal_id loop
    v_sec := coalesce(v_sec || chr(10), '') || '- ' || r.name || ' (' || r.internal_id || ') · ' || coalesce(r.display_name, '?');
  end loop;
  if v_sec is not null then v_lines := v_lines || ('**📥 오늘 반납 예정**' || chr(10) || v_sec); end if;

  -- 내일 반납 예정 (금요일에는 주말과 월요일까지)
  v_sec := null;
  for r in select e.name, e.internal_id, p.display_name, l.due_date
             from public.loans l join public.equipment e on e.id = l.equipment_id
             left join public.profiles p on p.id = l.requester_id
            where l.status = 'out' and l.due_date > v_today and l.due_date <= v_next
            order by l.due_date, e.internal_id loop
    v_sec := coalesce(v_sec || chr(10), '') || '- ' || r.name || ' (' || r.internal_id || ') · ' || coalesce(r.display_name, '?')
             || case when v_next - v_today > 1
                     then ' · ' || to_char(r.due_date, 'MM/DD') || '(' || (array['월','화','수','목','금','토','일'])[extract(isodow from r.due_date)::int] || ')'
                     else '' end;
  end loop;
  if v_sec is not null then
    v_lines := v_lines || ((case when v_next - v_today > 1 then '**📅 주말·월요일 반납 예정**' else '**📅 내일 반납 예정**' end)
                           || chr(10) || v_sec);
  end if;

  -- 반납 확인 대기
  v_sec := null;
  for r in select e.name, e.internal_id, p.display_name
             from public.loans l join public.equipment e on e.id = l.equipment_id
             left join public.profiles p on p.id = l.requester_id
            where l.status = 'checking' order by l.returned_at loop
    v_sec := coalesce(v_sec || chr(10), '') || '- ' || r.name || ' (' || r.internal_id || ') · ' || coalesce(r.display_name, '?');
  end loop;
  if v_sec is not null then v_lines := v_lines || ('**🔍 반납 확인 대기**' || chr(10) || v_sec); end if;

  if cardinality(v_lines) = 0 then
    return;                                   -- 알릴 게 없으면 보내지 않음
  end if;
  perform private.teams_send('🗓️ 오늘의 데모장비 (' || to_char(v_today, 'MM/DD') || ')', v_lines, 'home');
end;
$$;
