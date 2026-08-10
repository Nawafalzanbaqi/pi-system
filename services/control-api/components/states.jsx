'use client';
// states.jsx — viewState primitives (loading / error / empty / ready) + the
// destructive ConfirmDialog and the useConfirm() hook, ported from the prototype.
// Each screen maps its real fetch state 1:1 onto these. The shimmer/dialog
// keyframes now live in globals.css (the prototype injected them at runtime).
// The confirm flow is driven by the PURE lib/confirm-machine.js reducer so the
// confirm→pending→success/error transitions are unit-testable without a browser.
import { useReducer, useState } from 'react';
import { motion, AnimatePresence } from 'framer-motion';
import { F_AR, F_EN, F_MONO } from './theme.js';
import { Spinner } from './primitives.jsx';
import { confirmReducer, confirmView } from '../lib/confirm-machine.js';

// ---- Skeleton primitives ---------------------------------------------------
export const Skel = ({ w = '100%', h = 12, r = 6, t, style }) => {
  const cssVar = t ? {
    ['--skel-bg']: `${t.inkMuted}26`,
    ['--skel-shimmer']: t.bg === '#0b0b0c' ? 'rgba(255,255,255,0.06)' : 'rgba(255,255,255,0.55)',
  } : {};
  return <span className="skel" style={{ display: 'inline-block', width: w, height: h, borderRadius: r, ...cssVar, ...style }} />;
};

export const SkeletonOverview = ({ t }) => (
  <div style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
    <div style={{ background: t.panel, border: `1px solid ${t.border}`, borderRadius: 14, padding: '18px 22px', display: 'flex', alignItems: 'center', gap: 24 }}>
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', gap: 10 }}>
        <Skel w={70} h={20} r={999} t={t} /><Skel w="60%" h={22} t={t} /><Skel w="85%" h={12} t={t} />
        <div style={{ display: 'flex', gap: 8, marginTop: 6 }}><Skel w={130} h={28} t={t} /><Skel w={150} h={28} t={t} /></div>
      </div>
      <div style={{ display: 'flex', gap: 24, paddingInlineStart: 24, borderInlineStart: `1px solid ${t.border}` }}>
        {[0, 1, 2].map((i) => (
          <div key={i} style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 6 }}>
            <Skel w={110} h={110} r={'50%'} t={t} /><Skel w={70} h={11} t={t} />
          </div>
        ))}
      </div>
    </div>
    <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 12 }}>
      {[0, 1, 2, 3].map((i) => (
        <div key={i} style={{ background: t.panel, border: `1px solid ${t.border}`, borderRadius: 12, padding: '14px 16px', display: 'flex', flexDirection: 'column', gap: 10 }}>
          <Skel w="55%" h={11} t={t} /><Skel w="50%" h={26} t={t} /><Skel w="80%" h={20} t={t} />
        </div>
      ))}
    </div>
    <div style={{ display: 'grid', gridTemplateColumns: '1.5fr 1fr', gap: 14 }}>
      <div style={{ background: t.panel, border: `1px solid ${t.border}`, borderRadius: 12, padding: '14px 16px' }}>
        <Skel w="30%" h={14} t={t} style={{ marginBottom: 12 }} />
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(5, 1fr)', gap: 8 }}>
          {Array.from({ length: 15 }).map((_, i) => <Skel key={i} w="100%" h={36} t={t} />)}
        </div>
      </div>
      <div style={{ background: t.panel, border: `1px solid ${t.border}`, borderRadius: 12, padding: '14px 16px' }}>
        <Skel w="40%" h={14} t={t} style={{ marginBottom: 12 }} />
        <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
          {[0, 1, 2, 3, 4, 5].map((i) => (
            <div key={i} style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
              <Skel w={42} h={10} t={t} /><Skel w={6} h={6} r={999} t={t} /><Skel w={44} h={10} t={t} /><Skel w="60%" h={10} t={t} />
            </div>
          ))}
        </div>
      </div>
    </div>
  </div>
);

