// adapt.js — turn the control API's GET responses into the structured shapes the
// UI renders. PURE + tolerant by design.
// ===========================================================================
// HONEST NOTE on the status/system-health/projects/checks endpoints: Part #1
// returns the host tool's TEXT report inside `data.output` (e.g. `scripts/pi
// status` prints human lines; there is no JSON mode). The design's mock data is
// structured. These adapters bridge the gap WITHOUT touching any host script or
// the API's security:
//   * if the data is ALREADY structured ({overall,services} etc.) — used as-is
//     (future-proof: if these endpoints later emit JSON, the UI just works);
//   * otherwise the host text is parsed best-effort AND the raw text is always
//     kept so the screen can show it verbatim and never pretend more than it knows.
// Each adapter returns { ...structured, raw, structured: boolean }.

const STATE_WORDS = ['running', 'healthy', 'unhealthy', 'starting', 'restarting', 'exited', 'stopped', 'dead', 'created', 'paused', 'up', 'down'];
const stateNorm = (w) => {
  const s = String(w || '').toLowerCase();
  if (s === 'up') return 'running';
  if (s === 'exited' || s === 'dead') return 'stopped';
  return STATE_WORDS.includes(s) ? s : 'unknown';
};

// Unwrap the {action,exitCode,output} envelope to the inner text; pass structured through.
function unwrap(data) {
  if (data && typeof data === 'object' && 'output' in data && typeof data.output === 'string') {
    return { text: data.output, exitCode: data.exitCode };
  }
  return { obj: data };
}

const overallFromServices = (services) => {
  if (!services.length) return 'unknown';
  if (services.some((s) => ['stopped', 'dead', 'down'].includes(s.state))) return 'down';
  if (services.some((s) => ['unhealthy', 'restarting', 'starting'].includes(s.state))) return 'degraded';
  return 'up';
};

export function adaptStatus(data) {
  const u = unwrap(data);
  if (u.obj && (Array.isArray(u.obj.services) || u.obj.overall)) {
    const services = Array.isArray(u.obj.services) ? u.obj.services.map((s) => ({ name: String(s.name), state: stateNorm(s.state) })) : [];
    return { overall: u.obj.overall || overallFromServices(services), services, raw: null, structured: true };
  }
  // Parse text: lines like "caddy   running" / "✓ postgres  healthy" / "analytics: unhealthy".
  const services = [];
  for (const line of String(u.text || '').split('\n')) {
    const m = line.match(/([a-z][a-z0-9_-]{1,40})\s*[:=]?\s+\b(running|healthy|unhealthy|starting|restarting|exited|stopped|dead|created|paused|up|down)\b/i);
    if (m) services.push({ name: m[1].toLowerCase(), state: stateNorm(m[2]) });
  }
  return { overall: overallFromServices(services), services, raw: u.text || '', structured: false };
}

const num = (s) => { const n = parseFloat(String(s).replace(/[, ]/g, '')); return Number.isFinite(n) ? n : null; };

export function adaptSystemHealth(data) {
  const u = unwrap(data);
  if (u.obj && (u.obj.cpuTempC != null || u.obj.ram || u.obj.disk)) {
    return { ...u.obj, raw: null, structured: true };
  }
  const text = String(u.text || '');
  const temp = text.match(/(?:cpu[^0-9]{0,12}|temp[^0-9]{0,12})([0-9]{1,3}(?:\.[0-9])?)\s*°?\s*c/i);
  const ram = text.match(/(?:ram|mem(?:ory)?)[^0-9]{0,12}([0-9.]+)\s*(?:mb|mib)?\s*\/\s*([0-9.]+)\s*(mb|mib|gb|gib)/i);
  const disk = text.match(/disk[^0-9]{0,12}([0-9.]+)\s*\/\s*([0-9.]+)\s*(gb|gib|tb)/i);
  const verdict = (text.match(/\b(pass|warn|fail|ok|degraded)\b/i) || [])[1];
  const toMB = (v, unit) => (unit && /gb|gib/i.test(unit) ? num(v) * 1024 : num(v));
  return {
    cpuTempC: temp ? num(temp[1]) : null,
    cpuThrottled: /throttl/i.test(text),
    ram: ram ? { usedMB: toMB(ram[1], ram[3]), totalMB: toMB(ram[2], ram[3]) } : null,
    disk: disk ? { usedGB: num(disk[1]), totalGB: num(disk[2]) } : null,
    verdict: verdict ? verdict.toLowerCase().replace('ok', 'pass').replace('degraded', 'warn') : 'unknown',
    raw: text,
    structured: false,
  };
}

