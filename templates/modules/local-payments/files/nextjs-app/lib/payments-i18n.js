// local-payments — tiny, self-contained bilingual labels for the checkout UI.
// =============================================================================
// Deliberately SELF-CONTAINED: it does NOT import the i18n-bilingual module, so
// local-payments composes on any base with or without i18n.
//   * WITH i18n-bilingual: the page passes the route's /<locale> down, and this
//     reads the same NEXT_PUBLIC_DEFAULT_LOCALE + `pi_locale` cookie i18n uses.
//   * WITHOUT it: it falls back to the scaffold default locale stamped below.
// =============================================================================

export const PAYMENTS_DEFAULT_LOCALE =
  (typeof process !== 'undefined' && process.env.NEXT_PUBLIC_DEFAULT_LOCALE) || '__DEFAULT_LOCALE__';

const MESSAGES = {
  ar: {
    title: 'الدفع',
    amount: 'المبلغ',
    description: 'الوصف',
    pay: 'ادفع الآن',
    paying: 'جارٍ التحويل…',
    simulate: 'محاكاة دفعة ناجحة (وضع تجريبي)',
    simulating: 'جارٍ المحاكاة…',
    unavailable: 'خدمة الدفع غير متاحة حاليًا. يرجى المحاولة لاحقًا.',
    returnTitle: 'حالة الدفع',
    checking: 'جارٍ التحقق من حالة الدفع…',
    paid: 'تم الدفع بنجاح. شكرًا لك!',
    pending: 'الدفع قيد الانتظار.',
    failed: 'تعذّر إتمام الدفع.',
    reference: 'الرقم المرجعي:',
    notFound: 'لم يتم العثور على عملية الدفع.',
    backToCheckout: 'العودة إلى الدفع',
    sar: 'ر.س',
  },
  en: {
    title: 'Checkout',
    amount: 'Amount',
    description: 'Description',
    pay: 'Pay now',
    paying: 'Redirecting…',
    simulate: 'Simulate a successful payment (sandbox)',
    simulating: 'Simulating…',
    unavailable: 'The payment service is currently unavailable. Please try again later.',
    returnTitle: 'Payment status',
    checking: 'Checking payment status…',
    paid: 'Payment successful. Thank you!',
    pending: 'Payment is pending.',
    failed: 'The payment could not be completed.',
    reference: 'Reference:',
    notFound: 'Payment not found.',
    backToCheckout: 'Back to checkout',
    sar: 'SAR',
  },
};

export function paymentsMessages(locale) {
  return MESSAGES[locale] || MESSAGES[PAYMENTS_DEFAULT_LOCALE] || MESSAGES.en;
}

export function paymentsDir(locale) {
  return locale === 'ar' ? 'rtl' : 'ltr';
}

// Resolve the active locale from an explicit value (the [locale] route param when
// i18n is present), else the pi_locale cookie, else the scaffold default. Always
// returns a supported locale ('ar' | 'en').
export function resolveLocale(explicit, cookieLocale) {
  const candidate = explicit || cookieLocale || PAYMENTS_DEFAULT_LOCALE;
  return candidate === 'ar' || candidate === 'en' ? candidate : 'en';
}

// Format a minor-unit amount (e.g. halalas) as a major-unit string (e.g. 10.00).
export function formatAmount(amountMinor) {
  const n = Number(amountMinor || 0) / 100;
  return n.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}
