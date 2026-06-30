const SUPABASE_URL = process.env.SUPABASE_URL;
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const ADMIN_PASSWORD = process.env.ADMIN_PASSWORD;

function authCheck(req) {
  const auth = req.headers['authorization'] || '';
  const token = auth.startsWith('Bearer ') ? auth.slice(7) : '';
  return token === ADMIN_PASSWORD;
}

const sbHeaders = () => ({
  apikey: SERVICE_ROLE_KEY,
  Authorization: `Bearer ${SERVICE_ROLE_KEY}`,
});

async function fetchAllRows(baseUrl) {
  const PAGE_SIZE = 1000;
  const allRows = [];
  let offset = 0;

  while (true) {
    const response = await fetch(baseUrl, {
      headers: {
        ...sbHeaders(),
        'Range-Unit': 'items',
        Range: `${offset}-${offset + PAGE_SIZE - 1}`,
        Prefer: 'count=exact',
      },
    });
    if (!response.ok) {
      const text = await response.text();
      throw new Error(text);
    }
    const data = await response.json();
    if (!Array.isArray(data) || data.length === 0) break;
    allRows.push(...data);

    const contentRange = response.headers.get('Content-Range');
    if (contentRange) {
      const match = contentRange.match(/\/(\d+)$/);
      if (match && allRows.length >= parseInt(match[1])) break;
    }
    if (data.length < PAGE_SIZE) break;
    offset += PAGE_SIZE;
  }
  return allRows;
}

async function fetchSchoolMap() {
  const url = `${SUPABASE_URL}/rest/v1/schools?select=neis_code,name&limit=2000`;
  const res = await fetch(url, { headers: sbHeaders() });
  if (!res.ok) return {};
  const data = await res.json();
  const map = {};
  for (const s of data) map[s.neis_code] = s.name;
  return map;
}

function toCSV(rows, schoolMap) {
  const headers = ['강좌코드', '강좌명', '학번', '이름', '학교코드', '학교명', '연락처', '신청일시'];
  const lines = [headers.join(',')];
  for (const r of rows) {
    const courseName = r.courses?.name || '';
    const schoolName = schoolMap[r.school] || '';
    lines.push(
      [
        r.course_code,
        `"${courseName.replace(/"/g, '""')}"`,
        r.student_no,
        `"${(r.name || '').replace(/"/g, '""')}"`,
        r.school || '',
        `"${schoolName.replace(/"/g, '""')}"`,
        `"${r.phone || ''}"`,
        r.created_at || '',
      ].join(',')
    );
  }
  return lines.join('\r\n');
}

export default async function handler(req, res) {
  if (req.method !== 'GET') return res.status(405).end();
  if (!authCheck(req)) return res.status(401).json({ error: 'Unauthorized' });

  const { code, format } = req.query;

  if (format === 'csv') {
    let csvUrl = `${SUPABASE_URL}/rest/v1/enrollments?select=*,courses(name)&status=in.(active,pending)&order=student_no`;
    if (code) csvUrl += `&course_code=eq.${encodeURIComponent(code)}`;

    let allRows;
    try {
      [allRows] = await Promise.all([fetchAllRows(csvUrl)]);
    } catch (e) {
      return res.status(502).json({ error: e.message });
    }

    const schoolMap = await fetchSchoolMap();
    const csv = toCSV(allRows, schoolMap);
    const filename = code ? `enrollments_${code}.csv` : 'enrollments_all.csv';
    res.setHeader('Content-Type', 'text/csv; charset=utf-8');
    res.setHeader('Content-Disposition', `attachment; filename="${filename}"`);
    return res.status(200).send('\uFEFF' + csv);
  }

  // JSON — 기존 동작 유지
  let url = `${SUPABASE_URL}/rest/v1/enrollments?select=*&status=in.(active,pending)&order=student_no`;
  if (code) url += `&course_code=eq.${encodeURIComponent(code)}`;

  const response = await fetch(url, { headers: sbHeaders() });
  if (!response.ok) {
    const text = await response.text();
    return res.status(502).json({ error: text });
  }

  res.setHeader('Cache-Control', 'no-store');
  return res.status(200).json(await response.json());
}
