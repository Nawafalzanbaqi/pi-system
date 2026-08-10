// auth-sso — example protected page (/account). The layout guard guarantees a
// session here; this page shows the user's claims and, when a backend is wired,
// demonstrates the end-to-end loop by calling the protected backend /api/me with
// the user's access token.
import { getSession } from '../../lib/auth/session';
import { callBackend, backendConfigured } from '../../lib/auth/api';
import AuthStatus from '../../components/AuthStatus';

export const dynamic = 'force-dynamic';

export default async function AccountPage() {
  const session = await getSession(); // guaranteed non-null by app/account/layout.jsx
  const apiResult = backendConfigured() ? await callBackend('/api/me') : null;

  return (
    <main style={{ fontFamily: 'system-ui, sans-serif', padding: '2rem', lineHeight: 1.6 }}>
      <h1>Your account</h1>
      <p><AuthStatus /></p>

      <h2>Session (from the OIDC id token)</h2>
      <ul>
        <li>Subject: <code>{session?.sub}</code></li>
        <li>Username: <code>{session?.preferred_username || '—'}</code></li>
        <li>Name: <code>{session?.name || '—'}</code></li>
        <li>Email: <code>{session?.email || '—'}</code></li>
      </ul>

      <h2>Protected backend call <code>GET /api/me</code></h2>
      {!backendConfigured() ? (
        <p>No backend is wired to this app (set <code>BACKEND_URL</code>); the .NET
          resource server is the fullstack/dotnet-api half of this module.</p>
      ) : apiResult?.ok ? (
        <pre style={{ background: '#f4f4f4', padding: '1rem', overflowX: 'auto' }}>
          {JSON.stringify(apiResult.data, null, 2)}
        </pre>
      ) : (
        <p>Backend responded <code>{apiResult?.status}</code> — the access token may
          be expired, or the backend is still validating against the realm.</p>
      )}
    </main>
  );
}
