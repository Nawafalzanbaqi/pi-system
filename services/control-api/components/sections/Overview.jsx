'use client';
// Overview.jsx — the live status dashboard. WIRED: /api/status + /api/system-health
// (polled every POLL_MS) and /api/projects. Actions: restart an unhealthy platform
// service, and start/stop the core stack — all through the destructive ConfirmDialog
// → POST /api/actions/* → pending → success → refresh. The audit strip has no
// endpoint yet, so it is badged "sample · live source pending".
import { useMemo } from 'react';
import { F_AR, F_EN, F_MONO, stateToKind } from '../theme.js';
import { Pill, Dot, Gauge, KpiCard, Panel, btnGhost } from '../primitives.jsx';
import { Sparkline } from '../charts.jsx';
import { SkeletonOverview, EmptyState, ErrorState } from '../states.jsx';
import { usePolledResource, POLL_MS } from '../use-api.js';
import { adaptStatus, adaptSystemHealth, adaptProjects } from '../../lib/adapt.js';
import { VALID_RESTART_SERVICES } from '../../lib/bridge-core.js';

const SAMPLE_AUDIT = [
  { ts: '17:42', identity: 'omar', action: 'deploy noor-store @ v0.14.2', result: 'ok' },
  { ts: '17:31', identity: 'cron', action: 'nightly backup → minio', result: 'ok' },
  { ts: '17:08', identity: 'omar', action: 'restart analytics', result: 'fail' },
  { ts: '16:55', identity: 'auto', action: 'tls renew · *.pi.local', result: 'ok' },
  { ts: '16:12', identity: 'omar', action: 'new project · naseem-bakery', result: 'ok' },
];

