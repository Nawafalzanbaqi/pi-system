'use client';
// Growth.jsx — LIVE (control-panel part #4). Prospects (read/organize only),
// Site quality (SEO), and privacy-first Analytics are wired to read-only API
// endpoints; the bilingual Message drafts stay STATIC, copy-paste only (never
// auto-sent — the legal/ethical boundary). Prospects are READ-ONLY in the panel:
// no scraping, no outreach send, no editing here (adding/updating a prospect
// would be a separate operator-only, audited write — a possible later part).
import { useMemo, useState } from 'react';
import { motion, AnimatePresence } from 'framer-motion';
import { F_AR, F_EN, F_MONO } from '../theme.js';
import { Panel, Pill, Dot, IconButton, Icon, Bar } from '../primitives.jsx';
import { Sparkline, BarChart7d } from '../charts.jsx';
import { SkeletonProspects, EmptyState, ErrorState } from '../states.jsx';
import { usePolledResource, POLL_MS } from '../use-api.js';
import { adaptProspects, adaptSeo, adaptAnalytics } from '../../lib/adapt.js';
import { PROSPECT_STATUSES, SAMPLE_TEMPLATES, scoreKind, impactKind } from '../catalog.js';

export default function Growth({ t, L, lang, client }) {
  const [tab, setTab] = useState('prospects');
  const [open, setOpen] = useState(null);
  const prospects = usePolledResource(() => client.getGrowthProspects(), { intervalMs: POLL_MS * 6 });
  const seo = usePolledResource(() => client.getGrowthSeo(), { intervalMs: POLL_MS * 6 });
  const pj = useMemo(() => adaptProspects(prospects.data), [prospects.data]);
  const sj = useMemo(() => adaptSeo(seo.data), [seo.data]);

  const tabs = [
    { k: 'prospects', label: L.tab_prospects, badge: pj.prospects.length },
    { k: 'seo', label: L.tab_seo, badge: sj.sites.length },
    { k: 'analytics', label: L.tab_analytics, badge: null },
    { k: 'templates', label: L.tab_templates, badge: SAMPLE_TEMPLATES.length },
  ];
  return (
    <div style={{ position: 'relative', height: '100%', display: 'flex', flexDirection: 'column', overflow: 'hidden' }}>
      <div style={{ display: 'flex', gap: 0, borderBottom: `1px solid ${t.border}`, alignItems: 'center', justifyContent: 'space-between', padding: '0 28px' }}>
        <div style={{ display: 'flex' }}>
          {tabs.map((tb) => {
            const active = tb.k === tab;
            return (
              <button key={tb.k} onClick={() => setTab(tb.k)} style={{ padding: '10px 16px', background: 'transparent', border: 'none', borderBottom: `2px solid ${active ? t.ink : 'transparent'}`, color: active ? t.ink : t.inkSoft, fontFamily: lang === 'ar' ? F_AR : F_EN, fontSize: 13, fontWeight: active ? 600 : 500, cursor: 'pointer', marginBottom: -1, display: 'inline-flex', alignItems: 'center', gap: 6 }}>
                {tb.label}{tb.badge != null ? <span style={{ fontFamily: F_MONO, fontSize: 10, color: t.inkMuted, background: t.panelAlt, padding: '1px 6px', borderRadius: 5 }}>{tb.badge}</span> : null}
              </button>
            );
          })}
        </div>
      </div>
      <div style={{ flex: 1, minHeight: 0, overflow: 'auto', padding: '18px 28px 28px' }}>
        {tab === 'prospects' ? <ProspectsBoard t={t} L={L} lang={lang} res={prospects} pj={pj} onOpen={setOpen} /> : null}
        {tab === 'seo' ? <SeoView t={t} L={L} lang={lang} res={seo} sj={sj} /> : null}
        {tab === 'analytics' ? <AnalyticsView t={t} L={L} lang={lang} client={client} /> : null}
        {tab === 'templates' ? <TemplatesView t={t} L={L} lang={lang} /> : null}
      </div>
      <AnimatePresence>{open ? <ProspectReport key="r" p={open} onClose={() => setOpen(null)} t={t} L={L} lang={lang} /> : null}</AnimatePresence>
    </div>
  );
}

