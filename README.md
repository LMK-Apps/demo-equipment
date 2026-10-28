# 데모장비 출납

Laerdal Medical Korea 사내 데모장비 관리·출납 신청·배송 요청·반납 대장 앱.

- 앱 주소: https://lmk-apps.github.io/demo-equipment/
- 버전 기록: [CHANGELOG.md](CHANGELOG.md)

## 구성

| 구성 | 역할 |
| --- | --- |
| GitHub Pages | 화면(`index.html`) 배포. `main` 브랜치에 올라가면 1~2분 뒤 반영 |
| Supabase | 카카오 로그인, DB(Postgres), 권한(RLS) |
| Kakao Developers | 카카오 로그인 앱 |

## 폴더

| 경로 | 내용 |
| --- | --- |
| `index.html` | 앱 전체 (화면, 버전 기록 포함) |
| `manifest.webmanifest`, `*.png` | 홈 화면 앱 이름과 아이콘 |
| `supabase/schema.sql` | DB 첫 설치 스키마 |
| `supabase/migrations/` | 이후 DB 변경. 번호 순서대로 Supabase SQL Editor에서 실행 |
| `supabase/sample_equipment.sql` | 샘플 장비 10대와 삭제 SQL |
| `tools/make_changelog.js` | `index.html`의 버전 기록에서 `CHANGELOG.md` 생성 |

## 보안 원칙

- 코드에는 Supabase **공개 키**(`sb_publishable_`)만 둔다. 비밀 키, DB 비밀번호는 절대 올리지 않는다.
- 모든 권한은 DB(RLS, 트리거, 함수)가 판단한다. 화면에서 버튼을 숨기는 것은 보안이 아니다.
