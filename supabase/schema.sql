-- =====================================================================
-- 데모장비 출납 앱 · Supabase 스키마 v1
-- 실행 위치: Supabase 대시보드 > SQL Editor (프로젝트 생성 직후 1회)
-- 원칙: 브라우저에는 공개 키만 둔다. 모든 권한은 RLS·트리거·DB 함수가 판단한다.
-- =====================================================================

create extension if not exists btree_gist with schema extensions;

-- 앱 전용 내부 함수·표는 private 스키마에 둔다 (API로 노출되지 않음)
create schema if not exists private;
revoke all on schema private from public;
grant usage on schema private to authenticated;

-- ---------------------------------------------------------------------
-- 1. 테이블
-- ---------------------------------------------------------------------

-- 사용자: 카카오로 처음 로그인하면 'pending'으로 자동 생성된다. 관리자가 'active'로 승인한다.
create table public.profiles (
  id           uuid primary key references auth.users(id) on delete cascade,
  display_name text not null default '',
  role         text not null default 'applicant' check (role in ('applicant', 'admin')),
  status       text not null default 'pending'   check (status in ('pending', 'active', 'disabled')),
  approved_by  uuid references public.profiles(id),
  approved_at  timestamptz,
  created_at   timestamptz not null default now()
);

create table public.equipment (
  id         uuid primary key default gen_random_uuid(),
  asset_no   text not null unique,
  name       text not null,
  item_no    text not null default '',
  serial_no  text not null default '',
  category   text not null check (category in ('BLS', 'ALS', '환자 시뮬레이터', '술기 트레이너', '소프트웨어', '기타')),
  location   text not null check (length(trim(location)) > 0),  -- 문정, 의왕, 또는 직접 기록
  status     text not null default 'available'
             check (status in ('available', 'onloan', 'inspect', 'repair', 'retired')),
  components text not null default '',
  note       text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- 출납: 장비 1대 = 1행. 함께 빌린 장비는 같은 loan_no를 쓴다.
create table public.loans (
  id                 uuid primary key default gen_random_uuid(),
  loan_no            text not null,
  equipment_id       uuid not null references public.equipment(id),
  requester_id       uuid not null references public.profiles(id),
  internal_requester text not null default '',
  external_requester text not null default '',
  purpose            text not null check (purpose in ('고객 데모', '전시회', '교육·워크숍', '학회', '내부 교육', '기타')),
  customer           text not null default '',
  note               text not null default '',
  start_date         date not null,
  due_date           date not null,
  delivery           boolean not null default false,
  status             text not null default 'reserved'
                     check (status in ('reserved', 'out', 'checking', 'done', 'cancelled')),
  checkout_at        timestamptz,
  returned_at        timestamptz,
  return_condition   text check (return_condition in ('ok', 'minor', 'broken', 'missing')),
  return_note        text not null default '',
  checked_by         uuid references public.profiles(id),
  extension_count    int  not null default 0,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  constraint loans_dates check (due_date >= start_date),
  -- 같은 장비, 겹치는 기간의 '예약'·'출고'는 DB가 막는다 (동시 신청 포함)
  constraint loans_no_overlap exclude using gist (
    equipment_id with =,
    daterange(start_date, due_date, '[]') with &&
  ) where (status in ('reserved', 'out'))
);
create index loans_loan_no_idx on public.loans (loan_no);
create index loans_requester_idx on public.loans (requester_id);

-- 배송: 신청번호마다 출고 배송 1건, 회수 1건까지
create table public.shipments (
  id             uuid primary key default gen_random_uuid(),
  loan_no        text not null,
  direction      text not null check (direction in ('outbound', 'pickup')),
  recipient      text not null,
  phone          text not null,
  address        text not null,
  requested_date date not null,
  memo           text not null default '',
  carrier        text not null default '',
  tracking_no    text not null default '',
  -- scheduled: 회수 예정(아직 반납 전) / pending: 요청 전 / requested: 요청 완료
  status         text not null default 'pending'
                 check (status in ('scheduled', 'pending', 'requested', 'in_transit', 'delivered', 'done')),
  created_by     uuid not null references public.profiles(id),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  unique (loan_no, direction)
);

-- 이력: 트리거만 쓴다. 사용자는 수정할 수 없다.
create table public.activity_log (
  id         bigint generated always as identity primary key,
  at         timestamptz not null default now(),
  actor      uuid,
  table_name text not null,
  row_id     uuid,
  action     text not null,
  detail     jsonb not null default '{}'
);

-- 신청번호 월별 일련번호
create table private.loan_counters (
  ym      text primary key,
  last_no int  not null
);

-- ---------------------------------------------------------------------
-- 2. 권한 확인 함수
-- ---------------------------------------------------------------------

create or replace function private.is_active()
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from public.profiles where id = auth.uid() and status = 'active');
$$;