const ScoreRing = ({ value, label, size = 86, t, lang }) => {
  const k = scoreKind(value); const color = k === 'warn' ? t.warn : k === 'bad' ? t.bad : t.ok;
  const r = size / 2 - 6; const c = 2 * Math.PI * r; const dash = (value / 100) * c;
  return (
    <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 5 }}>
      <div style={{ position: 'relative', width: size, height: size }}>
        <svg width={size} height={size} viewBox={`0 0 ${size} ${size}`} style={{ transform: 'rotate(-90deg)' }}>
          <circle cx={size / 2} cy={size / 2} r={r} fill="none" stroke={`${t.inkMuted}33`} strokeWidth="5" />
          <circle cx={size / 2} cy={size / 2} r={r} fill="none" stroke={color} strokeWidth="5" strokeLinecap="round" strokeDasharray={`${dash} ${c - dash}`} />
        </svg>
        <div style={{ position: 'absolute', inset: 0, display: 'flex', alignItems: 'center', justifyContent: 'center', fontFamily: F_MONO, fontSize: size > 80 ? 22 : 18, fontWeight: 600, color: t.ink, letterSpacing: '-.02em' }}>{value}</div>
      </div>
      <span style={{ fontSize: 11, color: t.inkSoft, fontFamily: lang === 'ar' ? F_AR : F_EN }}>{label}</span>
    </div>
  );
};

function ProspectsBoard({ t, L, lang, res, pj, onOpen }) {
  if (res.state === 'loading' && !res.data) return <SkeletonProspects t={t} />;
  if (res.state === 'error') return (
    <ErrorState t={t} lang={lang} title={lang === 'ar' ? 'تعذّر جلب العملاء المحتملين' : "Couldn't load prospects"} body={lang === 'ar' ? 'تأكّد أنّ المنصّة تعمل ثمّ أعد المحاولة.' : 'Make sure the platform is running, then retry.'} retryLabel={lang === 'ar' ? 'أعد المحاولة' : 'Retry'} onRetry={() => res.refresh()} detail={res.error} />
  );
  if (pj.prospects.length === 0) return (
    <EmptyState t={t} lang={lang} icon="inbox" title={lang === 'ar' ? 'لا يوجد عملاء محتملون بعد' : 'No prospects yet'} body={lang === 'ar' ? 'تُضاف وتُدار من الطرفية: scripts/prospects.sh (تنظيم وتواصل يدوي فقط).' : 'Add & manage them from the CLI: scripts/prospects.sh (organize + manual contact only).'} />
  );
  return (
    <div style={{ display: 'grid', gridTemplateColumns: 'repeat(5, 1fr)', gap: 10 }}>
      {PROSPECT_STATUSES.map((st) => {
        const items = pj.prospects.filter((p) => p.status === st.id);
        return (
          <div key={st.id} style={{ display: 'flex', flexDirection: 'column', gap: 8, background: t.panelAlt, border: `1px solid ${t.border}`, borderRadius: 10, padding: 10, minHeight: 400 }}>
            <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '2px 4px' }}>
              <div style={{ display: 'flex', alignItems: 'center', gap: 7 }}><Dot kind={st.kind} t={t} size={6} /><span style={{ fontFamily: lang === 'ar' ? F_AR : F_EN, fontSize: 12, fontWeight: 600, color: t.ink }}>{lang === 'ar' ? st.ar : st.en}</span></div>
              <span style={{ fontFamily: F_MONO, fontSize: 10, color: t.inkMuted }}>{items.length}</span>
            </div>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
              {items.map((p) => <ProspectCard key={p.id} p={p} t={t} lang={lang} L={L} onClick={() => onOpen(p)} />)}
            </div>
          </div>
        );
      })}
    </div>
  );
}

