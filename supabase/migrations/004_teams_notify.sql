-- =====================================================================
-- 마이그레이션 004 · Teams 채널 알림
--   1) 출납 신청 즉시: 신청번호 1건당 메시지 1개
--   2) 반납 신청 즉시: 장비 1대당 메시지 1개 (자가점검 포함)
--   3) 평일 오전 9시: 출고 예정(오늘·내일), 오늘 반납 예정, 연체, 반납 확인 대기 요약
-- 웹훅 주소는 코드에 넣지 않고 Supabase Vault에 따로 저장한다 (supabase/setup_teams_webhook.sql).
-- 웹훅 주소가 없거나 Teams 전송이 실패해도 신청·반납은 그대로 저장된다.
-- 실행 위치: Supabase SQL Editor (003 실행 후 1회)
-- =====================================================================

create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron with schema pg_catalog;

-- 1. 앱 주소 (알림 카드의 '앱 열기' 버튼)
create or replace function private.app_url()
returns text language sql immutable
as $$ select 'https://lmk-apps.github.io/demo-equipment/' $$;

-- 2. Teams로 Adaptive Card 보내기
create or replace function private.teams_send(p_title text, p_lines text[], p_view text default 'home')
returns void language plpgsql security definer set search_path = ''
as $$
declare
  v_url  text;
  v_body jsonb;
begin
  select decrypted_secret into v_url
    from vault.decrypted_secrets where name = 'teams_webhook_url' limit 1;
  if coalesce(v_url, '') = '' then
    return;                                   -- 아직 설정 전: 조용히 넘어감
  end if;

  v_body := jsonb_build_object(
    'type', 'message',
    'attachments', jsonb_build_array(jsonb_build_object(
      'contentType', 'application/vnd.microsoft.card.adaptive',
      'contentUrl', null,
      'content', jsonb_build_object(
        '$schema', 'http://adaptivecards.io/schemas/adaptive-card.json',
        'type', 'AdaptiveCard',
        'version', '1.4',
        'body', jsonb_build_array(jsonb_build_object(
                  'type', 'TextBlock', 'text', p_title, 'weight', 'Bolder', 'size', 'Medium', 'wrap', true))
                || coalesce((select jsonb_agg(jsonb_build_object('type', 'TextBlock', 'text', l, 'wrap', true, 'spacing', 'Small'))
                               from unnest(p_lines) l), '[]'::jsonb),
        'actions', jsonb_build_array(jsonb_build_object(
                     'type', 'Action.OpenUrl', 'title', '앱 열기', 'url', private.app_url() || '#' || p_view))
      )
    ))
  );

  perform net.http_post(
    url     := v_url,
    body    := v_body,
    headers := '{"Content-Type": "application/json"}'::jsonb
  );
exception when others then
  raise warning 'Teams 알림 전송 실패: %', sqlerrm;   -- 알림 실패가 업무를 막지 않게
end;
$$;

revoke all on function private.teams_send(text, text[], text) from public;

