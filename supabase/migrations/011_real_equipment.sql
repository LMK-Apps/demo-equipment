-- =====================================================================
-- 마이그레이션 011 · 실제 데모장비 등록 (DEMO_SIM.xlsx, 80대)
--   1) 테스트 데이터 전부 삭제: 배송, 출납, 장비, 이력, 신청번호 카운터 (사용자 계정은 그대로)
--   2) 분류를 4개로 변경: 시뮬레이터, BLS, MBL, Skill T.
--      (엑셀의 L&T, MU, EZ, LGH는 Skill T.로 넣고 메모에 제품군을 남김)
--   3) 자산번호: 비워 둘 수 있고, 여러 장비가 같은 번호를 써도 됨 (구분은 내부 ID)
--   4) 라벨 칸 추가 (SM3G, RA1, RJ1 등 장비 표시)
--   5) 내부 ID를 EQ-0001부터 다시 시작하고, 엑셀 순서대로 장비 등록
--      - 보관위치가 빈 칸이나 '-'면 '미확인' (32대)
--      - 상태가 '사용불가'면 '수리 필요' (4대)
--      - 취득연도, 비고, 실사 상태는 메모에 넣음
--   6) Teams 알림의 장비 표시를 자산번호 대신 내부 ID로 변경
-- 되돌릴 수 없다. 지우기 전 데이터는 GitHub 백업 저장소에 남아 있다.
-- 실행 위치: Supabase SQL Editor (010 실행 후 1회)
-- =====================================================================

begin;

-- 1. 테스트 데이터 삭제 (이력은 마지막에: 삭제도 이력에 남기 때문)
delete from public.shipments;
delete from public.loans;
delete from public.equipment;
delete from public.activity_log;
delete from private.loan_counters;   -- 신청번호도 D-LMK-연월-001부터 다시

-- 2. 분류
alter table public.equipment drop constraint if exists equipment_category_check;
alter table public.equipment add constraint equipment_category_check
  check (category in ('시뮬레이터', 'BLS', 'MBL', 'Skill T.'));

-- 3. 자산번호: 중복 허용, 빈 값 허용('')
alter table public.equipment drop constraint if exists equipment_asset_no_key;
alter table public.equipment alter column asset_no set default '';

-- 4. 라벨
alter table public.equipment add column if not exists label text not null default '';

-- 5. 내부 ID 다시 시작 + 등록 (내부 ID는 트리거가 이 순서대로 붙임)
select setval('private.equipment_internal_seq', 1, false);