export const SkeletonProjects = ({ t, count = 6 }) => (
  <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 14 }}>
    {Array.from({ length: count }).map((_, i) => (
      <div key={i} style={{ background: t.panel, border: `1px solid ${t.border}`, borderRadius: 12, padding: '16px 16px 12px', display: 'flex', flexDirection: 'column', gap: 12 }}>
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}><Skel w="55%" h={14} t={t} /><Skel w={10} h={10} r={999} t={t} /></div>
        <Skel w="75%" h={10} t={t} />
        <div style={{ display: 'flex', flexWrap: 'wrap', gap: 4 }}><Skel w={70} h={18} t={t} /><Skel w={84} h={18} t={t} /><Skel w={56} h={18} t={t} /></div>
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', paddingTop: 8, borderTop: `1px solid ${t.borderSoft}` }}>
          <div style={{ display: 'flex', gap: 6 }}><Skel w={50} h={22} t={t} /><Skel w={50} h={22} t={t} /><Skel w={50} h={22} t={t} /></div><Skel w={70} h={10} t={t} />
        </div>
      </div>
    ))}
  </div>
);

export const SkeletonMonitoring = ({ t }) => (
  <div style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
    <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 12 }}>
      {[0, 1, 2].map((i) => (
        <div key={i} style={{ background: t.panel, border: `1px solid ${t.border}`, borderRadius: 12, padding: '14px 16px' }}>
          <div style={{ display: 'flex', justifyContent: 'space-between', marginBottom: 10 }}><Skel w="40%" h={12} t={t} /><Skel w={48} h={20} r={999} t={t} /></div>
          <Skel w="100%" h={160} t={t} />
        </div>
      ))}
    </div>
    <div style={{ display: 'grid', gridTemplateColumns: '1fr 1.3fr', gap: 12 }}>
      <div style={{ background: t.panel, border: `1px solid ${t.border}`, borderRadius: 12, padding: '14px 16px' }}><Skel w="50%" h={14} t={t} style={{ marginBottom: 12 }} />{Array.from({ length: 8 }).map((_, i) => <Skel key={i} w="100%" h={20} t={t} style={{ marginBottom: 8 }} />)}</div>
      <div style={{ background: t.panel, border: `1px solid ${t.border}`, borderRadius: 12, padding: '14px 16px' }}><Skel w="40%" h={14} t={t} style={{ marginBottom: 12 }} />{Array.from({ length: 7 }).map((_, i) => <Skel key={i} w="100%" h={18} t={t} style={{ marginBottom: 10 }} />)}</div>
    </div>
  </div>
);

export const SkeletonProspects = ({ t }) => (
  <div style={{ display: 'grid', gridTemplateColumns: 'repeat(5, 1fr)', gap: 10 }}>
    {[0, 1, 2, 3, 4].map((c) => (
      <div key={c} style={{ background: t.panelAlt, border: `1px solid ${t.border}`, borderRadius: 10, padding: 10, minHeight: 400, display: 'flex', flexDirection: 'column', gap: 8 }}>
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}><Skel w="50%" h={12} t={t} /><Skel w={20} h={10} t={t} /></div>
        {Array.from({ length: [3, 2, 1, 1, 1][c] || 1 }).map((_, i) => (
          <div key={i} style={{ background: t.panel, border: `1px solid ${t.border}`, borderRadius: 8, padding: 10, display: 'flex', flexDirection: 'column', gap: 6 }}>
            <Skel w="70%" h={12} t={t} /><Skel w="55%" h={10} t={t} />
          </div>
        ))}
      </div>
    ))}
  </div>
);

