// Rendered per-request so the runtime env (DATABASE_URL) is reflected live.
export const dynamic = 'force-dynamic';

export default function Home() {
  const dbConfigured = Boolean(process.env.DATABASE_URL);
  return (
    <main style={{ fontFamily: 'system-ui, sans-serif', padding: '2rem', lineHeight: 1.6 }}>
      <h1>__PROJECT_NAME__</h1>
      <p>Next.js app scaffolded for pi-system, fronted by Caddy at the subdomain &quot;__SUBDOMAIN__&quot;.</p>
      <ul>
        <li>Database target: <code>__DB_ENGINE__</code></li>
        <li>DATABASE_URL configured: <code>{String(dbConfigured)}</code></li>
        <li>Health endpoint: <code>/health</code></li>
      </ul>
    </main>
  );
}
