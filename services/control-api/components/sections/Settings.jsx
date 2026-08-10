'use client';
// Settings.jsx — the integrations manager. FULLY WIRED to the live API:
//   GET  /api/integrations        → per-key { set, secret, restart_services, value? }
//   PUT  /api/integrations/{key}  → write a new value (operator-only)
//   POST /api/actions/restart-service → apply (allowlisted services)
// SECURITY INVARIANT (preserved end to end): the API NEVER returns a secret value
// (only set/empty + a masked indicator), so KeyRow has nothing secret to render —
// the input is write-only, the "reveal" eye only un-masks what the OPERATOR is
// currently typing, and we never cache a typed secret beyond the in-flight save.
import { useMemo, useRef, useState } from 'react';
import { F_AR, F_EN, F_MONO } from '../theme.js';
import { Pill, Dot, Icon } from '../primitives.jsx';
import { EmptyState, ErrorState, Skel } from '../states.jsx';
import { motion, AnimatePresence } from 'framer-motion';
import { usePolledResource } from '../use-api.js';
import { INTEGRATION_PRESENTATION } from '../catalog.js';
import { VALID_RESTART_SERVICES } from '../../lib/bridge-core.js';
import { displayableKeyValue } from '../../lib/integrations-view.js';

export default function Settings({ t, L, lang, client, confirm, isOperator }) {
  const res = usePolledResource(() => client.getIntegrations(), { isEmpty: (d) => !d?.integrations?.length });
  const [restartList, setRestartList] = useState([]);
  const groups = res.data?.integrations || [];

  const addRestart = (svcs) => setRestartList((prev) => Array.from(new Set([...prev, ...(svcs || [])])));
  const clearRestart = () => setRestartList([]);

  const restartOne = (service) => confirm.ask({
    title: lang === 'ar' ? `إعادة تشغيل ${service}؟` : `Restart ${service}?`, target: service, impact: [service], destructive: false,
    confirmLabel: lang === 'ar' ? 'أعد التشغيل' : 'Restart',
    message: lang === 'ar' ? 'ستتوقّف الخدمة ثوانٍ ثم تعود لتطبيق التغييرات.' : 'The service restarts in a few seconds to apply the change.',
    onConfirm: async () => { const r = await client.restartService(service); if (!r.ok) throw new Error(r.error || 'restart failed'); setRestartList((p) => p.filter((s) => s !== service)); },
  });

  let body;
  if (res.state === 'loading' && !res.data) {
    body = (
      <div style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
        {[0, 1, 2, 3].map((i) => (
          <div key={i} style={{ background: t.panel, border: `1px solid ${t.border}`, borderRadius: 12, padding: '18px 20px' }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 12, marginBottom: 14 }}><Skel w={36} h={36} r={7} t={t} /><div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}><Skel w={140} h={14} t={t} /><Skel w={260} h={10} t={t} /></div></div>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>{[0, 1, 2].map((j) => <Skel key={j} w="100%" h={64} t={t} />)}</div>
          </div>
        ))}
      </div>
    );
  } else if (res.state === 'error') {
    body = <ErrorState t={t} lang={lang} title={res.unauthorized ? (lang === 'ar' ? 'انتهت الجلسة' : 'Session expired') : (lang === 'ar' ? 'تعذّر تحميل التكاملات' : "Couldn't load integrations")} body={lang === 'ar' ? 'فشل قراءة ملف التهيئة. القيم لم تتغيّر.' : 'Could not read the config. Your saved values are untouched.'} retryLabel={lang === 'ar' ? 'أعد المحاولة' : 'Retry'} onRetry={() => res.refresh()} detail={res.error} />;
  } else if (res.state === 'empty') {
    body = <EmptyState t={t} lang={lang} icon="plug" title={lang === 'ar' ? 'لا تكاملات مهيّأة' : 'No integrations configured yet'} body={lang === 'ar' ? 'هيّئ تيليغرام للإشعارات أو ميسر للمدفوعات.' : 'Connect Telegram for alerts or Moyasar for payments.'} />;
  } else {
    body = (
      <div style={{ display: 'flex', flexDirection: 'column', gap: 14, paddingBottom: 72 }}>
        <div style={{ marginBottom: 0 }}>
          <p style={{ margin: 0, fontSize: 12, color: t.inkSoft, fontFamily: lang === 'ar' ? F_AR : F_EN, display: 'flex', alignItems: 'center', gap: 8 }}>
            <LockIcon size={12} />{L.section_integrations_sub}
            {!isOperator ? <span style={{ color: t.warn }}>· {L.not_operator}</span> : null}
          </p>
        </div>
        {groups.map((g) => (
          <IntegrationGroup key={g.id} group={g} t={t} L={L} lang={lang} isOperator={isOperator} confirm={confirm}
            onSaved={(svcs) => { addRestart(svcs); res.refresh(); }}
            client={client} />
        ))}
      </div>
    );
  }

  return (
    <div style={{ position: 'relative', height: '100%' }}>
      <div style={{ height: '100%', overflow: 'auto', padding: '18px 28px 28px' }}>{body}</div>
      <AnimatePresence>
        {restartList.length > 0 ? (
          <RestartDrawer key="rd" services={restartList} t={t} L={L} lang={lang} isOperator={isOperator}
            onRestart={(s) => restartOne(s)} onDismiss={clearRestart} />
        ) : null}
      </AnimatePresence>
    </div>
  );
}

