// catalog.js — the data-driven arrays the screens render from (ported verbatim
// from the prototype). Two kinds live here:
//   1. REAL catalogs that mirror what the platform/API actually offers — the
//      wizard's PRESETS / DATABASES / MODULES (these map 1:1 to
//      scripts/new-project.sh flags) and STAGE_DEFS / PROSPECT_STATUSES.
//   2. SAMPLE_* fixtures for the Monitoring time-series and Growth (prospects /
//      SEO / analytics / templates) screens, which have NO control-api endpoint
//      yet — they are clearly named SAMPLE_ and the UI badges them "sample data,
//      live source pending" so nothing pretends to be live.
// Adding a preset/db/module/stage is one entry here; no JSX change.

// ---- Wizard catalogs (map to scripts/new-project.sh) ------------------------
export const PRESETS = [
  { id: 'clinic', icon: 'plus', ar: 'عيادة', en: 'Clinic',
    ar_sub: 'مواعيد، أطباء، خدمات', en_sub: 'Appointments, doctors, services',
    defaults: ['i18n-bilingual', 'content-admin', 'bookings', 'auth-sso', 'web-analytics', 'seo-toolkit'] },
  { id: 'ecommerce', icon: 'cart', ar: 'متجر إلكتروني', en: 'Ecommerce',
    ar_sub: 'منتجات، سلّة، دفع', en_sub: 'Catalog, cart, checkout',
    defaults: ['i18n-bilingual', 'content-admin', 'local-payments', 'web-analytics', 'seo-toolkit', 'whatsapp-integration'] },
  { id: 'company-site', icon: 'office', ar: 'موقع شركة', en: 'Company site',
    ar_sub: 'خدمات، عنّا، اتصل', en_sub: 'Services, about, contact',
    defaults: ['i18n-bilingual', 'content-admin', 'web-analytics', 'seo-toolkit'] },
  { id: 'real-estate', icon: 'home', ar: 'عقارات', en: 'Real estate',
    ar_sub: 'وحدات، جولات، طلبات', en_sub: 'Listings, tours, leads',
    defaults: ['i18n-bilingual', 'content-admin', 'bookings', 'web-analytics', 'seo-toolkit', 'whatsapp-integration'] },
];

export const DATABASES = [
  { id: 'postgres', ar: 'PostgreSQL', en: 'PostgreSQL', ar_sub: 'الأنسب لمعظم الحالات', en_sub: 'Recommended for most cases', recommended: true },
  { id: 'mysql', ar: 'MySQL', en: 'MySQL', ar_sub: 'بديل مألوف', en_sub: 'Familiar alternative' },
  { id: 'mongo', ar: 'MongoDB', en: 'MongoDB', ar_sub: 'مرن للوثائق', en_sub: 'Flexible for documents' },
  { id: 'none', ar: 'بدون قاعدة', en: 'No database', ar_sub: 'موقع ثابت فقط', en_sub: 'Static site only' },
];

export const MODULES = [
  { id: 'i18n-bilingual', ar: 'ثنائي اللغة (ع/EN)', en: 'Bilingual (AR/EN)', ar_sub: 'يدعم RTL تلقائيًا', en_sub: 'RTL-aware by default' },
  { id: 'content-admin', ar: 'لوحة المحتوى', en: 'Content admin', ar_sub: 'تحرير الصفحات والمحتوى', en_sub: 'Edit pages & copy' },
  { id: 'bookings', ar: 'الحجوزات', en: 'Bookings', ar_sub: 'تقويم + تأكيدات', en_sub: 'Calendar + confirmations' },
  { id: 'auth-sso', ar: 'تسجيل دخول موحّد', en: 'Auth · SSO', ar_sub: 'بريد + قوقل + ماجيك لينك', en_sub: 'Email + Google + magic link' },
  { id: 'whatsapp-integration', ar: 'واتساب', en: 'WhatsApp', ar_sub: 'إشعارات وردود', en_sub: 'Alerts & replies' },
  { id: 'local-payments', ar: 'مدفوعات محلية', en: 'Local payments', ar_sub: 'مدى + ميسر + STC Pay', en_sub: 'Mada + Moyasar + STC Pay' },
  { id: 'web-analytics', ar: 'إحصاءات', en: 'Web analytics', ar_sub: 'خصوصية أولاً، بلا كوكيز', en_sub: 'Privacy-first, no cookies' },
  { id: 'seo-toolkit', ar: 'أدوات SEO', en: 'SEO toolkit', ar_sub: 'sitemap, OG, schema', en_sub: 'sitemap, OG, schema' },
];

