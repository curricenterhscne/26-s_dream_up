import * as XLSX from 'xlsx';

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

function toXLSX(rows, schoolMap) {
  const headers = ['강좌코드', '강좌명', '학번', '이름', '학교코드', '학교명', '연락처', '신청일시'];
  const data = [headers];
  for (const r of rows) {
    data.push([
      r.course_code || '',
      r.courses?.name || '',
      r.student_no || '',
      r.name || '',
      r.school || '',
      schoolMap[r.school] || '',
      r.phone || '',
      r.created_at || '',
    ]);
  }
  const wb = XLSX.utils.book_new();
  const ws = XLSX.utils.aoa_to_sheet(data);
  // 학번·연락처 열을 텍스트 형식으로 강제 지정 (C·G열, 0-indexed 2·6)
  const textCols = [2, 6];
  const range = XLSX.utils.decode_range(ws['!ref']);
  for (let row = 1; row <= range.e.r; row++) {
    for (const col of textCols) {
      const addr = XLSX.utils.encode_cell({ r: row, c: col });
      if (ws[addr]) { ws[addr].t = 's'; ws[addr].z = '@'; }
    }
  }
  XLSX.utils.book_append_sheet(wb, ws, '신청자');
  return XLSX.write(wb, { type: 'buffer', bookType: 'xlsx' });
}

export default async function handler(req, res) {
  if (req.method !== 'GET') return res.status(405).end();
  if (!authCheck(req)) return res.status(401).json({ error: 'Unauthorized' });

  const { code, format } = req.query;

  if (format === 'excel') {
    let xlUrl = `${SUPABASE_URL}/rest/v1/enrollments?select=*,courses(name)&status=in.(active,pending)&order=student_no`;
    if (code) xlUrl += `&course_code=eq.${encodeURIComponent(code)}`;

    let allRows;
    try {
      allRows = await fetchAllRows(xlUrl);
    } catch (e) {
      return res.status(502).json({ error: e.message });
    }

    const schoolMap = await fetchSchoolMap();
    const buf = toXLSX(allRows, schoolMap);
    const filename = code ? `enrollments_${code}.xlsx` : 'enrollments_all.xlsx';
    res.setHeader('Content-Type', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet');
    res.setHeader('Content-Disposition', `attachment; filename="${filename}"`);
    return res.status(200).send(buf);
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