function ServiceIcon({ name, t, size = 28 }) {
  const map = { tg: { bg: '#e3f3fc', fg: '#2b88c5', letter: 'T' }, ai: { bg: '#f2eafc', fg: '#7a4ad1', letter: 'A' }, wa: { bg: '#e6f7ea', fg: '#2c8a4f', letter: 'W' }, pay: { bg: '#fff4e3', fg: '#b56a16', letter: '₪' }, plaus: { bg: '#eaf6ea', fg: '#3a8c47', letter: 'P' }, cf: { bg: '#fbe7c8', fg: '#a05a13', letter: 'C' }, mail: { bg: '#eef0f6', fg: '#4a567a', letter: 'M' } };
  const c = map[name] || { bg: t.panelAlt, fg: t.ink, letter: '•' };
  const dark = t.bg === '#0b0b0c';
  return <div style={{ width: size, height: size, borderRadius: 7, flexShrink: 0, background: dark ? t.panelAlt : c.bg, color: dark ? t.ink : c.fg, display: 'flex', alignItems: 'center', justifyContent: 'center', fontFamily: F_MONO, fontWeight: 600, fontSize: size > 30 ? 14 : 13, border: `1px solid ${t.border}` }}>{c.letter}</div>;
}

function IntegrationGroup({ group, t, L, lang, isOperator, confirm, onSaved, client }) {
  const pres = INTEGRATION_PRESENTATION[group.id] || { icon: 'mail' };
  const label = lang === 'ar' ? (pres.ar || group.label) : (group.label || group.id);
  const keys = group.keys || [];
  const setSecrets = keys.filter((k) => k.secret && k.set);
  const isActive = keys.some((k) => k.secret) ? setSecrets.length > 0 : keys.some((k) => k.set);
  return (
    <section style={{ background: t.panel, border: `1px solid ${t.border}`, borderRadius: 12, padding: '18px 20px', display: 'flex', flexDirection: 'column', gap: 14 }}>
      <header style={{ display: 'flex', alignItems: 'flex-start', gap: 14 }}>
        <ServiceIcon name={pres.icon} t={t} size={36} />
        <div style={{ flex: 1, minWidth: 0 }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 10, flexWrap: 'wrap' }}>
            <h3 style={{ margin: 0, fontSize: 16, fontWeight: 600, color: t.ink, fontFamily: lang === 'ar' ? F_AR : F_EN, letterSpacing: '-.005em' }}>{label}</h3>
            <Pill kind={isActive ? 'ok' : 'muted'} t={t}><span style={{ fontFamily: lang === 'ar' ? F_AR : F_EN }}>{isActive ? L.active : L.not_configured}</span></Pill>
            <span style={{ fontFamily: F_MONO, fontSize: 11, color: t.inkMuted }}>{L.keys_count(keys.length)}</span>
          </div>
          {group.description ? <p style={{ margin: '4px 0 0', fontSize: 12, color: t.inkSoft, fontFamily: lang === 'ar' ? F_AR : F_EN, lineHeight: 1.45 }}>{group.description}</p> : null}
        </div>
      </header>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
        {keys.map((k) => <KeyRow key={k.key} k={k} t={t} L={L} lang={lang} isOperator={isOperator} confirm={confirm} client={client} onSaved={onSaved} />)}
      </div>
    </section>
  );
}

