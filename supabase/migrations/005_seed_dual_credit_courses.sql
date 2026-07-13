-- 005_seed_dual_credit_courses.sql
-- 2026학년도 2학기 고교-대학 연계 학점 인정 14강좌 데이터 교체
-- ⚠️ 실행 전 반드시 enrollments 테이블 비워야 합니다 (FK 제약)

-- 1) 기존 데이터 정리
TRUNCATE TABLE enrollments;
DELETE FROM courses;

-- 2) 14개 신규 강좌 삽입 (capacity=15)
INSERT INTO courses (code, name, org, region, capacity, enrolled_count, is_registerable, is_closed_manual) VALUES ('GD26C001', '교육과 심리학의 이해', '국립공주대학교', '천안', 15, 0, true, false);
INSERT INTO courses (code, name, org, region, capacity, enrolled_count, is_registerable, is_closed_manual) VALUES ('GD26C002', '몽골학으로 읽는 AI 시대', '단국대학교', '천안', 15, 0, true, false);
INSERT INTO courses (code, name, org, region, capacity, enrolled_count, is_registerable, is_closed_manual) VALUES ('GD26C003', '아랍어와 아랍문화', '단국대학교', '천안', 15, 0, true, false);
INSERT INTO courses (code, name, org, region, capacity, enrolled_count, is_registerable, is_closed_manual) VALUES ('GD26C004', '베트남 이해와 탐구 프로젝트', '단국대학교', '천안', 15, 0, true, false);
INSERT INTO courses (code, name, org, region, capacity, enrolled_count, is_registerable, is_closed_manual) VALUES ('GD26C005', '포르투갈·브라질 언어와 문화의 이해', '단국대학교', '천안', 15, 0, true, false);
INSERT INTO courses (code, name, org, region, capacity, enrolled_count, is_registerable, is_closed_manual) VALUES ('GD26C006', '글로벌 이슈 탐구와 영어 학술 연구 실제', '단국대학교', '천안', 15, 0, true, false);
INSERT INTO courses (code, name, org, region, capacity, enrolled_count, is_registerable, is_closed_manual) VALUES ('GD26C007', '미적분학 핵심 개념 탐구', '단국대학교', '천안', 15, 0, true, false);
INSERT INTO courses (code, name, org, region, capacity, enrolled_count, is_registerable, is_closed_manual) VALUES ('GD26C008', '화학분석기기의 이해 및 실습', '단국대학교', '천안', 15, 0, true, false);
INSERT INTO courses (code, name, org, region, capacity, enrolled_count, is_registerable, is_closed_manual) VALUES ('GD26C009', '보건과 건강관리', '백석대학교', '천안', 15, 0, true, false);
INSERT INTO courses (code, name, org, region, capacity, enrolled_count, is_registerable, is_closed_manual) VALUES ('GD26C010', '베이킹과 조리 실습', '백석대학교', '천안', 15, 0, true, false);
INSERT INTO courses (code, name, org, region, capacity, enrolled_count, is_registerable, is_closed_manual) VALUES ('GD26C011', '사건으로 읽는 법과학', '순천향대학교', '아산', 15, 0, true, false);
INSERT INTO courses (code, name, org, region, capacity, enrolled_count, is_registerable, is_closed_manual) VALUES ('GD26C012', '호텔리어의 이해', '순천향대학교', '아산', 15, 0, true, false);
INSERT INTO courses (code, name, org, region, capacity, enrolled_count, is_registerable, is_closed_manual) VALUES ('GD26C013', '예술활용 심리상담', '순천향대학교', '아산', 15, 0, true, false);
INSERT INTO courses (code, name, org, region, capacity, enrolled_count, is_registerable, is_closed_manual) VALUES ('GD26C014', '네 가지 시선으로 탐험하는 생명과학', '충남대학교', '대전', 15, 0, true, false);

-- 3) settings 업데이트: 단일 신청 기간
UPDATE settings SET
  open_at    = '2026-07-16T18:00:00+09:00',
  close1_at  = '2026-07-31T23:59:59+09:00',
  open2_at   = NULL,
  close2_at  = NULL;