create or replace function private.is_admin()
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from public.profiles where id = auth.uid() and status = 'active' and role = 'admin');
$$;

revoke all on function private.is_active(), private.is_admin() from public;
grant execute on function private.is_active(), private.is_admin() to authenticated;

-- ---------------------------------------------------------------------
-- 3. 트리거
-- ---------------------------------------------------------------------

-- 카카오 첫 로그인 → 승인 대기 사용자 생성
create or replace function private.handle_new_user()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  insert into public.profiles (id, display_name)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'name',
             new.raw_user_meta_data ->> 'full_name',
             new.raw_user_meta_data ->> 'preferred_username',
             new.raw_user_meta_data ->> 'user_name',
             '')
  );
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function private.handle_new_user();

-- 공통 이력 기록 (바뀐 열만 저장)
create or replace function private.log_change()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare
  v_detail jsonb;
begin
  if tg_op = 'UPDATE' then
    select coalesce(jsonb_object_agg(n.key, n.value), '{}')
      into v_detail
      from jsonb_each(to_jsonb(new)) n
     where n.key not in ('updated_at')
       and to_jsonb(old) -> n.key is distinct from n.value;
    if v_detail = '{}' then
      return null;
    end if;
  elsif tg_op = 'INSERT' then
    v_detail := to_jsonb(new);
  else
    v_detail := to_jsonb(old);
  end if;
  insert into public.activity_log (actor, table_name, row_id, action, detail)
  values (auth.uid(), tg_table_name, coalesce(new.id, old.id), lower(tg_op), v_detail);
  return null;
end;
$$;

create or replace function private.touch_updated_at()
returns trigger language plpgsql set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

-- 사용자 승인·권한 변경 규칙
create or replace function private.guard_profile_update()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if auth.uid() is null then          -- 대시보드·서비스 키 작업
    return new;
  end if;
  if new.id <> old.id then
    raise exception '사용자 ID는 바꿀 수 없어요.' using errcode = '42501';
  end if;
  if new.id = auth.uid() and (new.role <> old.role or new.status <> old.status) then
    raise exception '본인의 역할이나 상태는 바꿀 수 없어요. 다른 관리자에게 요청해 주세요.' using errcode = '42501';
  end if;
  if new.status = 'active' and old.status <> 'active' then
    new.approved_by := auth.uid();
    new.approved_at := now();
  end if;
  return new;
end;
$$;

-- 출납 변경 규칙: 신청자는 본인 신청의 연장·취소·반납 등록만 할 수 있다
create or replace function private.guard_loan_update()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare
  v_free text[] := array['status', 'due_date', 'returned_at', 'extension_count', 'updated_at'];
