'use client';
// primitives.jsx — the shared design-system primitives, ported from the prototype
// (hifi-overview.jsx + projects.jsx). Visuals are byte-for-byte the design's
// inline-token styles; the only swap is animation: the prototype's hand-rolled
// requestAnimationFrame count-up is now driven by framer-motion's `animate()`
// (useAnimatedNumber) and the Bar/Gauge fills are framer `motion` elements, so
// reduced-motion is honoured globally via <MotionConfig reducedMotion="user">.
import { useEffect, useState } from 'react';
import { animate, motion } from 'framer-motion';
import { F_AR, F_EN, F_MONO } from './theme.js';

const EASE_OUT = [0.16, 1, 0.3, 1];

// Count-up hook (framer-motion). duration in ms to match the prototype's API.
export function useAnimatedNumber(target, { duration = 1100, decimals = 0 } = {}) {
  const [v, setV] = useState(0);
  useEffect(() => {
    const reduced = typeof window !== 'undefined'
      && window.matchMedia?.('(prefers-reduced-motion: reduce)').matches;
    if (reduced) { setV(Number(Number(target).toFixed(decimals))); return; }
    const controls = animate(0, Number(target) || 0, {
      duration: duration / 1000,
      ease: EASE_OUT,
      onUpdate: (x) => setV(Number(x.toFixed(decimals))),
    });
    return () => controls.stop();
  }, [target, duration, decimals]);
  return v;
}

export const AnimatedNumber = ({ value, decimals = 0, duration = 1100, ...rest }) => {
  const v = useAnimatedNumber(value, { duration, decimals });
  return <span {...rest}>{v}</span>;
};

export const Spinner = ({ color = '#fff', size = 11 }) => (
  <svg width={size} height={size} viewBox="0 0 16 16" fill="none" stroke={color} strokeWidth="1.8"
    strokeLinecap="round" style={{ animation: 'spin 900ms linear infinite' }}>
    <path d="M14 8a6 6 0 11-6-6" />
  </svg>
);

export const Pill = ({ kind = 'ok', children, t }) => {
  const map = { ok: [t.ok, t.okSoft], warn: [t.warn, t.warnSoft], bad: [t.bad, t.badSoft], muted: [t.inkSoft, t.panelAlt] };
  const [fg, bg] = map[kind] || map.ok;
  return (
    <span style={{
      display: 'inline-flex', alignItems: 'center', gap: 6, padding: '3px 9px', borderRadius: 999,
      background: bg, color: fg, fontSize: 11, fontWeight: 600, letterSpacing: '.02em', border: `1px solid ${fg}22`,
    }}>
      <span style={{ width: 6, height: 6, borderRadius: '50%', background: fg }} />
      {children}
    </span>
  );
};

export const Dot = ({ kind = 'ok', t, size = 8 }) => {
  const c = kind === 'warn' ? t.warn : kind === 'bad' ? t.bad : kind === 'muted' ? t.inkMuted : t.ok;
  return <span style={{ width: size, height: size, borderRadius: '50%', background: c, display: 'inline-block', boxShadow: `0 0 0 2px ${c}22` }} />;
};

export const Bar = ({ value, max = 100, kind = 'ok', t, height = 6, animateDelay = 0 }) => {
  const pct = Math.max(0, Math.min(100, (value / max) * 100));
  const color = kind === 'warn' ? t.warn : kind === 'bad' ? t.bad : t.ok;
  return (
    <div style={{ height, borderRadius: height, background: `${t.inkMuted}22`, overflow: 'hidden' }}>
      <motion.div
        initial={{ width: 0 }}
        animate={{ width: `${pct}%` }}
        transition={{ duration: 1, ease: EASE_OUT, delay: animateDelay / 1000 }}
        style={{ height: '100%', background: color }}
      />
    </div>
  );
};

export const Gauge = ({ value, max = 100, label, unit = '', kind = 'ok', t, size = 120, suffix }) => {
  const pct = Math.max(0, Math.min(1, value / max));
  const animatedPct = useAnimatedNumber(pct * 100, { duration: 1100, decimals: 1 });
  const r = size / 2 - 8;
  const c = 2 * Math.PI * r;
  const dash = (animatedPct / 100) * c;
  const color = kind === 'warn' ? t.warn : kind === 'bad' ? t.bad : t.ok;
  const trackColor = `${t.inkMuted}33`;
  const num = useAnimatedNumber(value, { duration: 1100, decimals: unit === '°' ? 1 : 0 });
  return (
    <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 6 }}>
      <div style={{ position: 'relative', width: size, height: size }}>
        <svg width={size} height={size} viewBox={`0 0 ${size} ${size}`} style={{ transform: 'rotate(-90deg)' }}>
          <circle cx={size / 2} cy={size / 2} r={r} fill="none" stroke={trackColor} strokeWidth="6" />
          <circle cx={size / 2} cy={size / 2} r={r} fill="none" stroke={color} strokeWidth="6" strokeLinecap="round"
            strokeDasharray={`${dash} ${c - dash}`} style={{ transition: 'stroke 200ms' }} />
        </svg>
        <div style={{ position: 'absolute', inset: 0, display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', gap: 2 }}>
          <div style={{ fontFamily: F_MONO, fontSize: size > 100 ? 22 : 18, fontWeight: 600, color: t.ink, letterSpacing: '-.02em' }}>
            {num}{unit}
          </div>
          {suffix ? <div style={{ fontFamily: F_MONO, fontSize: 10, color: t.inkSoft }}>{suffix}</div> : null}
        </div>
      </div>
      <div style={{ fontSize: 12, color: t.inkSoft, fontFamily: F_EN, letterSpacing: '.02em' }}>{label}</div>
    </div>
  );
};

