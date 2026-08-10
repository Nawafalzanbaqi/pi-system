// ===========================================================================
// pi-system Control PANEL (UI) — PURE-LOGIC test driver (raw node, no browser).
// ---------------------------------------------------------------------------
// Imports ONLY the dependency-free UI logic modules (no React, no next, no jose)
// and proves the security-critical + wiring behaviour Part #2 introduces:
//   * API CLIENT request shaping   correct method/path/body + bearer attached
//   * AUTH GUARD decision           no session -> login; session -> app
//   * SECRETS NEVER RENDERED        a secret key never yields a displayable value
//   * ACTION STATE MACHINE          confirm -> pending -> success | error
//   * WIZARD PAYLOAD builder        selections -> exact generate payload + command
//   * LIVE-DATA ADAPTERS            structured pass-through + tolerant text parse
// Exits non-zero on any failure (run.sh aggregates).
// ===========================================================================
import { buildRequest, ENDPOINTS, createClient } from '../../services/control-api/lib/api-client.js';
import { panelGate } from '../../services/control-api/lib/panel-gate.js';
import { displayableKeyValue, secretValueLeaks, isSecretKey } from '../../services/control-api/lib/integrations-view.js';
import { confirmReducer, confirmView } from '../../services/control-api/lib/confirm-machine.js';
import { buildGeneratePayload, buildCreateConfirm } from '../../services/control-api/lib/wizard-payload.js';
import {
  adaptStatus, adaptSystemHealth, adaptProjects,
  adaptMonitoring, adaptMonitoringAlerts, adaptBackup, adaptSeo, adaptProspects, adaptAnalytics,
} from '../../services/control-api/lib/adapt.js';

let run = 0, failed = 0;
const G = process.stdout.isTTY ? '\x1b[0;32m' : '';
const R = process.stdout.isTTY ? '\x1b[0;31m' : '';
const C = process.stdout.isTTY ? '\x1b[1;36m' : '';
const O = process.stdout.isTTY ? '\x1b[0m' : '';
const section = (s) => console.log(`\n${C}== ${s} ==${O}`);
function ok(name, cond) { run++; if (cond) console.log(`  ${G}✓${O} ${name}`); else { failed++; console.log(`  ${R}✗${O} ${name}`); } }
const eq = (name, a, b) => ok(`${name} (got ${JSON.stringify(a)})`, a === b);

// --- API CLIENT request shaping -------------------------------------------
section('API client — request shaping (method/path/body + bearer)');
{
  const g = buildRequest({ path: ENDPOINTS.status });
  eq('GET status path', g.url, '/api/status');
  eq('GET method', g.method, 'GET');
  eq('GET has no body', g.body, undefined);
  eq('GET has no content-type', g.headers['Content-Type'], undefined);
  eq('GET sends cookie credentials', g.credentials, 'same-origin');
  eq('Accept header present', g.headers.Accept, 'application/json');
  ok('GET has no Authorization without token', !('Authorization' in g.headers));

  const gb = buildRequest({ path: ENDPOINTS.status, token: 'TOK.EN' });
  eq('bearer attached when token given', gb.headers.Authorization, 'Bearer TOK.EN');

  const p = buildRequest({ method: 'put', path: ENDPOINTS.integrationKey('TG_BOT_TOKEN'), body: { value: 'x' }, token: 'T' });
  eq('PUT method upper-cased', p.method, 'PUT');
  eq('PUT path encodes key', p.url, '/api/integrations/TG_BOT_TOKEN');
  eq('PUT content-type json', p.headers['Content-Type'], 'application/json');
  eq('PUT body serialized', p.body, JSON.stringify({ value: 'x' }));
  eq('PUT bearer attached', p.headers.Authorization, 'Bearer T');

  const post = buildRequest({ method: 'POST', path: ENDPOINTS.action('up'), body: { profile: 'core' } });
  eq('action path', post.url, '/api/actions/up');
  eq('action body', post.body, JSON.stringify({ profile: 'core' }));

  // A GET must never carry a body even if one is passed.
  const gbody = buildRequest({ method: 'GET', path: '/x', body: { a: 1 } });
  eq('GET drops body', gbody.body, undefined);

  // key with unsafe chars is URL-encoded.
  eq('integrationKey encodes', ENDPOINTS.integrationKey('A/B'), '/api/integrations/A%2FB');

  // createClient shapes calls through buildRequest (capture via fake fetch).
  let captured = null;
  const fakeFetch = async (url, init) => { captured = { url, init }; return { ok: true, status: 200, json: async () => ({ status: 'ok', data: { ok: 1 } }) }; };
  const client = createClient({ token: 'ZZ', fetchImpl: fakeFetch });
  await client.restartService('analytics');
  eq('client POST restart path', captured.url, '/api/actions/restart-service');
  eq('client POST restart body', captured.init.body, JSON.stringify({ service: 'analytics' }));
  eq('client attaches bearer', captured.init.headers.Authorization, 'Bearer ZZ');
}