begin
  new.updated_at := now();

  -- RLS를 통과한 행만 여기에 온다. auth.uid()가 없으면 대시보드·서비스 키 작업이다.
  if auth.uid() is null then
    return new;
  end if;

  if new.due_date is distinct from old.due_date then
    if old.status not in ('reserved', 'out') or new.status <> old.status then
      raise exception '연장은 예약 또는 출고 상태에서만 할 수 있어요.' using errcode = '22023';
    end if;
    if new.due_date <= old.due_date then
      raise exception '연장은 지금 반납 예정일보다 뒤 날짜로만 할 수 있어요.' using errcode = '22023';
    end if;
    new.extension_count := old.extension_count + 1;
  end if;

  if private.is_admin() then
    if new.status is distinct from old.status then
      if new.status = 'out' then
        new.checkout_at := coalesce(new.checkout_at, now());
      elsif new.status = 'checking' then
        new.returned_at := coalesce(new.returned_at, now());
      elsif new.status = 'done' then
        if new.return_condition is null then
          raise exception '반납 점검 결과를 골라 주세요.' using errcode = '22023';
        end if;
        if new.return_condition <> 'ok' and coalesce(trim(new.return_note), '') = '' then
          raise exception '손상이나 누락이 있으면 점검 메모를 적어 주세요.' using errcode = '22023';
        end if;
        new.checked_by  := auth.uid();
        new.returned_at := coalesce(new.returned_at, now());
      end if;
    end if;
    return new;
  end if;

  -- 여기부터 신청자
  if (to_jsonb(new) - v_free) is distinct from (to_jsonb(old) - v_free) then
    raise exception '신청자는 반납 예정일 연장, 예약 취소, 반납 등록만 할 수 있어요.' using errcode = '42501';
  end if;

  if new.status is distinct from old.status then
    if old.status = 'reserved' and new.status = 'cancelled' then
      null;
    elsif old.status = 'out' and new.status = 'checking' then
      new.returned_at := now();
    else
      raise exception '이 상태 변경은 장비 관리자만 할 수 있어요.' using errcode = '42501';
    end if;
  end if;

  if new.status = old.status then
    new.returned_at := old.returned_at;
  end if;
  if new.due_date = old.due_date then
    new.extension_count := old.extension_count;
  end if;
  return new;
end;
$$;

-- 출납 상태가 바뀌면 장비 상태와 회수 요청을 맞춘다
create or replace function private.after_loan_change()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if tg_op = 'UPDATE' and new.status is distinct from old.status then
    if new.status = 'out' then
      update public.equipment set status = 'onloan', updated_at = now() where id = new.equipment_id;
    elsif new.status = 'checking' then
      update public.equipment set status = 'inspect', updated_at = now() where id = new.equipment_id;
      if new.delivery then
        update public.shipments set status = 'pending', updated_at = now()
         where loan_no = new.loan_no and direction = 'pickup' and status = 'scheduled';
      end if;
    elsif new.status = 'done' then
      update public.equipment
         set status = case when new.return_condition in ('ok', 'minor') then 'available' else 'repair' end,
             updated_at = now()
       where id = new.equipment_id;
    end if;
  end if;
  return null;
end;
$$;

create trigger profiles_guard   before update on public.profiles  for each row execute function private.guard_profile_update();
create trigger profiles_log     after insert or update on public.profiles for each row execute function private.log_change();
create trigger equipment_touch  before update on public.equipment for each row execute function private.touch_updated_at();
create trigger equipment_log    after insert or update or delete on public.equipment for each row execute function private.log_change();
create trigger loans_guard      before update on public.loans     for each row execute function private.guard_loan_update();
create trigger loans_after      after update on public.loans      for each row execute function private.after_loan_change();
create trigger loans_log        after insert or update on public.loans for each row execute function private.log_change();
create trigger shipments_touch  before update on public.shipments for each row execute function private.touch_updated_at();
create trigger shipments_log    after insert or update on public.shipments for each row execute function private.log_change();

-- ---------------------------------------------------------------------
-- 4. 출납 신청 함수 (신청은 이 함수로만 한다)
--    신청번호 발급, 장비 여러 대, 배송·회수 요청을 한 번에 처리한다.
--    하나라도 실패하면 전체가 취소된다.
-- ---------------------------------------------------------------------

