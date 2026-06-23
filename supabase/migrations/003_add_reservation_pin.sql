-- =============================================================
-- 꿈키움 003: 학교 테이블 · PIN 취소 · 선점(reserve) 패턴
-- =============================================================

-- 0) pgcrypto (SHA-256 PIN 해시)
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ──────────────────────────────────────────
-- 1. schools 테이블
-- ──────────────────────────────────────────
CREATE TABLE IF NOT EXISTS schools (
  neis_code   text PRIMARY KEY,
  name        text NOT NULL,
  region_code text,
  region_name text
);
ALTER TABLE schools ENABLE ROW LEVEL SECURITY;
-- 개인정보 없으므로 anon 직접 SELECT 허용
DROP POLICY IF EXISTS schools_read ON schools;
CREATE POLICY schools_read ON schools FOR SELECT USING (true);

-- ──────────────────────────────────────────
-- 2. enrollments 스키마 변경
-- ──────────────────────────────────────────
ALTER TABLE enrollments ADD COLUMN IF NOT EXISTS cancel_pin     text;
ALTER TABLE enrollments ADD COLUMN IF NOT EXISTS reservation_id uuid UNIQUE;
ALTER TABLE enrollments ADD COLUMN IF NOT EXISTS expires_at     timestamptz;

-- status에 pending / expired 추가
ALTER TABLE enrollments DROP CONSTRAINT IF EXISTS enrollments_status_check;
ALTER TABLE enrollments ADD CONSTRAINT enrollments_status_check
  CHECK (status IN ('pending','active','cancelled','expired'));

-- pending 행은 학생 정보 없으므로 NOT NULL 해제
ALTER TABLE enrollments ALTER COLUMN school     DROP NOT NULL;
ALTER TABLE enrollments ALTER COLUMN student_no DROP NOT NULL;
ALTER TABLE enrollments ALTER COLUMN name       DROP NOT NULL;
ALTER TABLE enrollments ALTER COLUMN phone      DROP NOT NULL;

-- ──────────────────────────────────────────
-- 3. get_course_status 재작성 (만료 pending 정리 포함)
--    VOLATILE로 변경 (cleanup UPDATE 포함)
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
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  -- 만료된 pending 전량 정리 → 카운터 복원
  WITH exp AS (
    UPDATE enrollments SET status = 'expired'
    WHERE status = 'pending' AND expires_at < now()
    RETURNING course_code
  )
  UPDATE courses c
     SET enrolled_count = GREATEST(
           c.enrolled_count
           - (SELECT count(*) FROM exp WHERE exp.course_code = c.code),
           0)
   WHERE code IN (SELECT DISTINCT course_code FROM exp);

  RETURN QUERY
  SELECT
    c.code, c.name, c.org, c.region,
    c.capacity, c.enrolled_count,
    GREATEST(c.capacity - c.enrolled_count, 0),
    (c.enrolled_count >= c.capacity OR c.is_closed_manual),
    c.is_registerable,
    c.is_closed_manual
  FROM courses c
  ORDER BY c.code;
END $$;

REVOKE EXECUTE ON FUNCTION get_course_status() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION get_course_status() TO anon, authenticated;