insert into public.equipment (asset_no, name, item_no, serial_no, label, category, location, status, components, note) values
  ('LMK-Demo-2021162', 'SimMan3GPlus', '212-03350', '21203227734', 'SM3G', '시뮬레이터', '의왕', 'available', 'Torso, Legs, 충전기, 인스트럭터PC(+충전기), 환자모니터PC(+충전기), 라우터', '취득연도: 2021 / 212-03350 (Upgrade SMCC)'),
  ('LMK-Demo-2025189', 'MamaAnne', '380-00150', '380UMM3225004', '', '시뮬레이터', '의왕', 'available', 'Torso, Legs, 충전기, 인스트럭터PC(+충전기), 환자모니터PC(+충전기), 라우터', '취득연도: 2025 / 380-00150'),
  ('LMK-Demo-2019131', 'SimBaby', '', '24609190229', '', '시뮬레이터', '의왕', 'available', 'SimBaby본체, 충전기, 인스트럭터PC(+충전기), 환자모니터PC(+충전기), 라우터', '취득연도: 2019'),
  ('LMK-Demo-2012025', 'SimJunior', '', 'TSBG05001003', '', '시뮬레이터', '의왕', 'available', '', '취득연도: 2012'),
  ('LMK-Demo-2019127', 'SimMan3G', '', '22430T0003541', '', '시뮬레이터', '의왕', 'available', 'Torso, Legs, 충전기, 인스트럭터PC(+충전기), 환자모니터PC(+충전기), 라우터', '취득연도: 2019'),
  ('LMK-Demo-2014055', 'SimMan3G TR', '212-08899', '21210143976', '', '시뮬레이터', '의왕', 'available', 'Torso, Legs, 충전기, 인스트럭터PC(+충전기), 환자모니터PC(+충전기), 라우터', '취득연도: 2014 / 212-08899, 구형 다리'),
  ('', 'SimMan3G TR', '213-02050', '21337162295', '', '시뮬레이터', '의왕', 'available', 'Torso, Legs, 충전기, 인스트럭터PC(+충전기), 환자모니터PC(+충전기), 라우터', '213-02050'),
  ('LMK-Demo-2023166', 'SimMan ALS', '', '23535222974', 'ALS-01', '시뮬레이터', '의왕', 'available', 'Torso, Legs, 충전기, 인스트럭터PC(+충전기), 환자모니터PC(+충전기), 라우터', '취득연도: 2023 / SimMan ALS (다리결속신형) , Ingmar Plugin 장착, LinkboxPlus1'),
  ('LMK-Demo-2016077', 'SimMan ALS', '', '23505160016', 'ALS-02', '시뮬레이터', '의왕', 'available', 'Torso, Legs, 충전기, 인스트럭터PC(+충전기), 환자모니터PC(+충전기), 라우터', '취득연도: 2016 / SimMan ALS(다리결속구형) LinkboxPlus1'),
  ('LMK-Demo-2018117', 'NursingAnne Simulator', '320-05050', '320UMM2718012', '', '시뮬레이터', '의왕', 'available', 'NAS 본체, 충전기, 인스트럭터PC(+충전기), 환자모니터PC(+충전기), 라우터', '취득연도: 2018 / 320-05050'),
  ('LMK-Demo-2017107', 'SimMom', '', '', '', '시뮬레이터', '의왕', 'available', 'SimMom본체, 충전기, 인스트럭터PC(+충전기), 환자모니터PC(+충전기), 라우터', '취득연도: 2017'),
  ('LMK-Demo-2026205', 'Emily', '', '', '', '시뮬레이터', '의왕', 'available', 'Emily본체, 충전기, 인스트럭터PC(+충전기), 환자모니터PC(+충전기), 라우터', '취득연도: 2026'),
  ('LMK-Demo-2025188', 'Paul', 'PHE02', 'PHE02-029', '', '시뮬레이터', '의왕', 'available', 'Paul본체, 충전기, 인스트럭터PC(+충전기), 환자모니터PC(+충전기), 라우터', '취득연도: 2025 / SimCharacter PHE02 / PaullV2'),
  ('LMK-Demo-2026204', 'Harvey® Premier (w/ Harvey Audio)', 'HARVEYPR-L', '', 'HVY', '시뮬레이터', '의왕', 'available', '태블릿PC, 무선청진기, 라우터', '취득연도: 2026'),
  ('LMK-Demo-2021162-1', 'Advanced Lung Module', '420-00050', '', 'ASL', '시뮬레이터', '의왕', 'available', '', '취득연도: 2021'),
  ('LMK-Demo-2015073', 'Resusci Anne QCPR <Upgraded, BLE>', '171-01250', '1713916040', 'RA1', 'BLS', '미확인', 'available', '충전어뎁터', '취득연도: 2015'),
  ('', 'Resusci Anne QCPR (Torso) <upgraded, FB, BLE>', '171-00150', '1711618040', 'RA2', 'BLS', '미확인', 'available', '충전어뎁터', ''),
  ('LMK-Demo-2018119', 'Resusci Anne QCPR', '171-01260', '1713818050', 'RA3', 'BLS', '미확인', 'available', '충전어뎁터', '취득연도: 2018'),
  ('', 'RA-QCPR (AED) AW', '177-07350', '', 'RA4', 'BLS', '미확인', 'available', '충전어뎁터', '취득연도: 2026'),
  ('LMK-Demo-2023168', 'Little Anne Light 6-Pack', '135-01350', '', 'LA1', 'BLS', '의왕', 'available', '', '취득연도: 2023'),
  ('LMK-Demo-2023172', 'Little Anne Light 6-Pack', '135-01350', '', 'LA2', 'BLS', '의왕', 'available', '', '취득연도: 2023'),
  ('LMK-Demo-2024185', 'Resusci Junior QCPR, SimPad PLUS SkillR IE', '181-00150', '', 'RJ1', 'BLS', '미확인', 'available', '충전어뎁터, SimPad PLUS SkillR.(+충전기)', '취득연도: 2025'),
  ('LMK-Demo-2024185', 'Resusci Junior QCPR, SimPad PLUS SkillR IE', '181-00150', '', 'RJ2', 'BLS', '미확인', 'available', '충전어뎁터, SimPad PLUS SkillR.(+충전기)', '취득연도: 2025'),
  ('LMK-Demo-2024185', 'Resusci Junior QCPR, SimPad PLUS SkillR IE', '181-00150', '', 'RJ3', 'BLS', '미확인', 'available', '충전어뎁터, SimPad PLUS SkillR.(+충전기)', '취득연도: 2025'),
  ('LMK-Demo-2024185', 'Resusci Junior QCPR, SimPad PLUS SkillR IE', '181-00150', '', 'RJ4', 'BLS', '미확인', 'available', '충전어뎁터, SimPad PLUS SkillR.(+충전기)', '취득연도: 2025'),
  ('LMK-Demo-2024185', 'Resusci Junior QCPR, SimPad PLUS SkillR IE', '181-00150', '', 'RJ5', 'BLS', '미확인', 'available', '충전어뎁터, SimPad PLUS SkillR.(+충전기)', '취득연도: 2025'),
  ('LMK-Demo-2024185', 'Resusci Junior QCPR, SimPad PLUS SkillR IE', '181-00150', '', 'RJ6', 'BLS', '미확인', 'available', '충전어뎁터, SimPad PLUS SkillR.(+충전기)', '취득연도: 2025'),
  ('LMK-DEMO-2024182', 'Resusci Baby QCPR, SimPad PLUS SkillR IE', '161-01260', '1611024018', 'RB1', 'BLS', '미확인', 'available', '충전어뎁터, SimPad PLUS SkillR.(+충전기)', '취득연도: 2024'),
  ('LMK-DEMO-2024182', 'Resusci Baby QCPR, SimPad PLUS SkillR IE', '161-01260', '1611024015', 'RB2', 'BLS', '미확인', 'available', '충전어뎁터, SimPad PLUS SkillR.(+충전기)', '취득연도: 2024'),
  ('LMK-DEMO-2024182', 'Resusci Baby QCPR, SimPad PLUS SkillR IE', '161-01260', '1611024013', 'RB3', 'BLS', '미확인', 'available', '충전어뎁터, SimPad PLUS SkillR.(+충전기)', '취득연도: 2024'),
  ('LMK-DEMO-2024182', 'Resusci Baby QCPR, SimPad PLUS SkillR IE', '161-01260', '1611024006', 'RB4', 'BLS', '미확인', 'available', '충전어뎁터, SimPad PLUS SkillR.(+충전기)', '취득연도: 2024'),
  ('LMK-DEMO-2024182', 'Resusci Baby QCPR, SimPad PLUS SkillR IE', '161-01260', '1611024016', 'RB5', 'BLS', '미확인', 'available', '충전어뎁터, SimPad PLUS SkillR.(+충전기)', '취득연도: 2024'),
  ('LMK-DEMO-2024182', 'Resusci Baby QCPR, SimPad PLUS SkillR IE', '161-01260', '', 'RB6', 'BLS', '미확인', 'available', '충전어뎁터, SimPad PLUS SkillR.(+충전기)', '취득연도: 2024'),
  ('', 'Little Junior QCPR', '128-01050', 'C29155-1541', 'LJ1', 'BLS', '미확인', 'available', '', ''),
  ('', 'Little Junior QCPR', '128-01050', 'C30297-1072', 'LJ2', 'BLS', '미확인', 'available', '', ''),
  ('', 'Little Junior QCPR', '128-01050', 'C30297-1438', 'LJ3', 'BLS', '미확인', 'available', '', ''),
  ('LMK-Demo-2020142', 'Little Baby QCPR 4-Pack', '134-01050', '', 'LB', 'BLS', '미확인', 'available', '', '취득연도: 2020'),
  ('LMK-Demo-2023167', 'Laerdal Monitor AHA (IE) with instructor tablet', '550-02050', '5501523007', 'MBL1', 'MBL', '미확인', 'available', 'iPad(강사용)', '취득연도: 2023'),
  ('LMK-Demo-2023170-1', 'Monitor by Laerdal case AHA', '550-04050', '', 'MBL2', 'MBL', '미확인', 'available', 'iPad(강사용)', '취득연도: 2023'),
  ('LMK-Demo-2026203', 'Emergency Care Learning Lab', '430-00033', '', 'EC1', 'Skill T.', '미확인', 'available', '', '취득연도: 2026'),
  ('LMK-Demo-2026203', 'Emergency Care Learning Lab', '430-00033', '', 'EC2', 'Skill T.', '미확인', 'available', '', '취득연도: 2026'),
  ('', 'Demo LAAS Complete Kit', 'Q135-03150', '13535260006', 'LAAS1', 'Skill T.', '미확인', 'available', '', '취득연도: 2026'),
  ('', 'Demo LAAS Complete Kit', 'Q135-03150', '13535260007', 'LAAS2', 'Skill T.', '미확인', 'available', '', '취득연도: 2026'),
  ('LMK-Demo-2024184', 'Airway Management Trainer (IE)', '25000026', '', 'AMT1', 'Skill T.', '의왕', 'available', 'Lubricant', '취득연도: 2025'),
  ('LMK-Demo-2024184', 'Airway Management Trainer (IE)', '25000026', '', 'AMT2', 'Skill T.', '미확인', 'repair', 'Lubricant', '취득연도: 2025 / 실사 상태: 사용불가'),
  ('LMK-Demo-2017093', 'Paediatric Intubation Trainer', '255-00001', '', 'P-AMT', 'Skill T.', '의왕', 'available', '', '취득연도: 2017'),
  ('', 'Neonatal Intubation Trainer', '250-00101', '', 'N-AMT', 'Skill T.', '의왕', 'available', 'Lubricant', ''),
  ('', 'Arterial Arm Stick Kit', '375-80001', '', 'ARM', 'Skill T.', '의왕', 'available', '', ''),
  ('LMK-Demo-2017096', 'Chest Drain & Needle Decompression trainer', 'LIM-60230', '', 'LIM', 'Skill T.', '미확인', 'repair', '', '제품군: L&T / 취득연도: 2017 / 실사 상태: 사용불가'),
  ('LMK-Demo-2019134', 'Abdominal Examination Trainer (Bag 1/2)', 'LIM-60000', '', 'LIM', 'Skill T.', '의왕', 'available', '', '제품군: L&T / 취득연도: 2019'),
  ('LMK-Demo-2019134', 'Abdominal Examination Trainer (Bag 2/2)', 'LIM-60000', '', 'LIM', 'Skill T.', '의왕', 'available', '', '제품군: L&T / 취득연도: 2019'),
  ('LMK-Demo-2021161', 'Clean Bleed Mat', 'LIM-70408', '', 'LIM', 'Skill T.', '의왕', 'available', '', '제품군: L&T / 취득연도: 2021'),
  ('LMK-Demo-2016082', 'Rectal Examination Trainer Mk 2 (A)', 'LIM-60120', '', 'LIM', 'Skill T.', '의왕', 'available', '', '제품군: L&T / 취득연도: 2016'),
  ('LMK-Demo-2016082', 'Rectal Examination Trainer Mk 2 (B)', 'LIM-60120', '', 'LIM', 'Skill T.', '의왕', 'available', '', '제품군: L&T / 취득연도: 2016'),
  ('LMK-Demo-2016084', 'Clinical Male Pelvic Trainer (Bag 1/2)', 'LIM-60950', '', 'LIM', 'Skill T.', '의왕', 'available', '', '제품군: L&T / 취득연도: 2016'),
  ('LMK-Demo-2016084', 'Clinical Male Pelvic Trainer (Bag2/2)', 'LIM-60951', '', 'LIM', 'Skill T.', '의왕', 'available', '', '제품군: L&T / 취득연도: 2016'),
  ('LMK-Demo-2020150', 'Advanced Venipuncture Arm', 'LIM-70300', '', 'LIM', 'Skill T.', '미확인', 'repair', '', '제품군: L&T / 취득연도: 2021 / 실사 상태: 사용불가'),
  ('LMK-Demo-2024181', 'Advanced Venipuncture Arm', 'LIM-70300', '', 'LIM', 'Skill T.', '의왕', 'available', '', '제품군: L&T / 취득연도: 2024'),
  ('LMK-Demo-2025188', 'Augmented Reality Mat for Catheterisation', 'LIM-60131', '', 'LIM', 'Skill T.', '의왕', 'available', '', '제품군: L&T / 취득연도: 2025'),
  ('LMK-Demo-2025188', 'Augmented Reality Mat for Abdominal Examination', 'LIM-60134', '', 'LIM', 'Skill T.', '의왕', 'available', '', '제품군: L&T / 취득연도: 2025'),
  ('LMK-Demo-2016085', 'PROMPT Flex Birthing', 'LIM-80105', '', 'LIM', 'Skill T.', '미확인', 'repair', '', '제품군: L&T / 취득연도: 2016 / 실사 상태: 사용불가'),
  ('LMK-Demo-2025188', 'Augmented Reality Mat for PROMPT Flex Birthing Simulator', 'LIM-60133', '', 'LIM', 'Skill T.', '의왕', 'available', '', '제품군: L&T / 취득연도: 2025 / Prompt Flex 장비와 함께 위치함.'),
  ('', 'Advanced Male Catheterization Trainer', 'LIM-60151', '', 'LIM', 'Skill T.', '의왕', 'available', '', '제품군: L&T'),
  ('LMK-Demo-2016083', 'Advanced Catheterization Trainer', 'LIM-60150', '', 'LIM', 'Skill T.', '의왕', 'available', '', '제품군: L&T / 취득연도: 2016'),
  ('LMK-Demo-2025183', 'Female Catheterization Trainer', 'LIM-60851', '', 'LIM', 'Skill T.', '의왕', 'available', '', '제품군: L&T / 취득연도: 2025'),
  ('LMK-Demo-2025190', 'Arterial Puncture Wrist', 'LIM-72500', '', 'LIM', 'Skill T.', '의왕', 'available', '', '제품군: L&T / 취득연도: 2025'),
  ('LMK-Demo-2016081', 'Advanced Breast Examination Trainer', 'LIM-40201', '', 'LIM', 'Skill T.', '의왕', 'available', '', '제품군: L&T / 취득연도: 2016'),
  ('LMK-Demo-2016081', 'Peter PICC Line', 'LIM-VTA0600', '', 'LIM', 'Skill T.', '의왕', 'available', '', '제품군: L&T / 취득연도: 2016'),
  ('LMK-Demo-2025189-1', 'CVC Ultrasound Model (Skin, Hand pump)', 'MU-E-CVC-MHS', '1525', 'MU', 'Skill T.', '의왕', 'available', '+교체 스킨 2개 (투명/스킨)', '제품군: MU / 취득연도: 2025'),
  ('LMK-Demo-2025189-1', 'PICC Ultrasound Model (Skin, Hand pump)', 'MU-E-PICC-MHS', '1525', 'MU', 'Skill T.', '의왕', 'available', '', '제품군: MU / 취득연도: 2025'),
  ('LMK-Demo-2025189-1', 'Cardiac Exam US trans Transparent', 'MU-E-HEART-MNT', '', 'MU', 'Skill T.', '의왕', 'available', '', '제품군: MU / 취득연도: 2025'),
  ('LMK-Demo-2025189-1', 'Regional Anesthesia Blk Transparent', 'MU-E-ANA-BNT', '', 'MU', 'Skill T.', '의왕', 'available', '', '제품군: MU / 취득연도: 2025'),
  ('LMK-Demo-2025189-1', 'Regional Anesthesia Blk With skin', 'MU-E-ANA-BNS', '', 'MU', 'Skill T.', '의왕', 'available', '', '제품군: MU / 취득연도: 2025'),
  ('', 'EZ-Arm', 'EZ-7710', '', 'EZ', 'Skill T.', '미확인', 'available', '', '제품군: EZ / 사용 후 액체 완전 제거할 것!'),
  ('', 'EZ-Arm', 'EZ-7710', '', 'EZ', 'Skill T.', '미확인', 'available', '', '제품군: EZ / 사용 후 액체 완전 제거할 것!'),
  ('LMK-Demo-2012028', 'MamaNatalie', '340-01333', '', 'LGH', 'Skill T.', '의왕', 'available', '', '제품군: LGH / 취득연도: 2012'),
  ('', 'MamaNatalie', '340-01333', '', 'LGH', 'Skill T.', '의왕', 'available', '', '제품군: LGH'),
  ('', 'MamaNatalie', '340-01333', '', 'LGH', 'Skill T.', '의왕', 'available', '', '제품군: LGH'),
  ('', 'MamaNatalie', '340-01333', '', 'LGH', 'Skill T.', '의왕', 'available', '', '제품군: LGH'),
  ('LMK-Demo-2018116', 'MamaBirthie(Light)', '360-00133', '', 'LGH', 'Skill T.', '의왕', 'available', '', '제품군: LGH / 취득연도: 2018');