export const IconButton = ({ children, t, ...rest }) => (
  <button {...rest} style={{
    width: 28, height: 28, display: 'inline-flex', alignItems: 'center', justifyContent: 'center',
    background: t.panel, border: `1px solid ${t.border}`, borderRadius: 7, cursor: 'pointer',
  }}>{children}</button>
);

export const Segmented = ({ value, onChange, options, t }) => (
  <div style={{ display: 'inline-flex', background: t.panel, border: `1px solid ${t.border}`, borderRadius: 7, padding: 2 }}>
    {options.map((o) => (
      <button key={o.k} onClick={() => onChange(o.k)} style={{
        padding: '4px 10px', borderRadius: 5, border: 'none', cursor: 'pointer',
        background: value === o.k ? t.panelAlt : 'transparent', color: value === o.k ? t.ink : t.inkSoft,
        fontFamily: F_MONO, fontSize: 11, fontWeight: value === o.k ? 600 : 500, letterSpacing: '.04em',
      }}>{o.label}</button>
    ))}
  </div>
);

export const Row = ({ label, value, children, t, lang }) => (
  <div style={{ display: 'flex', flexDirection: 'column', gap: 3 }}>
    <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'baseline' }}>
      <span style={{ fontSize: 11, color: t.inkSoft, fontFamily: lang === 'ar' ? F_AR : F_EN }}>{label}</span>
      <span style={{ fontSize: 10, color: t.inkSoft, fontFamily: F_MONO }}>{value}</span>
    </div>
    {children}
  </div>
);

export const Panel = ({ title, subtitle, action, children, t, lang }) => (
  <section style={{ background: t.panel, border: `1px solid ${t.border}`, borderRadius: 12, padding: '14px 16px 16px', display: 'flex', flexDirection: 'column', gap: 12 }}>
    {(title || action) ? (
      <header style={{ display: 'flex', alignItems: 'baseline', justifyContent: 'space-between', gap: 12 }}>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 1 }}>
          {title ? <h3 style={{ margin: 0, fontSize: 14, fontWeight: 600, color: t.ink, fontFamily: lang === 'ar' ? F_AR : F_EN, letterSpacing: '-.005em' }}>{title}</h3> : null}
          {subtitle ? <span style={{ fontSize: 11, color: t.inkSoft, fontFamily: lang === 'ar' ? F_AR : F_EN }}>{subtitle}</span> : null}
        </div>
        {action}
      </header>
    ) : null}
    {children}
  </section>
);

export const KpiCard = ({ title, value, unit, sub, kind = 'ok', t, lang, delta, spark }) => (
  <div style={{ background: t.panel, border: `1px solid ${t.border}`, borderRadius: 12, padding: '14px 16px', display: 'flex', flexDirection: 'column', gap: 8, transition: 'border-color 150ms, background 150ms' }}
    onMouseEnter={(e) => { e.currentTarget.style.background = t.panelAlt; }}
    onMouseLeave={(e) => { e.currentTarget.style.background = t.panel; }}>
    <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
      <span style={{ fontSize: 12, color: t.inkSoft, fontFamily: lang === 'ar' ? F_AR : F_EN }}>{title}</span>
      {sub ? <span style={{ fontFamily: F_MONO, fontSize: 10, color: t.inkMuted }}>{sub}</span> : null}
    </div>
    <div style={{ display: 'flex', alignItems: 'baseline', gap: 6 }}>
      <span style={{ fontFamily: F_MONO, fontSize: 28, fontWeight: 600, letterSpacing: '-.02em', color: t.ink }}>{value}</span>
      {unit ? <span style={{ fontFamily: F_MONO, fontSize: 13, color: t.inkSoft }}>{unit}</span> : null}
    </div>
    {spark || null}
    {delta ? <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}><Pill kind={kind} t={t}>{delta}</Pill></div> : null}
  </div>
);