-- ──────────────────────────────────────────
-- 4. reserve_course — 30초 선점 RPC
-- ──────────────────────────────────────────
CREATE OR REPLACE FUNCTION reserve_course(p_code text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_rid uuid        := gen_random_uuid();
  v_exp timestamptz := now() + interval '30 seconds';
  v_upd int;
  v_s   settings%ROWTYPE;
BEGIN
  SELECT * INTO v_s FROM settings LIMIT 1;

  -- 신청 기간 체크
  IF now() < v_s.open_at THEN
    RETURN jsonb_build_object('ok',false,'error','not_open');
  END IF;
  IF v_s.close1_at IS NOT NULL AND v_s.open2_at IS NOT NULL
     AND now() > v_s.close1_at AND now() < v_s.open2_at THEN
    RETURN jsonb_build_object('ok',false,'error','between_periods');
  END IF;
  IF v_s.close2_at IS NOT NULL AND now() > v_s.close2_at THEN
    RETURN jsonb_build_object('ok',false,'error','period_closed');
  END IF;

  -- 이 강좌의 만료 pending 정리
  WITH exp AS (
    UPDATE enrollments SET status = 'expired'
    WHERE course_code = p_code AND status = 'pending' AND expires_at < now()
    RETURNING 1
  )
  UPDATE courses
     SET enrolled_count = GREATEST(enrolled_count - (SELECT count(*) FROM exp), 0)
   WHERE code = p_code;

  -- 신청 가능 강좌?
  IF NOT EXISTS (SELECT 1 FROM courses WHERE code = p_code AND is_registerable) THEN
    RETURN jsonb_build_object('ok',false,'error','not_registerable');
  END IF;

  -- 좌석 원자적 확보
  UPDATE courses
     SET enrolled_count = enrolled_count + 1
   WHERE code = p_code
     AND is_registerable   = true
     AND is_closed_manual  = false
     AND enrolled_count    < capacity
  RETURNING 1 INTO v_upd;

  IF v_upd IS NULL THEN
    RETURN jsonb_build_object('ok',false,'error','full');
  END IF;

  -- pending 행 생성
  INSERT INTO enrollments(course_code, status, reservation_id, expires_at)
  VALUES (p_code, 'pending', v_rid, v_exp);

  RETURN jsonb_build_object(
    'ok',             true,
    'reservation_id', v_rid,
    'expires_at',     v_exp
  );
END $$;

REVOKE EXECUTE ON FUNCTION reserve_course(text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION reserve_course(text) TO anon, authenticated;

-- ──────────────────────────────────────────
-- 5. confirm_enrollment — 선점 확정
-- ──────────────────────────────────────────
CREATE OR REPLACE FUNCTION confirm_enrollment(
  p_rid    uuid,
  p_school text,
  p_stno   text,
  p_name   text,
  p_phone  text,
  p_pin    text   -- 4자리 숫자 평문, 서버에서 SHA-256 해시
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_phone text := regexp_replace(p_phone, '[^0-9]', '', 'g');
  v_pin   text := encode(digest(p_pin, 'sha256'), 'hex');
  v_row   enrollments%ROWTYPE;
BEGIN
  SELECT * INTO v_row
  FROM enrollments
  WHERE reservation_id = p_rid AND status = 'pending'
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok',false,'error','reservation_notfound');
  END IF;

  -- 만료 확인
  IF now() > v_row.expires_at THEN
    UPDATE enrollments SET status = 'expired'   WHERE id = v_row.id;
    UPDATE courses SET enrolled_count = GREATEST(enrolled_count - 1, 0) WHERE code = v_row.course_code;
    RETURN jsonb_build_object('ok',false,'error','reservation_expired');
  END IF;

  -- 중복 확인 (학교+학번 또는 전화)
  IF EXISTS (
    SELECT 1 FROM enrollments
    WHERE status = 'active'
      AND id <> v_row.id
      AND ((school = p_school AND student_no = p_stno) OR phone = v_phone)
  ) THEN
    UPDATE enrollments SET status = 'expired'   WHERE id = v_row.id;
    UPDATE courses SET enrolled_count = GREATEST(enrolled_count - 1, 0) WHERE code = v_row.course_code;
    RETURN jsonb_build_object('ok',false,'error','duplicate');
  END IF;

  -- 확정
  BEGIN
    UPDATE enrollments
       SET status      = 'active',
           school      = p_school,
           student_no  = p_stno,
           name        = p_name,
           phone       = v_phone,
           cancel_pin  = v_pin,
           expires_at  = NULL
     WHERE id = v_row.id;
  EXCEPTION WHEN unique_violation THEN
    UPDATE enrollments SET status = 'expired'   WHERE id = v_row.id;
    UPDATE courses SET enrolled_count = GREATEST(enrolled_count - 1, 0) WHERE code = v_row.course_code;
    RETURN jsonb_build_object('ok',false,'error','duplicate');
  END;

  RETURN jsonb_build_object('ok', true);
END $$;

REVOKE EXECUTE ON FUNCTION confirm_enrollment(uuid,text,text,text,text,text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION confirm_enrollment(uuid,text,text,text,text,text) TO anon, authenticated;

-- ──────────────────────────────────────────
-- 6. cancel_enrollment — 4자리 PIN 추가 (기존 3인자 버전 제거)
-- ──────────────────────────────────────────
DROP FUNCTION IF EXISTS cancel_enrollment(text, text, text);

CREATE OR REPLACE FUNCTION cancel_enrollment(
  p_school text,
  p_stno   text,
  p_phone  text,
  p_pin    text   -- 4자리 취소 비번
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_phone text := regexp_replace(p_phone, '[^0-9]', '', 'g');
  v_pin   text := encode(digest(p_pin, 'sha256'), 'hex');
  v_code  text;
  v_s     settings%ROWTYPE;
BEGIN
  SELECT * INTO v_s FROM settings LIMIT 1;
  IF v_s.close2_at IS NOT NULL AND now() > v_s.close2_at THEN
    RETURN jsonb_build_object('ok',false,'error','period_closed');
  END IF;

  SELECT course_code INTO v_code
  FROM enrollments
  WHERE status     = 'active'
    AND school     = p_school
    AND student_no = p_stno
    AND phone      = v_phone
    AND cancel_pin = v_pin
  FOR UPDATE;

  IF v_code IS NULL THEN
    RETURN jsonb_build_object('ok',false,'error','notfound_or_wrong_pin');
  END IF;

  UPDATE enrollments
     SET status = 'cancelled'
   WHERE status     = 'active'
     AND school     = p_school
     AND student_no = p_stno
     AND phone      = v_phone;

  UPDATE courses
     SET enrolled_count = GREATEST(enrolled_count - 1, 0)
   WHERE code = v_code;

  RETURN jsonb_build_object('ok', true);
END $$;

REVOKE EXECUTE ON FUNCTION cancel_enrollment(text,text,text,text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION cancel_enrollment(text,text,text,text) TO anon, authenticated;

-- ──────────────────────────────────────────
-- 7. release_reservation — 사용자가 직접 닫을 때 즉시 반납
-- ──────────────────────────────────────────
CREATE OR REPLACE FUNCTION release_reservation(p_rid uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_row enrollments%ROWTYPE;
BEGIN
  SELECT * INTO v_row FROM enrollments
  WHERE reservation_id = p_rid AND status = 'pending' FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok',false,'error','notfound');
  END IF;
  UPDATE enrollments SET status = 'expired'                        WHERE id = v_row.id;
  UPDATE courses SET enrolled_count = GREATEST(enrolled_count-1,0) WHERE code = v_row.course_code;
  RETURN jsonb_build_object('ok', true);
END $$;

REVOKE EXECUTE ON FUNCTION release_reservation(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION release_reservation(uuid) TO anon, authenticated;

-- ──────────────────────────────────────────
-- 8. get_my_enrollment — 서명 동일, PIN 불필요(조회는 학번+전화면 충분)
-- ──────────────────────────────────────────
-- 기존 함수 그대로 유지 (변경 없음)

-- ──────────────────────────────────────────
-- 8. admin_reset_test_data 재작성 (pending/expired 포함 정리)
-- ──────────────────────────────────────────
CREATE OR REPLACE FUNCTION admin_reset_test_data(p_confirm text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF p_confirm <> 'RESET-실행확인' THEN
    RETURN jsonb_build_object('ok',false,'error','confirm_mismatch');
  END IF;
  IF now() >= (SELECT open_at FROM settings LIMIT 1) THEN
    RETURN jsonb_build_object('ok',false,'error','already_open');
  END IF;
  TRUNCATE TABLE enrollments;
  UPDATE courses SET enrolled_count = 0, is_closed_manual = false, capacity = 15;
  UPDATE settings SET open_at = '2026-06-25 18:00:00+09';
  RETURN jsonb_build_object('ok',true);
END $$;

REVOKE EXECUTE ON FUNCTION admin_reset_test_data(text) FROM anon;
REVOKE EXECUTE ON FUNCTION admin_reset_test_data(text) FROM authenticated;
