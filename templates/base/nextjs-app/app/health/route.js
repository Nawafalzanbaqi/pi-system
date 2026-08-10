// Health endpoint required by the platform (Caddy / Uptime Kuma / Docker HEALTHCHECK).
export const dynamic = 'force-dynamic';

export async function GET() {
  return Response.json({ status: 'healthy', service: '__PROJECT_NAME__' });
}
