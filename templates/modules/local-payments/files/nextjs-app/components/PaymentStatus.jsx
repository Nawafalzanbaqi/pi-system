'use client';

// local-payments — client payment-status panel for the return page.
// =============================================================================
// Reads a payment's reference (from the return URL) and polls the same-origin
// /api/payments/<reference> Route Handler (server-side proxy to the .NET backend)
// until the status settles. For a real provider the webhook may land a moment after
// the redirect back, so it polls a few times before showing "pending". Bilingual +
// RTL-aware. React only — no dependencies.
// =============================================================================
import { useEffect, useState } from 'react';
import { paymentsMessages, paymentsDir, formatAmount } from '../lib/payments-i18n';

export default function PaymentStatus({ reference, locale = 'en' }) {
  const t = paymentsMessages(locale);
  const dir = paymentsDir(locale);
  const [state, setState] = useState({ loading: true, payment: null, notFound: false });

  useEffect(() => {
    if (!reference) { setState({ loading: false, payment: null, notFound: true }); return; }
    let active = true;
    let tries = 0;

    async function poll() {
      tries += 1;
      try {
        const res = await fetch(`/api/payments/${encodeURIComponent(reference)}`, { cache: 'no-store' });
        if (res.status === 404) { if (active) setState({ loading: false, payment: null, notFound: true }); return; }
        const data = await res.json().catch(() => null);
        if (!active) return;
        setState({ loading: false, payment: data, notFound: false });
        // Keep polling briefly while still pending (a real webhook may be in flight).
        if (data && data.status === 'pending' && tries < 5) setTimeout(poll, 1500);
      } catch {
        if (active && tries < 5) setTimeout(poll, 1500);
      }
    }
    poll();
    return () => { active = false; };
  }, [reference]);

  if (state.loading) return <p role="status">{t.checking}</p>;
  if (state.notFound || !state.payment) return <p role="alert">{t.notFound}</p>;

  const p = state.payment;
  const msg = p.status === 'paid' ? t.paid : p.status === 'failed' ? t.failed : t.pending;
  const color = p.status === 'paid' ? 'green' : p.status === 'failed' ? 'crimson' : 'inherit';

  return (
    <div dir={dir}>
      <p role="status" style={{ color, fontWeight: 600 }}>{msg}</p>
      <p>{t.reference} <strong>{p.reference}</strong></p>
      <p>{t.amount}: {formatAmount(p.amountMinor)} {p.currency === 'SAR' ? t.sar : p.currency}</p>
    </div>
  );
}
