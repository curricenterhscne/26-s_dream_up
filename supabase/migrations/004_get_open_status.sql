-- =============================================================
-- 꿈키움 004: get_open_status RPC — 1·2차 오픈 기간 지원
-- =============================================================

CREATE OR REPLACE FUNCTION get_open_status()
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_s     settings%ROWTYPE;
  v_open  bool := false;
  v_phase text := 'closed';
BEGIN
  SELECT * INTO v_s FROM settings LIMIT 1;

  IF now() < v_s.open_at THEN
    -- 1차 오픈 전
    v_phase := 'before_open';

  ELSIF v_s.close1_at IS NULL OR now() <= v_s.close1_at THEN
    -- 1차 신청 기간
    v_phase := 'open1';
    v_open  := true;

  ELSIF v_s.open2_at IS NOT NULL AND now() < v_s.open2_at THEN
    -- 1차 마감 ~ 2차 오픈 사이 공백
    v_phase := 'between';

  ELSIF v_s.open2_at IS NOT NULL AND now() >= v_s.open2_at
    AND (v_s.close2_at IS NULL OR now() <= v_s.close2_at) THEN
    -- 2차 신청 기간
    v_phase := 'open2';
    v_open  := true;

  ELSE
    v_phase := 'closed';
  END IF;

  RETURN jsonb_build_object(
    'server_now', now(),
    'is_open',    v_open,
    'phase',      v_phase,
    'open_at',    v_s.open_at,
    'close1_at',  v_s.close1_at,
    'open2_at',   v_s.open2_at,
    'close2_at',  v_s.close2_at
  );
END $$;

REVOKE EXECUTE ON FUNCTION get_open_status() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION get_open_status() TO anon, authenticated;
