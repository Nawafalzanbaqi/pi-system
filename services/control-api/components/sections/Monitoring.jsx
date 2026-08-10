'use client';
// Monitoring.jsx — LIVE (control-panel part #4). Time-series + verdict come from
// the host health monitor's own status file + log via GET /api/monitoring; the
// per-service panel shows a current docker-stats snapshot; alerts come from
// GET /api/monitoring/alerts; the backup widget from GET /api/backup-status. All
// read-only (the audited bot-exec bridge -> scripts/panel-read.sh). The current
// CPU/RAM/disk point is overlaid from the live /api/system-health value.
//
// HONEST about granularity: the time-series is the health monitor's log (one row
// per scheduled run, ~15 min apart), so the range selector slices the last N rows
// of REAL history rather than inventing sub-minute points. Per-container memory is
// a CURRENT snapshot (no per-service history is persisted) — shown as usage bars.
import { useMemo, useState } from 'react';
import { F_AR, F_EN, F_MONO } from '../theme.js';
import { Panel, Pill, Dot, Bar } from '../primitives.jsx';
import { AreaChart } from '../charts.jsx';
import { SkeletonMonitoring, EmptyState, ErrorState } from '../states.jsx';
import { usePolledResource, POLL_MS } from '../use-api.js';
import { adaptSystemHealth, adaptMonitoring, adaptMonitoringAlerts, adaptBackup } from '../../lib/adapt.js';
import { THRESHOLDS, SERVICE_RAM_CAP } from '../catalog.js';

// How many trailing history rows each range shows (rows are ~15 min apart).
const RANGE_ROWS = { '1h': 4, '5h': 20, '24h': 96, '7d': 672 };

