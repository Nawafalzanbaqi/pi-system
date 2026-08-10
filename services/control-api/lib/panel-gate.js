// panel-gate.js — PURE UI route-guard decision. Given the (already-verified)
// session and whether OIDC is configured, decide what the entry page renders.
// Extracted so the guard logic is unit-testable without Next/cookies/jose:
//   no session            -> 'login'  (LoginGate; offers sign-in if configured)
//   session w/ subject     -> 'app'    (AppShell)
// The API routes still enforce auth independently; this is only the UI gate.
export function panelGate({ session, configured } = {}) {
  if (session && typeof session === 'object' && session.sub) {
    return { view: 'app', isOperator: !!session.isOperator };
  }
  return { view: 'login', configured: !!configured };
}