-- 6. Teams 알림: 장비를 내부 ID로 표시
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
      '**' || e.name || '** (' || e.internal_id || ') · ' || coalesce((select display_name from public.profiles where id = new.requester_id), '?'),
      case new.return_method
        when 'drop_uiwang'   then '직접 반납 – 의왕'
        when 'drop_munjeong' then '직접 반납 – 문정'
        when 'pickup'        then '🚚 물류사 회수 요청 → ' || coalesce(new.return_place, '장소 미정') || ' · 회수 요청 메일을 보내 주세요'
        else '반납 방법 기록 없음' end,
      '자가점검: ' || case new.return_self_check
        when 'ok' then '정상' when 'minor' then '경미한 손상'
        when 'broken' then '⚠️ 파손 또는 수리 필요' when 'missing' then '⚠️ 구성품 누락' else '기록 없음' end
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
  for r in select l.loan_no, e.name, e.internal_id, p.display_name, l.due_date
             from public.loans l join public.equipment e on e.id = l.equipment_id
             left join public.profiles p on p.id = l.requester_id
            where l.status = 'out' and l.due_date < v_today order by l.due_date loop
    v_sec := coalesce(v_sec || chr(10), '') || '- ' || r.name || ' (' || r.internal_id || ') · ' || coalesce(r.display_name, '?')
             || ' · ' || (v_today - r.due_date) || '일 지남';
  end loop;
  if v_sec is not null then v_lines := v_lines || ('**🔴 연체**' || chr(10) || v_sec); end if;

  -- 출고 예정 (오늘·내일)
  v_sec := null;
  for r in select l.loan_no, l.start_date, string_agg(e.name, ', ' order by e.internal_id) names,
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
  for r in select e.name, e.internal_id, p.display_name
             from public.loans l join public.equipment e on e.id = l.equipment_id
             left join public.profiles p on p.id = l.requester_id
            where l.status = 'out' and l.due_date = v_today order by e.internal_id loop
    v_sec := coalesce(v_sec || chr(10), '') || '- ' || r.name || ' (' || r.internal_id || ') · ' || coalesce(r.display_name, '?');
  end loop;
  if v_sec is not null then v_lines := v_lines || ('**📥 오늘 반납 예정**' || chr(10) || v_sec); end if;

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

commit;

select category, count(*) from public.equipment group by category order by 1;