// --- AUTH GUARD ------------------------------------------------------------
section('Auth guard — no token -> login; session -> app');
{
  eq('null session -> login', panelGate({ session: null, configured: true }).view, 'login');
  eq('login passes configured', panelGate({ session: null, configured: true }).configured, true);
  eq('login when unconfigured', panelGate({ session: null, configured: false }).configured, false);
  eq('session without sub -> login', panelGate({ session: {}, configured: true }).view, 'login');
  const g = panelGate({ session: { sub: 'u1', isOperator: true }, configured: true });
  eq('session with sub -> app', g.view, 'app');
  eq('operator flag carried', g.isOperator, true);
  eq('non-operator session -> app, not operator', panelGate({ session: { sub: 'u2' }, configured: true }).isOperator, false);
}

// --- SECRETS NEVER RENDERED ------------------------------------------------
section('Integrations — a secret value is never displayable');
{
  // Fixture shaped exactly like GET /api/integrations.
  const fixture = [
    { id: 'telegram', label: 'Telegram bot', keys: [
      { key: 'TG_BOT_TOKEN', label: 'Bot token', secret: true, set: true, masked: '••••••••', restart_services: ['automation'] },
      { key: 'TG_CHAT_ID', label: 'Chat ID', secret: false, set: true, value: '12345', restart_services: ['automation'] },
    ] },
  ];
  eq('secret key is flagged', isSecretKey(fixture[0].keys[0]), true);
  eq('secret never displayable', displayableKeyValue(fixture[0].keys[0]), null);
  eq('non-secret value displayable', displayableKeyValue(fixture[0].keys[1]), '12345');
  ok('clean fixture has no leaks', secretValueLeaks(fixture).length === 0);

  // Even a MALICIOUS object carrying a value on a secret key must not render.
  const malicious = { key: 'X', secret: true, set: true, value: 'super-secret' };
  eq('malicious secret still null', displayableKeyValue(malicious), null);
  ok('leak audit catches value on secret', secretValueLeaks([{ keys: [malicious] }]).includes('X'));
  ok('leak audit catches non-bullet mask', secretValueLeaks([{ keys: [{ key: 'Y', secret: true, masked: 'abcd' }] }]).includes('Y'));
}

// --- ACTION STATE MACHINE --------------------------------------------------
section('Action confirm -> pending -> success | error');
{
  eq('idle + ask -> confirming', confirmReducer('idle', 'ask'), 'confirming');
  eq('confirming view open', confirmView('confirming').open, true);
  eq('confirming not pending', confirmView('confirming').pending, false);
  eq('confirming + confirm -> pending', confirmReducer('confirming', 'confirm'), 'pending');
  eq('pending disables confirm button', confirmView('pending').confirmDisabled, true);
  eq('pending + resolve -> success', confirmReducer('pending', 'resolve'), 'success');
  eq('success view', confirmView('success').success, true);
  eq('pending + reject -> error', confirmReducer('pending', 'reject'), 'error');
  eq('error view failed', confirmView('error').failed, true);
  eq('error + confirm -> pending (retry)', confirmReducer('error', 'confirm'), 'pending');
  eq('error + cancel -> idle', confirmReducer('error', 'cancel'), 'idle');
  eq('success + close -> idle', confirmReducer('success', 'close'), 'idle');
  eq('confirming + cancel -> idle', confirmReducer('confirming', 'cancel'), 'idle');
  eq('unknown event no-op', confirmReducer('pending', 'wat'), 'pending');
  eq('idle view closed', confirmView('idle').open, false);
}

