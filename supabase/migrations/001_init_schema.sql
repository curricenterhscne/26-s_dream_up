-- =============================================================
-- 꿈키움 선착순 수강신청 — 001 초기 스키마
-- =============================================================

-- ──────────────────────────────────────────
-- 1. settings (오픈 시각 등 전역 설정)
-- ──────────────────────────────────────────
CREATE TABLE IF NOT EXISTS settings (
  id       int PRIMARY KEY DEFAULT 1 CHECK (id = 1),  -- 단일 행 보장
  open_at  timestamptz NOT NULL,                       -- 수강신청 오픈 시각 (UTC 저장)
  close1_at timestamptz,                               -- 1차 마감 (2026-06-28 15:00+09)
  open2_at  timestamptz,                               -- 2차 오픈 (2026-06-30 18:00+09)
  close2_at timestamptz                                -- 2차 마감 (2026-06-30 21:00+09)
);

-- 초기값 삽입 (이미 존재하면 UPDATE)
INSERT INTO settings (id, open_at, close1_at, open2_at, close2_at)
VALUES (
  1,
  '2026-06-25 18:00:00+09',
  '2026-06-28 15:00:00+09',
  '2026-06-30 18:00:00+09',
  '2026-06-30 21:00:00+09'
)
ON CONFLICT (id) DO UPDATE SET
  open_at   = EXCLUDED.open_at,
  close1_at = EXCLUDED.close1_at,
  open2_at  = EXCLUDED.open2_at,
  close2_at = EXCLUDED.close2_at;

-- ──────────────────────────────────────────
-- 2. courses (강좌 — 89행, HTML DATA에서 시드)
-- ──────────────────────────────────────────
CREATE TABLE IF NOT EXISTS courses (
  code             text PRIMARY KEY,          -- DC26B001 ~ DC26B089
  name             text NOT NULL,             -- 강좌명
  org              text NOT NULL,             -- 기관명
  region           text NOT NULL,             -- 지역
  capacity         int  NOT NULL DEFAULT 15,  -- 정원 (전 강좌 15 균일)
  enrolled_count   int  NOT NULL DEFAULT 0,   -- 현재 신청 인원 (원자적 카운터)
  min_open         int  NOT NULL DEFAULT 5,   -- 폐강 기준 (미만 시 폐강)
  is_registerable  bool NOT NULL DEFAULT true, -- DC26B054만 false
  is_closed_manual bool NOT NULL DEFAULT false -- 운영자 강제 마감
);

-- 정원 초과 방지 DB 레벨 제약 (카운터가 음수·초과 불가)
ALTER TABLE courses ADD CONSTRAINT enrolled_non_negative
  CHECK (enrolled_count >= 0);
ALTER TABLE courses ADD CONSTRAINT enrolled_not_exceed_capacity
  CHECK (enrolled_count <= capacity);

-- ──────────────────────────────────────────
-- 3. enrollments (신청 내역 — 학생당 1행)
-- ──────────────────────────────────────────
CREATE TABLE IF NOT EXISTS enrollments (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  course_code text        NOT NULL REFERENCES courses(code),
  school      text        NOT NULL,   -- 학교명
  student_no  text        NOT NULL,   -- 학번
  name        text        NOT NULL,   -- 이름
  phone       text        NOT NULL,   -- 휴대폰 (숫자만 정규화 저장)
  created_at  timestamptz NOT NULL DEFAULT now(),
  status      text        NOT NULL DEFAULT 'active' CHECK (status IN ('active','cancelled'))
);

-- 중복 방지: 학교+학번 기준 active 1건만
CREATE UNIQUE INDEX IF NOT EXISTS uniq_active_student
  ON enrollments (school, student_no)
  WHERE status = 'active';

-- 중복 방지: 휴대폰 기준 active 1건만 (보조)
CREATE UNIQUE INDEX IF NOT EXISTS uniq_active_phone
  ON enrollments (phone)
  WHERE status = 'active';

-- 정합성 검증 뷰 (enrolled_count vs 실제 카운트 대조용)
CREATE OR REPLACE VIEW v_course_count_check AS
SELECT
  c.code,
  c.enrolled_count        AS counter,
  COUNT(e.id)             AS actual,
  c.enrolled_count - COUNT(e.id) AS diff
FROM courses c
LEFT JOIN enrollments e ON e.course_code = c.code AND e.status = 'active'
GROUP BY c.code, c.enrolled_count
HAVING c.enrolled_count <> COUNT(e.id);  -- 불일치 행만 반환