-- 3. 새 출납 신청: 커밋 시점에 신청번호당 한 번만
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

  select string_agg(e.name || ' (' || e.asset_no || ')', ', ' order by e.asset_no), count(*)
    into v_items, v_cnt
    from public.loans l join public.equipment e on e.id = l.equipment_id
   where l.loan_no = new.loan_no;
  select * into v_ship from public.shipments where loan_no = new.loan_no and direction = 'outbound';

  perform private.teams_send(
    '📦 새 출납 신청 ' || new.loan_no,
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

drop trigger if exists loans_notify_new on public.loans;
create constraint trigger loans_notify_new
  after insert on public.loans
  deferrable initially deferred
  for each row execute function private.notify_new_loan();

-- 4. 반납 신청 (출고 → 반납 확인 중)
create or replace function private.notify_return()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare
  e public.equipment%rowtype;
begin
  if not (old.status = 'out' and new.status = 'checking') then
    return null;
  end if;
  select * into e from public.equipment where id = new.equipment_id;
  perform private.teams_send(
    '↩️ 반납 신청 ' || new.loan_no,
    array_remove(array[
      '**' || e.name || '** (' || e.asset_no || ') · ' || coalesce((select display_name from public.profiles where id = new.requester_id), '?'),
      case new.return_method
        when 'drop_uiwang'   then '직접 반납 – 의왕'
        when 'drop_munjeong' then '직접 반납 – 문정'
        when 'pickup'        then '🚚 물류사 회수 요청 · 회수 요청 메일을 보내 주세요'
        else '반납 방법 기록 없음' end,
      '자가점검: ' || case new.return_self_check
        when 'ok' then '정상' when 'minor' then '경미한 손상'
        when 'broken' then '⚠️ 파손' when 'missing' then '⚠️ 구성품 누락' else '기록 없음' end
        || case when coalesce(new.return_self_note, '') <> '' then ' · ' || new.return_self_note else '' end,
      case when (new.returned_at at time zone 'Asia/Seoul')::date > new.due_date
           then '연체 반납 (' || ((new.returned_at at time zone 'Asia/Seoul')::date - new.due_date) || '일)' end,
      '장비 관리자는 반납 확인을 해 주세요'
    ], null),
    'ledger'
  );
  return null;
end;
$$;

drop trigger if exists loans_notify_return on public.loans;
create trigger loans_notify_return
  after update of status on public.loans
  for each row execute function private.notify_return();

-- 5. 평일 오전 요약
create or replace function private.notify_daily_digest()
returns void language plpgsql security definer set search_path = ''
as $$
declare
  v_today date := (now() at time zone 'Asia/Seoul')::date;
  v_lines text[] := '{}';
  r record;
  v_sec text;
begin
  -- 연체
  v_sec := null;
  for r in select l.loan_no, e.name, e.asset_no, p.display_name, l.due_date
             from public.loans l join public.equipment e on e.id = l.equipment_id
             left join public.profiles p on p.id = l.requester_id
            where l.status = 'out' and l.due_date < v_today order by l.due_date loop
    v_sec := coalesce(v_sec || chr(10), '') || '- ' || r.name || ' (' || r.asset_no || ') · ' || coalesce(r.display_name, '?')
             || ' · ' || (v_today - r.due_date) || '일 지남';
  end loop;
  if v_sec is not null then v_lines := v_lines || ('**🔴 연체**' || chr(10) || v_sec); end if;

  -- 출고 예정 (오늘·내일)
  v_sec := null;
  for r in select l.loan_no, l.start_date, string_agg(e.name, ', ' order by e.asset_no) names,
                  min(p.display_name) who, bool_or(l.delivery) delivery
             from public.loans l join public.equipment e on e.id = l.equipment_id
             left join public.profiles p on p.id = l.requester_id
            where l.status = 'reserved' and l.start_date between v_today and v_today + 1
            group by l.loan_no, l.start_date order by l.start_date, l.loan_no loop
    v_sec := coalesce(v_sec || chr(10), '') || '- ' || case when r.start_date = v_today then '오늘' else '내일' end
             || ' · ' || r.loan_no || ' · ' || coalesce(r.who, '?') || ' · ' || r.names || case when r.delivery then ' · 배송' else '' end;
  end loop;
  if v_sec is not null then v_lines := v_lines || ('**📤 출고 예정**' || chr(10) || v_sec); end if;

  -- 오늘 반납 예정
  v_sec := null;
  for r in select e.name, e.asset_no, p.display_name
             from public.loans l join public.equipment e on e.id = l.equipment_id
             left join public.profiles p on p.id = l.requester_id
            where l.status = 'out' and l.due_date = v_today order by e.asset_no loop
    v_sec := coalesce(v_sec || chr(10), '') || '- ' || r.name || ' (' || r.asset_no || ') · ' || coalesce(r.display_name, '?');
  end loop;
  if v_sec is not null then v_lines := v_lines || ('**📥 오늘 반납 예정**' || chr(10) || v_sec); end if;

  -- 반납 확인 대기
  v_sec := null;
  for r in select e.name, e.asset_no, p.display_name
             from public.loans l join public.equipment e on e.id = l.equipment_id
             left join public.profiles p on p.id = l.requester_id
            where l.status = 'checking' order by l.returned_at loop
    v_sec := coalesce(v_sec || chr(10), '') || '- ' || r.name || ' (' || r.asset_no || ') · ' || coalesce(r.display_name, '?');
  end loop;
  if v_sec is not null then v_lines := v_lines || ('**🔍 반납 확인 대기**' || chr(10) || v_sec); end if;

  if cardinality(v_lines) = 0 then
    return;                                   -- 알릴 게 없으면 보내지 않음
  end if;
  perform private.teams_send('🗓️ 오늘의 데모장비 (' || to_char(v_today, 'MM/DD') || ')', v_lines, 'home');
end;
$$;

-- 평일 09:00 (한국 시간) = 00:00 UTC
select cron.unschedule(jobid) from cron.job where jobname = 'demo-daily-digest';
select cron.schedule('demo-daily-digest', '0 0 * * 1-5', 'select private.notify_daily_digest()');
