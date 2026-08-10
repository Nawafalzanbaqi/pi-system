// app/page.jsx — the panel entry point. SERVER component: it reads the session
// cookie and the OIDC config server-side and renders EITHER the authenticated
// AppShell or the LoginGate. This is the route guard — unauthenticated visitors
// never get the panel, only the sign-in screen. (The API routes enforce auth
// independently; this is the UI-side gate.)
import { cookies } from 'next/headers';
import { getSession } from '../lib/auth/session.js';
import { oidcConfigured } from '../lib/auth/oidc.js';
import { sessionSecretConfigured } from '../lib/auth/session-core.js';
import AppShell from '../components/AppShell.jsx';
import LoginGate from '../components/LoginGate.jsx';
import { panelGate } from '../lib/panel-gate.js';

export const dynamic = 'force-dynamic';
export const runtime = 'nodejs';

export default async function Page({ searchParams }) {
  const store = await cookies();
  const theme = store.get('pi_theme')?.value === 'dark' ? 'dark' : 'light';
  const lang = store.get('pi_lang')?.value === 'en' ? 'en' : 'ar';
  const sp = searchParams ? await searchParams : {};
  const configured = oidcConfigured() && sessionSecretConfigured();
  const session = await getSession();
  const gate = panelGate({ session, configured });

  if (gate.view === 'login') {
    return <LoginGate configured={gate.configured} lang={lang} theme={theme} authError={typeof sp.auth_error === 'string' ? sp.auth_error : null} />;
  }

  const user = { sub: session.sub, name: session.name, email: session.email, username: session.preferred_username };
  return <AppShell initialLang={lang} initialTheme={theme} user={user} isOperator={gate.isOperator} />;
}
