// whatsapp-integration — provider status for "__PROJECT_NAME__".
// =============================================================================
// GET /api/whatsapp/status — reports the active provider and whether it can really
// send, WITHOUT exposing any secret. Handy to confirm mock vs cloud_api wiring.
// =============================================================================
import { NextResponse } from 'next/server';
import { getSender } from '../../../../lib/whatsapp';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

export async function GET() {
  const sender = getSender();
  return NextResponse.json({
    provider: sender.provider,
    configured: sender.configured,
    note: sender.provider === 'mock'
      ? 'Mock provider active — messages are logged, not delivered. Set WHATSAPP_PROVIDER=cloud_api with Meta credentials to send for real.'
      : (sender.configured
        ? 'Cloud API active and configured.'
        : 'Cloud API selected but missing credentials — set WHATSAPP_PHONE_NUMBER_ID and WHATSAPP_ACCESS_TOKEN.'),
  });
}
