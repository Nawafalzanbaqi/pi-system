// ===========================================================================
// pi-system Control API — bounded in-memory TTL CACHE (PURE core + tiny store)
// ---------------------------------------------------------------------------
// A small, bounded, time-to-live cache for the READ-ONLY data feeds (Monitoring /
// Growth). The panel polls these every few seconds, often from several widgets/tabs
// at once; without a cache each poll is a fresh SSH round-trip to the host. This
// coalesces repeated reads within a short TTL into ONE host call.
//
// It caches ONLY non-secret, HOST-GLOBAL read RESULTS (the same data every operator
// sees) — never writes, never anything per-identity — so the key is the action's argv,
// NOT the caller. It is SIZE-bounded (the oldest entry is evicted past the cap) and is
// trivially disabled by setting the TTL to 0. Authorization + rate limiting still run on
// every request BEFORE the cache is consulted, so the cache never bypasses a check.
//
// cacheGet/cacheSet are PURE (state in -> state out) so they are fully testable; the
// module-level Map is the runtime store, mirroring lib/ratelimit.js.
// ===========================================================================

// cacheGet(state, key, now) -> { hit, value }
// A miss (absent or expired) returns { hit:false }. Pure: it does not mutate state — an
// expired entry is simply reported as a miss and overwritten on the next cacheSet.
export function cacheGet(state, key, now) {
  const e = state.get(key);
  if (!e) return { hit: false };
  if (now >= e.expiresAt) return { hit: false };
  return { hit: true, value: e.value };
}

// cacheSet(state, key, value, now, { ttlMs, maxEntries }) -> state (mutated + returned)
// Stores value with an expiry; enforces the size bound by evicting the OLDEST inserted
// entry (a Map preserves insertion order) once over capacity. Re-inserting an existing
// key refreshes both its value and its recency.
export function cacheSet(state, key, value, now, { ttlMs, maxEntries = 64 }) {
  state.delete(key);                 // re-insert so this key becomes the most-recent
  state.set(key, { value, expiresAt: now + ttlMs });
  const cap = maxEntries > 0 ? maxEntries : 64;
  while (state.size > cap) {
    const oldest = state.keys().next().value;
    if (oldest === undefined) break;
    state.delete(oldest);
  }
  return state;
}

// --- Runtime singleton store ----------------------------------------------
const _store = new Map();

export function readCacheGet(key) { return cacheGet(_store, key, Date.now()); }
export function readCacheSet(key, value, opts) { return cacheSet(_store, key, value, Date.now(), opts); }
// Test/maintenance helper: empty the singleton store.
export function readCacheClear() { _store.clear(); }
