// LoginGate.jsx — the unauthenticated / unconfigured screen. SERVER component
// (no client JS needed): a calm centered card that either starts the browser
// OIDC login (link to /api/auth/login) or, when the panel's Keycloak client isn't
// set up yet, explains the deferred one-time setup. Themed from the same TOKENS.
import { TOKENS, F_AR, F_EN, F_MONO } from './theme.js';

const ERRORS = {
  expired: { ar: 'انتهت مهلة تسجيل الدخول. حاول مرة أخرى.', en: 'The login timed out. Please try again.' },
  exchange: { ar: 'تعذّر إكمال تسجيل الدخول.', en: 'Could not complete the sign-in.' },
  discovery: { ar: 'تعذّر الوصول إلى خادم الهوية.', en: 'Could not reach the identity server.' },
  unconfigured: { ar: 'لوحة التحكم غير مهيّأة بعد.', en: 'The control panel is not configured yet.' },
};

export default function LoginGate({ configured = false, lang = 'ar', theme = 'light', authError }) {
  const t = TOKENS[theme] || TOKENS.light;
  const dir = lang === 'ar' ? 'rtl' : 'ltr';
  const F = lang === 'ar' ? F_AR : F_EN;
  const err = authError && ERRORS[authError] ? (lang === 'ar' ? ERRORS[authError].ar : ERRORS[authError].en) : null;

  return (
    <div dir={dir} style={{ minHeight: '100vh', background: t.bg, color: t.ink, display: 'flex', alignItems: 'center', justifyContent: 'center', padding: 24, fontFamily: F }}>
      <div style={{ width: 'min(420px, 100%)', background: t.panel, border: `1px solid ${t.border}`, borderRadius: 16, padding: '32px 28px', display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 14, boxShadow: '0 24px 80px rgba(0,0,0,0.12)' }}>
        <div style={{ width: 44, height: 44, borderRadius: 12, background: t.ink, color: t.bg, display: 'flex', alignItems: 'center', justifyContent: 'center', fontFamily: F_MONO, fontWeight: 700, fontSize: 24 }}>π</div>
        <div style={{ textAlign: 'center' }}>
          <h1 style={{ margin: 0, fontSize: 18, fontWeight: 600, color: t.ink, letterSpacing: '-.01em' }}>{lang === 'ar' ? 'لوحة تحكّم π' : 'π control panel'}</h1>
          <p style={{ margin: '4px 0 0', fontSize: 12.5, color: t.inkSoft }}>{lang === 'ar' ? 'منصة العمل الحرّ المستضافة ذاتيًا' : 'self-hosted freelance platform'}</p>
        </div>

        {err ? (
          <div style={{ width: '100%', padding: '8px 12px', background: t.warnSoft, border: `1px solid ${t.warn}33`, borderRadius: 8, fontSize: 12, color: t.warn, textAlign: 'center' }}>{err}</div>
        ) : null}

        {configured ? (
          <a href="/api/auth/login?returnTo=/" style={{ width: '100%', textAlign: 'center', padding: '10px 16px', borderRadius: 9, background: t.ink, color: t.bg, textDecoration: 'none', fontSize: 13, fontWeight: 600 }}>
            {lang === 'ar' ? 'تسجيل الدخول عبر Keycloak' : 'Sign in with Keycloak'}
          </a>
        ) : (
          <div style={{ width: '100%', display: 'flex', flexDirection: 'column', gap: 8 }}>
            <div style={{ padding: '10px 12px', background: t.panelAlt, border: `1px solid ${t.border}`, borderRadius: 9, fontSize: 12.5, color: t.inkSoft, lineHeight: 1.5 }}>
              {lang === 'ar'
                ? 'تسجيل الدخول غير مُفعّل بعد. أنشئ عميل Keycloak للوحة واضبط متغيّرات CONTROL_API_OIDC_* و CONTROL_API_SESSION_SECRET في ‎.env‎ ثم أعد التشغيل.'
                : 'Sign-in is not enabled yet. Create the panel’s Keycloak client and set CONTROL_API_OIDC_* + CONTROL_API_SESSION_SECRET in .env, then restart.'}
            </div>
            <code dir="ltr" style={{ fontFamily: F_MONO, fontSize: 11, color: t.inkMuted, background: t.panelAlt, border: `1px solid ${t.border}`, borderRadius: 7, padding: '8px 10px' }}>docs/README.md → Control panel</code>
          </div>
        )}
      </div>
    </div>
  );
}
