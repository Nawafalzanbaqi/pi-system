// local-payments — server-side proxy for the provider WEBHOOK.
// =============================================================================
// POST /api/payments/webhook — the public webhook URL you register with the
// provider. On fullstack/nextjs-app the web service is what Caddy fronts, so the
// provider's call lands here; we forward the RAW body (so the secret_token /
// signature stays byte-intact) to the internal .NET backend, which verifies and
// records it idempotently. Returns the backend's status (200 on accept, 401 on a
// failed verification). The .NET service is the single source of truth.
// =============================================================================
import { NextResponse } from 'next/server';
import { paymentsApiBase } from '../../../../lib/payments';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

export async function POST(request) {
  const base = paymentsApiBase();
  if (!base) {
    return NextResponse.json({ error: 'The payments backend is not configured.' }, { status: 503 });
  }

  // Raw body — never re-serialize, or a signature/secret over the bytes would break.
  const raw = await request.text();
  const headers = { 'Content-Type': request.headers.get('content-type') || 'application/json' };
  // Pass through known signature headers (provider-dependent).
  for (const h of ['x-mock-signature', 'x-hub-signature-256', 'x-signature']) {
    const v = request.headers.get(h);
    if (v) headers[h] = v;
  }

  try {
    const res = await fetch(`${base}/api/payments/webhook`, {
      method: 'POST',
      body: raw,
      headers,
      cache: 'no-store',
    });
    const text = await res.text();
    return new NextResponse(text || null, {
      status: res.status,
      headers: { 'Content-Type': 'application/json; charset=utf-8' },
    });
  } catch (err) {
    return NextResponse.json({ error: String(err) }, { status: 502 });
  }
}