create or replace function public.create_loan_request(
  p_equipment_ids uuid[],
  p_start         date,
  p_due           date,
  p_purpose       text,
  p_customer      text  default '',
  p_internal      text  default '',
  p_external      text  default '',
  p_note          text  default '',
  p_shipment      jsonb default null   -- {recipient, phone, address, date, pickup_date?, memo?}
)
returns text
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid   uuid := auth.uid();
  v_today date := (now() at time zone 'Asia/Seoul')::date;
  v_ids   uuid[];
  v_ym    text;
  v_n     int;
  v_no    text;
  v_eq    uuid;
begin
  if not private.is_active() then
    raise exception '승인된 사용자만 신청할 수 있어요.' using errcode = '42501';
  end if;

  select array_agg(distinct x) into v_ids from unnest(p_equipment_ids) x where x is not null;
  if v_ids is null then
    raise exception '빌릴 장비를 1대 이상 골라 주세요.' using errcode = '22023';
  end if;
  if cardinality(v_ids) > 20 then
    raise exception '한 번에 20대까지 신청할 수 있어요.' using errcode = '22023';
  end if;
  if p_start is null or p_due is null or p_due < p_start then
    raise exception '반납 예정일은 사용 시작일과 같거나 그 뒤여야 해요.' using errcode = '22023';
  end if;
  if p_start < v_today then
    raise exception '사용 시작일은 오늘이나 그 뒤로 정해 주세요.' using errcode = '22023';
  end if;
  if exists (
    select 1 from unnest(v_ids) i(id)
      left join public.equipment e on e.id = i.id
     where e.id is null or e.status in ('inspect', 'repair', 'retired')
  ) then
    raise exception '점검·수리 중이거나 없는 장비가 들어 있어요.' using errcode = '22023';
  end if;
  if p_shipment is not null and (
       coalesce(trim(p_shipment ->> 'recipient'), '') = ''
    or coalesce(trim(p_shipment ->> 'phone'), '') = ''
    or coalesce(trim(p_shipment ->> 'address'), '') = ''
    or (p_shipment ->> 'date') is null
  ) then
    raise exception '배송이 필요하면 수령인, 연락처, 주소, 도착 희망일을 모두 입력해 주세요.' using errcode = '22023';
  end if;

  v_ym := to_char(now() at time zone 'Asia/Seoul', 'YYMM');
  insert into private.loan_counters (ym, last_no) values (v_ym, 1)
  on conflict (ym) do update set last_no = private.loan_counters.last_no + 1
  returning last_no into v_n;
  v_no := 'D-LMK-' || v_ym || '-' || lpad(v_n::text, 3, '0');

  begin
    foreach v_eq in array v_ids loop
      insert into public.loans (
        loan_no, equipment_id, requester_id, internal_requester, external_requester,
        purpose, customer, note, start_date, due_date, delivery
      ) values (
        v_no, v_eq, v_uid, coalesce(trim(p_internal), ''), coalesce(trim(p_external), ''),
        p_purpose, coalesce(trim(p_customer), ''), coalesce(trim(p_note), ''), p_start, p_due, p_shipment is not null
      );
    end loop;
  exception when exclusion_violation then
    raise exception '같은 기간에 이미 예약된 장비가 있어요. 장비나 기간을 바꿔 주세요.' using errcode = '23P01';
  end;

  if p_shipment is not null then
    insert into public.shipments (loan_no, direction, recipient, phone, address, requested_date, memo, status, created_by)
    values (v_no, 'outbound', trim(p_shipment ->> 'recipient'), trim(p_shipment ->> 'phone'),
            trim(p_shipment ->> 'address'), (p_shipment ->> 'date')::date,
            coalesce(p_shipment ->> 'memo', ''), 'pending', v_uid);
    if (p_shipment ->> 'pickup_date') is not null then
      insert into public.shipments (loan_no, direction, recipient, phone, address, requested_date, memo, status, created_by)
      values (v_no, 'pickup', trim(p_shipment ->> 'recipient'), trim(p_shipment ->> 'phone'),
              trim(p_shipment ->> 'address'), (p_shipment ->> 'pickup_date')::date,
              coalesce(p_shipment ->> 'memo', ''), 'scheduled', v_uid);
    end if;
  end if;

  return v_no;
