// whatsapp-integration — the SWAPPABLE-PROVIDER selector for "__PROJECT_NAME__".
// =============================================================================
// ONE place that picks the active sender from WHATSAPP_PROVIDER, mirroring the
// .NET WhatsappHostingStartup. Callers import getSender() and use the same small
// interface (provider, configured, sendText, sendTemplate) regardless of which
// provider is live — so flipping mock -> cloud_api is a pure env change.
//   blank | "mock"  -> the mock sender (default; logs + returns success)
//   "cloud_api"     -> the real WhatsApp Cloud API sender
// Server-side only (these read secrets from process.env and must never run in the
// browser). Used by the Route Handlers under app/api/whatsapp/.
// =============================================================================
import { createMockSender } from './mock';
import { createCloudApiSender } from './cloud-api';

export function getSender() {
  const provider = String(process.env.WHATSAPP_PROVIDER || '').trim().toLowerCase();
  if (provider === 'cloud_api' || provider === 'cloudapi' || provider === 'cloud') {
    return createCloudApiSender(process.env);
  }
  // "", "mock", or anything unrecognised => the safe mock default.
  return createMockSender();
}