// ThemeToggle glyph (sun/moon) shared by every section's top bar.
export const ThemeGlyph = ({ theme, t }) => (theme === 'light' ? (
  <svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke={t.inkSoft} strokeWidth="1.5" strokeLinecap="round"><path d="M12.5 9.5A5 5 0 016.5 3.5a5 5 0 106 6z" /></svg>
) : (
  <svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke={t.inkSoft} strokeWidth="1.5" strokeLinecap="round"><circle cx="8" cy="8" r="3" /><path d="M8 1.5v1.5M8 13v1.5M1.5 8h1.5M13 8h1.5M3.3 3.3l1 1M11.7 11.7l1 1M3.3 12.7l1-1M11.7 4.3l1-1" /></svg>
));

// Shared inline icon set (from the prototype's projects.jsx Icon).
export const Icon = ({ name, size = 16, stroke, strokeWidth = 1.5 }) => {
  const props = { width: size, height: size, viewBox: '0 0 16 16', fill: 'none', stroke, strokeWidth, strokeLinecap: 'round', strokeLinejoin: 'round' };
  switch (name) {
    case 'plus': return <svg {...props}><path d="M8 4v8M4 8h8" /></svg>;
    case 'cart': return <svg {...props}><path d="M2 3h2l1.5 8h7l1.5-5H5" /><circle cx="6" cy="13.5" r="1" /><circle cx="12" cy="13.5" r="1" /></svg>;
    case 'office': return <svg {...props}><rect x="2.5" y="3" width="11" height="11" rx="1" /><path d="M5 6h2M9 6h2M5 9h2M9 9h2M5 12h6" /></svg>;
    case 'home': return <svg {...props}><path d="M2.5 8L8 3l5.5 5" /><path d="M4 8v5.5h8V8" /></svg>;
    case 'check': return <svg {...props}><path d="M3.5 8.5L6.5 11.5 12.5 5" /></svg>;
    case 'arrowR': return <svg {...props}><path d="M3 8h10M9 4l4 4-4 4" /></svg>;
    case 'arrowL': return <svg {...props}><path d="M13 8H3M7 4L3 8l4 4" /></svg>;
    case 'spin': return <svg {...props}><path d="M14 8a6 6 0 11-6-6" /></svg>;
    case 'open': return <svg {...props}><path d="M5 3h-2v10h10v-2" /><path d="M9 3h4v4" /><path d="M7 9l6-6" /></svg>;
    case 'play': return <svg {...props}><path d="M5 3.5v9l8-4.5z" /></svg>;
    case 'stop': return <svg {...props}><rect x="4" y="4" width="8" height="8" rx="1" /></svg>;
    case 'logs': return <svg {...props}><path d="M3 3h10v10H3z" /><path d="M5.5 6h5M5.5 8.5h5M5.5 11h3" /></svg>;
    case 'dots': return <svg {...props}><circle cx="4" cy="8" r=".8" /><circle cx="8" cy="8" r=".8" /><circle cx="12" cy="8" r=".8" /></svg>;
    case 'x': return <svg {...props}><path d="M4 4l8 8M12 4l-8 8" /></svg>;
    case 'globe': return <svg {...props}><circle cx="8" cy="8" r="5.5" /><path d="M2.5 8h11M8 2.5c2 2 2 9 0 11M8 2.5c-2 2-2 9 0 11" /></svg>;
    case 'db': return <svg {...props}><ellipse cx="8" cy="4" rx="5" ry="2" /><path d="M3 4v8c0 1.1 2.2 2 5 2s5-.9 5-2V4" /><path d="M3 8c0 1.1 2.2 2 5 2s5-.9 5-2" /></svg>;
    case 'logout': return <svg {...props}><path d="M6 14H3V2h3" /><path d="M10 11l3-3-3-3" /><path d="M13 8H6" /></svg>;
    case 'refresh': return <svg {...props}><path d="M13.5 7.5A5.5 5.5 0 117.5 2" /><path d="M10.5 2v3.5h3.5" /></svg>;
    case 'copy': return <svg {...props}><rect x="5" y="5" width="8" height="8" rx="1" /><path d="M11 5V3.5A1.5 1.5 0 009.5 2H4a2 2 0 00-2 2v5.5A1.5 1.5 0 003.5 11H5" /></svg>;
    default: return null;
  }
};

export const btnPrimary = (t, lang) => ({ padding: '7px 14px', borderRadius: 7, background: t.ink, color: t.bg, border: 'none', cursor: 'pointer', fontFamily: lang === 'ar' ? F_AR : F_EN, fontSize: 12, fontWeight: 500 });
export const btnGhost = (t, lang) => ({ padding: '7px 14px', borderRadius: 7, background: 'transparent', color: t.ink, border: `1px solid ${t.border}`, cursor: 'pointer', fontFamily: lang === 'ar' ? F_AR : F_EN, fontSize: 12, fontWeight: 500 });
