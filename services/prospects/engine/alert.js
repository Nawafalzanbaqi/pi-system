// pi-system prospect organizer — the OPERATOR analysis ALERT message (PURE).
// ===========================================================================
// After a prospect's public-site analysis completes, the operator wants a tidy,
// at-a-glance heads-up in their OWN channel (e.g. their own Telegram) — NOT a long
// report to read, and NEVER a message to the prospect. formatProspectAlert turns one
// analysis (the SAME audit object the SEO engine produces, carrying audit.verdict)
// into that rich, well-formatted alert: client name, site URL, overall score + tier,
// the single biggest-opportunity line, the top 3 findings, the OPTIONAL AI lead-quality
// score (only when a prior `assist` produced one), and where the full report is saved.
//
// PURE + DETERMINISTIC: no I/O, no clock, no network. It honours a pre-attached
// audit.verdict (computeVerdict's { overall, tier, topFindings, opportunity }) or
// derives it, so the SAME input always yields the SAME text — unit-tested offline.
// notify.js (notifyAnalysis) is what actually DELIVERS the text via the operator's
// own seam (PROSPECTS_NOTIFY_CMD / Uptime-Kuma); this file only FORMATS it.
//
// BOUNDARY: every alert ends with an explicit operator-only reminder. There is no
// prospect address/handle anywhere in this module — it cannot message a prospect.
// ===========================================================================

import { computeVerdict } from '../../seo/engine/verdict.js';
import { summarizeDiff } from '../../seo/engine/diff.js';
import { panelTopRiskLine } from '../../seo/engine/specialists.js';

// Priority -> a single, parse-mode-agnostic glyph (works in plain text or Markdown).
const PRIORITY_EMOJI = { critical: '🔴', high: '🟠', medium: '🟡', low: '⚪' };

// Localized framing only. Arabic first (the platform default); the finding TITLES
// themselves stay in the SEO engine's own deterministic English, exactly like
// report.js buildProspectReport — only the labels around them are translated.
const L = {
  ar: {
    title: 'تحليل عميل محتمل',
    site: 'الموقع', engine: 'المحرك',
    overall: 'النتيجة الإجمالية', opportunity: 'أكبر فرصة',
    top: 'أبرز الملاحظات',
    noFindings: 'لا توجد ملاحظات جوهرية — الموقع في حالة جيدة.',
    unreachable: 'الموقع غير متاح حاليًا — إعادته إلى الإنترنت هي الأولوية القصوى.',
    lead: 'تقييم جودة العميل (ذكاء اصطناعي)', next: 'الخطوة المقترحة',
    report: 'التقرير الكامل', noReport: '(لم يُسجَّل مسار تقرير)',
    boundary: 'تذكير للمشغّل فقط — تواصَل بنفسك؛ لم يُرسَل هذا إلى العميل.',
    site_fallback: 'الموقع',
    tier: { excellent: 'ممتاز', good: 'جيد', fair: 'مقبول', poor: 'ضعيف' },
    prio: { critical: 'حرجة', high: 'عالية', medium: 'متوسطة', low: 'منخفضة' },
    cat: {
      seo: 'تحسين محركات البحث', performance: 'الأداء', security: 'الأمان',
      'best-practices': 'أفضل الممارسات', accessibility: 'سهولة الوصول',
    },
  },
  en: {
    title: 'Prospect analysis',
    site: 'Site', engine: 'Engine',
    overall: 'Overall', opportunity: 'Biggest win',
    top: 'Top findings',
    noFindings: 'No major issues found — the site is in good shape.',
    unreachable: 'The site is unreachable right now — getting it back online is the most urgent fix.',
    lead: 'AI lead score', next: 'next',
    report: 'Full report', noReport: '(no report path recorded)',
    boundary: 'Operator-only reminder — reach out yourself; this was NOT sent to the prospect.',
    site_fallback: 'the site',
    tier: { excellent: 'excellent', good: 'good', fair: 'fair', poor: 'poor' },
    prio: { critical: 'critical', high: 'high', medium: 'medium', low: 'low' },
    cat: {
      seo: 'SEO', performance: 'Performance', security: 'Security',
      'best-practices': 'Best practices', accessibility: 'Accessibility',
    },
  },
};