function ProspectCard({ p, t, lang, L, onClick }) {
  const a = p.analysis;
  const overall = a ? Math.round((a.performance + a.seo + a.accessibility) / 3) : null;
  return (
    <button onClick={onClick} style={{ display: 'flex', flexDirection: 'column', gap: 6, padding: '10px 11px', background: t.panel, border: `1px solid ${t.border}`, borderRadius: 8, cursor: 'pointer', textAlign: lang === 'ar' ? 'right' : 'left', transition: 'border-color 120ms, transform 120ms' }}
      onMouseEnter={(e) => { e.currentTarget.style.borderColor = t.inkMuted; e.currentTarget.style.transform = 'translateY(-1px)'; }}
      onMouseLeave={(e) => { e.currentTarget.style.borderColor = t.border; e.currentTarget.style.transform = 'none'; }}>
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
        <span style={{ fontFamily: lang === 'ar' ? F_AR : F_EN, fontSize: 13, fontWeight: 600, color: t.ink, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap', minWidth: 0 }}>{p.name}</span>
        {overall != null ? <Dot kind={scoreKind(overall)} t={t} size={6} /> : null}
      </div>
      {p.url ? <span style={{ fontFamily: F_MONO, fontSize: 11, color: t.inkMuted, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{p.url.replace(/^https?:\/\//, '')}</span> : null}
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
        <span style={{ fontFamily: lang === 'ar' ? F_AR : F_EN, fontSize: 10, color: t.inkSoft }}>{overall != null ? `${overall}/100` : (lang === 'ar' ? 'بلا تحليل' : 'no analysis')}</span>
        <span style={{ fontFamily: F_MONO, fontSize: 10, color: p.followup ? t.warn : t.inkMuted }}>{p.followup ? `📅 ${p.followup}` : L.no_follow_up}</span>
      </div>
    </button>
  );
}

function ProspectReport({ p, onClose, t, L, lang }) {
  const a = p.analysis;
  const overall = a ? Math.round((a.performance + a.seo + a.accessibility) / 3) : null;
  const counts = a && a.counts ? a.counts : null;
  const countRow = (label, n, color) => (
    <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
      <span style={{ width: 6, height: 6, borderRadius: '50%', background: color }} />
      <span style={{ flex: 1, fontSize: 12, color: t.ink, fontFamily: lang === 'ar' ? F_AR : F_EN }}>{label}</span>
      <span style={{ fontFamily: F_MONO, fontSize: 12, color: t.inkSoft }}>{n ?? 0}</span>
    </div>
  );
  return (
    <motion.div initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }}
      style={{ position: 'absolute', inset: 0, background: 'rgba(0,0,0,0.45)', zIndex: 60, display: 'flex', alignItems: 'stretch', justifyContent: 'flex-end', backdropFilter: 'blur(2px)' }}
      onClick={(e) => { if (e.target === e.currentTarget) onClose(); }}>
      <motion.aside initial={{ x: 20, opacity: 0 }} animate={{ x: 0, opacity: 1 }} exit={{ x: 20, opacity: 0 }} transition={{ duration: 0.22, ease: [0.2, 0.7, 0.3, 1] }}
        style={{ width: 'min(640px, 100%)', height: '100%', background: t.panel, borderInlineStart: `1px solid ${t.border}`, boxShadow: '-12px 0 40px rgba(0,0,0,0.18)', display: 'flex', flexDirection: 'column', overflow: 'hidden' }}>
        <header style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '14px 20px', borderBottom: `1px solid ${t.border}` }}>
          <div style={{ display: 'flex', flexDirection: 'column', gap: 2 }}>
            <span style={{ fontSize: 10, color: t.inkMuted, fontFamily: F_MONO, letterSpacing: '.06em', textTransform: 'uppercase' }}>{L.site_score}</span>
            <h2 style={{ margin: 0, fontSize: 18, fontWeight: 600, color: t.ink, fontFamily: lang === 'ar' ? F_AR : F_EN, letterSpacing: '-.01em' }}>{p.name}</h2>
            <span style={{ fontFamily: F_MONO, fontSize: 11, color: t.inkSoft }}>{p.url || (lang === 'ar' ? 'بدون رابط' : 'no URL')}</span>
          </div>
          <IconButton t={t} onClick={onClose}><Icon name="x" size={12} stroke={t.inkSoft} /></IconButton>
        </header>
        <div style={{ flex: 1, overflow: 'auto', padding: '20px 22px 28px', display: 'flex', flexDirection: 'column', gap: 16 }}>
          {!a ? (
            <EmptyState t={t} lang={lang} icon="sparkle" title={lang === 'ar' ? 'لا يوجد تحليل بعد' : 'No analysis yet'} body={lang === 'ar' ? 'شغّل تحليلًا من الطرفية: scripts/prospects.sh analyze <id> (يدقّق الموقع العام للعميل مرّة واحدة).' : 'Run one from the CLI: scripts/prospects.sh analyze <id> (audits the prospect’s public site once).'} />
          ) : (
            <>
              <div style={{ background: t.panelAlt, border: `1px solid ${t.border}`, borderRadius: 12, padding: '16px', display: 'flex', alignItems: 'center', gap: 24, flexWrap: 'wrap' }}>
                <div style={{ display: 'flex', flexDirection: 'column', gap: 3, flex: 1, minWidth: 180 }}>
                  <Pill kind={scoreKind(overall)} t={t}><span style={{ fontFamily: F_MONO, letterSpacing: '.06em' }}>{overall} / 100</span></Pill>
                  <h3 style={{ margin: '6px 0 0', fontSize: 15, fontWeight: 600, color: t.ink, fontFamily: lang === 'ar' ? F_AR : F_EN }}>{lang === 'ar' ? 'تقرير الجودة الإجمالي' : 'Overall quality report'}</h3>
                  {a.summary ? <p style={{ margin: '2px 0 0', fontSize: 11, color: t.inkSoft, fontFamily: lang === 'ar' ? F_AR : F_EN }}>{a.summary}</p> : null}
                  {a.ts ? <span style={{ marginTop: 4, fontFamily: F_MONO, fontSize: 10, color: t.inkMuted }}>{String(a.ts).slice(0, 10)}</span> : null}
                </div>
                <div style={{ display: 'flex', gap: 14, paddingInlineStart: 16, borderInlineStart: `1px solid ${t.border}` }}>
                  <ScoreRing value={a.performance} label={L.score_perf} t={t} lang={lang} />
                  <ScoreRing value={a.seo} label={L.score_seo} t={t} lang={lang} />
                  <ScoreRing value={a.accessibility} label={L.score_a11y} t={t} lang={lang} />
                </div>
              </div>
              <Panel t={t} lang={lang} title={L.recs_title} subtitle={lang === 'ar' ? 'عدد النتائج حسب الأولوية' : 'Findings by priority'}>
                {counts ? (
                  <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
                    {countRow(lang === 'ar' ? 'حرجة' : 'Critical', counts.critical, t.bad)}
                    {countRow(L.impact_high, counts.high, t.bad)}
                    {countRow(L.impact_med, counts.medium, t.warn)}
                    {countRow(L.impact_low, counts.low, t.inkSoft)}
                    <p style={{ margin: '4px 0 0', fontSize: 11, color: t.inkMuted, fontFamily: lang === 'ar' ? F_AR : F_EN }}>{lang === 'ar' ? 'التقرير الكامل محفوظ على الجهاز (data/prospects/reports).' : 'The full report is saved on the host (data/prospects/reports).'}</p>
                  </div>
                ) : (
                  <div style={{ padding: '10px 2px', fontSize: 12, color: t.inkSoft, fontFamily: lang === 'ar' ? F_AR : F_EN }}>{lang === 'ar' ? 'لا تفاصيل إضافية.' : 'No further detail.'}</div>
                )}
              </Panel>
            </>
          )}
        </div>
      </motion.aside>
    </motion.div>
  );
}

function SeoView({ t, L, lang, res, sj }) {
  if (res.state === 'loading' && !res.data) return <SkeletonProspects t={t} />;
  if (res.state === 'error') return (
    <ErrorState t={t} lang={lang} title={lang === 'ar' ? 'تعذّر جلب تقارير الجودة' : "Couldn't load site audits"} body={lang === 'ar' ? 'تأكّد أنّ المنصّة تعمل ثمّ أعد المحاولة.' : 'Make sure the platform is running, then retry.'} retryLabel={lang === 'ar' ? 'أعد المحاولة' : 'Retry'} onRetry={() => res.refresh()} detail={res.error} />
  );
  if (sj.sites.length === 0) return (
    <EmptyState t={t} lang={lang} icon="sparkle" title={lang === 'ar' ? 'لا توجد عمليات تدقيق بعد' : 'No audits yet'} body={lang === 'ar' ? 'شغّل: scripts/seo.sh audit <name> لإضافة أوّل نتيجة.' : 'Run scripts/seo.sh audit <name> to record the first result.'} />
  );
  return (
    <div style={{ display: 'grid', gridTemplateColumns: 'repeat(2, 1fr)', gap: 12 }}>
      {sj.sites.map((a) => {
        const overall = Math.round((a.latest.performance + a.latest.seo + a.latest.accessibility) / 3);
        return (
          <Panel key={a.site} t={t} lang={lang} title={a.site} subtitle={L.seo_recent} action={<Pill kind={scoreKind(overall)} t={t}><span style={{ fontFamily: F_MONO }}>{overall}</span></Pill>}>
            <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 12 }}>
              <SeoMini label={L.score_perf} data={a.perf} t={t} lang={lang} />
              <SeoMini label={L.score_seo} data={a.seo} t={t} lang={lang} />
              <SeoMini label={L.score_a11y} data={a.a11y} t={t} lang={lang} />
            </div>
            <div style={{ marginTop: 12, paddingTop: 10, borderTop: `1px solid ${t.borderSoft}` }}>
              <div style={{ fontSize: 11, color: t.inkMuted, fontFamily: lang === 'ar' ? F_AR : F_EN, marginBottom: 6, letterSpacing: '.04em', textTransform: 'uppercase' }}>{L.seo_recs}</div>
              {a.recs.length === 0 ? <div style={{ fontSize: 12, color: t.inkSoft, fontFamily: lang === 'ar' ? F_AR : F_EN }}>{lang === 'ar' ? 'لا توصيات — أداء جيد.' : 'No recommendations — performing well.'}</div> : (
                <ul style={{ listStyle: 'none', padding: 0, margin: 0, display: 'flex', flexDirection: 'column', gap: 5 }}>
                  {a.recs.map((r, i) => { const k = impactKind(r.impact); const color = k === 'warn' ? t.warn : k === 'bad' ? t.bad : t.inkSoft; return (
                    <li key={i} style={{ display: 'flex', alignItems: 'center', gap: 8 }}><span style={{ width: 5, height: 5, borderRadius: '50%', background: color }} /><span style={{ flex: 1, fontSize: 12, color: t.ink, fontFamily: lang === 'ar' ? F_AR : F_EN }}>{lang === 'ar' ? r.ar : r.en}</span><span style={{ fontSize: 10, color, fontFamily: lang === 'ar' ? F_AR : F_EN }}>{r.impact === 'high' ? L.impact_high : r.impact === 'med' ? L.impact_med : L.impact_low}</span></li>
                  ); })}
                </ul>
              )}
            </div>
          </Panel>
        );
      })}
    </div>
  );
}
const SeoMini = ({ label, data, t, lang }) => {
  const v = data.at(-1) ?? 0; const k = scoreKind(v);
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 5 }}>
      <div style={{ display: 'flex', alignItems: 'baseline', justifyContent: 'space-between' }}><span style={{ fontSize: 11, color: t.inkSoft, fontFamily: lang === 'ar' ? F_AR : F_EN }}>{label}</span><span style={{ fontFamily: F_MONO, fontSize: 14, fontWeight: 600, color: t.ink }}>{v}</span></div>
      <Sparkline data={data.length > 1 ? data : [v, v]} t={t} kind={k} height={26} />
    </div>
  );
};