-- ──────────────────────────────────────────
-- 4. RLS 활성화 (직접 접근 전면 차단)
-- ──────────────────────────────────────────
ALTER TABLE settings    ENABLE ROW LEVEL SECURITY;
ALTER TABLE courses     ENABLE ROW LEVEL SECURITY;
ALTER TABLE enrollments ENABLE ROW LEVEL SECURITY;

-- 정책 없음 = anon/authenticated 모두 직접 SELECT/INSERT/UPDATE/DELETE 불가
-- 모든 접근은 SECURITY DEFINER RPC 경유

-- ──────────────────────────────────────────
-- 5. RPC: get_course_status — 강좌별 잔여석 (개인정보 반환 없음)
-- ──────────────────────────────────────────
CREATE OR REPLACE FUNCTION get_course_status()
RETURNS TABLE (
  code             text,
  name             text,
  org              text,
  region           text,
  capacity         int,
  enrolled_count   int,
  remaining        int,
  is_full          bool,
  is_registerable  bool,
  is_closed_manual bool
)
LANGUAGE sql SECURITY DEFINER STABLE AS $$
  SELECT
    code,
    name,
    org,
    region,
    capacity,
    enrolled_count,
    GREATEST(capacity - enrolled_count, 0) AS remaining,
    (enrolled_count >= capacity OR is_closed_manual) AS is_full,
    is_registerable,
    is_closed_manual
  FROM courses
  ORDER BY code;
$$;

REVOKE EXECUTE ON FUNCTION get_course_status() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION get_course_status() TO anon, authenticated;

-- ──────────────────────────────────────────
-- 6. RPC: get_my_enrollment — 본인 신청 1건 조회
-- ──────────────────────────────────────────
CREATE OR REPLACE FUNCTION get_my_enrollment(
  p_school     text,
  p_student_no text,
  p_phone      text
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER STABLE AS $$
DECLARE
  v_phone text := regexp_replace(p_phone, '[^0-9]', '', 'g');
  v_row   enrollments%ROWTYPE;
  v_cname text;
BEGIN
  SELECT e.* INTO v_row
  FROM enrollments e
  WHERE e.status      = 'active'
    AND e.school      = p_school
    AND e.student_no  = p_student_no
    AND e.phone       = v_phone
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'notfound');
  END IF;

  SELECT name INTO v_cname FROM courses WHERE code = v_row.course_code;

  -- 개인정보(이름·전화) 반환 금지 — 강좌명·상태만 반환
  RETURN jsonb_build_object(
    'ok',          true,
    'course_code', v_row.course_code,
    'course_name', v_cname,
    'status',      v_row.status,
    'created_at',  v_row.created_at
  );
END $$;

REVOKE EXECUTE ON FUNCTION get_my_enrollment(text,text,text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION get_my_enrollment(text,text,text) TO anon, authenticated;

-- ──────────────────────────────────────────
-- 7. RPC: apply_course — 동시성 안전 신청 (이 시스템의 심장)
-- ──────────────────────────────────────────
CREATE OR REPLACE FUNCTION apply_course(
  p_code       text,
  p_school     text,
  p_student_no text,
  p_name       text,
  p_phone      text
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_phone   text := regexp_replace(p_phone, '[^0-9]', '', 'g');
  v_updated int;
  v_s       settings%ROWTYPE;
BEGIN
  -- 0) 신청기간 체크 (서버 시각 기준)
  SELECT * INTO v_s FROM settings LIMIT 1;

  IF now() < v_s.open_at THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_open');
  END IF;

  -- 1차 마감 ~ 2차 오픈 사이 공백기: 신청 차단 (잔여석 조회만 허용)
  IF v_s.close1_at IS NOT NULL AND v_s.open2_at IS NOT NULL
     AND now() > v_s.close1_at AND now() < v_s.open2_at THEN
    RETURN jsonb_build_object('ok', false, 'error', 'between_periods');
  END IF;

  -- 2차 마감 이후
  IF v_s.close2_at IS NOT NULL AND now() > v_s.close2_at THEN
    RETURN jsonb_build_object('ok', false, 'error', 'period_closed');
  END IF;

  -- 1) 이미 신청한 학생인가? (1인 1강좌 — 학번 OR 휴대폰 기준)
  IF EXISTS (
    SELECT 1 FROM enrollments
    WHERE status = 'active'
      AND (
        (school = p_school AND student_no = p_student_no)
        OR phone = v_phone
      )
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'duplicate');
  END IF;

  -- 2) 신청 가능 강좌인지 (DC26B054 등 제외)
  IF NOT EXISTS (
    SELECT 1 FROM courses WHERE code = p_code AND is_registerable = true
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_registerable');
  END IF;

  -- 3) 정원 원자적 확보: 행 잠금 + 조건부 증가 (핵심 — Race Condition 방지)
  UPDATE courses
     SET enrolled_count = enrolled_count + 1
   WHERE code              = p_code
     AND is_registerable   = true
     AND is_closed_manual  = false
     AND enrolled_count    < capacity
  RETURNING 1 INTO v_updated;

  IF v_updated IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'full');
  END IF;

  -- 4) 신청 기록 INSERT (유니크 위반 시 정원 롤백)
  BEGIN
    INSERT INTO enrollments (course_code, school, student_no, name, phone)
    VALUES (p_code, p_school, p_student_no, p_name, v_phone);
  EXCEPTION WHEN unique_violation THEN
    UPDATE courses SET enrolled_count = enrolled_count - 1 WHERE code = p_code;
    RETURN jsonb_build_object('ok', false, 'error', 'duplicate');
  END;

  RETURN jsonb_build_object('ok', true);