end;
$$;

revoke all on function public.create_loan_request(uuid[], date, date, text, text, text, text, text, jsonb) from public, anon;
grant execute on function public.create_loan_request(uuid[], date, date, text, text, text, text, text, jsonb) to authenticated;

-- ---------------------------------------------------------------------
-- 5. RLS 정책
-- ---------------------------------------------------------------------

alter table public.profiles     enable row level security;
alter table public.equipment    enable row level security;
alter table public.loans        enable row level security;
alter table public.shipments    enable row level security;
alter table public.activity_log enable row level security;

-- 로그인한 사용자에게 필요한 권한만 명시적으로 준다 (프로젝트 기본 권한 설정과 관계없이 동작하도록)
grant usage on schema public to authenticated;
grant select, update                 on public.profiles     to authenticated;
grant select, insert, update, delete on public.equipment    to authenticated;
grant select, update                 on public.loans        to authenticated;
grant select, update                 on public.shipments    to authenticated;
grant select                         on public.activity_log to authenticated;

-- 로그인하지 않은 사람(anon)은 아무것도 못 한다
revoke all on public.profiles, public.equipment, public.loans, public.shipments, public.activity_log from anon;
-- 클라이언트는 직접 추가·삭제하지 않는 표 (신청 함수와 트리거가 대신 쓴다)
revoke insert, delete on public.profiles, public.loans, public.shipments, public.activity_log from authenticated;
revoke update on public.activity_log from authenticated;
revoke truncate, references, trigger on public.profiles, public.equipment, public.loans, public.shipments, public.activity_log from authenticated;

-- profiles: 본인 행은 항상 보임(승인 대기 화면용). 승인된 사용자는 서로의 이름을 봄. 수정은 관리자만.
create policy profiles_select on public.profiles for select to authenticated
  using (id = (select auth.uid()) or (select private.is_active()));
create policy profiles_update on public.profiles for update to authenticated
  using ((select private.is_admin())) with check ((select private.is_admin()));

-- equipment: 승인된 사용자는 읽기, 관리자는 쓰기
create policy equipment_select on public.equipment for select to authenticated
  using ((select private.is_active()));
create policy equipment_insert on public.equipment for insert to authenticated
  with check ((select private.is_admin()));
create policy equipment_update on public.equipment for update to authenticated
  using ((select private.is_admin())) with check ((select private.is_admin()));
create policy equipment_delete on public.equipment for delete to authenticated
  using ((select private.is_admin()));

-- loans: 승인된 사용자는 전체 대장 읽기. 수정은 관리자 또는 본인 신청(세부 규칙은 guard 트리거)
create policy loans_select on public.loans for select to authenticated
  using ((select private.is_active()));
create policy loans_update on public.loans for update to authenticated
  using ((select private.is_admin()) or ((select private.is_active()) and requester_id = (select auth.uid())))
  with check ((select private.is_admin()) or ((select private.is_active()) and requester_id = (select auth.uid())));

-- shipments: 승인된 사용자는 읽기, 상태·운송장 수정은 관리자
create policy shipments_select on public.shipments for select to authenticated
  using ((select private.is_active()));
create policy shipments_update on public.shipments for update to authenticated
  using ((select private.is_admin())) with check ((select private.is_admin()));

-- activity_log: 관리자만 읽기
create policy activity_log_select on public.activity_log for select to authenticated
  using ((select private.is_admin()));

-- ---------------------------------------------------------------------
-- 6. 첫 관리자 지정 (본인이 카카오로 한 번 로그인한 뒤, 대시보드에서 1회 실행)
--    update public.profiles set role = 'admin', status = 'active'
--     where id = '<Authentication > Users에 보이는 내 User UID>';
-- ---------------------------------------------------------------------
