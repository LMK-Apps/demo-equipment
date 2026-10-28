-- =====================================================================
-- Teams 웹훅 주소 저장 (Supabase SQL Editor에서 직접 실행)
-- 이 파일을 고쳐서 GitHub에 올리지 마세요. 주소는 SQL Editor에만 붙여 넣으세요.
-- =====================================================================

-- 처음 저장할 때
select vault.create_secret('여기에-Teams-웹훅-URL-붙여넣기', 'teams_webhook_url', 'Teams 데모장비 알림 채널');

-- 주소를 바꿀 때 (처음 저장할 때는 실행하지 않음)
-- select vault.update_secret((select id from vault.secrets where name = 'teams_webhook_url'), '새-웹훅-URL');

-- 시험 메시지 보내기: 실행하고 10초 안에 Teams 채널에 카드가 보이면 성공
select private.teams_send('✅ 데모장비 알림 연결 시험', array['이 메시지가 보이면 알림 설정이 끝난 거예요.'], 'home');

-- 전송 결과 확인 (status_code 202 또는 200이면 성공)
-- select id, status_code, left(content, 120) as content, created from net._http_response order by created desc limit 5;