export default function Overview({ t, L, lang, client, confirm, isOperator }) {
  const status = usePolledResource(() => client.getStatus(), { intervalMs: POLL_MS });
  const health = usePolledResource(() => client.getSystemHealth(), { intervalMs: POLL_MS });
  const projects = usePolledResource(() => client.getProjects(), { intervalMs: POLL_MS * 4 });

  const st = useMemo(() => adaptStatus(status.data), [status.data]);
  const hp = useMemo(() => adaptSystemHealth(health.data), [health.data]);
  const pj = useMemo(() => adaptProjects(projects.data), [projects.data]);

  const loading = status.state === 'loading' && !status.data;
  const errored = status.state === 'error';

  const refreshAll = () => { status.refresh(); health.refresh(); projects.refresh(); };

  const runAction = (action, body, conf) => confirm.ask({
    ...conf,
    onConfirm: async () => {
      const res = await client.runAction(action, body);
      if (!res.ok) throw new Error(res.error || 'action failed');
      setTimeout(refreshAll, 400);
    },
  });
  const restart = (service, conf) => confirm.ask({
    ...conf,
    onConfirm: async () => {
      const res = await client.restartService(service);
      if (!res.ok) throw new Error(res.error || 'restart failed');
      setTimeout(refreshAll, 400);
    },
  });

  if (loading) return <SkeletonOverview t={t} />;
  if (errored) {
    return (
      <ErrorState t={t} lang={lang}
        title={status.unauthorized ? (lang === 'ar' ? 'انتهت الجلسة' : 'Session expired') : (lang === 'ar' ? 'تعذّر الاتصال بالمنصة' : "Couldn't reach the platform")}
        body={status.unauthorized ? (lang === 'ar' ? 'سجّل الدخول من جديد للمتابعة.' : 'Sign in again to continue.') : (lang === 'ar' ? 'لم نتمكن من قراءة حالة المنصة. تأكّد أنها تعمل ثم أعد المحاولة.' : "We couldn't read the platform status. Make sure it's running, then retry.")}
        retryLabel={lang === 'ar' ? 'أعد المحاولة' : 'Retry'} onRetry={refreshAll} detail={status.error} />
    );
  }

  const services = st.services;
  const running = services.filter((s) => stateToKind(s.state) === 'ok').length;
  const unhealthy = services.filter((s) => stateToKind(s.state) === 'warn' || stateToKind(s.state) === 'bad');
  const overall = st.overall;
  const overallKind = overall === 'up' ? 'ok' : overall === 'degraded' ? 'warn' : overall === 'down' ? 'bad' : 'muted';
  const liveProjects = pj.projects.filter((p) => p.state === 'up').length;

  // Pick a restartable unhealthy service to surface in the hero (allowlisted only).
  const restartTarget = unhealthy.map((s) => s.name).find((n) => VALID_RESTART_SERVICES.includes(n));

  if (status.state === 'empty' || (services.length === 0 && !st.raw)) {
    return (
      <EmptyState t={t} lang={lang} icon="sparkle"
        title={lang === 'ar' ? 'المنصة جاهزة — أضف أوّل مشروع' : 'Platform is ready — add your first project'}
        body={lang === 'ar' ? 'كل الخدمات تعمل، لكن لم تُنشِئ أي مشروع بعد.' : 'All services are running, but no projects yet.'} />
    );
  }

  const ram = hp.ram, disk = hp.disk;

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
      {/* Status hero */}
      <section style={{ background: t.panel, border: `1px solid ${t.border}`, borderRadius: 14, padding: '18px 22px', display: 'flex', alignItems: 'center', gap: 24, flexWrap: 'wrap' }}>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 8, flex: 1, minWidth: 240 }}>
          <Pill kind={overallKind} t={t}><span style={{ fontFamily: F_MONO, letterSpacing: '.06em' }}>{L[`pill_${overall}`] || overall.toUpperCase()}</span></Pill>
          <h2 style={{ margin: 0, fontSize: 24, fontWeight: 600, color: t.ink, fontFamily: lang === 'ar' ? F_AR : F_EN, letterSpacing: '-.01em', lineHeight: 1.2 }}>
            {L[`status_${overall}`] || L.status_up}
          </h2>
          <p style={{ margin: 0, fontSize: 13, color: t.inkSoft, fontFamily: lang === 'ar' ? F_AR : F_EN, lineHeight: 1.4 }}>
            {lang === 'ar' ? `${running} من ${services.length} خدمة تعمل · ${unhealthy.length} بحاجة لمتابعة.` : `${running} of ${services.length} services healthy · ${unhealthy.length} need attention.`}
          </p>
          <div style={{ display: 'flex', gap: 8, marginTop: 4, flexWrap: 'wrap' }}>
            <button onClick={refreshAll} style={btnGhost(t, lang)}>{lang === 'ar' ? 'فحص الصحة' : 'Run health check'}</button>
            {isOperator && restartTarget ? (
              <button style={btnGhost(t, lang)} onClick={() => restart(restartTarget, {
                title: lang === 'ar' ? `إعادة تشغيل ${restartTarget}؟` : `Restart ${restartTarget}?`,
                target: restartTarget, impact: [restartTarget], destructive: false,
                confirmLabel: lang === 'ar' ? 'أعد التشغيل' : 'Restart',
                message: lang === 'ar' ? 'ستتوقّف الخدمة ثوانٍ ثم تعود.' : 'The service restarts in a few seconds.',
              })}>{lang === 'ar' ? `إعادة تشغيل ${restartTarget}` : `Restart ${restartTarget}`}</button>
            ) : null}
            {isOperator ? (
              <>
                <button style={btnGhost(t, lang)} onClick={() => runAction('up', { profile: 'core' }, {
                  title: lang === 'ar' ? 'تشغيل النواة؟' : 'Start the core stack?', target: 'profile: core', destructive: false,
                  confirmLabel: lang === 'ar' ? 'تشغيل' : 'Start', message: lang === 'ar' ? 'سيتم تشغيل خدمات النواة.' : 'Brings up the core services.',
                })}>{lang === 'ar' ? 'تشغيل النواة' : 'Start core'}</button>
                <button style={btnGhost(t, lang)} onClick={() => runAction('down', { profile: 'core' }, {
                  title: lang === 'ar' ? 'إيقاف النواة؟' : 'Stop the core stack?', target: 'profile: core', destructive: true,
                  confirmLabel: lang === 'ar' ? 'إيقاف' : 'Stop', impact: services.slice(0, 6).map((s) => s.name),
                  message: lang === 'ar' ? 'ستتوقّف خدمات النواة (البيانات تبقى).' : 'Stops the core services (data is kept).',
                })}>{lang === 'ar' ? 'إيقاف النواة' : 'Stop core'}</button>
              </>
            ) : null}
          </div>
        </div>
        <div style={{ display: 'flex', gap: 24, paddingInlineStart: 24, borderInlineStart: `1px solid ${t.border}`, paddingBlock: 4, flexWrap: 'wrap' }}>
          <Gauge value={hp.cpuTempC || 0} max={80} kind={(hp.cpuTempC || 0) >= 75 ? 'bad' : (hp.cpuTempC || 0) >= 60 ? 'warn' : 'ok'} t={t} label={L.cpu} unit="°" suffix={hp.cpuThrottled ? 'throttled' : '/80°C'} />
          <Gauge value={ram ? Math.round((ram.usedMB / ram.totalMB) * 100) : 0} max={100} kind={ram && (ram.usedMB / ram.totalMB) >= 0.9 ? 'bad' : ram && (ram.usedMB / ram.totalMB) >= 0.75 ? 'warn' : 'ok'} t={t} label={L.ram} unit="%" suffix={ram ? `${(ram.usedMB / 1024).toFixed(1)} / ${(ram.totalMB / 1024).toFixed(0)} GB` : '—'} />
          <Gauge value={disk ? Math.round((disk.usedGB / disk.totalGB) * 100) : 0} max={100} kind={disk && (disk.usedGB / disk.totalGB) >= 0.92 ? 'bad' : disk && (disk.usedGB / disk.totalGB) >= 0.8 ? 'warn' : 'ok'} t={t} label={L.disk} unit="%" suffix={disk ? `${disk.usedGB} / ${disk.totalGB} GB` : '—'} />
        </div>
      </section>

      {/* KPI row */}
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 12 }}>
        <KpiCard t={t} lang={lang} title={L.services_running} value={String(running)} unit={`/ ${services.length}`} sub={lang === 'ar' ? 'الآن' : 'now'} kind={unhealthy.length ? 'warn' : 'ok'} delta={unhealthy.length ? (lang === 'ar' ? `${unhealthy.length} بحاجة لمتابعة` : `${unhealthy.length} need attention`) : (lang === 'ar' ? 'سليم' : 'all healthy')} />
        <KpiCard t={t} lang={lang} title={L.projects_live} value={String(liveProjects)} unit={`/ ${pj.projects.length}`} sub="30d" kind="ok" spark={<Sparkline data={[5, 5, 6, 6, 6, 7, 7, liveProjects || 7]} t={t} kind="ok" />} />
        <KpiCard t={t} lang={lang} title={L.host_verdict} value={hp.verdict === 'pass' ? (lang === 'ar' ? L.verdict_pass : 'Pass') : hp.verdict === 'warn' ? (lang === 'ar' ? L.verdict_warn : 'Warn') : hp.verdict === 'fail' ? (lang === 'ar' ? L.verdict_fail : 'Fail') : '—'} sub="raspi-5" kind={hp.verdict === 'fail' ? 'bad' : hp.verdict === 'warn' ? 'warn' : 'ok'} />
        <KpiCard t={t} lang={lang} title={L.cpu} value={hp.cpuTempC != null ? hp.cpuTempC.toFixed(1) : '—'} unit="°C" sub="raspi-5" kind={(hp.cpuTempC || 0) >= 60 ? 'warn' : 'ok'} spark={<Sparkline data={[48, 49, 51, 50, 52, 51, hp.cpuTempC || 52]} t={t} kind="ok" />} />
      </div>

      {/* Services + Activity */}
      <div style={{ display: 'grid', gridTemplateColumns: '1.5fr 1fr', gap: 14 }}>
        <Panel t={t} lang={lang} title={L.services} subtitle={`${services.length} · ${L.services_sub}`}>
          {services.length ? (
            <div style={{ display: 'grid', gridTemplateColumns: 'repeat(5, 1fr)', gap: 8 }}>
              {services.map((svc) => (
                <div key={svc.name} title={svc.name} style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '9px 11px', background: t.panel, border: `1px solid ${t.border}`, borderRadius: 8 }}>
                  <Dot kind={stateToKind(svc.state)} t={t} />
                  <div style={{ display: 'flex', flexDirection: 'column', minWidth: 0, flex: 1 }}>
                    <span style={{ fontFamily: F_MONO, fontSize: 12, fontWeight: 500, color: t.ink, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{svc.name}</span>
                    <span style={{ fontFamily: lang === 'ar' ? F_AR : F_EN, fontSize: 10, color: t.inkMuted }}>{L.states[svc.state] || svc.state}</span>
                  </div>
                </div>
              ))}
            </div>
          ) : (
            <RawOutput t={t} lang={lang} raw={st.raw} />
          )}
        </Panel>

        <Panel t={t} lang={lang} title={L.recent} subtitle={`${L.recent_sub} · ${L.sample}`}>
          <div style={{ display: 'flex', flexDirection: 'column' }}>
            {SAMPLE_AUDIT.map((a, i) => (
              <div key={i} style={{ display: 'flex', alignItems: 'center', gap: 12, padding: '9px 0', borderBottom: i < SAMPLE_AUDIT.length - 1 ? `1px solid ${t.borderSoft}` : 'none' }}>
                <span style={{ fontFamily: F_MONO, fontSize: 11, color: t.inkMuted, width: 42, flexShrink: 0 }}>{a.ts}</span>
                <Dot kind={a.result === 'ok' ? 'ok' : 'bad'} t={t} size={6} />
                <span style={{ fontFamily: F_MONO, fontSize: 11, color: t.inkSoft, minWidth: 44 }}>{a.identity}</span>
                <span style={{ fontFamily: F_MONO, fontSize: 12, color: t.ink, flex: 1, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{a.action}</span>
              </div>
            ))}
          </div>
        </Panel>
      </div>

      {/* Live projects strip */}
      <Panel t={t} lang={lang} title={L.projects_live_title} subtitle={lang === 'ar' ? `${pj.projects.length} مشاريع · ${liveProjects} منشورة` : `${pj.projects.length} projects · ${liveProjects} live`}>
        {pj.projects.length ? (
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 8 }}>
            {pj.projects.slice(0, 4).map((p) => (
              <div key={p.name} style={{ display: 'flex', flexDirection: 'column', gap: 8, padding: '10px 12px', background: t.panel, border: `1px solid ${t.border}`, borderRadius: 9 }}>
                <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
                  <span style={{ fontFamily: F_MONO, fontSize: 12, fontWeight: 600, color: t.ink, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{p.name}</span>
                  <Dot kind={stateToKind(p.state)} t={t} size={7} />
                </div>
                <span style={{ fontFamily: F_MONO, fontSize: 10, color: t.inkMuted }}>{p.subdomain}.pi.local</span>
              </div>
            ))}
          </div>
        ) : (
          <span style={{ fontFamily: lang === 'ar' ? F_AR : F_EN, fontSize: 12, color: t.inkSoft }}>{lang === 'ar' ? 'لا مشاريع بعد.' : 'No projects yet.'}</span>
        )}
      </Panel>
    </div>
  );
}

// When status parsing yields no structured services, show the host's raw text so
// nothing is hidden (honest fallback for the text-only endpoint).
function RawOutput({ t, lang, raw }) {
  return (
    <div>
      <div style={{ fontSize: 11, color: t.inkMuted, fontFamily: lang === 'ar' ? F_AR : F_EN, marginBottom: 6 }}>
        {lang === 'ar' ? 'مخرجات الجهاز (نصية):' : 'Host output (raw):'}
      </div>
      <pre dir="ltr" style={{ margin: 0, padding: '10px 12px', background: t.panelAlt, border: `1px solid ${t.border}`, borderRadius: 7, fontFamily: F_MONO, fontSize: 11, color: t.inkSoft, overflow: 'auto', maxHeight: 220, whiteSpace: 'pre-wrap' }}>{raw || (lang === 'ar' ? 'لا مخرجات' : 'no output')}</pre>
    </div>
  );
}