// --- WIZARD PAYLOAD --------------------------------------------------------
section('New-project wizard — payload builder');
{
  const res = buildGeneratePayload({ preset: 'ecommerce', db: 'postgres', modules: ['i18n-bilingual', 'web-analytics', 'i18n-bilingual'], subdomain: 'noor', locale: 'ar' });
  ok('valid selection', res.valid === true && res.errors.length === 0);
  eq('name derived from subdomain', res.payload.name, 'noor');
  eq('preset carried', res.payload.preset, 'ecommerce');
  eq('db carried', res.payload.db, 'postgres');
  eq('locale carried', res.payload.locale, 'ar');
  eq('modules deduped', res.payload.modules.length, 2);
  ok('projects[] mirrors payload', JSON.stringify(res.projects[0]) === JSON.stringify(res.payload));
  ok('command has new-project.sh', res.command.includes('scripts/new-project.sh'));
  ok('command has --preset ecommerce', res.command.includes('--preset ecommerce'));
  ok('command has --subdomain noor', res.command.includes('--subdomain noor'));
  ok('command has --modules csv', res.command.includes('--modules i18n-bilingual,web-analytics'));

  ok('invalid subdomain rejected', buildGeneratePayload({ preset: 'clinic', db: 'none', subdomain: 'A', locale: 'ar', modules: [] }).valid === false);
  ok('invalid preset rejected', buildGeneratePayload({ preset: 'nope', db: 'none', subdomain: 'ab', locale: 'ar', modules: [] }).valid === false);
  ok('invalid db rejected', buildGeneratePayload({ preset: 'clinic', db: 'oracle', subdomain: 'ab', locale: 'ar', modules: [] }).valid === false);
  ok('invalid locale rejected', buildGeneratePayload({ preset: 'clinic', db: 'none', subdomain: 'ab', locale: 'fr', modules: [] }).valid === false);
  ok('unknown module rejected', buildGeneratePayload({ preset: 'clinic', db: 'none', subdomain: 'ab', locale: 'ar', modules: ['hack'] }).valid === false);
  // subdomain is sanitized lower-case by the input; builder also lower-cases.
  eq('subdomain lower-cased', buildGeneratePayload({ preset: 'clinic', db: 'none', subdomain: 'AbC', locale: 'ar', modules: [] }).payload.subdomain, 'abc');
}