// Arabic for anything that is not explicitly English (RTL-first default), matching
// report.js buildProspectReport.
function normLocale(locale) {
  return String(locale || '').trim().toLowerCase().startsWith('en') ? 'en' : 'ar';
}

function clientName(a, t) {
  return a.name || a.url || t.site_fallback;
}

// Honour a pre-attached AI assist (record or alert shape); only when it actually
// produced a lead score. Returns { leadScore, nextAction } or null.
function aiAssistOf(a) {
  const ai = a.aiAssist || a.ai_assist;
  if (ai && ai.enabled !== false && ai.leadScore != null) {
    return { leadScore: ai.leadScore, nextAction: ai.nextAction || null };
  }
  return null;
}

// One localized, plain-language "biggest opportunity" line (the sales hook).
function opportunityLine(a, verdict, t) {
  if (a.ok === false) return t.unreachable;
  const top = (verdict.topFindings || [])[0];
  if (!top) return t.noFindings;
  const cat = t.cat[top.category] || top.category;
  const prio = t.prio[top.priority] || top.priority;
  return t === L.ar
    ? `${top.title} — ملاحظة بأولوية ${prio} ضمن فئة ${cat}.`
    : `${top.title} — a ${prio}-priority ${cat} fix.`;
}

// formatProspectAlert(audit, { locale }) -> the full, multi-line operator alert string.
// `audit` is the analysis audit (name/url/scores/verdict/engine/ok), OPTIONALLY
// augmented by the caller with: name (the human business name), reportFile (saved path),
// and aiAssist/ai_assist (a prior decision-assist with a leadScore). Pure.
export function formatProspectAlert(audit, opts = {}) {
  const a = audit || {};
  const loc = normLocale(opts.locale);
  const t = L[loc];
  const verdict = (a.verdict && typeof a.verdict === 'object') ? a.verdict : computeVerdict(a);
  const overall = Number.isFinite(verdict.overall) ? verdict.overall : 0;
  const tier = verdict.tier || 'poor';

  const lines = [];
  lines.push(`🔍 ${t.title} — ${clientName(a, t)}`);
  lines.push(`${t.site}: ${a.url || '—'}${a.engine ? `  ·  ${t.engine}: ${a.engine}` : ''}`);
  lines.push(`${t.overall}: ${overall}/100 (${t.tier[tier] || tier})`);
  lines.push(`${t.opportunity}: ${opportunityLine(a, verdict, t)}`);
  lines.push('');

  const top = (verdict.topFindings || []).slice(0, 3);
  if (top.length) {
    lines.push(`${t.top}:`);
    top.forEach((f, i) => {
      const cat = t.cat[f.category] || f.category;
      lines.push(`${i + 1}. ${PRIORITY_EMOJI[f.priority] || '•'} ${f.title} (${cat})`);
    });
    lines.push('');
  }

  // Specialist panel (optional): the single #1 cross-cutting priority — operator-only.
  const panelLine = a.panel ? panelTopRiskLine(a.panel, loc) : '';
  if (panelLine) { lines.push(`🧭 ${panelLine}`); lines.push(''); }

  const ai = aiAssistOf(a);
  if (ai) {
    lines.push(`⭐ ${t.lead}: ${ai.leadScore}/100${ai.nextAction ? `  —  ${t.next}: ${ai.nextAction}` : ''}`);
    lines.push('');
  }

  lines.push(`📄 ${t.report}: ${a.reportFile || t.noReport}`);
  lines.push(`🔒 ${t.boundary}`);
  return lines.join('\n');
}