export const STAGE_DEFS = [
  { id: 'generate', ar: 'توليد', en: 'Generate', ar_sub: 'من القالب', en_sub: 'from template' },
  { id: 'build', ar: 'بناء', en: 'Build', ar_sub: 'تثبيت + bundle', en_sub: 'install + bundle' },
  { id: 'quality-gate', ar: 'بوّابة الجودة', en: 'Quality gate', ar_sub: 'lint + types + tests', en_sub: 'lint + types + tests' },
  { id: 'deploy', ar: 'نشر', en: 'Deploy', ar_sub: 'إلى caddy', en_sub: 'to caddy' },
  { id: 'live', ar: 'منشور', en: 'Live', ar_sub: 'صحة التحقق', en_sub: 'health verified' },
];

export const PRESET_NAMES_AR = { clinic: 'عيادة', ecommerce: 'متجر', 'company-site': 'موقع شركة', 'real-estate': 'عقارات' };
export const PRESET_NAMES_EN = { clinic: 'Clinic', ecommerce: 'Ecommerce', 'company-site': 'Company site', 'real-estate': 'Real estate' };

export const moduleLabel = (id, lang) => {
  const m = MODULES.find((x) => x.id === id);
  return m ? (lang === 'ar' ? m.ar : m.en) : id;
};

// ---- Integration presentation overlay --------------------------------------
// GET /api/integrations returns the live, authoritative shape (id, label, keys
// with set/secret/restart_services). It carries English labels only. This map
// supplies the calm service icon + an Arabic label per integration/key WITHOUT
// becoming a second source of truth: anything not listed falls back to the
// API's own label. It NEVER contains a value — presentation only.
export const INTEGRATION_PRESENTATION = {
  telegram:  { icon: 'tg',    ar: 'بوت تيليغرام' },
  ai:        { icon: 'ai',    ar: 'مزود الذكاء الاصطناعي' },
  whatsapp:  { icon: 'wa',    ar: 'واتساب للأعمال' },
  payments:  { icon: 'pay',   ar: 'المدفوعات' },
  analytics: { icon: 'plaus', ar: 'الإحصاءات' },
  cloudflare:{ icon: 'cf',    ar: 'كلاودفلير' },
  smtp:      { icon: 'mail',  ar: 'البريد الإلكتروني' },
};

// ---- Growth: prospects ------------------------------------------------------
export const PROSPECT_STATUSES = [
  { id: 'new', ar: 'جديد', en: 'New', kind: 'muted' },
  { id: 'contacted', ar: 'تواصل أوّل', en: 'Contacted', kind: 'muted' },
  { id: 'in-talks', ar: 'محادثة جارية', en: 'In talks', kind: 'warn' },
  { id: 'won', ar: 'مكسب', en: 'Won', kind: 'ok' },
  { id: 'lost', ar: 'خسارة', en: 'Lost', kind: 'bad' },
];

// ---- Monitoring thresholds + caps (match Overview vitals) -------------------
export const THRESHOLDS = {
  cpuTempC: { warn: 60, fail: 75 },
  ramPct: { warn: 75, fail: 90 },
  diskPct: { warn: 80, fail: 92 },
  servicePct: { warn: 70, fail: 90 },
};
export const SERVICE_RAM_CAP = {
  postgres: 512, redis: 128, caddy: 96, n8n: 384, minio: 256, analytics: 256, auth: 128, mailer: 128,
};

// ===========================================================================
// SAMPLE fixtures — Monitoring & Growth have no control-api endpoint yet.
// The UI renders these and badges them "sample data · live source pending" so
// they never masquerade as live. Swapping to live = a data swap, not a redesign.
// ===========================================================================
const _gen = (n, base, swing, drift = 0, jitter = 1) => {
  const out = [];
  let v = base;
  for (let i = 0; i < n; i++) {
    v += (Math.random() - 0.5) * jitter + drift * 0.02;
    v = Math.max(0, v);
    const wobble = Math.sin(i / 6) * swing * 0.5 + Math.cos(i / 11) * swing * 0.3;
    out.push(Math.round((base + wobble + (v - base)) * 10) / 10);
  }
  return out;
};