export default function Monitoring({ t, L, lang, client }) {
  const [range, setRange] = useState('5h');
  const mon = usePolledResource(() => client.getMonitoring(), { intervalMs: POLL_MS * 4 });
  const health = usePolledResource(() => client.getSystemHealth(), { intervalMs: POLL_MS });
  const hp = useMemo(() => adaptSystemHealth(health.data), [health.data]);
  const m = useMemo(() => adaptMonitoring(mon.data), [mon.data]);

  const ramTotal = hp.ram?.totalMB || 8192;
  const diskTotal = hp.disk?.totalGB || 232;

  const pts = useMemo(() => {
    const n = RANGE_ROWS[range] || 20;
    return m.points.slice(-n);
  }, [m.points, range]);

  // Real history -> the three series (RAM/disk %-of-total -> absolute, so the
  // existing MB/GB charts keep working); overlay the live current as last point.
  const cpu = withLast(pts.map((p) => p.cpuTempC ?? 0), hp.cpuTempC);
  const ram = withLast(pts.map((p) => (p.ramPct == null ? 0 : Math.round((p.ramPct / 100) * ramTotal))), hp.ram?.usedMB);
  const disk = withLast(pts.map((p) => (p.diskPct == null ? 0 : Math.round((p.diskPct / 100) * diskTotal))), hp.disk?.usedGB);

  const cpuKind = (v) => (v >= THRESHOLDS.cpuTempC.fail ? 'bad' : v >= THRESHOLDS.cpuTempC.warn ? 'warn' : 'ok');
  const ramKind = (v) => { const p = (v / ramTotal) * 100; return p >= THRESHOLDS.ramPct.fail ? 'bad' : p >= THRESHOLDS.ramPct.warn ? 'warn' : 'ok'; };
  const diskKind = (v) => { const p = (v / diskTotal) * 100; return p >= THRESHOLDS.diskPct.fail ? 'bad' : p >= THRESHOLDS.diskPct.warn ? 'warn' : 'ok'; };

  if (mon.state === 'loading' && !mon.data) return <SkeletonMonitoring t={t} />;
  if (mon.state === 'error') return (
    <div style={{ padding: 4 }}>
      <ErrorState t={t} lang={lang} title={lang === 'ar' ? 'تعذّر جلب بيانات الرصد' : "Couldn't load monitoring"} body={lang === 'ar' ? 'تأكّد أنّ المنصّة تعمل ومراقب الصحة قد عمل مرّة على الأقل.' : 'Make sure the platform is up and the health monitor has run at least once.'} retryLabel={lang === 'ar' ? 'أعد المحاولة' : 'Retry'} onRetry={() => mon.refresh()} detail={mon.error} />
    </div>
  );

  const verdictKind = m.verdict === 'fail' ? 'bad' : m.verdict === 'warn' ? 'warn' : m.verdict === 'pass' ? 'ok' : 'muted';
  const verdictLabel = m.verdict === 'pass' ? L.verdict_pass : m.verdict === 'warn' ? L.verdict_warn : m.verdict === 'fail' ? L.verdict_fail : (lang === 'ar' ? 'غير معروف' : 'Unknown');

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 12, flexWrap: 'wrap' }}>
        <div style={{ display: 'inline-flex', alignItems: 'center', gap: 8 }}>
          <Pill kind={verdictKind} t={t}><span style={{ fontFamily: lang === 'ar' ? F_AR : F_EN }}>{L.host_verdict}: {verdictLabel}</span></Pill>
          <span style={{ fontFamily: F_MONO, fontSize: 11, color: t.inkMuted }}>{pts.length} {lang === 'ar' ? 'نقطة' : 'pts'}</span>
        </div>
        <RangeSelector value={range} onChange={setRange} t={t} L={L} lang={lang} />
      </div>

      {pts.length === 0 ? (
        <EmptyState t={t} lang={lang} icon="box" title={lang === 'ar' ? 'لا يوجد سجل بعد' : 'No history yet'} body={lang === 'ar' ? 'سيظهر الرسم البياني بعد أوّل تشغيل لمراقب الصحة (scripts/health-monitor.sh --status-dir).' : 'Charts appear after the health monitor runs (scripts/health-monitor.sh --status-dir).'} />
      ) : (
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 12 }}>
          <Panel t={t} lang={lang} title={L.chart_cpu}>
            <AreaChart data={cpu} t={t} lang={lang} label={L.chart_cpu} unit={L.chart_cpu_unit} thresholds={{ warn: THRESHOLDS.cpuTempC.warn, fail: THRESHOLDS.cpuTempC.fail }} kindOf={cpuKind} niceMin={30} niceMax={85} />
          </Panel>
          <Panel t={t} lang={lang} title={L.chart_ram}>
            <AreaChart data={ram} t={t} lang={lang} label={L.chart_ram} unit={L.chart_ram_unit} thresholds={{ warn: ramTotal * (THRESHOLDS.ramPct.warn / 100), fail: ramTotal * (THRESHOLDS.ramPct.fail / 100) }} kindOf={ramKind} niceMin={0} niceMax={ramTotal} />
          </Panel>
          <Panel t={t} lang={lang} title={L.chart_disk}>
            <AreaChart data={disk} t={t} lang={lang} label={L.chart_disk} unit={L.chart_disk_unit} thresholds={{ warn: diskTotal * (THRESHOLDS.diskPct.warn / 100), fail: diskTotal * (THRESHOLDS.diskPct.fail / 100) }} kindOf={diskKind} niceMin={0} niceMax={diskTotal} />
          </Panel>
        </div>
      )}

      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1.3fr', gap: 12 }}>
        <Panel t={t} lang={lang} title={L.chart_services} subtitle={L.chart_services_sub}>
          {m.perService.length === 0 ? (
            <div style={{ padding: '16px 4px', fontSize: 12, color: t.inkSoft, fontFamily: lang === 'ar' ? F_AR : F_EN }}>{lang === 'ar' ? 'لا توجد حاويات قيد التشغيل أو Docker غير متاح.' : 'No running containers, or Docker is unavailable.'}</div>
          ) : (
            <div style={{ display: 'flex', flexDirection: 'column' }}>
              {m.perService.map((s, i, arr) => (
                <div key={s.name} style={{ borderBottom: i < arr.length - 1 ? `1px solid ${t.borderSoft}` : 'none' }}>
                  <ServiceMemRow s={s} t={t} lang={lang} />
                </div>
              ))}
            </div>
          )}
        </Panel>
        <AlertsPanel t={t} L={L} lang={lang} client={client} />
      </div>

      <BackupWidget t={t} L={L} lang={lang} client={client} />
    </div>
  );
}

function withLast(arr, live) {
  if (live == null || Number.isNaN(live) || arr.length === 0) return arr;
  const copy = arr.slice();
  copy[copy.length - 1] = Number(live);
  return copy;
}