// ===========================================================================
// RE-AUDIT regression alert — the OPERATOR heads-up for monitoring existing clients.
// ===========================================================================
// When a re-audit of an EXISTING client regresses (a new critical/high finding, a
// tier drop, or the site going offline), the operator wants a concise "client X
// regressed" heads-up in their OWN channel — same boundary as formatProspectAlert
// (operator-only; NEVER a message to the client). The CALLER decides whether to send
// (diff.isMeaningfulChange); this file only FORMATS, reusing the bilingual
// summarizeDiff for the body. Pure + deterministic — unit-tested in both locales.
const RL = {
  ar: { regressed: 'تراجُع', wentOffline: 'أصبح الموقع غير متاح', newCrit: 'ملاحظة حرجة جديدة', newHigh: 'ملاحظة عالية الأولوية جديدة', tierDrop: 'تراجَع التقييم', changes: 'التغييرات منذ آخر فحص' },
  en: { regressed: 'regressed', wentOffline: 'the site went offline', newCrit: 'new critical issue', newHigh: 'new high-priority issue', tierDrop: 'tier dropped', changes: 'Changes since last audit' },
};

// The single, plain-language reason this re-audit is alert-worthy (regressions first).
function reauditLead(loc, diff, t, rl) {
  const d = diff || {};
  if (d.wentOffline) return rl.wentOffline;
  const nf = (d.findings && d.findings.new) || [];
  const crit = nf.find((x) => x.priority === 'critical');
  if (crit) return `${rl.newCrit} — ${t.cat[crit.category] || crit.category}`;
  const high = nf.find((x) => x.priority === 'high');
  if (high) return `${rl.newHigh} — ${t.cat[high.category] || high.category}`;
  if (d.tierDropped && d.tier) return `${rl.tierDrop} ${t.tier[d.tier.previous] || d.tier.previous}→${t.tier[d.tier.current] || d.tier.current}`;
  return rl.regressed;
}

// formatReauditAlert(audit, { locale }) -> the full, multi-line OPERATOR regression
// alert. `audit` carries name (the human business name), url, diff (the delta from
// diffAudits), and OPTIONALLY reportFile. Pure. Ends with the operator-only boundary.
export function formatReauditAlert(audit, opts = {}) {
  const a = audit || {};
  const loc = normLocale(opts.locale);
  const t = L[loc];
  const rl = RL[loc];
  const diff = a.diff || {};
  const lead = reauditLead(loc, diff, t, rl);

  const lines = [];
  lines.push(`⚠️ ${clientName(a, t)} — ${rl.regressed}: ${lead}`);
  lines.push(`${t.site}: ${a.url || '—'}${a.engine ? `  ·  ${t.engine}: ${a.engine}` : ''}`);
  lines.push('');
  lines.push(`${rl.changes}:`);
  lines.push(summarizeDiff(diff, { locale: loc }));
  lines.push('');
  lines.push(`📄 ${t.report}: ${a.reportFile || t.noReport}`);
  lines.push(`🔒 ${t.boundary}`);
  return lines.join('\n');
}

// formatReauditAlertSummary(audit, { locale }) -> a single compact line for the
// Uptime-Kuma "msg" param and stderr. Pure.
export function formatReauditAlertSummary(audit, opts = {}) {
  const a = audit || {};
  const loc = normLocale(opts.locale);
  const t = L[loc];
  const rl = RL[loc];
  return `${clientName(a, t)}: ${rl.regressed} — ${reauditLead(loc, a.diff || {}, t, rl)}`;
}

// formatProspectAlertSummary(audit, { locale }) -> a single compact line (no newlines)
// for the Uptime-Kuma "msg" param and stderr. Pure.
export function formatProspectAlertSummary(audit, opts = {}) {
  const a = audit || {};
  const loc = normLocale(opts.locale);
  const t = L[loc];
  const verdict = (a.verdict && typeof a.verdict === 'object') ? a.verdict : computeVerdict(a);
  const overall = Number.isFinite(verdict.overall) ? verdict.overall : 0;
  const tier = verdict.tier || 'poor';
  const top = (verdict.topFindings || [])[0];
  const ai = aiAssistOf(a);
  const topPart = top ? ` · ${loc === 'ar' ? 'أبرز' : 'top'}: ${top.title}` : '';
  const leadPart = ai ? ` · ${loc === 'ar' ? 'تقييم' : 'lead'} ${ai.leadScore}` : '';
  return `${clientName(a, t)}: ${overall}/100 (${t.tier[tier] || tier})${topPart}${leadPart}`;
}