export const SAMPLE_METRICS = {
  cpuTempC: _gen(60, 50, 7, 0.1, 0.8).map((v, i) => (i > 48 ? v + 4 : v)),
  ramUsedMB: _gen(60, 5300, 280, 0.5, 60),
  diskUsedGB: _gen(60, 127, 0.6, 0.02, 0.05),
  perService: {
    postgres: _gen(60, 410, 30, 0, 8), redis: _gen(60, 92, 10, 0, 3), caddy: _gen(60, 64, 6, 0, 2),
    n8n: _gen(60, 245, 25, 0, 6), minio: _gen(60, 128, 12, 0, 3), analytics: _gen(60, 180, 22, 0.4, 7),
    auth: _gen(60, 88, 8, 0, 2), mailer: _gen(60, 70, 6, 0, 2),
  },
};

export const SAMPLE_ALERTS = [
  { ts: '17:42', severity: 'warn', source: 'analytics', message_ar: 'استهلاك ذاكرة مرتفع لخدمة analytics', message_en: 'analytics memory above warn threshold (75%)' },
  { ts: '17:31', severity: 'info', source: 'backup', message_ar: 'تمت النسخة الاحتياطية الليلية بنجاح', message_en: 'nightly backup completed → minio' },
  { ts: '17:08', severity: 'critical', source: 'analytics', message_ar: 'تعذّر إعادة تشغيل analytics مرة واحدة', message_en: 'analytics restart failed (1 attempt)' },
  { ts: '16:55', severity: 'info', source: 'caddy', message_ar: 'تجديد شهادات TLS · *.pi.local', message_en: 'TLS renewed for *.pi.local' },
  { ts: '16:12', severity: 'info', source: 'projects', message_ar: 'مشروع جديد · naseem-bakery منشور', message_en: 'new project naseem-bakery deployed' },
  { ts: '15:48', severity: 'info', source: 'backup', message_ar: 'تجربة استعادة أسبوعية ناجحة', message_en: 'weekly restore-drill passed' },
  { ts: '14:31', severity: 'warn', source: 'cpu', message_ar: 'حرارة المعالج تجاوزت 60° لـ 4 دقائق', message_en: 'cpu temp above 60° for 4 min' },
  { ts: '13:02', severity: 'info', source: 'auth', message_ar: 'تسجيل دخول جديد · omar@pi', message_en: 'login · omar@pi from 192.168.1.42' },
  { ts: '11:47', severity: 'warn', source: 'disk', message_ar: 'القرص يقترب من 60%', message_en: 'disk approaching 60% usage' },
  { ts: '08:30', severity: 'info', source: 'cron', message_ar: 'تشغيل المهام المجدولة', message_en: 'scheduled jobs run' },
];

export const SAMPLE_BACKUP = {
  lastBackupISO: '2026-05-23T02:00:00', ageHours: 8,
  lastDrillISO: '2026-05-21T03:30:00', lastDrillResult: 'pass',
  nextScheduledISO: '2026-05-24T02:00:00', sizeGB: 18.4,
  destination: 'minio · pi.local', retention: '14 nightly · 8 weekly · 6 monthly',
};