function AnalyticsView({ t, L, lang, client }) {
  const res = usePolledResource(() => client.getGrowthAnalytics(), { intervalMs: POLL_MS * 12 });
  const a = useMemo(() => adaptAnalytics(res.data), [res.data]);

  if (res.state === 'loading' && !res.data) return <SkeletonProspects t={t} />;
  if (res.state === 'error') return (
    <ErrorState t={t} lang={lang} title={lang === 'ar' ? 'تعذّر جلب الإحصاءات' : "Couldn't load analytics"} retryLabel={lang === 'ar' ? 'أعد المحاولة' : 'Retry'} onRetry={() => res.refresh()} detail={res.error} />
  );
  if (!a.configured) return (
    <EmptyState t={t} lang={lang} icon="plug" title={lang === 'ar' ? 'الإحصاءات غير مهيّأة' : 'Analytics not configured'} body={lang === 'ar' ? 'لربط Umami: شغّل خدمة analytics وعيّن CONTROL_API_ANALYTICS_UMAMI_URL/USERNAME/PASSWORD/WEBSITE_ID في .env. تبقى الاعتمادات على الخادم ولا تصل المتصفّح.' : 'To wire Umami: run the analytics service and set CONTROL_API_ANALYTICS_UMAMI_URL/USERNAME/PASSWORD/WEBSITE_ID in .env. Credentials stay server-side, never sent to the browser.'} />
  );
  if (a.ok === false) return (
    <ErrorState t={t} lang={lang} title={lang === 'ar' ? 'تعذّر الوصول إلى Umami' : "Couldn't reach Umami"} body={lang === 'ar' ? 'الإحصاءات مهيّأة لكن الخدمة لا تستجيب.' : 'Analytics is configured but the service did not respond.'} retryLabel={lang === 'ar' ? 'أعد المحاولة' : 'Retry'} onRetry={() => res.refresh()} detail={a.error} />
  );

  const delta = a.totalVisitorsPrev7d > 0 ? Math.round(((a.totalVisitors7d - a.totalVisitorsPrev7d) / a.totalVisitorsPrev7d) * 100) : 0;
  const maxRef = Math.max(1, ...a.topReferrers.map((r) => r.views));
  const maxPage = Math.max(1, ...a.topPages.map((p) => p.views));
  const maxGeo = Math.max(1, ...a.countries.map((c) => c.views));
  const loc = lang === 'ar' ? 'ar-EG' : 'en-US';
  const BarRow = ({ label, value, max }) => (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 3 }}>
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 8 }}>{label}<span style={{ fontFamily: F_MONO, fontSize: 11, color: t.inkSoft }}>{value.toLocaleString(loc)}</span></div>
      <Bar value={(value / max) * 100} max={100} kind="ok" t={t} />
    </div>
  );
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
      <div style={{ display: 'grid', gridTemplateColumns: '1.4fr 1fr 1fr', gap: 12 }}>
        <Panel t={t} lang={lang} title={L.analytics_visitors} subtitle={L.analytics_window}>
          <div style={{ display: 'flex', alignItems: 'baseline', gap: 10, marginBottom: 8 }}>
            <span style={{ fontFamily: F_MONO, fontSize: 30, fontWeight: 600, color: t.ink, letterSpacing: '-.02em' }}>{a.totalVisitors7d.toLocaleString(loc)}</span>
            <Pill kind={delta >= 0 ? 'ok' : 'bad'} t={t}><span style={{ fontFamily: F_MONO }}>{L.analytics_delta(delta)}</span></Pill>
          </div>
          {a.visitorsSeries.length ? <BarChart7d data={a.visitorsSeries} t={t} lang={lang} /> : <div style={{ fontSize: 12, color: t.inkSoft, fontFamily: lang === 'ar' ? F_AR : F_EN }}>{lang === 'ar' ? 'لا سلسلة بعد.' : 'No series yet.'}</div>}
        </Panel>
        <Panel t={t} lang={lang} title={L.analytics_top}>
          <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>{a.topPages.length ? a.topPages.map((p) => <BarRow key={p.path} label={<span style={{ fontFamily: F_MONO, fontSize: 11, color: t.ink }}>{p.path}</span>} value={p.views} max={maxPage} />) : <span style={{ fontSize: 12, color: t.inkSoft }}>—</span>}</div>
        </Panel>
        <Panel t={t} lang={lang} title={L.analytics_refs}>
          <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>{a.topReferrers.length ? a.topReferrers.map((r) => <BarRow key={r.src} label={<span style={{ fontFamily: lang === 'ar' ? F_AR : F_EN, fontSize: 11, color: t.ink }}>{r.src}</span>} value={r.views} max={maxRef} />) : <span style={{ fontSize: 12, color: t.inkSoft }}>—</span>}</div>
        </Panel>
      </div>
      <Panel t={t} lang={lang} title={L.analytics_geo} subtitle={lang === 'ar' ? 'مجاميع الزيارات حسب الدولة (بدون كوكيز)' : 'Visits by country (privacy-first, no cookies)'}>
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(5, 1fr)', gap: 10 }}>
          {a.countries.map((c, i) => (
            <div key={c.code} style={{ padding: '12px 14px', background: t.panelAlt, border: `1px solid ${t.border}`, borderRadius: 9, display: 'flex', flexDirection: 'column', gap: 6 }}>
              <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}><span style={{ fontFamily: F_MONO, fontSize: 10, color: t.inkMuted, letterSpacing: '.06em' }}>{c.code}</span><span style={{ fontFamily: F_MONO, fontSize: 14, fontWeight: 600, color: t.ink }}>{c.views.toLocaleString(loc)}</span></div>
              <Bar value={c.views} max={maxGeo} kind="ok" t={t} animateDelay={i * 60} />
            </div>
          ))}
        </div>
      </Panel>
    </div>
  );
}

