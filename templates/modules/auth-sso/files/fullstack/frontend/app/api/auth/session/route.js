// auth-sso — read-only session probe for client components.
// Returns { authenticated, user } WITHOUT ever exposing the tokens. Lives under
// /api/auth/* (i18n-safe). Node runtime (it decrypts the session cookie).
import { NextResponse } from 'next/server';
import { getSession } from '../../../../lib/auth/session';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

export async function GET() {
  const session = await getSession();
  if (!session) return NextResponse.json({ authenticated: false });
  return NextResponse.json({
    authenticated: true,
    user: {
      sub: session.sub,
      name: session.name,
      email: session.email,
      username: session.preferred_username,
    },
  });
}
