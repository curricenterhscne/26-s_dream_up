/**
 * 꿈키움 선착순 수강신청 — 동시성 테스트
 *
 * 목적: 정원 15인 강좌에 동시 50요청을 보내
 *       정확히 15건만 성공하는지 검증.
 *
 * 사전 설정:
 *   1) Supabase 마이그레이션(001, 002) 적용 완료
 *   2) 테스트를 위해 settings.open_at을 과거로 설정:
 *      UPDATE settings SET open_at = now() - interval '1 minute';
 *   3) 테스트 후 초기화 SQL(§10-5) 실행
 *
 * 실행:
 *   SUPABASE_URL=https://xxx.supabase.co \
 *   SUPABASE_ANON_KEY=eyJ... \
 *   TEST_COURSE_CODE=DC26B001 \
 *   node test/concurrency_test.js
 *
 * 선택 옵션:
 *   CONCURRENT=50   동시 요청 수 (기본 50)
 *   CAPACITY=15     기대 정원 (기본 15)
 */

'use strict';

const SUPABASE_URL  = process.env.SUPABASE_URL;
const SUPABASE_ANON = process.env.SUPABASE_ANON_KEY;
const COURSE_CODE   = process.env.TEST_COURSE_CODE || 'DC26B001';
const CONCURRENT    = parseInt(process.env.CONCURRENT || '50', 10);
const CAPACITY      = parseInt(process.env.CAPACITY   || '15', 10);

if (!SUPABASE_URL || !SUPABASE_ANON) {
  console.error('[ERROR] SUPABASE_URL 과 SUPABASE_ANON_KEY 환경변수를 설정하세요.');
  process.exit(1);
}