function KeyRow({ k, t, L, lang, isOperator, confirm, client, onSaved }) {
  const [value, setValue] = useState('');
  const [editing, setEditing] = useState(false);
  const [reveal, setReveal] = useState(false);
  const [busy, setBusy] = useState(false);
  const [flash, setFlash] = useState(false);
  const [error, setError] = useState(null);
  const isSet = !!k.set;

  const doSave = async (newValue) => {
    setBusy(true); setError(null);
    const res = await client.setIntegrationKey(k.key, newValue);
    setBusy(false);
    if (!res.ok) { setError(res.forbidden ? L.not_operator : (res.error || L.save_failed)); return false; }
    // SECURITY: clear the typed value from state immediately after the write.
    setValue(''); setReveal(false); setEditing(false);
    setFlash(true); setTimeout(() => setFlash(false), 1600);
    onSaved?.(res.data?.restart_services || k.restart_services || []);
    return true;
  };

  // enum-typed key → choice chips + save
  if (Array.isArray(k.enum) && k.enum.length) {
    return <EnumRow k={k} t={t} L={L} lang={lang} isOperator={isOperator} busy={busy} error={error} flash={flash} onSave={doSave} />;
  }

  const placeholder = k.secret ? (isSet ? L.place_secret : L.place_empty) : (isSet ? L.place_text : L.place_text_empty);

  return (
    <div style={{ display: 'grid', gap: 6, padding: '12px 14px', background: editing ? t.panelAlt : t.bg, border: `1px solid ${editing ? t.inkMuted : t.border}`, borderRadius: 9, transition: 'border-color 120ms, background 120ms' }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 10, justifyContent: 'space-between' }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 8, minWidth: 0, flexWrap: 'wrap' }}>
          <span style={{ fontFamily: lang === 'ar' ? F_AR : F_EN, fontSize: 13, fontWeight: 500, color: t.ink }}>{k.label || k.key}</span>
          <code style={{ fontFamily: F_MONO, fontSize: 10, color: t.inkMuted, background: t.panelAlt, border: `1px solid ${t.border}`, padding: '1px 6px', borderRadius: 5 }}>{k.key}</code>
          {k.secret ? <span style={{ fontFamily: lang === 'ar' ? F_AR : F_EN, fontSize: 10, color: t.inkSoft, border: `1px dashed ${t.border}`, padding: '1px 6px', borderRadius: 5, display: 'inline-flex', alignItems: 'center', gap: 4 }}><LockIcon size={9} />{L.secret_note}</span> : null}
          {displayableKeyValue(k) ? <code style={{ fontFamily: F_MONO, fontSize: 10, color: t.inkSoft }} dir="ltr">{displayableKeyValue(k)}</code> : null}
        </div>
        <StatusBadge isSet={isSet} t={t} L={L} lang={lang} flash={flash} />
      </div>

      <div style={{ display: 'flex', alignItems: 'stretch', gap: 8 }}>
        <div style={{ flex: 1, display: 'flex', alignItems: 'stretch', background: t.bg, border: `1px solid ${t.border}`, borderRadius: 7, overflow: 'hidden', opacity: isOperator ? 1 : 0.6 }}>
          <input type={k.secret && !reveal ? 'password' : 'text'} value={value} disabled={!isOperator || busy}
            onChange={(e) => { setValue(e.target.value); setError(null); if (!editing) setEditing(true); }} onFocus={() => setEditing(true)}
            placeholder={placeholder} dir="ltr" spellCheck={false} autoComplete="off"
            style={{ flex: 1, padding: '8px 12px', border: 'none', outline: 'none', background: 'transparent', color: t.ink, fontFamily: F_MONO, fontSize: 13, textAlign: lang === 'ar' ? 'right' : 'left' }} />
          {k.secret ? (
            <button title={L.cannot_show} onClick={() => { if (value.length > 0) setReveal((r) => !r); }} style={{ padding: '0 10px', border: 'none', background: 'transparent', cursor: value.length > 0 ? 'pointer' : 'not-allowed', color: value.length > 0 ? t.inkSoft : t.inkMuted, borderInlineStart: `1px solid ${t.border}`, display: 'inline-flex', alignItems: 'center', justifyContent: 'center' }}>
              <EyeIcon open={reveal && value.length > 0} />
            </button>
          ) : null}
        </div>
        {value.length > 0 ? (
          <>
            <button onClick={() => { setValue(''); setEditing(false); setError(null); }} disabled={busy} style={btn(t, lang, 'ghost')}>{L.cancel}</button>
            <button onClick={() => doSave(value)} disabled={busy} style={btn(t, lang, 'primary')}>{busy ? '…' : L.save}</button>
          </>
        ) : (isSet && isOperator ? (
          <button onClick={() => confirm.ask({
            title: L.confirm_clear_t, target: k.key, message: L.confirm_clear_m, impact: k.restart_services, destructive: true, confirmLabel: L.confirm_clear_yes,
            onConfirm: async () => { const okk = await doSave(''); if (!okk) throw new Error('clear failed'); },
          })} style={btn(t, lang, 'ghost')}>{L.clear}</button>
        ) : null)}
      </div>

      {error ? <div style={{ fontSize: 11, color: t.bad, fontFamily: lang === 'ar' ? F_AR : F_EN }}>{error}</div> : null}
      {k.secret && isSet && value.length === 0 && !error ? (
        <div style={{ fontSize: 10, color: t.inkMuted, fontFamily: lang === 'ar' ? F_AR : F_EN, display: 'flex', alignItems: 'center', gap: 6, paddingTop: 1 }}><LockIcon size={9} />{L.cannot_show} · {L.leave_blank}</div>
      ) : null}
      {flash && (k.restart_services?.length) ? (
        <div style={{ marginTop: 4, padding: '8px 12px', background: t.warnSoft, border: `1px solid ${t.warn}33`, borderRadius: 7, display: 'flex', alignItems: 'center', gap: 8, animation: 'srIn 220ms cubic-bezier(.2,.7,.3,1)' }}>
          <span style={{ width: 7, height: 7, borderRadius: '50%', background: t.warn }} />
          <span style={{ flex: 1, fontFamily: lang === 'ar' ? F_AR : F_EN, fontSize: 11, color: t.warn, fontWeight: 500 }}>{L.restart_msg(k.restart_services.join(', '))}</span>
        </div>
      ) : null}
    </div>
  );
}

