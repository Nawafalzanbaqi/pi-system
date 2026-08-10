'use client';
// use-api.js — data hooks that map a real fetch lifecycle onto the prototype's
// viewState ('loading' | 'error' | 'empty' | 'ready'), 1:1. A screen never
// crashes on a failed call (apiFetch already normalises errors); 401/403 are
// surfaced as flags so the shell can prompt re-login / not-authorized.
import { useCallback, useEffect, useRef, useState } from 'react';

// Configurable refresh cadence for the live vitals (Overview status + health).
export const POLL_MS = (() => {
  const n = parseInt(process.env.NEXT_PUBLIC_CONTROL_PANEL_POLL_MS || '', 10);
  return Number.isFinite(n) && n >= 1000 ? n : 5000;
})();

export function usePolledResource(fetcher, { intervalMs = 0, enabled = true, isEmpty } = {}) {
  const fref = useRef(fetcher); fref.current = fetcher;
  const emptyRef = useRef(isEmpty); emptyRef.current = isEmpty;
  const mounted = useRef(true);
  const [s, setS] = useState({ state: 'loading', data: null, error: null, unauthorized: false, forbidden: false });

  const load = useCallback(async (silent = false) => {
    if (!enabled) { setS({ state: 'empty', data: null, error: null, unauthorized: false, forbidden: false }); return; }
    if (!silent) setS((p) => ({ ...p, state: p.data ? p.state : 'loading' }));
    const res = await fref.current();
    if (!mounted.current) return;
    if (res.unauthorized || res.forbidden) {
      setS({ state: 'error', data: null, error: res.error || 'not authorized', unauthorized: !!res.unauthorized, forbidden: !!res.forbidden });
      return;
    }
    if (!res.ok) { setS((p) => ({ state: 'error', data: p.data, error: res.error || 'request failed', unauthorized: false, forbidden: false })); return; }
    const empty = typeof emptyRef.current === 'function' && emptyRef.current(res.data);
    setS({ state: empty ? 'empty' : 'ready', data: res.data, error: null, unauthorized: false, forbidden: false });
  }, [enabled]);

  useEffect(() => { mounted.current = true; load(); return () => { mounted.current = false; }; }, [load]);
  useEffect(() => {
    if (!intervalMs || !enabled) return undefined;
    const id = setInterval(() => load(true), intervalMs);
    return () => clearInterval(id);
  }, [intervalMs, enabled, load]);

  return { ...s, refresh: () => load(false) };
}
