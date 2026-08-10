// bookings — tiny, self-contained bilingual labels for the booking UI.
// =============================================================================
// Deliberately SELF-CONTAINED: it does NOT import the i18n-bilingual module, so
// bookings composes on any base with or without i18n.
//   * WITH i18n-bilingual: the page passes the route's /<locale> down, and this
//     reads the same NEXT_PUBLIC_DEFAULT_LOCALE + `pi_locale` cookie i18n uses, so
//     the language stays in sync.
//   * WITHOUT it: it falls back to the scaffold default locale stamped below.
// Text direction (RTL for Arabic) is also derived here, but the document <html dir>
// is already set by the base / i18n root layout — the widget just mirrors itself.
// =============================================================================

export const BOOKINGS_DEFAULT_LOCALE =
  (typeof process !== 'undefined' && process.env.NEXT_PUBLIC_DEFAULT_LOCALE) || '__DEFAULT_LOCALE__';

const MESSAGES = {
  ar: {
    title: 'احجز موعدًا',
    chooseService: 'اختر الخدمة',
    chooseSlot: 'اختر الوقت المتاح',
    loading: 'جارٍ التحميل…',
    noSlots: 'لا توجد أوقات متاحة حاليًا.',
    pick: '— اختر —',
    name: 'الاسم',
    email: 'البريد الإلكتروني',
    phone: 'رقم الهاتف (اختياري)',
    notes: 'ملاحظات (اختياري)',
    submit: 'تأكيد الحجز',
    submitting: 'جارٍ الحجز…',
    success: 'تم استلام حجزك. رقم المرجع:',
    minutes: 'دقيقة',
    required: 'يرجى إدخال الاسم وبريد إلكتروني صحيح واختيار وقت.',
    unavailable: 'خدمة الحجوزات غير متاحة حاليًا. يرجى المحاولة لاحقًا.',
    slotTaken: 'هذا الوقت لم يعد متاحًا، يرجى اختيار وقت آخر.',
    noServices: 'لا توجد خدمات متاحة بعد.',
  },
  en: {
    title: 'Book an appointment',
    chooseService: 'Choose a service',
    chooseSlot: 'Choose an available time',
    loading: 'Loading…',
    noSlots: 'No available times right now.',
    pick: '— pick one —',
    name: 'Name',
    email: 'Email',
    phone: 'Phone (optional)',
    notes: 'Notes (optional)',
    submit: 'Confirm booking',
    submitting: 'Booking…',
    success: 'Your booking was received. Reference:',
    minutes: 'min',
    required: 'Please enter your name, a valid email and pick a time.',
    unavailable: 'The booking service is currently unavailable. Please try again later.',
    slotTaken: 'That time is no longer available — please pick another.',
    noServices: 'No services are available yet.',
  },
};

export function bookingsMessages(locale) {
  return MESSAGES[locale] || MESSAGES[BOOKINGS_DEFAULT_LOCALE] || MESSAGES.en;
}

export function bookingsDir(locale) {
  return locale === 'ar' ? 'rtl' : 'ltr';
}

// Resolve the active locale from an explicit value (the [locale] route param when
// i18n is present), else the pi_locale cookie, else the scaffold default. Always
// returns a supported locale ('ar' | 'en').
export function resolveLocale(explicit, cookieLocale) {
  const candidate = explicit || cookieLocale || BOOKINGS_DEFAULT_LOCALE;
  return candidate === 'ar' || candidate === 'en' ? candidate : 'en';
}
