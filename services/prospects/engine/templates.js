// pi-system prospect organizer — DRAFT message TEMPLATES (copy-yourself).
// ===========================================================================
// Renders a draft outreach message the operator can COPY, personalize, and send
// THEMSELVES through their own channel (their email client, their WhatsApp, etc.).
//
// CRITICAL BOUNDARY (architectural, not a toggle): this module ONLY returns text.
// It does NOT send anything, has NO transport (no SMTP/WhatsApp/HTTP client), and
// is NOT wired to any send path anywhere in this engine. There is deliberately no
// "send template" action. Bulk/automated outreach is out of scope by design — the
// operator contacts each prospect manually, one at a time, after personalizing the
// draft. Every template keeps obvious [PLACEHOLDERS] so it can never be fired off
// verbatim by mistake.
//
// Pure: same (kind, context) => same text, so it is unit-testable.
// ===========================================================================

export const TEMPLATE_KINDS = ['intro', 'followup', 'audit-offer'];
export const TEMPLATE_LANGS = ['en', 'ar'];

export function isValidKind(k) {
  return TEMPLATE_KINDS.includes(k);
}
export function isValidLang(l) {
  return TEMPLATE_LANGS.includes(l);
}

// Pull a short, human "here's what I noticed" line out of a stored analysis, if any.
function noticedLine(prospect, lang) {
  const a = prospect && prospect.lastAnalysis;
  if (!a || !a.counts) {
    return lang === 'ar'
      ? 'لاحظت بعض النقاط البسيطة التي يمكن تحسينها في موقعكم.'
      : 'I noticed a few small things on your website that could be improved.';
  }
  const c = a.counts;
  const n = (c.critical || 0) + (c.high || 0);
  if (lang === 'ar') {
    return n > 0
      ? `راجعت موقعكم العام ولاحظت ${n} نقطة ذات أولوية (إضافةً إلى نقاط أصغر) يمكن أن تحسّن الظهور والأداء.`
      : 'راجعت موقعكم العام ولاحظت بعض الفرص البسيطة لتحسين الظهور والأداء.';
  }
  return n > 0
    ? `I took a look at your public website and noticed ${n} higher-priority item(s) (plus a few smaller ones) that could improve your visibility and speed.`
    : 'I took a look at your public website and noticed a few small opportunities to improve visibility and speed.';
}

function tEn(kind, prospect) {
  const name = (prospect && prospect.name) || '[BUSINESS NAME]';
  switch (kind) {
    case 'intro':
      return [
        `Subject: A quick idea for ${name}`,
        '',
        `Hi [CONTACT NAME],`,
        '',
        `I'm [YOUR NAME], a freelance [web developer/designer] based in [YOUR CITY]. ` +
          `I came across ${name} and liked [SOMETHING SPECIFIC YOU GENUINELY NOTICED].`,
        '',
        `${noticedLine(prospect, 'en')} If it's useful, I'd be glad to share a short, no-obligation summary.`,
        '',
        `Would you be open to a quick chat this week?`,
        '',
        `Best regards,`,
        `[YOUR NAME] · [YOUR PHONE] · [YOUR WEBSITE]`,
      ].join('\n');
    case 'followup':
      return [
        `Subject: Following up — ${name}`,
        '',
        `Hi [CONTACT NAME],`,
        '',
        `Just following up on my note from [DATE] about ${name}. No pressure at all — ` +
          `I know things get busy.`,
        '',
        `If helpful, I'm happy to send over the short summary I mentioned, or set up a ` +
          `10-minute call at a time that suits you.`,
        '',
        `Either way, wishing you a great [week/season].`,
        '',
        `Best regards,`,
        `[YOUR NAME] · [YOUR PHONE]`,
      ].join('\n');
    case 'audit-offer':
      return [
        `Subject: A few notes on the ${name} website`,
        '',
        `Hi [CONTACT NAME],`,
        '',
        `${noticedLine(prospect, 'en')}`,
        '',
        `I put together a short, plain-English summary you're welcome to keep whether or ` +
          `not we work together. [PASTE OR ATTACH THE REPORT YOU GENERATED, after reviewing/editing it].`,
        '',
        `If you'd like, I can walk through the top items in a quick call and suggest ` +
          `what's worth doing first.`,
        '',
        `Best regards,`,
        `[YOUR NAME] · [YOUR PHONE] · [YOUR WEBSITE]`,
      ].join('\n');
    default:
      return '';
  }
}