export function adaptProjects(data) {
  const u = unwrap(data);
  if (Array.isArray(u.obj)) {
    return { projects: u.obj.map(normalizeProject), raw: null, structured: true };
  }
  if (u.obj && Array.isArray(u.obj.projects)) {
    return { projects: u.obj.projects.map(normalizeProject), raw: null, structured: true };
  }
  // Parse text: each non-empty, non-heading line that starts with a valid project
  // name (and optionally a state word) becomes a project entry.
  const projects = [];
  for (const line of String(u.text || '').split('\n')) {
    const m = line.match(/^[\s•*\-]*([a-z][a-z0-9-]{1,38}[a-z0-9])\b(.*)$/);
    if (!m) continue;
    if (/^(usage|projects|name|generated|no\b|total)/i.test(m[1])) continue;
    const stateM = m[2].match(/\b(running|up|down|stopped|degraded|exited|healthy|unhealthy)\b/i);
    projects.push(normalizeProject({ name: m[1], state: stateM ? stateNorm(stateM[1]) : 'unknown', subdomain: m[1], modules: [], stages: [] }));
  }
  return { projects, raw: u.text || '', structured: false };
}

function normalizeProject(p) {
  const state = p.state === 'running' ? 'up' : stateNorm(p.state);
  return {
    name: String(p.name || ''),
    preset: p.preset || 'company-site',
    subdomain: p.subdomain || p.name || '',
    state: ['up', 'degraded', 'down'].includes(state) ? state : (state === 'running' ? 'up' : state === 'stopped' ? 'down' : 'unknown'),
    locale: p.locale || 'ar',
    modules: Array.isArray(p.modules) ? p.modules : [],
    stages: Array.isArray(p.stages) ? p.stages : [],
    deployedAt: p.deployedAt || null,
  };
}

export function adaptChecks(data) {
  const u = unwrap(data);
  if (u.obj && typeof u.obj === 'object' && !('output' in u.obj)) {
    return { ...u.obj, raw: null, structured: true };
  }
  const text = String(u.text || '');
  const verdict = /\bNOT READY\b/i.test(text) ? 'not-ready' : /\bREADY\b/i.test(text) ? 'ready' : 'unknown';
  return { verdict, raw: text, structured: false };
}

// ===========================================================================
// PART #4 — Monitoring + Growth live-data adapters.
// ---------------------------------------------------------------------------
// The read-only panel-data endpoints return the bot-exec envelope
// { action, exitCode, output } where `output` is the JSON scripts/panel-read.sh
// printed (which it built from the producers' OWN status/log/store files). These
// adapters are PURE: they JSON-parse that output and map it into the exact shapes
// the Monitoring/Growth views render. They tolerate missing/empty sources (the
// producer emits null/[]) by returning empty, never throwing.
// ===========================================================================

// Pull the panel-read JSON object out of whatever the endpoint handed us:
// the {output:"<json>"} envelope (today), an already-parsed object, or null.
function panelJson(data) {
  if (data == null) return null;
  if (typeof data === 'object' && 'output' in data) {
    const out = data.output;
    if (out && typeof out === 'object') return out;
    if (typeof out === 'string') { try { return JSON.parse(out); } catch { return null; } }
    return null;
  }
  if (typeof data === 'object') return data;
  if (typeof data === 'string') { try { return JSON.parse(data); } catch { return null; } }
  return null;
}