// Current memory vs the container's own limit (a snapshot — no series persisted).
function ServiceMemRow({ s, t, lang }) {
  const cap = s.limitMiB || SERVICE_RAM_CAP[shortName(s.name)] || 256;
  const pct = s.pct || (cap ? (s.memMiB / cap) * 100 : 0);
  const kind = pct >= THRESHOLDS.servicePct.fail ? 'bad' : pct >= THRESHOLDS.servicePct.warn ? 'warn' : 'ok';
  return (
    <div style={{ display: 'grid', gridTemplateColumns: '150px 1fr 92px', alignItems: 'center', gap: 12, padding: '8px 4px' }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 8, minWidth: 0 }}>
        <Dot kind={kind} t={t} size={6} /><span style={{ fontFamily: F_MONO, fontSize: 12, color: t.ink, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{shortName(s.name)}</span>
      </div>
      <Bar value={s.memMiB} max={cap} kind={kind} t={t} />
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'flex-end', gap: 6, fontFamily: F_MONO, fontSize: 11 }}>
        <span style={{ color: t.ink }}>{Math.round(s.memMiB)}</span><span style={{ color: t.inkMuted }}>/ {Math.round(cap)}MB</span>
      </div>
    </div>
  );
}
const shortName = (n) => String(n || '').replace(/^pi-system[_-]/, '');