function TemplatesView({ t, L, lang }) {
  const [selectedId, setSelectedId] = useState(SAMPLE_TEMPLATES[0].id);
  const tpl = SAMPLE_TEMPLATES.find((x) => x.id === selectedId);
  const [copied, setCopied] = useState(null);
  const copyBody = (which) => { try { navigator.clipboard.writeText(which === 'ar' ? tpl.ar_body : tpl.en_body); } catch { /* clipboard unavailable */ } setCopied(which); setTimeout(() => setCopied(null), 1400); };
  const Block = ({ dir, label, body, which }) => (
    <div style={{ background: t.panelAlt, border: `1px solid ${t.border}`, borderRadius: 9, overflow: 'hidden' }}>
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '8px 12px', borderBottom: `1px solid ${t.border}`, background: t.bg }}>
        <span style={{ fontFamily: F_MONO, fontSize: 11, color: t.inkSoft, letterSpacing: '.06em' }}>{label}</span>
        <button onClick={() => copyBody(which)} style={{ padding: '3px 10px', borderRadius: 6, background: copied === which ? t.ok : t.panelAlt, border: `1px solid ${copied === which ? t.ok : t.border}`, color: copied === which ? '#fff' : t.ink, cursor: 'pointer', fontFamily: lang === 'ar' ? F_AR : F_EN, fontSize: 11, fontWeight: 500, transition: 'background 150ms' }}>{copied === which ? L.copied : L.copy}</button>
      </div>
      <pre dir={dir} style={{ margin: 0, padding: '12px 14px', whiteSpace: 'pre-wrap', fontFamily: dir === 'rtl' ? F_AR : F_EN, fontSize: 12, lineHeight: 1.55, color: t.ink, textAlign: dir === 'rtl' ? 'right' : 'left', maxHeight: 240, overflow: 'auto' }}>{body}</pre>
    </div>
  );
  return (
    <div style={{ display: 'grid', gridTemplateColumns: '260px 1fr', gap: 12 }}>
      <div style={{ background: t.panel, border: `1px solid ${t.border}`, borderRadius: 11, padding: 8, display: 'flex', flexDirection: 'column', gap: 2 }}>
        {SAMPLE_TEMPLATES.map((tp) => {
          const active = tp.id === selectedId;
          return (
            <button key={tp.id} onClick={() => setSelectedId(tp.id)} style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '9px 10px', borderRadius: 7, background: active ? t.panelAlt : 'transparent', border: `1px solid ${active ? t.border : 'transparent'}`, color: active ? t.ink : t.inkSoft, cursor: 'pointer', fontFamily: lang === 'ar' ? F_AR : F_EN, fontSize: 13, fontWeight: active ? 600 : 500, textAlign: lang === 'ar' ? 'right' : 'left' }}>
              <span>{lang === 'ar' ? tp.ar_title : tp.en_title}</span><span style={{ fontFamily: F_MONO, fontSize: 9, color: t.inkMuted, background: t.bg, border: `1px solid ${t.border}`, padding: '1px 5px', borderRadius: 5 }}>AR/EN</span>
            </button>
          );
        })}
      </div>
      <div style={{ background: t.panel, border: `1px solid ${t.border}`, borderRadius: 11, padding: '14px 16px' }}>
        <div style={{ display: 'flex', alignItems: 'baseline', justifyContent: 'space-between', marginBottom: 10 }}>
          <h3 style={{ margin: 0, fontSize: 15, fontWeight: 600, color: t.ink, fontFamily: lang === 'ar' ? F_AR : F_EN }}>{lang === 'ar' ? tpl.ar_title : tpl.en_title}</h3>
          <span style={{ fontSize: 11, color: t.inkSoft, fontFamily: lang === 'ar' ? F_AR : F_EN }}>{L.templates_sub}</span>
        </div>
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(2, 1fr)', gap: 10 }}>
          <Block dir="rtl" label="AR" body={tpl.ar_body} which="ar" />
          <Block dir="ltr" label="EN" body={tpl.en_body} which="en" />
        </div>
      </div>
    </div>
  );
}