const toNum = (v) => { if (v == null || v === '' || v === '?') return null; const n = Number(v); return Number.isFinite(n) ? n : null; };

// One health.log line ->
//   "<ts>  <VERDICT>  temp=<n>°C root=<n>% mem=<n>% swap=<n>%"
const HEALTH_LINE = /^(\S+)\s+(PASS|WARN|FAIL|SKIP)\b.*?temp=([0-9.?]+)\D*root=([0-9.?]+)\D*mem=([0-9.?]+)\D*swap=([0-9.?]+)/i;
function parseHealthLine(line) {
  const m = String(line || '').match(HEALTH_LINE);
  if (!m) return null;
  return {
    ts: m[1],
    verdict: m[2].toUpperCase(),
    cpuTempC: toNum(m[3]),
    diskPct: toNum(m[4]),
    ramPct: toNum(m[5]),
    swapPct: toNum(m[6]),
  };
}

// GET /api/monitoring -> { points[], perService[], verdict, latest }
export function adaptMonitoring(data) {
  const j = panelJson(data);
  const points = Array.isArray(j?.history)
    ? j.history.map(parseHealthLine).filter(Boolean)
    : [];
  const perService = Array.isArray(j?.perService)
    ? j.perService.map((s) => ({
      name: String(s.name || ''),
      memMiB: toNum(s.memMiB) || 0,
      limitMiB: toNum(s.limitMiB) || 0,
      pct: toNum(s.pct) || 0,
      cpuPct: toNum(s.cpuPct) || 0,
    })).filter((s) => s.name)
    : [];
  const measured = j?.lastHealth?.measured || {};
  const latest = {
    cpuTempC: toNum(measured.cpu_temp_c),
    diskPct: toNum(measured.root_pct),
    ramPct: toNum(measured.mem_used_pct),
    swapPct: toNum(measured.swap_used_pct),
  };
  const verdict = (j?.lastHealth?.verdict
    || (points.length ? points[points.length - 1].verdict : '')
    || 'unknown').toString().toLowerCase();
  return { points, perService, verdict, latest, structured: !!j, raw: j ? null : (data?.output ?? null) };
}

const SEV_FROM_VERDICT = (v) => (v === 'FAIL' ? 'critical' : v === 'WARN' ? 'warn' : 'info');

// GET /api/monitoring/alerts -> [{ ts, severity, source, message }] newest-first.
export function adaptMonitoringAlerts(data) {
  const j = panelJson(data);
  const out = [];
  // The CURRENT alert detail (last-alert.txt) — the most recent, with detail lines.
  const alertLines = Array.isArray(j?.alert) ? j.alert : [];
  let headTs = ''; let headSev = 'warn';
  for (const line of alertLines) {
    const h = String(line).match(/health\s+(PASS|WARN|FAIL|SKIP)\s+@\s+(\S+)/i);
    if (h) { headSev = SEV_FROM_VERDICT(h[1].toUpperCase()); headTs = shortTs(h[2]); continue; }
    const detail = String(line).replace(/^\s*[-•]\s*/, '').trim();
    if (detail) out.push({ ts: headTs, severity: headSev, source: 'health', message: detail });
  }
  // Then the historical WARN/FAIL points from health.log (older), newest-first.
  const points = Array.isArray(j?.history) ? j.history.map(parseHealthLine).filter(Boolean) : [];
  for (let i = points.length - 1; i >= 0; i--) {
    const p = points[i];
    if (p.verdict !== 'WARN' && p.verdict !== 'FAIL') continue;
    out.push({
      ts: shortTs(p.ts),
      severity: SEV_FROM_VERDICT(p.verdict),
      source: 'health',
      message: `temp ${fmt(p.cpuTempC, '°C')} · disk ${fmt(p.diskPct, '%')} · RAM ${fmt(p.ramPct, '%')} · swap ${fmt(p.swapPct, '%')}`,
    });
  }
  return out.slice(0, 40);
}
const fmt = (v, unit) => (v == null ? '—' : `${v}${unit}`);
function shortTs(ts) {
  const s = String(ts || '');
  const m = s.match(/T(\d{2}:\d{2})/);
  if (m) { const d = s.match(/^(\d{4})-(\d{2})-(\d{2})/); return d ? `${d[2]}-${d[3]} ${m[1]}` : m[1]; }
  return s;
}