// --- WIZARD CREATE: submit -> confirm -> pending -> result -----------------
section('New-project wizard — create submit (confirm descriptor + state machine)');
{
  // buildCreateConfirm: a valid review produces the EXACT body to POST + dialog copy.
  const cc = buildCreateConfirm({ preset: 'clinic', db: 'postgres', subdomain: 'noor', locale: 'ar', modules: ['bookings', 'i18n-bilingual'] }, 'en');
  ok('valid selection is confirmable', cc.valid === true);
  eq('confirm body name', cc.payload.name, 'noor');
  eq('confirm names the exact target', cc.target, 'noor.pi.local');
  eq('confirm title names the project', cc.title, 'Create “noor”?');
  ok('confirm payload carries db', cc.payload.db === 'postgres');
  ok('confirm payload carries modules', JSON.stringify(cc.payload.modules) === JSON.stringify(['bookings', 'i18n-bilingual']));
  ok('confirm message says deploy is separate', /separate/i.test(cc.message));
  // Arabic copy is localized.
  eq('confirm title (ar)', buildCreateConfirm({ preset: 'clinic', db: 'none', subdomain: 'noor', locale: 'ar', modules: [] }, 'ar').title, 'إنشاء «noor»؟');
  // Invalid selections are NOT confirmable (the Create button stays disabled).
  ok('invalid subdomain not confirmable', buildCreateConfirm({ preset: 'clinic', db: 'none', subdomain: 'A', locale: 'ar', modules: [] }).valid === false);
  ok('unknown module not confirmable', buildCreateConfirm({ preset: 'clinic', db: 'none', subdomain: 'noor', locale: 'ar', modules: ['hack'] }).valid === false);

  // The submit drives the SAME confirm state machine as every destructive action:
  // review/confirming -> (confirm) pending -> (resolve) success | (reject) error.
  let s = 'confirming';
  eq('confirm dialog is open', confirmView(s).open, true);
  s = confirmReducer(s, 'confirm');
  eq('confirm -> pending (POST in flight)', s, 'pending');
  eq('pending disables the confirm button', confirmView(s).confirmDisabled, true);
  const success = confirmReducer(s, 'resolve');
  eq('resolve -> success (created)', success, 'success');
  eq('success view flagged', confirmView(success).success, true);
  const failed = confirmReducer(s, 'reject');
  eq('reject -> error (e.g. 409 conflict / 403)', failed, 'error');
  eq('error keeps the dialog open for a fix/retry', confirmView(failed).open, true);
  eq('error + cancel -> idle (back to review)', confirmReducer(failed, 'cancel'), 'idle');
}

// --- LIVE-DATA ADAPTERS ----------------------------------------------------
section('Adapters — structured pass-through + tolerant text parse');
{
  // Structured (future JSON) passes through unchanged.
  const s1 = adaptStatus({ overall: 'up', services: [{ name: 'caddy', state: 'running' }] });
  eq('structured status', s1.structured, true);
  eq('structured overall', s1.overall, 'up');

  // Text (today's reality): parse host output, keep raw.
  const s2 = adaptStatus({ action: 'status', exitCode: 0, output: 'caddy   running\npostgres  healthy\nanalytics  unhealthy' });
  eq('text status not structured', s2.structured, false);
  eq('text status parsed count', s2.services.length, 3);
  eq('text status overall degraded', s2.overall, 'degraded');
  ok('raw text kept', typeof s2.raw === 'string' && s2.raw.includes('caddy'));

  const h = adaptSystemHealth({ cpuTempC: 52.4, ram: { usedMB: 5530, totalMB: 8192 }, disk: { usedGB: 128, totalGB: 232 }, verdict: 'pass' });
  eq('structured health temp', h.cpuTempC, 52.4);
  eq('structured health verdict', h.verdict, 'pass');

  const p = adaptProjects([{ name: 'noor-store', state: 'running', subdomain: 'noor', modules: [], preset: 'ecommerce' }]);
  eq('structured projects count', p.projects.length, 1);
  eq('running normalised to up', p.projects[0].state, 'up');

  const pt = adaptProjects({ action: 'projects', exitCode: 0, output: 'al-shifa-clinic  running\nnoor-store  up' });
  eq('text projects parsed', pt.projects.length, 2);
}

// --- PART #4: live Monitoring/Growth feeds (request shaping) ---------------
section('Live feeds — client request shaping (read-only GETs)');
{
  let captured = null;
  const fakeFetch = async (url, init) => { captured = { url, init }; return { ok: true, status: 200, json: async () => ({ status: 'ok', data: {} }) }; };
  const client = createClient({ fetchImpl: fakeFetch });
  const paths = [
    ['getMonitoring', '/api/monitoring'],
    ['getMonitoringAlerts', '/api/monitoring/alerts'],
    ['getBackupStatus', '/api/backup-status'],
    ['getGrowthSeo', '/api/growth/seo'],
    ['getGrowthProspects', '/api/growth/prospects'],
    ['getGrowthAnalytics', '/api/growth/analytics'],
  ];
  for (const [fn, path] of paths) {
    await client[fn]();
    eq(`${fn} GETs ${path}`, captured.url, path);
    eq(`${fn} uses GET`, captured.init.method, 'GET');
    eq(`${fn} sends the cookie`, captured.init.credentials, 'same-origin');
    ok(`${fn} has no body`, captured.init.body === undefined);
  }
}

