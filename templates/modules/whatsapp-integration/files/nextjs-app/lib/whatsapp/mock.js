// whatsapp-integration — MOCK sender (DEFAULT) for "__PROJECT_NAME__".
// =============================================================================
// The JS twin of the .NET MockWhatsappSender. Active whenever WHATSAPP_PROVIDER is
// blank or "mock" (the default). It performs NO network call: it logs the message
// it WOULD send and returns success with a synthetic id. This is what lets the
// WhatsApp flow run and be tested on a plain nextjs-app base with NO external
// account. Server-side only (called from the Route Handlers under app/api/whatsapp).
// =============================================================================

function newId() {
  return 'wamid.MOCK-' + Math.random().toString(36).slice(2, 18).toUpperCase();
}

// Don't log full numbers — keep the last 4 digits only.
function redact(phone) {
  const p = String(phone || '').trim();
  return p.length <= 4 ? '****' : '*'.repeat(p.length - 4) + p.slice(-4);
}

export function createMockSender() {
  return {
    provider: 'mock',
    configured: true,

    async sendText(to, message) {
      const id = newId();
      console.log(`whatsapp(mock): TEXT -> ${redact(to)} | id=${id} | body=${message}`);
      return { success: true, provider: 'mock', messageId: id, error: null };
    },

    async sendTemplate(to, template, language, parameters = []) {
      const id = newId();
      console.log(
        `whatsapp(mock): TEMPLATE '${template}' [${language}] -> ${redact(to)} | id=${id} | params=[${parameters.join(', ')}]`,
      );
      return { success: true, provider: 'mock', messageId: id, error: null };
    },
  };
}