// GET /api/backup-status -> { configured, last, drill, next, size, destination, retention }
export function adaptBackup(data, now = Date.now()) {
  const j = panelJson(data);
  const lb = j?.lastBackup || null;
  const lv = j?.lastVerify || null;
  if (!lb && !lv) return { configured: false, raw: j ? null : (data?.output ?? null) };
  const ageHours = lb?.finished_at ? hoursSince(lb.finished_at, now) : null;
  return {
    configured: true,
    last: lb ? {
      finishedAt: lb.finished_at || null,
      ageHours,
      result: lb.result || 'unknown',
      succeeded: toNum(lb.succeeded),
      attempted: toNum(lb.attempted),
      failed: toNum(lb.failed),
    } : null,
    drill: lv ? {
      result: lv.result || 'unknown',
      passed: toNum(lv.passed),
      total: toNum(lv.total),
      finishedAt: lv.finished_at || null,
    } : null,
    // Not persisted by the producer (cron-scheduled / config-derived) -> honest nulls.
    next: null, size: null, destination: null, retention: null,
    structured: !!j,
  };
}
function hoursSince(iso, now) {
  const t = Date.parse(String(iso || '')); if (!Number.isFinite(t)) return null;
  return Math.max(0, Math.round((now - t) / 3600000));
}

// --- SEO recommendations: a compact, rule-based mapping of the audit `checks`
// into the impact-ranked list the Site-quality view renders. Deterministic, no AI
// (the canonical engine lives in services/seo; this is a faithful UI-side subset).
const IMPACT_RANK = { high: 0, med: 1, low: 2 };
function seoRecsFromChecks(checks) {
  if (!checks || typeof checks !== 'object') return [];
  const recs = [];
  const add = (cond, en, ar, impact) => { if (cond) recs.push({ en, ar, impact }); };
  add(checks.https === false, 'Serve the site over HTTPS', 'فعّل HTTPS للموقع', 'high');
  add(checks.title && checks.title.present === false, 'Add a page title', 'أضف عنوانًا للصفحة', 'high');
  add(checks.metaDescription && checks.metaDescription.present === false, 'Add a meta description', 'أضف وصف ميتا', 'med');
  add(checks.h1 && Number(checks.h1.count) === 0, 'Add a single H1 heading', 'أضف عنوان H1 واحدًا', 'med');
  add(checks.viewport === false, 'Add a responsive viewport tag', 'أضف وسم viewport متجاوب', 'med');
  add(Number(checks.imagesMissingAlt) > 0, `Add alt text to ${checks.imagesMissingAlt} image(s)`, `أضف نصًا بديلًا للصور (${checks.imagesMissingAlt})`, 'med');
  add(checks.canonical === false, 'Add a canonical URL', 'أضف رابط canonical', 'low');
  add(checks.structuredData === false, 'Add structured data (schema.org)', 'أضف بيانات منظّمة (schema.org)', 'low');
  const og = checks.openGraph || {};
  add(og.title === false || og.description === false || og.image === false, 'Complete the Open Graph tags', 'أكمل وسوم Open Graph', 'low');
  add(checks.robotsTxt === false, 'Add a robots.txt', 'أضف robots.txt', 'low');
  add(checks.sitemapXml === false, 'Add a sitemap.xml', 'أضف sitemap.xml', 'low');
  return recs.sort((a, b) => IMPACT_RANK[a.impact] - IMPACT_RANK[b.impact]).slice(0, 6);
}