// --- PART #4: live-data adapters (host JSON -> exact UI shapes) -------------
section('Live adapters — Monitoring');
{
  const env = (o) => ({ action: 'monitoring', exitCode: 0, output: JSON.stringify(o) });
  const m = adaptMonitoring(env({
    lastHealth: { verdict: 'WARN', measured: { cpu_temp_c: '58.2', root_pct: '83', mem_used_pct: '61', swap_used_pct: '3' } },
    history: [
      '2026-05-23T08:00:00+0000  PASS  temp=52°C root=80% mem=55% swap=2%',
      '2026-05-23T12:00:00+0000  FAIL  temp=82°C root=83% mem=61% swap=3%',
    ],
    perService: [{ name: 'pi-system_postgres', memMiB: 95, limitMiB: 256, pct: 37, cpuPct: 1 }],
  }));
  eq('points parsed', m.points.length, 2);
  eq('first point cpu', m.points[0].cpuTempC, 52);
  eq('first point disk%', m.points[0].diskPct, 80);
  eq('latest verdict (lowercased)', m.verdict, 'warn');
  eq('latest measured cpu', m.latest.cpuTempC, 58.2);
  eq('perService carried', m.perService[0].name, 'pi-system_postgres');
  eq('perService memMiB', m.perService[0].memMiB, 95);
  // Empty/missing source -> empty, never throws.
  const empty = adaptMonitoring(env({ lastHealth: null, history: [], perService: [] }));
  eq('empty monitoring -> 0 points', empty.points.length, 0);
  eq('empty monitoring -> unknown verdict', empty.verdict, 'unknown');
}

section('Live adapters — alerts');
{
  const al = adaptMonitoringAlerts({ output: JSON.stringify({
    history: ['2026-05-23T10:00:00+0000  WARN  temp=61°C root=82% mem=58% swap=3%', '2026-05-23T12:00:00+0000  FAIL  temp=82°C root=83% mem=61% swap=3%'],
    alert: ['pi-system health FAIL @ 2026-05-23T12:00:00+0000', '  - CPU temperature 82°C (FAIL)'],
  }) });
  ok('alerts produced', al.length >= 3);
  eq('current alert first + critical', al[0].severity, 'critical');
  ok('current alert detail carried', al[0].message.includes('CPU temperature'));
  ok('a WARN history row is mapped to warn', al.some((a) => a.severity === 'warn'));
  ok('every alert has ts/severity/source/message', al.every((a) => a.ts !== undefined && a.severity && a.source === 'health' && a.message));
}

section('Live adapters — backup');
{
  const b = adaptBackup({ output: JSON.stringify({
    lastBackup: { finished_at: '2026-05-23T02:00:30+0000', result: 'ok', succeeded: 6, attempted: 6, failed: 0 },
    lastVerify: { result: 'ok', passed: 7, total: 7, finished_at: '2026-05-21T03:30:00+0000' },
  }) }, Date.parse('2026-05-23T12:00:30+0000'));
  ok('backup configured', b.configured === true);
  eq('backup result', b.last.result, 'ok');
  eq('backup ageHours computed', b.last.ageHours, 10);
  eq('drill result', b.drill.result, 'ok');
  ok('next/size/destination honestly null', b.next === null && b.size === null && b.destination === null);
  ok('no backups -> configured:false', adaptBackup({ output: JSON.stringify({ lastBackup: null, lastVerify: null }) }).configured === false);
}

