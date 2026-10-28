# 작업 규칙

- 앱을 고칠 때마다 `index.html`의 `CHANGELOG` 배열 맨 위에 새 버전 항목을 추가한다. 화면의 버전 번호는 이 첫 항목에서 자동으로 읽는다.
- 버전 규칙: 버그 수정, 순서·문구 변경 같은 작은 수정은 세 번째 자리를 올린다 (v1.7.0 → v1.7.1). 새 기능 추가는 두 번째 자리를 올린다 (v1.7.1 → v1.8.0). 큰 개편만 첫 자리를 올린다.
- 그다음 `node tools/make_changelog.js`로 `CHANGELOG.md`를 다시 만든다. `CHANGELOG.md`는 직접 고치지 않는다.
- DB 변경은 `supabase/migrations/NNN_이름.sql`로 새 파일을 만들고, 버전 항목의 `db`에 파일 이름을 적는다. SQL 실행은 사용자가 Supabase SQL Editor에서 직접 한다. DB 변경이 있는 버전은 사용자가 SQL을 실행한 뒤에 `main`에 올린다.
- 비밀 키(`sb_secret_`, `service_role`), DB 비밀번호는 절대 커밋하지 않는다. 공개 키(`sb_publishable_`)만 허용한다.
- `main`에 올리면 GitHub Pages로 바로 배포된다. 올리기 전에 스크립트 문법 검사와 브라우저 확인을 한다.
- 사용자 안내 문구는 한국어, 짧은 문장, 존댓말 안내문("~해 주세요")으로 쓴다.
