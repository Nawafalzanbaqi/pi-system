'use client';

// local-payments — client checkout widget: create a payment, then go pay.
// =============================================================================
// Talks ONLY to same-origin Next.js Route Handlers under /api/payments, which run
// on the server and proxy to the .NET backend over the internal network — the
// browser never reaches the backend (or the API key) directly. Bilingual + RTL-aware
// via the `locale` passed from the page (cooperates with i18n-bilingual, and works
// standalone without it). No external dependencies — React only.
//
// Flow:
//   1. POST /api/payments  -> { reference, provider, redirectUrl, mockPayUrl }
//   2a. real provider: navigate to redirectUrl (the hosted mada/Apple Pay/card page)
//   2b. mock provider:  POST mockPayUrl (simulate paying -> signed webhook), then go
//       to the return page, which shows the now-paid status.
// =============================================================================
import { useState } from 'react';
import { paymentsMessages, paymentsDir, formatAmount } from '../lib/payments-i18n';

export default function CheckoutWidget({
  locale = 'en',
  amount = 1000,            // minor units (e.g. 1000 halalas = 10.00 SAR)
  currency = 'SAR',
  description = 'Order payment',
  returnPath = '/payment/return',
}) {
  const t = paymentsMessages(locale);
  const dir = paymentsDir(locale);

  const [busy, setBusy] = useState(false);
  const [phase, setPhase] = useState('idle'); // idle | creating | mock | error
  const [created, setCreated] = useState(null); // { reference, provider, mockPayUrl }
  const [error, setError] = useState(null);

  function goToReturn(reference) {
    window.location.href = `${returnPath}?ref=${encodeURIComponent(reference)}`;
  }

  async function startPayment() {
    setBusy(true);
    setError(null);
    try {
      const res = await fetch('/api/payments', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ amount, currency, description }),
      });
      const data = await res.json().catch(() => ({}));
      if (res.status === 503) { setError(t.unavailable); setPhase('error'); return; }
      if (!res.ok) { setError((data && data.error) || t.unavailable); setPhase('error'); return; }

      if (data.redirectUrl) {
        // Real provider: hand off to the hosted payment page.
        window.location.href = data.redirectUrl;
        return;
      }
      // Mock provider: reveal the simulate-pay control.
      setCreated({ reference: data.reference, provider: data.provider, mockPayUrl: data.mockPayUrl });
      setPhase('mock');
    } catch (err) {
      setError(String(err));
      setPhase('error');
    } finally {
      setBusy(false);
    }
  }

  async function simulatePay() {
    if (!created) return;
    setBusy(true);
    try {
      await fetch(created.mockPayUrl, { method: 'POST' });
      goToReturn(created.reference);
    } catch (err) {
      setError(String(err));
      setPhase('error');
    } finally {
      setBusy(false);
    }
  }

  const button = { padding: '0.6rem 1.2rem', borderRadius: '0.375rem', cursor: 'pointer', border: '1px solid currentColor' };

  return (
    <section dir={dir} className="payments-checkout" style={{ maxInlineSize: '32rem' }}>
      <h2>{t.title}</h2>
      <p>
        {t.amount}: <strong>{formatAmount(amount)} {currency === 'SAR' ? t.sar : currency}</strong>
      </p>
      <p>{t.description}: {description}</p>

      {phase !== 'mock' && (
        <button type="button" style={button} disabled={busy} onClick={startPayment}>
          {busy ? t.paying : t.pay}
        </button>
      )}

      {phase === 'mock' && created && (
        <div style={{ marginBlockStart: '1rem' }}>
          <p role="status">{t.reference} <strong>{created.reference}</strong></p>
          <button type="button" style={button} disabled={busy} onClick={simulatePay}>
            {busy ? t.simulating : t.simulate}
          </button>
        </div>
      )}

      {error && <p role="alert" style={{ color: 'crimson', marginBlockStart: '1rem' }}>{error}</p>}
    </section>
  );
}
