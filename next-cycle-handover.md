# 꿈키움 수강신청 — 다음 회기 인수인계

## 시스템 개요
충청남도교육청 꿈키움 학교 밖 교육 창의적체험활동 수강신청 시스템.
- **학생 수강신청**: GitHub Pages (`index.html`)
- **강좌 안내**: GitHub Pages (`guide.html`)
- **관리자**: Vercel (`admin/`)
- **DB/백엔드**: Supabase (PostgreSQL + RLS + 서버리스 RPC)

---

## 다음 회기에 업데이트해야 할 것들

### 1. 강좌 데이터 (`_embed_data.js` + Supabase)
강좌 정보가 담긴 파일:
- `_embed_data.js` — 프론트엔드 강좌 목록 표시용 (guide.html, index.html)
- `supabase/migrations/002_seed_courses.sql` — Supabase DB 시드

업데이트 절차:
1. 새 강좌 Excel/JSON을 받아 `_embed_data.js`의 `COURSE_DETAILS` 배열 교체
2. 강좌 코드 체계 확인 (현재: DC26B001~DC26B089)
3. `002_seed_courses.sql` 새 강좌 데이터로 재작성
4. Supabase SQL 에디터에서 기존 courses 데이터 삭제 후 새 시드 실행:
   ```sql
   TRUNCATE TABLE courses CASCADE;  -- enrollments도 함께 삭제됨
   -- 이후 새 002_seed_courses.sql 실행
   ```
5. 보령시 별도모집 강좌 등 `is_registerable=false` 대상 확인 후 UPDATE

### 2. 학교 데이터 (`schools_rows.sql`)
- 학교 추가/변경 없으면 재사용 가능
- 변경 시 `schools_rows.sql` 업데이트 후 Supabase에서 실행

### 3. 수강신청 일정 (`settings` 테이블)
Supabase SQL 에디터에서:
```sql
UPDATE settings SET
  open_at   = '2027-XX-XX 18:00:00+09',   -- 1차 오픈
  close1_at = '2027-XX-XX 15:00:00+09',   -- 1차 마감
  open2_at  = '2027-XX-XX 18:00:00+09',   -- 2차 오픈
  close2_at = '2027-XX-XX 21:00:00+09';   -- 2차 마감
```

### 4. 안내 텍스트 (index.html, guide.html 공통)
- 운영 기간, 신청 일정, 연도 등 텍스트 검색 후 일괄 수정
- 주요 검색어: `2026`, `6. 25`, `6. 28`, `6. 30`, `7. 20`, `8. 9`

### 5. 정원 수 변경 시
- 현재 전 강좌 capacity=15
- 변경 필요 시: `UPDATE courses SET capacity = {새정원};`

---

## 변경 불필요한 것들 (재사용)
- ✅ Supabase 스키마 (001, 003 migration) — 재실행 불필요
- ✅ 학교 데이터 (변동 없으면)
- ✅ admin/ Vercel 배포 — 강좌 데이터와 무관하게 그대로 동작
- ✅ 신청/취소/조회 RPC 로직
- ✅ index.html UI 구조 및 신청 흐름
- ✅ guide.html 강좌 안내 UI 구조

---

## 오픈 직전 체크리스트

- [ ] 새 강좌 데이터 `_embed_data.js` 반영 및 커밋/푸시
- [ ] Supabase courses 테이블 새 데이터로 교체
- [ ] settings 테이블 일정 업데이트
- [ ] Vercel admin 환경변수 확인 (SUPABASE_SERVICE_ROLE_KEY 만료 여부)
- [ ] 오픈 직전 리셋 SQL 실행:
  ```sql
  TRUNCATE TABLE enrollments;
  UPDATE courses SET enrolled_count = 0, is_closed_manual = false;
  ```
- [ ] 테스트: 신청 → 확정 → 취소 흐름 확인
- [ ] 관리자 페이지 명단/CSV 확인
- [ ] 학생 공지 URL: GitHub Pages 메인 URL (`index.html`)

---

## 인프라 정보

| 항목 | 값 |
|---|---|
| GitHub 레포 | `curricenterhscne/26-s_dream_up` |
| GitHub Pages URL | `https://curricenterhscne.github.io/26-s_dream_up/` |
| Supabase URL | `https://yhrgvnttjlitukrxdfdo.supabase.co` |
| Vercel (admin) | Root Directory: `admin`, Node 24.x |
| Vercel 환경변수 | SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY / ADMIN_PASSWORD |

---

## Claude Code에게 넘길 때 말할 것

> "꿈키움 수강신청 시스템 다음 회기 업데이트야.
> 새 강좌 데이터 파일 줄게. _embed_data.js와 Supabase courses 테이블을 교체하고,
> 안내 텍스트의 연도/일정을 [새 일정]으로 바꿔줘.
> 나머지 인프라(Supabase 스키마, Vercel admin, UI 구조)는 그대로 재사용해."
