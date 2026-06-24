const SUPABASE_URL = process.env.SUPABASE_URL;
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const ADMIN_PASSWORD = process.env.ADMIN_PASSWORD;

function authCheck(req) {
  const auth = req.headers['authorization'] || '';
  const token = auth.startsWith('Bearer ') ? auth.slice(7) : '';
  return token === ADMIN_PASSWORD;
}

function toCSV(rows) {
  const headers = ['강좌코드', '학번', '이름', '학교', '연락처', '신청일시'];
  const lines = [headers.join(',')];
  for (const r of rows) {
    lines.push(
      [
        r.course_code,
        r.student_no,
        `"${(r.name || '').replace(/"/g, '""')}"`,
        `"${(r.school || '').replace(/"/g, '""')}"`,
        r.phone || '',
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

  let url = `${SUPABASE_URL}/rest/v1/enrollments?select=*&status=eq.active&order=student_no`;
  if (code) url += `&course_code=eq.${encodeURIComponent(code)}`;

  const response = await fetch(url, {
    headers: {
      apikey: SERVICE_ROLE_KEY,
      Authorization: `Bearer ${SERVICE_ROLE_KEY}`,
    },
  });

  if (!response.ok) {
    const text = await response.text();
    return res.status(502).json({ error: text });
  }

  const data = await response.json();

  if (format === 'csv') {
    const csv = toCSV(data);
    const filename = code ? `enrollments_${code}.csv` : 'enrollments_all.csv';
    res.setHeader('Content-Type', 'text/csv; charset=utf-8');
    res.setHeader('Content-Disposition', `attachment; filename="${filename}"`);
    // BOM for Excel Korean encoding
    return res.status(200).send('\uFEFF' + csv);
  }

  res.setHeader('Cache-Control', 'no-store');
  return res.status(200).json(data);
}