END $$;

REVOKE EXECUTE ON FUNCTION apply_course(text,text,text,text,text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION apply_course(text,text,text,text,text) TO anon, authenticated;

-- ──────────────────────────────────────────
-- 8. RPC: cancel_enrollment — 마감 전 본인 취소
-- ──────────────────────────────────────────
CREATE OR REPLACE FUNCTION cancel_enrollment(
  p_school     text,
  p_student_no text,
  p_phone      text
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_phone text := regexp_replace(p_phone, '[^0-9]', '', 'g');
  v_code  text;
  v_s     settings%ROWTYPE;
BEGIN
  -- 신청기간 종료 후엔 취소 불가 (2차 마감 이후)
  SELECT * INTO v_s FROM settings LIMIT 1;
  IF v_s.close2_at IS NOT NULL AND now() > v_s.close2_at THEN
    RETURN jsonb_build_object('ok', false, 'error', 'period_closed');
  END IF;

  -- 본인 확인: 학교+학번+휴대폰 일치하는 active 신청 찾기
  SELECT course_code INTO v_code
  FROM enrollments
  WHERE status     = 'active'
    AND school     = p_school
    AND student_no = p_student_no
    AND phone      = v_phone
  FOR UPDATE;  -- 행 잠금

  IF v_code IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'notfound');
  END IF;

  -- 취소 처리
  UPDATE enrollments
     SET status = 'cancelled'
   WHERE status     = 'active'
     AND school     = p_school
     AND student_no = p_student_no
     AND phone      = v_phone;

  -- 정원 카운터 복원 (자동 재오픈 효과)
  UPDATE courses
     SET enrolled_count = GREATEST(enrolled_count - 1, 0)
   WHERE code = v_code;

  RETURN jsonb_build_object('ok', true);
END $$;

REVOKE EXECUTE ON FUNCTION cancel_enrollment(text,text,text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION cancel_enrollment(text,text,text) TO anon, authenticated;

-- ──────────────────────────────────────────
-- 9. 관리자 전용 RPC: admin_reset_test_data
--    (service_role만 실행 가능 — anon/authenticated 차단)
-- ──────────────────────────────────────────
CREATE OR REPLACE FUNCTION admin_reset_test_data(p_confirm text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF p_confirm <> 'RESET-실행확인' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'confirm_mismatch');
  END IF;

  -- 본번 시작 후 실수 방지: open_at 이후엔 실행 거부
  IF now() >= (SELECT open_at FROM settings LIMIT 1) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'already_open');
  END IF;

  TRUNCATE TABLE enrollments;
  UPDATE courses SET enrolled_count = 0, is_closed_manual = false;
  UPDATE settings SET open_at = '2026-06-25 18:00:00+09';

  RETURN jsonb_build_object('ok', true);
END $$;

-- anon/authenticated 호출 차단 — service_role만 실행 가능
REVOKE EXECUTE ON FUNCTION admin_reset_test_data(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION admin_reset_test_data(text) FROM anon;
REVOKE EXECUTE ON FUNCTION admin_reset_test_data(text) FROM authenticated;
