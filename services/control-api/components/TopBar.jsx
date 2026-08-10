'use client';
// TopBar.jsx — the per-section header (title + subtitle on the start side; tools
// on the end side). Tools always include the AR/EN Segmented and the light/dark
// toggle (the bilingual + theming primitives baked into the layout). Sections
// pass `extra` (e.g. filter tabs / range selector) and `actions` (e.g. New
// project), plus an optional live/refresh affordance.
import { F_AR, F_EN, F_MONO } from './theme.js';
import { Segmented, IconButton, ThemeGlyph, Icon, Dot } from './primitives.jsx';

export default function TopBar({ t, lang, setLang, theme, setTheme, title, subtitle, extra, actions, onRefresh, live, user, isOperator, onLogout }) {
  return (
    <header style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '14px 28px', borderBottom: `1px solid ${t.border}`, background: t.bg, gap: 12 }}>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 2, minWidth: 0 }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
          <h1 style={{ margin: 0, fontSize: 20, fontWeight: 600, letterSpacing: '-.01em', color: t.ink, fontFamily: lang === 'ar' ? F_AR : F_EN, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{title}</h1>
          {live ? (
            <span style={{ display: 'inline-flex', alignItems: 'center', gap: 5, fontFamily: F_MONO, fontSize: 10, color: t.inkMuted }}>
              <Dot kind="ok" t={t} size={6} />{lang === 'ar' ? 'مباشر' : 'live'}
            </span>
          ) : null}
        </div>
        {subtitle ? <div style={{ fontSize: 12, color: t.inkSoft, fontFamily: lang === 'ar' ? F_AR : F_EN, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{subtitle}</div> : null}
      </div>

      <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexShrink: 0 }}>
        {user ? (
          <div title={isOperator ? 'operator' : 'viewer'} style={{ display: 'flex', alignItems: 'center', gap: 6, padding: '4px 8px', background: t.panel, border: `1px solid ${t.border}`, borderRadius: 7 }}>
            <span style={{ width: 6, height: 6, borderRadius: '50%', background: isOperator ? t.ok : t.inkMuted }} />
            <span style={{ fontFamily: F_MONO, fontSize: 11, color: t.inkSoft, maxWidth: 120, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{user.username || user.name || user.email || 'user'}</span>
            {onLogout ? <button onClick={onLogout} title={lang === 'ar' ? 'تسجيل الخروج' : 'Sign out'} aria-label="sign out" style={{ display: 'inline-flex', background: 'transparent', border: 'none', cursor: 'pointer', color: t.inkSoft, padding: 0 }}><Icon name="logout" size={13} stroke={t.inkSoft} /></button> : null}
          </div>
        ) : null}
        {extra}
        {onRefresh ? (
          <IconButton t={t} onClick={onRefresh} title={lang === 'ar' ? 'تحديث' : 'Refresh'} aria-label="refresh"><Icon name="refresh" size={13} stroke={t.inkSoft} /></IconButton>
        ) : null}
        <Segmented t={t} value={lang} onChange={setLang} options={[{ k: 'ar', label: 'AR' }, { k: 'en', label: 'EN' }]} />
        <IconButton t={t} onClick={() => setTheme(theme === 'light' ? 'dark' : 'light')} aria-label="theme"><ThemeGlyph theme={theme} t={t} /></IconButton>
        {actions}
      </div>
    </header>
  );
}