function tAr(kind, prospect) {
  const name = (prospect && prospect.name) || '[اسم النشاط]';
  switch (kind) {
    case 'intro':
      return [
        `الموضوع: فكرة سريعة لـ ${name}`,
        '',
        `مرحباً [اسم جهة الاتصال]،`,
        '',
        `أنا [اسمك]، [مطوّر/مصمم] مواقع مستقل في [مدينتك]. اطّلعت على ${name} وأعجبني [أمر محدّد لاحظته فعلاً].`,
        '',
        `${noticedLine(prospect, 'ar')} ويسعدني مشاركتكم ملخصاً مختصراً دون أي التزام إن كان مفيداً.`,
        '',
        `هل لديكم استعداد لمحادثة قصيرة هذا الأسبوع؟`,
        '',
        `مع خالص التحية،`,
        `[اسمك] · [هاتفك] · [موقعك]`,
      ].join('\n');
    case 'followup':
      return [
        `الموضوع: متابعة — ${name}`,
        '',
        `مرحباً [اسم جهة الاتصال]،`,
        '',
        `أتابع رسالتي السابقة بتاريخ [التاريخ] بخصوص ${name}. لا يوجد أي ضغط إطلاقاً — أعلم أن الانشغال وارد.`,
        '',
        `إن كان مفيداً، يسعدني إرسال الملخص المختصر الذي ذكرته، أو ترتيب مكالمة قصيرة في الوقت المناسب لكم.`,
        '',
        `في كل الأحوال، أتمنى لكم [أسبوعاً] موفقاً.`,
        '',
        `مع خالص التحية،`,
        `[اسمك] · [هاتفك]`,
      ].join('\n');
    case 'audit-offer':
      return [
        `الموضوع: بعض الملاحظات على موقع ${name}`,
        '',
        `مرحباً [اسم جهة الاتصال]،`,
        '',
        `${noticedLine(prospect, 'ar')}`,
        '',
        `أعددت ملخصاً مختصراً وواضحاً يمكنكم الاحتفاظ به سواء تعاونّا أم لا. [الصق أو أرفق التقرير الذي أنشأته بعد مراجعته وتعديله].`,
        '',
        `وإن رغبتم، يمكنني استعراض أهم النقاط في مكالمة قصيرة واقتراح ما يستحق البدء به أولاً.`,
        '',
        `مع خالص التحية،`,
        `[اسمك] · [هاتفك] · [موقعك]`,
      ].join('\n');
    default:
      return '';
  }
}

// renderTemplate(kind, { prospect, lang }) -> a draft message string.
// Throws on an unknown kind/lang so the CLI can report it clearly.
export function renderTemplate(kind, ctx = {}) {
  if (!isValidKind(kind)) throw new Error(`unknown template '${kind}' (one of: ${TEMPLATE_KINDS.join(', ')})`);
  const lang = ctx.lang || 'en';
  if (!isValidLang(lang)) throw new Error(`unknown lang '${lang}' (one of: ${TEMPLATE_LANGS.join(', ')})`);
  const prospect = ctx.prospect || {};
  return lang === 'ar' ? tAr(kind, prospect) : tEn(kind, prospect);
}

// A short banner the CLI prints ABOVE the draft, so it is never mistaken for an
// auto-sent message. This tool does not send — the operator copies, edits, sends.
export function draftBanner(lang = 'en') {
  return lang === 'ar'
    ? '— مسودة للنسخ. هذه الأداة لا ترسل أي رسالة. راجعها وعدّلها ثم أرسلها بنفسك عبر قناتك الخاصة. —'
    : '— DRAFT to copy. This tool does NOT send anything. Review, personalize, then send it yourself from your own channel. —';
}
