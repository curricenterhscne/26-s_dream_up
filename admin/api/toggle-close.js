const SUPABASE_URL = process.env.SUPABASE_URL;
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const ADMIN_PASSWORD = process.env.ADMIN_PASSWORD;

function authCheck(req) {
  const auth = req.headers['authorization'] || '';
  const token = auth.startsWith('Bearer ') ? auth.slice(7) : '';
  return token === ADMIN_PASSWORD;
}

export default async function handler(req, res) {
  if (req.method !== 'POST') return res.status(405).end();
  if (!authCheck(req)) return res.status(401).json({ error: 'Unauthorized' });

  const { code, value } = req.body || {};
  if (!code || typeof value !== 'boolean') {
    return res.status(400).json({ error: 'code and value (boolean) required' });
  }

  const url = `${SUPABASE_URL}/rest/v1/courses?code=eq.${encodeURIComponent(code)}`;
  const response = await fetch(url, {
    method: 'PATCH',
    headers: {
      apikey: SERVICE_ROLE_KEY,
      Authorization: `Bearer ${SERVICE_ROLE_KEY}`,
      'Content-Type': 'application/json',
      Prefer: 'return=minimal',
    },
    body: JSON.stringify({ is_closed_manual: value }),
  });

  if (!response.ok) {
    const text = await response.text();
    return res.status(502).json({ error: text });
  }

  return res.status(200).json({ ok: true });
}