function EnumRow({ k, t, L, lang, isOperator, busy, error, flash, onSave }) {
  const [v, setV] = useState(k.value || k.enum[0]);
  return (
    <div style={{ padding: '12px 14px', background: t.bg, border: `1px solid ${t.border}`, borderRadius: 9, display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 10, flexWrap: 'wrap' }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 8, minWidth: 0 }}>
        <span style={{ fontFamily: lang === 'ar' ? F_AR : F_EN, fontSize: 13, fontWeight: 500, color: t.ink }}>{k.label || k.key}</span>
        <code style={{ fontFamily: F_MONO, fontSize: 10, color: t.inkMuted, background: t.panelAlt, border: `1px solid ${t.border}`, padding: '1px 6px', borderRadius: 5 }}>{k.key}</code>
      </div>
      <div style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
        <div style={{ display: 'inline-flex', background: t.panelAlt, border: `1px solid ${t.border}`, borderRadius: 7, padding: 2 }}>
          {k.enum.map((o) => <button key={o} onClick={() => setV(o)} disabled={!isOperator} style={{ padding: '4px 10px', borderRadius: 5, border: 'none', cursor: isOperator ? 'pointer' : 'not-allowed', background: v === o ? t.panel : 'transparent', color: v === o ? t.ink : t.inkSoft, fontFamily: F_MONO, fontSize: 11, fontWeight: v === o ? 600 : 500 }}>{o}</button>)}
        </div>
        <button onClick={() => onSave(v)} disabled={!isOperator || busy} style={{ padding: '5px 12px', borderRadius: 7, background: flash ? t.ok : t.ink, color: t.bg, border: 'none', cursor: 'pointer', fontFamily: lang === 'ar' ? F_AR : F_EN, fontSize: 12, transition: 'background 200ms' }}>{flash ? L.saved : busy ? '…' : L.save}</button>
      </div>
      {error ? <div style={{ width: '100%', fontSize: 11, color: t.bad, fontFamily: lang === 'ar' ? F_AR : F_EN }}>{error}</div> : null}
    </div>
  );
}

const btn = (t, lang, kind) => ({ padding: kind === 'primary' ? '7px 14px' : '7px 12px', borderRadius: 7, background: kind === 'primary' ? t.ink : 'transparent', color: kind === 'primary' ? t.bg : t.inkSoft, border: kind === 'primary' ? 'none' : `1px solid ${t.border}`, cursor: 'pointer', fontFamily: lang === 'ar' ? F_AR : F_EN, fontSize: 12, fontWeight: kind === 'primary' ? 500 : 400 });

