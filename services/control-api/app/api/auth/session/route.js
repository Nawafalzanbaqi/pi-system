// control-panel — read-only session probe for the client shell.
// Returns { configured, authenticated, user, isOperator } and NEVER the tokens.
// `configured:false` lets the UI show the "panel not set up yet" gate instead of
// a broken login. Node runtime (it decrypts the session cookie).
import { NextResponse } from 'next/server';
import { getSession } from '../../../../lib/auth/session.js';
import { oidcConfigured } from '../../../../lib/auth/oidc.js';
import { sessionSecretConfigured } from '../../../../lib/auth/session-core.js';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

export async function GET() {
  const configured = oidcConfigured() && sessionSecretConfigured();
  const session = await getSession();
  if (!session) return NextResponse.json({ configured, authenticated: false });
  return NextResponse.json({
    configured,
    authenticated: true,
    isOperator: Boolean(session.isOperator),
    user: {
      sub: session.sub,
      name: session.name,
      email: session.email,
      username: session.preferred_username,
    },
  });
}
