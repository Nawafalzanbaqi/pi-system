'use client';
// Sidebar.jsx — grouped nav + ambient host-vitals footer (the prototype's chosen
// shell direction B + nav N1). Nav items are now real (onNavigate); the footer
// vitals are LIVE (driven by the polled /api/system-health), falling back to "—"
// before the first sample.
import { F_AR, F_EN, F_MONO } from './theme.js';
import { Pill, Dot, Bar, Row } from './primitives.jsx';

const navIcon = (name, stroke) => {
  const props = { width: 16, height: 16, viewBox: '0 0 16 16', fill: 'none', stroke, strokeWidth: 1.5, strokeLinecap: 'round', strokeLinejoin: 'round' };
  switch (name) {
    case 'overview': return <svg {...props}><rect x="2" y="2" width="5" height="5" rx="1" /><rect x="9" y="2" width="5" height="5" rx="1" /><rect x="2" y="9" width="5" height="5" rx="1" /><rect x="9" y="9" width="5" height="5" rx="1" /></svg>;
    case 'projects': return <svg {...props}><path d="M2 5l6-3 6 3-6 3-6-3z" /><path d="M2 8l6 3 6-3" /><path d="M2 11l6 3 6-3" /></svg>;
    case 'monitor': return <svg {...props}><path d="M2 11l3-4 3 2 3-5 3 4" /></svg>;
    case 'growth': return <svg {...props}><path d="M2 12l4-4 3 3 5-6" /><path d="M9 5h5v5" /></svg>;
    case 'settings': return <svg {...props}><circle cx="8" cy="8" r="2" /><path d="M8 1.5v2M8 12.5v2M1.5 8h2M12.5 8h2M3.3 3.3l1.4 1.4M11.3 11.3l1.4 1.4M3.3 12.7l1.4-1.4M11.3 4.7l1.4-1.4" /></svg>;
    case 'integrations': return <svg {...props}><circle cx="4" cy="4" r="2" /><circle cx="12" cy="4" r="2" /><circle cx="8" cy="12" r="2" /><path d="M4 6v2a2 2 0 002 2h4a2 2 0 002-2V6" /></svg>;
    default: return null;
  }
};

export default function Sidebar({ t, L, lang, dir, current = 'overview', onNavigate, health }) {
  const navItem = (key, icon, badge) => {
    const active = key === current;
    return (
      <button key={key} onClick={() => onNavigate?.(key)} style={{
        display: 'flex', alignItems: 'center', gap: 10, padding: '7px 10px', borderRadius: 7,
        color: active ? t.ink : t.inkSoft, background: active ? t.panelAlt : 'transparent',
        fontSize: 13, fontWeight: active ? 600 : 500, fontFamily: lang === 'ar' ? F_AR : F_EN,
        border: `1px solid ${active ? t.border : 'transparent'}`, cursor: 'pointer', width: '100%',
        textAlign: lang === 'ar' ? 'right' : 'left', transition: 'background 120ms, color 120ms',
      }}
        onMouseEnter={(e) => { if (!active) { e.currentTarget.style.background = t.panelAlt; e.currentTarget.style.color = t.ink; } }}
        onMouseLeave={(e) => { if (!active) { e.currentTarget.style.background = 'transparent'; e.currentTarget.style.color = t.inkSoft; } }}>
        <span style={{ display: 'inline-flex', width: 16, height: 16 }}>{navIcon(icon, t.inkSoft)}</span>
        <span style={{ flex: 1 }}>{L[`nav_${key}`]}</span>
        {badge ? <Dot kind={badge} t={t} size={6} /> : null}
      </button>
    );
  };

  const group = (titleKey) => (
    <div style={{ padding: '12px 10px 4px', fontSize: 10, color: t.inkMuted, letterSpacing: '.12em', textTransform: 'uppercase', fontFamily: lang === 'ar' ? F_AR : F_EN }}>{L[titleKey]}</div>
  );

  const cpu = health?.cpuTempC;
  const ram = health?.ram;
  const disk = health?.disk;
  const fmt = (v, d = 0) => (v == null || Number.isNaN(v) ? '—' : Number(v).toFixed(d));

  return (
    <aside style={{ width: 230, flexShrink: 0, background: t.panel, borderInlineEnd: `1px solid ${t.border}`, display: 'flex', flexDirection: 'column', padding: '14px 12px 12px' }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '2px 6px 12px' }}>
        <div style={{ width: 28, height: 28, borderRadius: 8, background: t.ink, color: t.bg, display: 'flex', alignItems: 'center', justifyContent: 'center', fontFamily: F_MONO, fontWeight: 700, fontSize: 16 }}>π</div>
        <div style={{ display: 'flex', flexDirection: 'column', lineHeight: 1.1, minWidth: 0 }}>
          <div style={{ fontFamily: lang === 'ar' ? F_AR : F_EN, fontSize: 13, fontWeight: 600, color: t.ink }}>{L.app}</div>
          <div style={{ fontFamily: F_MONO, fontSize: 10, color: t.inkMuted }}>pi.local</div>
        </div>
      </div>

      <div style={{ display: 'flex', flexDirection: 'column', gap: 2, marginTop: 4 }}>
        {group('nav_platform')}
        {navItem('overview', 'overview')}
        {navItem('projects', 'projects')}
        {navItem('monitoring', 'monitor')}
        {group('nav_business')}
        {navItem('growth', 'growth')}
        {group('nav_system')}
        {navItem('settings', 'settings')}
      </div>

      <div style={{ flex: 1 }} />

      <div style={{ marginTop: 10, padding: '10px 11px', background: t.panelAlt, border: `1px solid ${t.border}`, borderRadius: 9, display: 'flex', flexDirection: 'column', gap: 8 }}>
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
          <Pill kind={cpu == null ? 'muted' : 'ok'} t={t}>{cpu == null ? '—' : L.pill_up}</Pill>
          <span style={{ fontFamily: F_MONO, fontSize: 11, color: t.inkSoft }}>{fmt(cpu, 1)}°C</span>
        </div>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
          <Row label={L.cpu} value={cpu == null ? '—' : `${Math.round((cpu / 80) * 100)}%`} t={t} lang={lang}>
            <Bar value={cpu || 0} max={80} kind="ok" t={t} animateDelay={100} />
          </Row>
          <Row label={L.ram} value={ram ? `${(ram.usedMB / 1024).toFixed(1)} / ${(ram.totalMB / 1024).toFixed(0)} GB` : '—'} t={t} lang={lang}>
            <Bar value={ram?.usedMB || 0} max={ram?.totalMB || 100} kind="warn" t={t} animateDelay={200} />
          </Row>
          <Row label={L.disk} value={disk ? `${disk.usedGB} / ${disk.totalGB} GB` : '—'} t={t} lang={lang}>
            <Bar value={disk?.usedGB || 0} max={disk?.totalGB || 100} kind="ok" t={t} animateDelay={300} />
          </Row>
        </div>
      </div>

      <div style={{ marginTop: 8, padding: '6px 4px 0', display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
        <span style={{ fontFamily: F_MONO, fontSize: 10, color: t.inkMuted }}>raspi-5 · 8GB</span>
      </div>
    </aside>
  );
}