// ── RPC 호출 헬퍼 ──────────────────────────────────────────────
async function rpc(fnName, params) {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${fnName}`, {
    method: 'POST',
    headers: {
      'Content-Type':  'application/json',
      'apikey':        SUPABASE_ANON,
      'Authorization': `Bearer ${SUPABASE_ANON}`,
    },
    body: JSON.stringify(params),
  });

  const text = await res.text();
  try   { return JSON.parse(text); }
  catch { return { ok: false, error: `http_${res.status}`, raw: text }; }
}

// ── 학생 데이터 생성 ────────────────────────────────────────────
function makeStudent(i) {
  const n   = String(i).padStart(4, '0');
  const phone = `010${n}${n}`;          // 010XXXXXX 형식 (숫자만)
  return {
    p_code:       COURSE_CODE,
    p_school:     '테스트고등학교',
    p_student_no: `2026${n}`,
    p_name:       `테스트학생${i}`,
    p_phone:      phone,
  };
}

// ── 메인 ────────────────────────────────────────────────────────
async function main() {
  console.log('='.repeat(60));
  console.log('꿈키움 동시성 테스트');
  console.log(`강좌: ${COURSE_CODE}  동시요청: ${CONCURRENT}  기대정원: ${CAPACITY}`);
  console.log('='.repeat(60));

  // 1) 테스트 전 현재 상태 확인
  console.log('\n[1] 테스트 전 강좌 상태 확인...');
  const before = await rpc('get_course_status', {});
  if (!Array.isArray(before)) {
    console.error('get_course_status 실패:', before);
    process.exit(1);
  }
  const target = before.find(c => c.code === COURSE_CODE);
  if (!target) {
    console.error(`강좌 ${COURSE_CODE} 을 DB에서 찾을 수 없습니다.`);
    process.exit(1);
  }
  console.log(`  enrolled_count: ${target.enrolled_count} / ${target.capacity}`);
  if (target.enrolled_count > 0) {
    console.warn('  ⚠️  이미 신청자가 있습니다. 초기화 후 재실행하세요.');
    console.warn('     UPDATE courses SET enrolled_count=0 WHERE code=\'' + COURSE_CODE + '\';');
    console.warn('     TRUNCATE TABLE enrollments;');
    process.exit(1);
  }

  // 2) 동시 요청 발사
  console.log(`\n[2] 동시 ${CONCURRENT}명 신청 요청 발사...`);
  const students = Array.from({ length: CONCURRENT }, (_, i) => makeStudent(i + 1));
  const startMs  = Date.now();

  const results = await Promise.allSettled(
    students.map(s => rpc('apply_course', s))
  );

  const elapsedMs = Date.now() - startMs;

  // 3) 결과 집계
  const success   = results.filter(r => r.status === 'fulfilled' && r.value?.ok === true);
  const full      = results.filter(r => r.status === 'fulfilled' && r.value?.error === 'full');
  const duplicate = results.filter(r => r.status === 'fulfilled' && r.value?.error === 'duplicate');
  const notOpen   = results.filter(r => r.status === 'fulfilled' && r.value?.error === 'not_open');
  const other     = results.filter(r => {
    if (r.status === 'rejected') return true;
    const e = r.value?.error;
    return e && !['full','duplicate','not_open'].includes(e) && r.value?.ok !== true;
  });

  console.log('\n[3] 결과 집계');
  console.log(`  성공(ok=true):   ${success.length}`);
  console.log(`  정원초과(full):  ${full.length}`);
  console.log(`  중복(duplicate): ${duplicate.length}`);
  console.log(`  오픈전(not_open):${notOpen.length}`);
  console.log(`  기타 오류:       ${other.length}`);
  console.log(`  소요시간:        ${elapsedMs}ms`);

  if (other.length > 0) {
    console.log('\n  [기타 오류 상세]');
    other.slice(0, 5).forEach((r, i) => {
      console.log(`    ${i+1}:`, r.status === 'rejected' ? r.reason : r.value);
    });
  }

  // 4) 테스트 후 DB 상태 확인
  console.log('\n[4] 테스트 후 DB 상태 확인...');
  const after = await rpc('get_course_status', {});
  const afterTarget = Array.isArray(after) && after.find(c => c.code === COURSE_CODE);
  if (afterTarget) {
    console.log(`  enrolled_count: ${afterTarget.enrolled_count} / ${afterTarget.capacity}`);
  }

  // 5) 검증
  console.log('\n[5] 검증');
  let pass = true;

  if (success.length !== CAPACITY) {
    console.error(`  ❌ FAIL: 성공 ${success.length}건 (기대: ${CAPACITY}건) — 정원 오차 발생!`);
    pass = false;
  } else {
    console.log(`  ✅ PASS: 성공 정확히 ${CAPACITY}건`);
  }

  if (afterTarget && afterTarget.enrolled_count !== CAPACITY) {
    console.error(`  ❌ FAIL: DB enrolled_count=${afterTarget.enrolled_count} (기대: ${CAPACITY})`);
    pass = false;
  } else if (afterTarget) {
    console.log(`  ✅ PASS: DB enrolled_count 정확히 ${CAPACITY}`);
  }

  if (success.length + full.length + duplicate.length + notOpen.length + other.length !== CONCURRENT) {
    console.warn('  ⚠️  응답 수 합계 불일치 (일부 요청 유실 가능성)');
  }

  console.log('\n' + '='.repeat(60));
  console.log(pass ? '전체 결과: ✅ PASS' : '전체 결과: ❌ FAIL');
  console.log('='.repeat(60));

  // 6) 사용 안내
  console.log(`
[테스트 완료 후 초기화 방법]
Supabase SQL Editor에서 아래 실행:

  SELECT admin_reset_test_data('RESET-실행확인');

또는 (open_at 이전에만 가능):
  TRUNCATE TABLE enrollments;
  UPDATE courses SET enrolled_count = 0, is_closed_manual = false;
`);

  process.exit(pass ? 0 : 1);
}

main().catch(err => {
  console.error('[FATAL]', err);
  process.exit(1);
});
