-- 데모장비 샘플 10대 등록 (Supabase SQL Editor에서 실행)
-- 모든 샘플은 관리 메모에 '[샘플]'이 붙어 있다. 실제 장비 등록 전에 아래 삭제 SQL로 지운다.

insert into public.equipment (asset_no, name, category, location, status, components, note) values
('DEMO-0001', 'Resusci Anne QCPR',          'BLS',            '문정', 'available', '마네킹 본체, 얼굴 피부 2, 기도 10, 케이스',                '[샘플] 실사 후 삭제'),
('DEMO-0002', 'Little Anne QCPR',           'BLS',            '문정', 'available', '마네킹 본체, 얼굴 피부, 기도 5, 가방',                     '[샘플] 실사 후 삭제'),
('DEMO-0003', 'Little Anne QCPR',           'BLS',            '의왕', 'available', '마네킹 본체, 얼굴 피부, 기도 5, 가방',                     '[샘플] 실사 후 삭제'),
('DEMO-0004', 'AED Trainer 3',              'BLS',            '문정', 'available', '트레이너 본체, 패드 2세트, 리모컨, 케이스',                 '[샘플] 실사 후 삭제'),
('DEMO-0005', 'SimMan 3G PLUS',             '환자 시뮬레이터', '의왕', 'available', '본체, 태블릿, 링크 박스, 전원 케이블, 운반 케이스 2',        '[샘플] 실사 후 삭제'),
('DEMO-0006', 'SimJunior',                  '환자 시뮬레이터', '의왕', 'available', '본체, 태블릿, 전원 케이블, 운반 케이스',                    '[샘플] 실사 후 삭제'),
('DEMO-0007', 'Nursing Anne Simulator',     '환자 시뮬레이터', '의왕', 'available', '본체, 태블릿, 교체용 모듈 세트, 운반 케이스',               '[샘플] 실사 후 삭제'),
('DEMO-0008', 'Airway Management Trainer',  'ALS',            '문정', 'available', '머리 모델, 받침대, 윤활제, 가방',                          '[샘플] 실사 후 삭제'),
('DEMO-0009', 'IV Training Arm',            '술기 트레이너',   '문정', 'repair',    '팔 본체, 혈관 튜브, 피부, 수액 백',                         '[샘플] 실사 후 삭제 · 혈관 튜브 교체 대기'),
('DEMO-0010', 'SimCapture 데모 키트',        '소프트웨어',      '문정', 'available', '노트북, 카메라 2, 마이크, 케이블 세트',                     '[샘플] 실사 후 삭제');

-- 결과 확인
select asset_no, name, category, location, status from public.equipment order by asset_no;

-- ---------------------------------------------------------------
-- 샘플 삭제 (실제 장비를 등록하기 전에 실행)
-- 샘플 장비로 출납 신청을 했다면 그 기록도 함께 지운다.
-- ---------------------------------------------------------------
-- delete from public.shipments where loan_no in (
--   select l.loan_no from public.loans l join public.equipment e on e.id = l.equipment_id where e.note like '[샘플]%');
-- delete from public.loans where equipment_id in (select id from public.equipment where note like '[샘플]%');
-- delete from public.equipment where note like '[샘플]%';
