// Rendered per-request so it calls the backend live, server-side, over the
// internal Docker network (never exposed to the browser directly).
export const dynamic = 'force-dynamic';

async function getBackendInfo() {
  const base = process.env.BACKEND_URL || '';
  try {
    const res = await fetch(base + '/api/info', { cache: 'no-store' });
    if (!res.ok) return { status: 'error', code: res.status };
    return await res.json();
  } catch (err) {
    return { status: 'unreachable', error: String(err) };
  }
}

export default async function Home() {
  const backend = await getBackendInfo();
  return (
    <main style={{ fontFamily: 'system-ui, sans-serif', padding: '2rem', lineHeight: 1.6 }}>
      <h1>__PROJECT_NAME__</h1>
      <p>Full-stack scaffold: this Next.js frontend calls the .NET API over the internal network.</p>
      <ul>
        <li>Backend target: <code>__PROJECT_NAME__-api:8080</code></li>
        <li>Database target: <code>__DB_ENGINE__</code></li>
        <li>Backend <code>/api/info</code> response: <code>{JSON.stringify(backend)}</code></li>
      </ul>
    </main>
  );
}
