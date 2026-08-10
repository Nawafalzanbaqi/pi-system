// PUBLIC liveness probe — the ONLY unauthenticated endpoint. Used by the Docker
// HEALTHCHECK, Caddy and Uptime Kuma. It reveals nothing sensitive: just that the
// process is up. Everything else under /api requires a valid Keycloak token.
export const dynamic = 'force-dynamic';
export const runtime = 'nodejs';

export async function GET() {
  return Response.json({ status: 'ok', data: { service: 'control-api', live: true } });
}