export const SAMPLE_PROSPECTS = [
  { name: 'مطعم الأصيل', url: 'al-aseel.local', status: 'new', followUpDate: '2026-05-26',
    contact: { ar: 'أحمد · واتساب', en: 'Ahmad · WhatsApp' }, sector_ar: 'مطاعم', sector_en: 'Restaurants',
    report: { performance: 42, seo: 58, accessibility: 71, recommendations: [
      { ar: 'تأخير تحميل الصور الكبيرة بالكسل', en: 'Lazy-load above-fold images', impact: 'high' },
      { ar: 'تقليل عدد ملفات JS غير المستخدمة', en: 'Remove unused JS bundles', impact: 'high' },
      { ar: 'وصف ميتا مفقود في 6 صفحات', en: 'Missing meta descriptions on 6 pages', impact: 'med' },
      { ar: 'تباين منخفض في 3 أزرار CTA', en: 'Low contrast on 3 CTAs', impact: 'med' },
      { ar: 'لا يوجد robots.txt', en: 'No robots.txt found', impact: 'low' },
    ] } },
  { name: 'عيادة د. سلمى', url: 'salma-clinic.local', status: 'contacted', followUpDate: '2026-05-24',
    contact: { ar: 'د. سلمى · بريد', en: 'Dr. Salma · email' }, sector_ar: 'صحة', sector_en: 'Healthcare',
    report: { performance: 67, seo: 72, accessibility: 80, recommendations: [
      { ar: 'إضافة schema.org للعيادة', en: 'Add MedicalClinic schema', impact: 'high' },
      { ar: 'سرعة استجابة الخادم بطيئة', en: 'Slow server response (TTFB)', impact: 'med' },
    ] } },
  { name: 'متجر زهور رنا', url: 'rana-flowers.local', status: 'in-talks', followUpDate: '2026-05-25',
    contact: { ar: 'رنا · واتساب', en: 'Rana · WhatsApp' }, sector_ar: 'متاجر', sector_en: 'Retail',
    report: { performance: 55, seo: 64, accessibility: 68, recommendations: [
      { ar: 'صور المنتجات أكبر من اللازم', en: 'Product images oversized', impact: 'high' },
    ] } },
  { name: 'استوديو يارا', url: 'yara-studio.local', status: 'in-talks', followUpDate: '2026-05-27',
    contact: { ar: 'يارا · إنستغرام', en: 'Yara · Instagram' }, sector_ar: 'مصممون', sector_en: 'Designers',
    report: { performance: 78, seo: 81, accessibility: 76, recommendations: [] } },
  { name: 'شركة ابن سينا', url: 'ibnsina.local', status: 'won', followUpDate: '2026-06-01',
    contact: { ar: 'أ. خالد', en: 'K. Khaled' }, sector_ar: 'شركات', sector_en: 'Corporate',
    report: { performance: 88, seo: 90, accessibility: 84, recommendations: [] } },
  { name: 'كافيه سمر', url: 'samar-cafe.local', status: 'lost', followUpDate: null,
    contact: { ar: 'سمر · واتساب', en: 'Samar · WhatsApp' }, sector_ar: 'مقاهي', sector_en: 'Cafés',
    report: { performance: 38, seo: 42, accessibility: 55, recommendations: [] } },
  { name: 'عقارات الواحة', url: 'wahaa.local', status: 'new', followUpDate: '2026-05-30',
    contact: { ar: 'سعد · هاتف', en: 'Saad · phone' }, sector_ar: 'عقارات', sector_en: 'Real estate',
    report: { performance: 49, seo: 55, accessibility: 60, recommendations: [] } },
  { name: 'صالون بسمة', url: 'basma.local', status: 'contacted', followUpDate: '2026-05-29',
    contact: { ar: 'بسمة · واتساب', en: 'Basma · WhatsApp' }, sector_ar: 'تجميل', sector_en: 'Beauty',
    report: { performance: 60, seo: 64, accessibility: 70, recommendations: [] } },
];

export const SAMPLE_SEO_AUDITS = [
  { site: 'noor-store', perf: [60, 62, 65, 68, 70, 72, 75, 78, 80, 81], seo: [70, 71, 72, 72, 74, 75, 76, 78, 80, 82], a11y: [68, 70, 71, 72, 72, 74, 75, 76, 77, 78],
    recs: [{ ar: 'إضافة hreflang للصفحات الثنائية', en: 'Add hreflang to bilingual pages', impact: 'high' }, { ar: 'تقليل CLS في الصفحة الرئيسية', en: 'Reduce homepage CLS', impact: 'med' }] },
  { site: 'studio-rashid', perf: [72, 74, 76, 77, 78, 79, 80, 82, 84, 86], seo: [78, 79, 80, 81, 82, 83, 84, 84, 85, 86], a11y: [74, 75, 76, 76, 77, 78, 79, 80, 81, 82],
    recs: [{ ar: 'صور بحاجة لـ alt واضح', en: 'Images need descriptive alt', impact: 'med' }] },
  { site: 'baytna-realty', perf: [48, 50, 52, 54, 55, 55, 56, 58, 60, 62], seo: [54, 55, 56, 57, 58, 60, 62, 63, 64, 66], a11y: [60, 61, 62, 63, 64, 65, 66, 67, 68, 68],
    recs: [{ ar: 'تأخير تحميل الخرائط', en: 'Lazy-load embedded maps', impact: 'high' }, { ar: 'حجم الصور كبير جدًا', en: 'Listing images too heavy', impact: 'high' }] },
  { site: 'al-shifa-clinic', perf: [65, 66, 68, 70, 71, 72, 72, 73, 74, 75], seo: [72, 73, 74, 75, 75, 76, 77, 78, 78, 79], a11y: [78, 79, 80, 81, 82, 82, 83, 84, 84, 85], recs: [] },
];

