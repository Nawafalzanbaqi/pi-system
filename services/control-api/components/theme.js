// theme.js — the design system's SINGLE SOURCE OF TRUTH.
// ---------------------------------------------------------------------------
// STYLING APPROACH (chosen + justified): the prototype expresses its entire
// visual language as one TOKENS object consumed through inline style objects.
// We keep exactly that — TOKENS here is the one place colours/elevation live —
// rather than re-expressing 6k lines of styling in Tailwind. Reasons:
//   * faithful port: the look/spacing/animation stay byte-for-byte the design's,
//     so we "port, don't redesign" (the hard constraint);
//   * one source of truth: a second styling system (Tailwind classes) would
//     fragment it and invite drift between AR/EN, light/dark;
//   * theming is a prop (t = TOKENS[theme]) threaded everywhere, which makes the
//     light/dark flip and the per-component logic trivial and testable.
// Document-level concerns (fonts, body bg, RTL, keyframes) live in globals.css.
// Font families resolve to the next/font CSS variables, with system fallbacks so
// the panel is legible even before the web fonts load (or if a build is offline).

export const TOKENS = {
  light: {
    bg:        '#fafaf9',
    panel:     '#ffffff',
    panelAlt:  '#f5f5f3',
    border:    '#e8e6e0',
    borderSoft:'#efede8',
    ink:       '#18181b',
    inkSoft:   '#52525b',
    inkMuted:  '#a1a1aa',
    ok:        'oklch(0.62 0.10 155)',
    okSoft:    'oklch(0.94 0.04 155)',
    warn:      'oklch(0.74 0.13 75)',
    warnSoft:  'oklch(0.95 0.05 75)',
    bad:       'oklch(0.60 0.18 27)',
    badSoft:   'oklch(0.95 0.04 27)',
    accent:    'oklch(0.50 0.10 250)',
    accentSoft:'oklch(0.95 0.03 250)',
  },
  dark: {
    bg:        '#0b0b0c',
    panel:     '#131315',
    panelAlt:  '#19191c',
    border:    '#232327',
    borderSoft:'#1c1c1f',
    ink:       '#f4f4f5',
    inkSoft:   '#a1a1aa',
    inkMuted:  '#52525b',
    ok:        'oklch(0.74 0.13 155)',
    okSoft:    'oklch(0.28 0.08 155)',
    warn:      'oklch(0.82 0.14 75)',
    warnSoft:  'oklch(0.30 0.10 75)',
    bad:       'oklch(0.72 0.18 27)',
    badSoft:   'oklch(0.28 0.12 27)',
    accent:    'oklch(0.72 0.12 250)',
    accentSoft:'oklch(0.28 0.07 250)',
  },
};

export const F_AR = "var(--font-ar), 'IBM Plex Sans Arabic', 'Reem Kufi', system-ui, sans-serif";
export const F_EN = "var(--font-en), 'Inter', system-ui, sans-serif";
export const F_MONO = "var(--font-mono), 'JetBrains Mono', ui-monospace, monospace";

export const isDark = (t) => t.bg === '#0b0b0c';

export function useTokens(theme) { return TOKENS[theme] || TOKENS.light; }

// Map a service/health state word to a token "kind". Shared by Overview's
// service grid, Projects cards and Monitoring so thresholds stay consistent.
export const stateToKind = (s) =>
  s === 'running' || s === 'healthy' || s === 'up' || s === 'pass' ? 'ok'
  : s === 'unhealthy' || s === 'degraded' || s === 'warn' ? 'warn'
  : s === 'down' || s === 'stopped' || s === 'fail' || s === 'bad' ? 'bad'
  : 'muted';

export const colorForKind = (kind, t) =>
  kind === 'warn' ? t.warn : kind === 'bad' ? t.bad : kind === 'muted' ? t.inkMuted : t.ok;
