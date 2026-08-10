// whatsapp-integration — REAL provider for "__PROJECT_NAME__": WhatsApp Cloud API.
// =============================================================================
// The JS twin of the .NET CloudApiWhatsappSender. Calls Meta's documented Graph
// API send-message endpoint:
//
//   POST https://graph.facebook.com/<version>/<phone-number-id>/messages
//   Authorization: Bearer <access-token>
//
// Selected ONLY when WHATSAPP_PROVIDER=cloud_api. Stays INERT until its credentials
// are present: with a blank phone-number-id or access-token `configured` is false
// and sends return a clear error instead of calling out. Built-in fetch only — no
// dependencies. Server-side only.
// =============================================================================

const DEFAULT_API_VERSION = 'v21.0';

// E.164 without a leading '+': the Cloud API wants just the digits.
function normalizePhone(phone) {
  const p = String(phone || '').trim();
  return p.startsWith('+') ? p.slice(1) : p;
}

export function createCloudApiSender(env = process.env) {
  const phoneNumberId = String(env.WHATSAPP_PHONE_NUMBER_ID || '').trim();
  const accessToken = String(env.WHATSAPP_ACCESS_TOKEN || '').trim();
  const apiVersion = String(env.WHATSAPP_API_VERSION || '').trim() || DEFAULT_API_VERSION;
  const configured = phoneNumberId.length > 0 && accessToken.length > 0;

  async function send(payload) {
    if (!configured) {
      return {
        success: false,
        provider: 'cloud_api',
        messageId: null,
        error: 'WhatsApp Cloud API is not configured (set WHATSAPP_PHONE_NUMBER_ID and WHATSAPP_ACCESS_TOKEN).',
      };
    }
    const url = `https://graph.facebook.com/${apiVersion}/${phoneNumberId}/messages`;
    try {
      const res = await fetch(url, {
        method: 'POST',
        headers: { Authorization: `Bearer ${accessToken}`, 'Content-Type': 'application/json' },
        body: JSON.stringify(payload),
        cache: 'no-store',
      });
      const text = await res.text();
      let data = null;
      try { data = JSON.parse(text); } catch { /* non-JSON */ }
      if (!res.ok) {
        const msg = (data && data.error && data.error.message) || text;
        return { success: false, provider: 'cloud_api', messageId: null, error: `Cloud API returned ${res.status}: ${msg}` };
      }
      const messageId = data && Array.isArray(data.messages) && data.messages[0] ? data.messages[0].id : null;
      return { success: true, provider: 'cloud_api', messageId, error: null };
    } catch (err) {
      return { success: false, provider: 'cloud_api', messageId: null, error: String(err) };
    }
  }

  return {
    provider: 'cloud_api',
    configured,

    sendText(to, message) {
      return send({
        messaging_product: 'whatsapp',
        recipient_type: 'individual',
        to: normalizePhone(to),
        type: 'text',
        text: { preview_url: false, body: message },
      });
    },

    sendTemplate(to, template, language, parameters = []) {
      const tpl = { name: template, language: { code: language } };
      if (parameters && parameters.length) {
        tpl.components = [{ type: 'body', parameters: parameters.map((p) => ({ type: 'text', text: String(p) })) }];
      }
      return send({
        messaging_product: 'whatsapp',
        recipient_type: 'individual',
        to: normalizePhone(to),
        type: 'template',
        template: tpl,
      });
    },
  };
}