const StatusBadge = ({ isSet, t, L, lang, flash }) => (
  <span style={{ display: 'inline-flex', alignItems: 'center', gap: 5, padding: '2px 8px', borderRadius: 999, fontSize: 10, fontWeight: 600, background: flash ? t.okSoft : (isSet ? t.okSoft : t.panelAlt), color: isSet || flash ? t.ok : t.inkSoft, border: `1px solid ${isSet || flash ? `${t.ok}33` : t.border}`, fontFamily: lang === 'ar' ? F_AR : F_EN, letterSpacing: '.02em', transition: 'background 200ms' }}>
    <span style={{ width: 5, height: 5, borderRadius: '50%', background: isSet || flash ? t.ok : t.inkMuted }} />{flash ? L.saved : (isSet ? L.set : L.empty)}
  </span>
);

const LockIcon = ({ size = 10 }) => <svg width={size} height={size} viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round"><rect x="3.5" y="7" width="9" height="6.5" rx="1.2" /><path d="M5.5 7V5a2.5 2.5 0 015 0v2" /></svg>;
const EyeIcon = ({ open }) => (open ? (
  <svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round"><path d="M1.5 8s2.5-4.5 6.5-4.5S14.5 8 14.5 8 12 12.5 8 12.5 1.5 8 1.5 8z" /><circle cx="8" cy="8" r="2" /></svg>
) : (
  <svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round"><path d="M2 8s2.5-4.5 6.5-4.5c1.4 0 2.6.5 3.6 1.2" /><path d="M14 8s-2.5 4.5-6.5 4.5c-1.2 0-2.3-.4-3.2-1" /><path d="M2 2l12 12" /></svg>
));

function RestartDrawer({ services, onRestart, onDismiss, t, L, lang, isOperator }) {
  return (
    <motion.div initial={{ y: 20, opacity: 0 }} animate={{ y: 0, opacity: 1 }} exit={{ y: 20, opacity: 0 }} transition={{ duration: 0.24, ease: [0.2, 0.7, 0.3, 1] }}
      style={{ position: 'absolute', bottom: 14, insetInlineStart: 0, insetInlineEnd: 0, zIndex: 40, display: 'flex', justifyContent: 'center', pointerEvents: 'none' }}>
      <div style={{ pointerEvents: 'auto', maxWidth: 760, width: '100%', background: t.panel, border: `1px solid ${t.border}`, borderRadius: 11, padding: '12px 14px', display: 'flex', alignItems: 'center', gap: 12, boxShadow: '0 12px 30px rgba(0,0,0,0.18), 0 2px 6px rgba(0,0,0,0.08)' }}>
        <div style={{ width: 32, height: 32, borderRadius: '50%', background: t.warnSoft, display: 'flex', alignItems: 'center', justifyContent: 'center', color: t.warn, flexShrink: 0 }}><Icon name="refresh" size={14} stroke={t.warn} /></div>
        <div style={{ flex: 1, display: 'flex', flexDirection: 'column', gap: 4, minWidth: 0 }}>
          <span style={{ fontFamily: lang === 'ar' ? F_AR : F_EN, fontSize: 13, fontWeight: 600, color: t.ink }}>{L.restart_title}</span>
          <div style={{ display: 'flex', flexWrap: 'wrap', gap: 6 }}>
            {services.map((s) => {
              const can = isOperator && VALID_RESTART_SERVICES.includes(s);
              return can
                ? <button key={s} onClick={() => onRestart(s)} style={{ fontFamily: F_MONO, fontSize: 11, color: t.ink, background: t.panelAlt, border: `1px solid ${t.border}`, padding: '2px 8px', borderRadius: 6, cursor: 'pointer' }}>{s} · {L.restart_now}</button>
                : <code key={s} title={lang === 'ar' ? 'أعد التشغيل يدويًا' : 'restart manually'} style={{ fontFamily: F_MONO, fontSize: 11, color: t.inkSoft, background: t.panelAlt, border: `1px solid ${t.border}`, padding: '2px 8px', borderRadius: 6 }}>{s}</code>;
            })}
          </div>
        </div>
        <button onClick={onDismiss} style={{ padding: '6px 12px', borderRadius: 7, background: 'transparent', color: t.ink, border: `1px solid ${t.border}`, cursor: 'pointer', fontFamily: lang === 'ar' ? F_AR : F_EN, fontSize: 12 }}>{L.restart_later}</button>
      </div>
    </motion.div>
  );
}
