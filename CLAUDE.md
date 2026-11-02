# 작업 규칙

- 앱을 고칠 때마다 `index.html`의 `CHANGELOG` 배열 맨 위에 새 버전 항목을 추가한다. 화면의 버전 번호는 이 첫 항목에서 자동으로 읽는다.
- 버전 규칙: 형식은 `v0.xxx`(소수점 셋째 자리). v0.001부터 시작해 배포할 때마다 0.001씩 올린다 (v0.028 → v0.029). 소수점 뒤 숫자가 정식 출시 전 총 배포 횟수가 된다 (사용자 결정, 2026-10-29). 정식 운영을 시작할 때만 v1.000으로 올린다.
- 그다음 `node tools/make_changelog.js`로 `CHANGELOG.md`를 다시 만든다. `CHANGELOG.md`는 직접 고치지 않는다.
- DB 변경은 `supabase/migrations/NNN_이름.sql`로 새 파일을 만들고, 버전 항목의 `db`에 파일 이름을 적는다. SQL 실행은 사용자가 Supabase SQL Editor에서 직접 한다. DB 변경이 있는 버전은 사용자가 SQL을 실행한 뒤에 `main`에 올린다.
- 비밀 키(`sb_secret_`, `service_role`), DB 비밀번호는 절대 커밋하지 않는다. 공개 키(`sb_publishable_`)만 허용한다.
- `main`에 올리면 GitHub Pages로 바로 배포된다. 올리기 전에 스크립트 문법 검사와 브라우저 확인을 한다.
- 사용자 안내 문구는 한국어, 짧은 문장, 존댓말 안내문("~해 주세요")으로 쓴다.
- 사용자 매뉴얼은 `manual/manual.md`가 원본이다. 고친 뒤 `python3 tools/make_manual.py`로 `manual/index.html`을 다시 만든다. 앱 맨 아래와 로그인 화면의 '사용 설명서' 링크가 `manual/`을 연다. 그림은 `manual/img/`에 둔다. 매뉴얼을 만들 때 CHANGELOG 맨 위 버전과 오늘 날짜가 ‘최종 업데이트’로 들어가므로, 앱 버전 항목을 먼저 추가한 뒤 만든다.
- 영어 화면: `i18n/en.js` 사전으로 화면 글자를 바꾼다(앱 코드는 한국어 그대로). 화면 문구나 서버 오류 메시지를 새로 만들거나 바꾸면 `i18n/en.js`에도 영어를 넣는다. DB로 가는 값(분류·목적·위치 등)은 번역하지 않는다. 공개 전에는 `I18N_PUBLIC = false`라 `?lang=en`으로 연 기기만 영어로 보인다.