section('Live adapters — SEO');
{
  const s = adaptSeo({ output: JSON.stringify({ audits: [
    { name: 'noor', url: 'https://noor.x', timestamp: '2026-05-22T10:00:00Z', scores: { performance: 60, seo: 64, accessibility: 68, 'best-practices': 70 }, checks: { https: false, title: { present: false }, imagesMissingAlt: 2 } },
    { name: 'noor', url: 'https://noor.x', timestamp: '2026-05-24T10:00:00Z', scores: { performance: 80, seo: 82, accessibility: 78, 'best-practices': 85 }, checks: { https: true, title: { present: true, length: 30 } } },
  ] }) });
  eq('one site grouped', s.sites.length, 1);
  eq('perf series oldest->newest', JSON.stringify(s.sites[0].perf), JSON.stringify([60, 80]));
  eq('latest scores from newest audit', s.sites[0].latest.performance, 80);
  ok('recs from LATEST checks (healthy -> none)', s.sites[0].recs.length === 0);
  // A site whose latest audit has issues yields impact-ranked recs.
  const bad = adaptSeo({ output: JSON.stringify({ audits: [{ name: 'bad', timestamp: '2026-05-24T10:00:00Z', scores: { performance: 30, seo: 20, accessibility: 40 }, checks: { https: false, title: { present: false }, metaDescription: { present: false }, imagesMissingAlt: 3 } }] }) });
  ok('bad site has recs', bad.sites[0].recs.length > 0);
  eq('highest-impact rec first', bad.sites[0].recs[0].impact, 'high');
  ok('recs are bilingual', bad.sites[0].recs.every((r) => r.en && r.ar && r.impact));
}

section('Live adapters — prospects (read-only board)');
{
  const p = adaptProspects({ output: JSON.stringify({ schema: 1, prospects: {
    'alpha-co': { id: 'alpha-co', name: 'Alpha Co', url: 'https://a.x', status: 'contacted', notes: [{}], followup: '2026-06-01', lastAnalysis: { ts: '2026-05-20', scores: { performance: 42, seo: 58, accessibility: 71, 'best-practices': 60 }, counts: { critical: 1, high: 2, medium: 3, low: 1 }, summary: 'needs work' } },
    'beta': { id: 'beta', name: 'Beta', url: null, status: 'new', notes: [], followup: null, lastAnalysis: null },
  } }) });
  eq('two prospects', p.prospects.length, 2);
  const a = p.prospects.find((x) => x.id === 'alpha-co');
  eq('analysis scores mapped', a.analysis.performance, 42);
  eq('analysis counts carried', a.analysis.counts.high, 2);
  eq('notes counted', a.notes, 1);
  eq('no-analysis prospect -> null analysis', p.prospects.find((x) => x.id === 'beta').analysis, null);
}

section('Live adapters — analytics (configured-or-not; never leaks creds)');
{
  eq('not configured passes through', adaptAnalytics({ configured: false }).configured, false);
  const err = adaptAnalytics({ configured: true, ok: false, error: 'umami unreachable' });
  ok('configured-but-unreachable surfaces an error', err.configured === true && err.ok === false);
  const a = adaptAnalytics({ configured: true, ok: true, raw: {
    visitors: 4218, prevVisitors: 3674, series: [420, 510, 480],
    urls: [{ x: '/', y: 1284 }, { x: '/products', y: 712 }],
    referrers: [{ x: 'direct', y: 1840 }], countries: [{ x: 'SA', y: 2841 }],
  } });
  eq('total visitors', a.totalVisitors7d, 4218);
  eq('prev visitors', a.totalVisitorsPrev7d, 3674);
  eq('series length', a.visitorsSeries.length, 3);
  eq('top page mapped', a.topPages[0].path, '/');
  eq('top referrer mapped', a.topReferrers[0].src, 'direct');
  eq('country mapped', a.countries[0].code, 'SA');
}

// --- tally -----------------------------------------------------------------
console.log(`\n${run} run, ${failed ? R : G}${failed} failed${O}`);
process.exit(failed ? 1 : 0);
