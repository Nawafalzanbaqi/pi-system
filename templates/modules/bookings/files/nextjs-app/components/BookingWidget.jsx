'use client';

// bookings — client booking widget: pick a service, see available times, submit.
// =============================================================================
// Talks ONLY to same-origin Next.js Route Handlers under /api/bookings, which run
// on the server and proxy to the .NET backend over the internal network — the
// browser never reaches the backend directly. Bilingual + RTL-aware via the
// `locale` passed from the page (so it cooperates with the i18n-bilingual module,
// and works standalone without it). No external dependencies — React only.
// =============================================================================
import { useEffect, useState } from 'react';
import { bookingsMessages, bookingsDir } from '../lib/bookings-i18n';

export default function BookingWidget({ locale = 'en', services = [] }) {
  const t = bookingsMessages(locale);
  const dir = bookingsDir(locale);
  const nameKey = locale === 'ar' ? 'nameAr' : 'nameEn';

  const [serviceId, setServiceId] = useState(services[0] ? String(services[0].id) : '');
  const [slots, setSlots] = useState([]);
  const [slotId, setSlotId] = useState('');
  const [form, setForm] = useState({ customerName: '', customerEmail: '', customerPhone: '', notes: '' });
  const [loadingSlots, setLoadingSlots] = useState(false);
  const [submitting, setSubmitting] = useState(false);
  const [result, setResult] = useState(null); // { ok, reference } | { error }

  async function loadSlots(id) {
    if (!id) { setSlots([]); return; }
    setLoadingSlots(true);
    try {
      const res = await fetch(`/api/bookings/slots?serviceId=${encodeURIComponent(id)}`, { cache: 'no-store' });
      const data = res.ok ? await res.json() : [];
      setSlots(Array.isArray(data) ? data : []);
    } catch {
      setSlots([]);
    } finally {
      setLoadingSlots(false);
    }
  }

  // Load the selected service's slots whenever the service changes.
  useEffect(() => {
    let active = true;
    setSlotId('');
    (async () => { if (active) await loadSlots(serviceId); })();
    return () => { active = false; };
  }, [serviceId]);

  function fmt(iso) {
    try {
      return new Date(iso).toLocaleString(locale === 'ar' ? 'ar' : 'en', {
        dateStyle: 'medium',
        timeStyle: 'short',
      });
    } catch {
      return iso;
    }
  }

  async function onSubmit(e) {
    e.preventDefault();
    setResult(null);
    if (!slotId || !form.customerName.trim() || !form.customerEmail.includes('@')) {
      setResult({ error: t.required });
      return;
    }
    setSubmitting(true);
    try {
      const res = await fetch('/api/bookings', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ slotId: Number(slotId), ...form }),
      });
      const data = await res.json().catch(() => ({}));
      if (res.ok) {
        setResult({ ok: true, reference: data.reference });
        setForm({ customerName: '', customerEmail: '', customerPhone: '', notes: '' });
        await loadSlots(serviceId); // the slot we took is now gone
        setSlotId('');
      } else if (res.status === 409) {
        setResult({ error: t.slotTaken });
        await loadSlots(serviceId);
      } else if (res.status === 503) {
        setResult({ error: t.unavailable });
      } else {
        setResult({ error: (data && data.error) || t.required });
      }
    } catch (err) {
      setResult({ error: String(err) });
    } finally {
      setSubmitting(false);
    }
  }

  // Logical-property styles so the widget mirrors automatically for RTL/LTR.
  const input = { display: 'block', inlineSize: '100%', padding: '0.5rem', marginBlockStart: '0.25rem', borderRadius: '0.375rem', border: '1px solid #ccc' };
  const field = { marginBlockEnd: '1rem' };

  if (!services.length) {
    return (
      <section dir={dir} className="bookings-widget" style={{ maxInlineSize: '36rem' }}>
        <h2>{t.title}</h2>
        <p role="status">{t.noServices}</p>
      </section>
    );
  }

  return (
    <section dir={dir} className="bookings-widget" style={{ maxInlineSize: '36rem' }}>
      <h2>{t.title}</h2>

      <div style={field}>
        <label>
          {t.chooseService}
          <select value={serviceId} onChange={(e) => setServiceId(e.target.value)} style={input}>
            {services.map((s) => (
              <option key={s.id} value={String(s.id)}>
                {(s[nameKey] || s.nameEn)} — {s.durationMinutes} {t.minutes}
              </option>
            ))}
          </select>
        </label>
      </div>

      <div style={field}>
        <label>
          {t.chooseSlot}
          <select
            value={slotId}
            onChange={(e) => setSlotId(e.target.value)}
            style={input}
            disabled={loadingSlots || slots.length === 0}
          >
            <option value="">{loadingSlots ? t.loading : (slots.length ? t.pick : t.noSlots)}</option>
            {slots.map((sl) => (
              <option key={sl.id} value={String(sl.id)}>{fmt(sl.startsAt)}</option>
            ))}
          </select>
        </label>
      </div>

      <form onSubmit={onSubmit}>
        <div style={field}>
          <label>{t.name}
            <input style={input} value={form.customerName} onChange={(e) => setForm({ ...form, customerName: e.target.value })} required />
          </label>
        </div>
        <div style={field}>
          <label>{t.email}
            <input style={input} type="email" value={form.customerEmail} onChange={(e) => setForm({ ...form, customerEmail: e.target.value })} required />
          </label>
        </div>
        <div style={field}>
          <label>{t.phone}
            <input style={input} value={form.customerPhone} onChange={(e) => setForm({ ...form, customerPhone: e.target.value })} />
          </label>
        </div>
        <div style={field}>
          <label>{t.notes}
            <textarea style={input} rows={3} value={form.notes} onChange={(e) => setForm({ ...form, notes: e.target.value })} />
          </label>
        </div>
        <button
          type="submit"
          disabled={submitting || !slotId}
          style={{ padding: '0.5rem 1rem', borderRadius: '0.375rem', cursor: 'pointer', border: '1px solid currentColor' }}
        >
          {submitting ? t.submitting : t.submit}
        </button>
      </form>

      {result && result.ok && (
        <p role="status" style={{ color: 'green', marginBlockStart: '1rem' }}>
          {t.success} <strong>{result.reference}</strong>
        </p>
      )}
      {result && result.error && (
        <p role="alert" style={{ color: 'crimson', marginBlockStart: '1rem' }}>{result.error}</p>
      )}
    </section>
  );
}