export const SAMPLE_ANALYTICS = {
  totalVisitors7d: 4218, totalVisitorsPrev7d: 3674, visitorsSeries: [420, 510, 480, 620, 540, 720, 928],
  topPages: [
    { path: '/', views: 1284, ar: 'الرئيسية', en: 'Home' },
    { path: '/products', views: 712, ar: 'المنتجات', en: 'Products' },
    { path: '/ar/services/clinic', views: 487, ar: 'خدمات العيادة', en: 'Clinic services' },
    { path: '/contact', views: 318, ar: 'تواصل', en: 'Contact' },
    { path: '/about', views: 224, ar: 'عنّا', en: 'About' },
  ],
  topReferrers: [
    { src: 'direct', views: 1840 }, { src: 'google.com', views: 1209 }, { src: 'x.com', views: 384 },
    { src: 'instagram', views: 312 }, { src: 'whatsapp', views: 287 }, { src: 'linkedin', views: 186 },
  ],
  countries: [
    { code: 'SA', ar: 'السعودية', en: 'Saudi Arabia', views: 2841 },
    { code: 'AE', ar: 'الإمارات', en: 'UAE', views: 612 },
    { code: 'EG', ar: 'مصر', en: 'Egypt', views: 348 },
    { code: 'KW', ar: 'الكويت', en: 'Kuwait', views: 217 },
    { code: 'OTHER', ar: 'أخرى', en: 'Other', views: 200 },
  ],
};

export const SAMPLE_TEMPLATES = [
  { id: 'first-outreach', ar_title: 'تواصل أوّل', en_title: 'First outreach',
    ar_body: 'السلام عليكم،\nموقعكم رائع، لكنه يحتاج تحسينات بسيطة قد تزيد عدد العملاء.\nأعددت لكم تقريرًا مختصرًا — يسعدني مشاركته خلال ٥ دقائق.\n\n— عمر',
    en_body: 'Hi there,\nI had a quick look at your site and put together a short report with a few\nhigh-impact improvements. Happy to walk you through it in 5 minutes.\n\n— Omar' },
  { id: 'report-share', ar_title: 'مشاركة التقرير', en_title: 'Share the report',
    ar_body: 'صباح الخير،\nأرفقت لكم تقرير الموقع: الأداء، SEO، وسهولة الوصول، مع توصيات بالأولويات.\nأي ملاحظة بخدمتكم.\n\n— عمر',
    en_body: 'Good morning,\nAttached is your site audit — performance, SEO, accessibility, and a\nprioritised list of fixes. Let me know what you think.\n\n— Omar' },
  { id: 'follow-up', ar_title: 'متابعة', en_title: 'Follow-up',
    ar_body: 'أهلًا،\nسؤال سريع: هل أتممت قراءة التقرير؟ أحب أن أتفق معكم على أهم ٣ تحسينات نبدأ بها.\n\n— عمر',
    en_body: 'Hi,\nQuick nudge — did you get a chance to read the report? Happy to pick the\ntop 3 fixes to start with.\n\n— Omar' },
  { id: 'proposal', ar_title: 'عرض السعر', en_title: 'Proposal',
    ar_body: 'شكرًا على وقتكم،\nبناءً على التقرير، اقترح المرحلة الأولى: تحسين الأداء + SEO الأساسي،\nبسعر ثابت خلال أسبوعين. التفاصيل في الملف المرفق.\n\n— عمر',
    en_body: 'Thanks for your time.\nBased on the audit, I propose phase 1: performance + foundational SEO,\nfixed-price, 2 weeks. Details in the attached proposal.\n\n— Omar' },
];

export const scoreKind = (v) => (v >= 80 ? 'ok' : v >= 60 ? 'warn' : 'bad');
export const impactKind = (k) => (k === 'high' ? 'bad' : k === 'med' ? 'warn' : 'muted');
