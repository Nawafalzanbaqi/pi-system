// whatsapp-integration — server-side SEND endpoint for "__PROJECT_NAME__".
// =============================================================================
// POST /api/whatsapp/send — runs on the Next.js server (so the access token never
// reaches the browser), resolves the active provider (mock | cloud_api) and sends.
//   Body: { "to": "9665...", "message": "hi" }                        -> text
//     or: { "to": "9665...", "template": "name", "language": "ar",
//           "parameters": ["..."] }                                   -> template
// Returns the provider result (200 on success, 502 when it couldn't deliver).
// =============================================================================
import { NextResponse } from 'next/server';
import { getSender } from '../../../../lib/whatsapp';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

export async function POST(request) {
  let body;
  try { body = await request.json(); } catch { body = {}; }

  const to = String(body.to ?? '').trim();
  if (!to) {
    return NextResponse.json({ error: '"to" (recipient phone, E.164) is required.' }, { status: 400 });
  }

  const sender = getSender();
  let result;
  if (body.template) {
    result = await sender.sendTemplate(
      to,
      String(body.template),
      body.language ? String(body.language) : 'en',
      Array.isArray(body.parameters) ? body.parameters.map(String) : [],
    );
  } else if (body.message) {
    result = await sender.sendText(to, String(body.message));
  } else {
    return NextResponse.json(
      { error: 'Provide either "message" (text) or "template" (+ optional language/parameters).' },
      { status: 400 },
    );
  }

  return NextResponse.json(result, { status: result.success ? 200 : 502 });
}