// GET /api/growth/seo -> [{ site, perf[], seo[], a11y[], recs[], latest, history[] }]
export function adaptSeo(data) {
  const j = panelJson(data);
  const audits = Array.isArray(j?.audits) ? j.audits : [];
  const bySite = new Map();
  for (const a of audits) {
    if (!a || !a.name || !a.scores) continue;
    if (!bySite.has(a.name)) bySite.set(a.name, []);
    bySite.get(a.name).push(a);
  }
  const sites = [];
  for (const [site, list] of bySite) {
    list.sort((x, y) => String(x.timestamp).localeCompare(String(y.timestamp)));
    const perf = list.map((a) => toNum(a.scores.performance) ?? 0);
    const seo = list.map((a) => toNum(a.scores.seo) ?? 0);
    const a11y = list.map((a) => toNum(a.scores.accessibility) ?? 0);
    const latest = list[list.length - 1];
    sites.push({
      site,
      url: latest.url || '',
      perf, seo, a11y,
      latest: {
        performance: toNum(latest.scores.performance) ?? 0,
        seo: toNum(latest.scores.seo) ?? 0,
        accessibility: toNum(latest.scores.accessibility) ?? 0,
      },
      recs: seoRecsFromChecks(latest.checks),
      history: list.map((a) => ({ ts: a.timestamp, perf: toNum(a.scores.performance) ?? 0, seo: toNum(a.scores.seo) ?? 0, a11y: toNum(a.scores.accessibility) ?? 0 })),
    });
  }
  sites.sort((a, b) => a.site.localeCompare(b.site));
  return { sites, structured: !!j };
}

// GET /api/growth/prospects -> { prospects[] } (board groups by status itself).
export function adaptProspects(data) {
  const j = panelJson(data);
  const map = j && j.prospects && typeof j.prospects === 'object' ? j.prospects : null;
  const list = map ? Object.values(map) : [];
  const prospects = list.map((p) => {
    const la = p && p.lastAnalysis ? p.lastAnalysis : null;
    const scores = la && la.scores ? la.scores : null;
    return {
      id: String(p.id || ''),
      name: String(p.name || p.id || ''),
      url: p.url || null,
      status: String(p.status || 'new'),
      followup: p.followup || null,
      notes: Array.isArray(p.notes) ? p.notes.length : 0,
      updatedAt: p.updatedAt || null,
      analysis: scores ? {
        performance: toNum(scores.performance) ?? 0,
        seo: toNum(scores.seo) ?? 0,
        accessibility: toNum(scores.accessibility) ?? 0,
        summary: la.summary || null,
        counts: la.counts || null,
        ts: la.ts || null,
      } : null,
    };
  }).filter((p) => p.id);
  return { prospects, structured: !!j };
}

// GET /api/growth/analytics -> the privacy-first summary OR a not-configured marker.
// `data` is what the analytics route returned (lib/umami.js result), shaped:
//   { configured:false }                                  -> not set up
//   { configured:true, ok:false, error }                  -> set up but unreachable
//   { configured:true, ok:true, raw:{...umami aggregates} }-> map to the UI summary
export function adaptAnalytics(data) {
  const d = panelJson(data) || data || {};
  if (!d || d.configured === false) return { configured: false };
  if (d.ok === false) return { configured: true, ok: false, error: d.error || 'analytics unavailable' };
  const raw = d.raw || {};
  const series = Array.isArray(raw.series) ? raw.series.map((n) => toNum(n) ?? 0) : [];
  const mapPairs = (arr, key) => (Array.isArray(arr) ? arr.map((x) => ({ [key]: String(x.x ?? x.label ?? ''), views: toNum(x.y ?? x.views) ?? 0 })) : []);
  return {
    configured: true,
    ok: true,
    totalVisitors7d: toNum(raw.visitors) ?? 0,
    totalVisitorsPrev7d: toNum(raw.prevVisitors) ?? 0,
    visitorsSeries: series,
    topPages: mapPairs(raw.urls, 'path').map((p) => ({ path: p.path, views: p.views })),
    topReferrers: mapPairs(raw.referrers, 'src').map((r) => ({ src: r.src || 'direct', views: r.views })),
    countries: mapPairs(raw.countries, 'code').map((c) => ({ code: c.code || '—', views: c.views })),
  };
}