// ---- EmptyState ------------------------------------------------------------
const EmptyIcon = ({ name, t }) => {
  const c = t.inkMuted;
  const props = { width: 28, height: 28, viewBox: '0 0 28 28', fill: 'none', stroke: c, strokeWidth: 1.4, strokeLinecap: 'round', strokeLinejoin: 'round' };
  switch (name) {
    case 'box': return <svg {...props}><path d="M4 9l10-5 10 5" /><path d="M4 9v11l10 5 10-5V9" /><path d="M14 14L4 9M14 14l10-5M14 14v11" /></svg>;
    case 'inbox': return <svg {...props}><path d="M4 16v4a2 2 0 002 2h16a2 2 0 002-2v-4" /><path d="M4 16l3-9h14l3 9" /><path d="M4 16h6l1.5 2.5h5L18 16h6" /></svg>;
    case 'plug': return <svg {...props}><path d="M9 4v6M19 4v6" /><path d="M6 10h16" /><path d="M14 22v-4a4 4 0 00-4-4h0a4 4 0 00-4 4" /></svg>;
    case 'sparkle': return <svg {...props}><path d="M14 4l2.5 6 6 2.5-6 2.5L14 21l-2.5-6L5.5 12.5l6-2.5z" /></svg>;
    default: return <svg {...props}><circle cx="14" cy="14" r="10" /></svg>;
  }
};

