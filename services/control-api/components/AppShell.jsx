'use client';
// AppShell.jsx — the authenticated panel root. Owns language (AR/EN), theme
// (light/dark) and the active section; keeps <html lang/dir/data-theme> + cookies
// in sync (so the next server render matches, no flash). Renders the Sidebar +
// per-section TopBar + the active section, and hosts the single ConfirmDialog
// (useConfirm) that every destructive action flows through. MotionConfig honours
// the OS reduced-motion setting globally.
import { useEffect, useMemo, useRef, useState } from 'react';
import { MotionConfig } from 'framer-motion';
import { useTokens } from './theme.js';
import { tFor } from './strings.js';
import { useConfirm } from './states.jsx';
import { usePolledResource, POLL_MS } from './use-api.js';
import { createClient } from '../lib/api-client.js';
import { adaptSystemHealth } from '../lib/adapt.js';
import Sidebar from './Sidebar.jsx';
import TopBar from './TopBar.jsx';
import { btnPrimary, Icon } from './primitives.jsx';
import Overview from './sections/Overview.jsx';
import Projects from './sections/Projects.jsx';
import Monitoring from './sections/Monitoring.jsx';
import Growth from './sections/Growth.jsx';
import Settings from './sections/Settings.jsx';

const SECTION_TABLE = { overview: null, projects: 'projects', monitoring: 'monitoring', growth: 'growth', settings: 'settings' };

function setCookie(name, value) {
  try { document.cookie = `${name}=${value}; path=/; max-age=31536000; samesite=lax`; } catch { /* SSR */ }
}

export default function AppShell({ initialLang = 'ar', initialTheme = 'light', user, isOperator = false }) {
  const [lang, setLangState] = useState(initialLang);
  const [theme, setThemeState] = useState(initialTheme);
  const [section, setSection] = useState('overview');
  const t = useTokens(theme);
  const dir = lang === 'ar' ? 'rtl' : 'ltr';
  const confirm = useConfirm();
  const client = useMemo(() => createClient(), []);
  const newProjectRef = useRef(() => {});

  useEffect(() => {
    const el = document.documentElement;
    el.lang = lang; el.dir = dir; el.dataset.theme = theme;
  }, [lang, dir, theme]);

  const setLang = (v) => { setLangState(v); setCookie('pi_lang', v); };
  const setTheme = (v) => { setThemeState(v); setCookie('pi_theme', v); };

  // Live host vitals for the sidebar footer (shared across sections).
  const health = usePolledResource(() => client.getSystemHealth(), { intervalMs: POLL_MS });
  const hp = useMemo(() => adaptSystemHealth(health.data), [health.data]);

  const baseL = tFor(null, lang);
  const L = tFor(SECTION_TABLE[section], lang);

  const topbar = {
    overview: { title: baseL.overview, subtitle: baseL.overview_sub, live: true },
    projects: { title: L.page_title, subtitle: L.page_sub, actions: isOperator ? <button style={{ ...btnPrimary(t, lang), display: 'inline-flex', alignItems: 'center', gap: 6 }} onClick={() => newProjectRef.current?.()}><Icon name="plus" size={13} stroke={t.bg} strokeWidth={2} />{L.new_project}</button> : null },
    monitoring: { title: L.page_title, subtitle: L.page_sub },
    growth: { title: L.page_title, subtitle: L.page_sub },
    settings: { title: L.page_title, subtitle: L.page_sub },
  }[section];

  const onLogout = () => { window.location.href = '/api/auth/logout'; };

  const sectionEl = (() => {
    const common = { t, L, lang, client, confirm, isOperator };
    switch (section) {
      case 'projects': return <Projects {...common} onNewProjectRef={newProjectRef} />;
      case 'monitoring': return <Monitoring {...common} />;
      case 'growth': return <Growth {...common} />;
      case 'settings': return <Settings {...common} />;
      default: return <Overview {...common} />;
    }
  })();

  const ownsLayout = section === 'projects' || section === 'growth' || section === 'settings';

  return (
    <MotionConfig reducedMotion="user">
      <div dir={dir} style={{ height: '100vh', background: t.bg, color: t.ink, display: 'flex', overflow: 'hidden', fontFamily: lang === 'ar' ? "var(--font-ar)" : "var(--font-en)" }}>
        <Sidebar t={t} L={baseL} lang={lang} dir={dir} current={section} onNavigate={setSection} health={hp} user={user} isOperator={isOperator} onLogout={onLogout} />
        <main style={{ flex: 1, minWidth: 0, display: 'flex', flexDirection: 'column', overflow: 'hidden', position: 'relative' }}>
          <TopBar t={t} lang={lang} setLang={setLang} theme={theme} setTheme={setTheme} title={topbar.title} subtitle={topbar.subtitle} actions={topbar.actions} live={topbar.live} user={user} isOperator={isOperator} onLogout={onLogout} />
          <div style={{ flex: 1, minHeight: 0, position: 'relative', overflow: 'hidden' }}>
            {ownsLayout ? sectionEl : (
              <div style={{ height: '100%', overflow: 'auto', padding: '20px 28px 28px' }}>{sectionEl}</div>
            )}
          </div>
          {confirm.dialog}
        </main>
      </div>
    </MotionConfig>
  );
}