function AlertsPanel({ t, L, lang, client }) {
  const [filter, setFilter] = useState('all');
  const alerts = usePolledResource(() => client.getMonitoringAlerts(), { intervalMs: POLL_MS * 4 });
  const list = useMemo(() => adaptMonitoringAlerts(alerts.data), [alerts.data]);
  const filtered = list.filter((a) => (filter === 'all' ? true : a.severity === filter));
  const counts = { all: list.length, info: list.filter((a) => a.severity === 'info').length, warn: list.filter((a) => a.severity === 'warn').length, critical: list.filter((a) => a.severity === 'critical').length };
  const sevColor = (s) => (s === 'critical' ? t.bad : s === 'warn' ? t.warn : t.inkSoft);
  const sevBg = (s) => (s === 'critical' ? t.badSoft : s === 'warn' ? t.warnSoft : t.panelAlt);
  return (
    <Panel t={t} lang={lang} title={L.alerts} subtitle={L.alerts_sub}
      action={(
        <div style={{ display: 'inline-flex', background: t.bg, border: `1px solid ${t.border}`, borderRadius: 7, padding: 2 }}>
          {['all', 'info', 'warn', 'critical'].map((k) => (
            <button key={k} onClick={() => setFilter(k)} style={{ padding: '3px 9px', borderRadius: 5, border: 'none', cursor: 'pointer', background: filter === k ? t.panelAlt : 'transparent', color: filter === k ? t.ink : t.inkSoft, fontFamily: lang === 'ar' ? F_AR : F_EN, fontSize: 11, fontWeight: filter === k ? 600 : 500, display: 'inline-flex', alignItems: 'center', gap: 5 }}>
              {k !== 'all' ? <span style={{ width: 5, height: 5, borderRadius: '50%', background: sevColor(k) }} /> : null}{L[`filter_${k}`]}<span style={{ fontFamily: F_MONO, fontSize: 10, color: t.inkMuted }}>{counts[k]}</span>
            </button>
          ))}
        </div>
      )}>
      <div style={{ display: 'flex', flexDirection: 'column', maxHeight: 380, overflow: 'auto' }}>
        {filtered.length === 0 ? (
          <div style={{ padding: '18px 4px', fontSize: 12, color: t.inkSoft, fontFamily: lang === 'ar' ? F_AR : F_EN, textAlign: 'center' }}>{lang === 'ar' ? 'لا تنبيهات — كل شيء سليم.' : 'No alerts — all clear.'}</div>
        ) : filtered.map((a, i) => (
          <div key={i} style={{ display: 'grid', gridTemplateColumns: '92px 86px 1fr auto', alignItems: 'center', gap: 12, padding: '10px 4px', borderBottom: i < filtered.length - 1 ? `1px solid ${t.borderSoft}` : 'none' }}>
            <span style={{ fontFamily: F_MONO, fontSize: 11, color: t.inkMuted }}>{a.ts}</span>
            <span style={{ display: 'inline-flex', alignItems: 'center', gap: 4, padding: '1px 7px', borderRadius: 999, fontSize: 10, fontWeight: 600, background: sevBg(a.severity), color: sevColor(a.severity), border: `1px solid ${sevColor(a.severity)}22`, fontFamily: lang === 'ar' ? F_AR : F_EN }}>
              <span style={{ width: 5, height: 5, borderRadius: '50%', background: sevColor(a.severity) }} />{a.severity === 'critical' ? L.filter_critical : a.severity === 'warn' ? L.filter_warn : L.filter_info}
            </span>
            <span style={{ fontFamily: F_MONO, fontSize: 12, color: t.ink, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{a.message}</span>
            <span style={{ fontFamily: F_MONO, fontSize: 10, color: t.inkSoft, background: t.panelAlt, border: `1px solid ${t.border}`, padding: '1px 6px', borderRadius: 5 }}>{a.source}</span>
          </div>
        ))}
      </div>
    </Panel>
  );
}

function BackupWidget({ t, L, lang, client }) {
  const res = usePolledResource(() => client.getBackupStatus(), { intervalMs: POLL_MS * 12 });
  const b = useMemo(() => adaptBackup(res.data), [res.data]);
  const fmtDate = (iso) => { try { return new Date(iso).toISOString().slice(0, 16).replace('T', ' '); } catch { return iso || '—'; } };
  const tile = (label, value, sub, kind) => {
    const color = kind === 'bad' ? t.bad : kind === 'muted' ? t.inkSoft : t.ok;
    return (
      <div style={{ padding: '12px 14px', background: t.panelAlt, border: `1px solid ${t.border}`, borderRadius: 9, display: 'flex', flexDirection: 'column', gap: 6 }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}><span style={{ width: 5, height: 5, borderRadius: '50%', background: color }} /><span style={{ fontSize: 11, color: t.inkSoft, fontFamily: lang === 'ar' ? F_AR : F_EN }}>{label}</span></div>
        <span style={{ fontFamily: F_MONO, fontSize: 20, fontWeight: 600, color: t.ink, letterSpacing: '-.02em' }}>{value}</span>
        <span style={{ fontFamily: F_MONO, fontSize: 10, color: t.inkMuted }}>{sub}</span>
      </div>
    );
  };
  return (
    <Panel t={t} lang={lang} title={L.backup}>
      {!b.configured ? (
        <div style={{ padding: '14px 4px', fontSize: 12, color: t.inkSoft, fontFamily: lang === 'ar' ? F_AR : F_EN }}>{lang === 'ar' ? 'لا توجد نسخ احتياطية بعد — شغّل services/backup أوّل مرّة.' : 'No backups yet — run the backup service once.'}</div>
      ) : (
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 10 }}>
          {tile(L.backup_last, b.last?.ageHours != null ? L.h_ago(b.last.ageHours) : '—', b.last ? `${fmtDate(b.last.finishedAt)} · ${b.last.result}` : '—', b.last?.result === 'ok' ? 'ok' : 'bad')}
          {tile(L.backup_drill, b.drill ? (b.drill.result === 'ok' ? L.backup_pass : L.backup_fail) : '—', b.drill ? `${fmtDate(b.drill.finishedAt)}` : (lang === 'ar' ? 'لم تُجرَ بعد' : 'not run yet'), b.drill ? (b.drill.result === 'ok' ? 'ok' : 'bad') : 'muted')}
          {tile(lang === 'ar' ? 'قواعد البيانات' : 'Databases', b.last ? `${b.last.succeeded ?? 0}/${b.last.attempted ?? 0}` : '—', lang === 'ar' ? 'نجحت/حاولت' : 'ok / attempted', (b.last && b.last.failed) ? 'bad' : 'muted')}
        </div>
      )}
    </Panel>
  );
}

function RangeSelector({ value, onChange, t, L, lang }) {
  return (
    <div style={{ display: 'inline-flex', background: t.panel, border: `1px solid ${t.border}`, borderRadius: 7, padding: 2 }}>
      {['1h', '5h', '24h', '7d'].map((k) => (
        <button key={k} onClick={() => onChange(k)} style={{ padding: '4px 10px', borderRadius: 5, border: 'none', cursor: 'pointer', background: value === k ? t.panelAlt : 'transparent', color: value === k ? t.ink : t.inkSoft, fontFamily: F_MONO, fontSize: 11, fontWeight: value === k ? 600 : 500, letterSpacing: '.04em' }}>{L[`range_${k}`]}</button>
      ))}
    </div>
  );
}