export const EmptyState = ({ icon = 'box', title, body, action, secondary, t, lang }) => (
  <div style={{ background: t.panel, border: `1px dashed ${t.border}`, borderRadius: 14, padding: '48px 32px', display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', gap: 10, textAlign: 'center' }}>
    <div style={{ width: 54, height: 54, borderRadius: '50%', background: t.panelAlt, border: `1px solid ${t.border}`, display: 'flex', alignItems: 'center', justifyContent: 'center' }}><EmptyIcon name={icon} t={t} /></div>
    <h3 style={{ margin: '4px 0 0', fontSize: 15, fontWeight: 600, color: t.ink, fontFamily: lang === 'ar' ? F_AR : F_EN, letterSpacing: '-.005em' }}>{title}</h3>
    {body ? <p style={{ margin: 0, maxWidth: 420, fontSize: 12.5, lineHeight: 1.5, color: t.inkSoft, fontFamily: lang === 'ar' ? F_AR : F_EN }}>{body}</p> : null}
    {(action || secondary) ? (
      <div style={{ display: 'flex', gap: 8, marginTop: 6 }}>
        {action ? <button onClick={action.onClick} style={{ padding: '7px 14px', borderRadius: 7, background: t.ink, color: t.bg, border: 'none', cursor: 'pointer', fontFamily: lang === 'ar' ? F_AR : F_EN, fontSize: 12, fontWeight: 500 }}>{action.label}</button> : null}
        {secondary ? <button onClick={secondary.onClick} style={{ padding: '7px 14px', borderRadius: 7, background: 'transparent', color: t.ink, border: `1px solid ${t.border}`, cursor: 'pointer', fontFamily: lang === 'ar' ? F_AR : F_EN, fontSize: 12, fontWeight: 500 }}>{secondary.label}</button> : null}
      </div>
    ) : null}
  </div>
);

// ---- ErrorState ------------------------------------------------------------
export const ErrorState = ({ title, body, onRetry, detail, retryLabel, t, lang }) => {
  const [showDetail, setShowDetail] = useState(false);
  return (
    <div style={{ background: t.panel, border: `1px solid ${t.border}`, borderRadius: 14, padding: '40px 32px', display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', gap: 10, textAlign: 'center' }}>
      <div style={{ width: 54, height: 54, borderRadius: '50%', background: t.warnSoft, border: `1px solid ${t.warn}33`, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
        <svg width="28" height="28" viewBox="0 0 28 28" fill="none" stroke={t.warn} strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round"><path d="M14 4l11 19H3z" /><path d="M14 11v6M14 19.5v.1" /></svg>
      </div>
      <h3 style={{ margin: '4px 0 0', fontSize: 15, fontWeight: 600, color: t.ink, fontFamily: lang === 'ar' ? F_AR : F_EN, letterSpacing: '-.005em' }}>{title}</h3>
      {body ? <p style={{ margin: 0, maxWidth: 460, fontSize: 12.5, lineHeight: 1.5, color: t.inkSoft, fontFamily: lang === 'ar' ? F_AR : F_EN }}>{body}</p> : null}
      <div style={{ display: 'flex', gap: 8, marginTop: 6 }}>
        {onRetry ? (
          <button onClick={onRetry} style={{ padding: '7px 14px', borderRadius: 7, background: t.ink, color: t.bg, border: 'none', cursor: 'pointer', fontFamily: lang === 'ar' ? F_AR : F_EN, fontSize: 12, fontWeight: 500, display: 'inline-flex', alignItems: 'center', gap: 6 }}>
            <svg width="11" height="11" viewBox="0 0 16 16" fill="none" stroke={t.bg} strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M13.5 7.5A5.5 5.5 0 117.5 2" /><path d="M10.5 2v3.5h3.5" /></svg>
            {retryLabel}
          </button>
        ) : null}
        {detail ? <button onClick={() => setShowDetail((s) => !s)} style={{ padding: '7px 14px', borderRadius: 7, background: 'transparent', color: t.inkSoft, border: `1px solid ${t.border}`, cursor: 'pointer', fontFamily: lang === 'ar' ? F_AR : F_EN, fontSize: 12 }}>{showDetail ? (lang === 'ar' ? 'إخفاء التفاصيل' : 'Hide details') : (lang === 'ar' ? 'إظهار التفاصيل' : 'Show details')}</button> : null}
      </div>
      {showDetail && detail ? (
        <pre dir="ltr" style={{ marginTop: 8, padding: '10px 12px', textAlign: 'left', background: t.panelAlt, border: `1px solid ${t.border}`, borderRadius: 7, fontFamily: F_MONO, fontSize: 11, color: t.inkSoft, maxWidth: 560, width: '100%', overflow: 'auto', maxHeight: 140, whiteSpace: 'pre-wrap' }}>{detail}</pre>
      ) : null}
    </div>
  );
};

// ---- ConfirmDialog ---------------------------------------------------------
export const ConfirmDialog = ({
  open, title, message, target, impact, confirmLabel, cancelLabel,
  destructive = false, pending = false, success = false, onConfirm, onCancel, t, lang,
}) => (
  <AnimatePresence>
    {open ? (
      <motion.div
        initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }}
        style={{ position: 'absolute', inset: 0, zIndex: 80, background: 'rgba(0,0,0,0.45)', backdropFilter: 'blur(2px)', display: 'flex', alignItems: 'center', justifyContent: 'center', padding: 24 }}
        onClick={(e) => { if (e.target === e.currentTarget && !pending) onCancel?.(); }}>
        <motion.div
          initial={{ y: 8, scale: 0.985, opacity: 0 }} animate={{ y: 0, scale: 1, opacity: 1 }} exit={{ y: 8, opacity: 0 }}
          transition={{ duration: 0.22, ease: [0.2, 0.7, 0.3, 1] }}
          style={{ width: 'min(440px, 100%)', background: t.panel, border: `1px solid ${t.border}`, borderRadius: 14, overflow: 'hidden', boxShadow: '0 24px 80px rgba(0,0,0,0.30), 0 2px 6px rgba(0,0,0,0.15)' }}>
          <div style={{ padding: '18px 20px 8px', display: 'flex', alignItems: 'flex-start', gap: 12 }}>
            <div style={{ width: 34, height: 34, borderRadius: '50%', background: destructive ? t.badSoft : t.panelAlt, color: destructive ? t.bad : t.ink, flexShrink: 0, display: 'flex', alignItems: 'center', justifyContent: 'center', border: `1px solid ${destructive ? `${t.bad}33` : t.border}` }}>
              {destructive ? (
                <svg width="15" height="15" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round"><path d="M8 1.5l7 12.5H1z" /><path d="M8 7v3M8 12v.1" /></svg>
              ) : (
                <svg width="15" height="15" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round"><circle cx="8" cy="8" r="6" /><path d="M8 5v3.5" /><path d="M8 11v.1" /></svg>
              )}
            </div>
            <div style={{ flex: 1, minWidth: 0 }}>
              <h3 style={{ margin: 0, fontSize: 15, fontWeight: 600, color: t.ink, fontFamily: lang === 'ar' ? F_AR : F_EN, letterSpacing: '-.005em', lineHeight: 1.3 }}>{title}</h3>
              {target ? <code style={{ display: 'inline-block', marginTop: 6, fontFamily: F_MONO, fontSize: 12, color: t.ink, background: t.panelAlt, border: `1px solid ${t.border}`, padding: '2px 8px', borderRadius: 6, direction: 'ltr' }}>{target}</code> : null}
              {message ? <p style={{ margin: '8px 0 0', fontSize: 12.5, lineHeight: 1.5, color: t.inkSoft, fontFamily: lang === 'ar' ? F_AR : F_EN }}>{message}</p> : null}
              {impact && impact.length ? (
                <div style={{ marginTop: 10, padding: '8px 10px', background: t.panelAlt, border: `1px solid ${t.border}`, borderRadius: 7 }}>
                  <div style={{ fontSize: 10, color: t.inkMuted, fontFamily: lang === 'ar' ? F_AR : F_EN, letterSpacing: '.06em', textTransform: 'uppercase', marginBottom: 5 }}>{lang === 'ar' ? 'الخدمات المتأثّرة' : 'Affected services'}</div>
                  <div style={{ display: 'flex', flexWrap: 'wrap', gap: 4 }}>
                    {impact.map((s) => <code key={s} style={{ fontFamily: F_MONO, fontSize: 10, color: t.ink, background: t.panel, border: `1px solid ${t.border}`, padding: '1px 6px', borderRadius: 5 }}>{s}</code>)}
                  </div>
                </div>
              ) : null}
            </div>
          </div>
          <div style={{ padding: '14px 20px 16px', display: 'flex', alignItems: 'center', justifyContent: 'flex-end', gap: 8 }}>
            <button onClick={onCancel} disabled={pending} style={{ padding: '7px 14px', borderRadius: 7, background: 'transparent', color: t.ink, border: `1px solid ${t.border}`, cursor: pending ? 'not-allowed' : 'pointer', fontFamily: lang === 'ar' ? F_AR : F_EN, fontSize: 12, fontWeight: 500, opacity: pending ? 0.6 : 1 }}>{cancelLabel || (lang === 'ar' ? 'إلغاء' : 'Cancel')}</button>
            <button onClick={onConfirm} disabled={pending || success} style={{ padding: '7px 16px', borderRadius: 7, background: success ? t.ok : (destructive ? t.bad : t.ink), color: success || destructive ? '#fff' : t.bg, border: 'none', cursor: pending ? 'wait' : 'pointer', fontFamily: lang === 'ar' ? F_AR : F_EN, fontSize: 12, fontWeight: 500, display: 'inline-flex', alignItems: 'center', gap: 7, opacity: pending && !success ? 0.85 : 1, transition: 'background 200ms' }}>
              {pending ? <Spinner color="#fff" /> : success ? <svg width="11" height="11" viewBox="0 0 16 16" fill="none" stroke="#fff" strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round"><path d="M3.5 8.5L6.5 11.5 12.5 5" /></svg> : null}
              {success ? (lang === 'ar' ? 'تم' : 'Done') : pending ? (lang === 'ar' ? 'جارٍ…' : 'Working…') : confirmLabel}
            </button>
          </div>
        </motion.div>
      </motion.div>
    ) : null}
  </AnimatePresence>
);

// ---- useConfirm hook (built on the pure confirm-machine) -------------------
export const useConfirm = () => {
  const [opts, setOpts] = useState(null);
  const [state, dispatch] = useReducer(confirmReducer, 'idle');
  const view = confirmView(state);

  const ask = (o) => { setOpts(o); dispatch('ask'); };
  const close = () => { dispatch('close'); setOpts(null); };

  const dialog = opts ? (
    <ConfirmDialog
      open={view.open}
      {...opts}
      pending={view.pending}
      success={view.success}
      onCancel={() => { opts.onCancel?.(); close(); }}
      onConfirm={async () => {
        dispatch('confirm');
        try {
          await opts.onConfirm?.();
          dispatch('resolve');
          setTimeout(close, 700);
        } catch (e) {
          dispatch('reject');
          opts.onError?.(e);
        }
      }}
    />
  ) : null;

  return { ask, close, dialog, state };
};

// ---- useViewState ----------------------------------------------------------
export const useViewState = (initial = 'ready') => {
  const [state, setState] = useState(initial);
  const retry = () => { setState('loading'); setTimeout(() => setState('ready'), 500); };
  return { state, retry, setState };
};
