// whatsapp-integration — inbound webhook for "__PROJECT_NAME__".
// =============================================================================
// GET  /api/whatsapp/webhook  Meta's subscription handshake — echo hub.challenge
//                             when hub.verify_token matches WHATSAPP_VERIFY_TOKEN.
// POST /api/whatsapp/webhook  inbound messages / status events — verified with
//                             HMAC-SHA256 over the RAW body using WHATSAPP_APP_SECRET
//                             (Meta's X-Hub-Signature-256). With no app secret set
//                             (dev), accepts but logs a warning so the flow still
//                             runs. Register this URL in Meta — see SETUP.md.
// =============================================================================
import { NextResponse } from 'next/server';
import crypto from 'node:crypto';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

export async function GET(request) {
  const url = new URL(request.url);
  const mode = url.searchParams.get('hub.mode');
  const token = url.searchParams.get('hub.verify_token') || '';
  const challenge = url.searchParams.get('hub.challenge') ?? '';
  const expected = String(process.env.WHATSAPP_VERIFY_TOKEN || '').trim();

  if (mode === 'subscribe' && expected && safeEqual(token, expected)) {
    return new NextResponse(challenge, { status: 200, headers: { 'Content-Type': 'text/plain; charset=utf-8' } });
  }
  return new NextResponse(null, { status: 403 });
}

export async function POST(request) {
  const appSecret = String(process.env.WHATSAPP_APP_SECRET || '').trim();
  const raw = await request.text();

  if (appSecret) {
    const sig = request.headers.get('x-hub-signature-256') || '';
    if (!verifySignature(raw, appSecret, sig)) {
      console.warn('whatsapp(webhook): rejected — invalid X-Hub-Signature-256.');
      return new NextResponse(null, { status: 401 });
    }
  } else {
    console.warn('whatsapp(webhook): WHATSAPP_APP_SECRET not set — accepting WITHOUT signature verification (dev only).');
  }

  // We don't persist inbound events here (database: none). Log + ACK 200 fast so
  // Meta does not retry. Add your own handling below.
  console.log(`whatsapp(webhook): received ${Buffer.byteLength(raw, 'utf8')} bytes.`);
  return new NextResponse(null, { status: 200 });
}

function verifySignature(raw, secret, header) {
  const prefix = 'sha256=';
  if (!header || !header.toLowerCase().startsWith(prefix)) return false;
  const provided = header.slice(prefix.length).trim().toLowerCase();
  const computed = crypto.createHmac('sha256', secret).update(raw, 'utf8').digest('hex');
  return safeEqual(provided, computed);
}

function safeEqual(a, b) {
  const ba = Buffer.from(String(a), 'utf8');
  const bb = Buffer.from(String(b), 'utf8');
  return ba.length === bb.length && crypto.timingSafeEqual(ba, bb);
}
