// ===========================================================================
// pi-system Control API — in-memory RATE LIMITER (PURE core + tiny store)
// ---------------------------------------------------------------------------
// Throttles the STATE-CHANGING and CONFIG-WRITING endpoints (a fixed-window
// counter per identity). Lightweight on purpose — no Redis, no extra container;
// the API is a single low-traffic operator tool. checkRate() is PURE (state in ->
// state out) so it is fully testable; the module-level Map is the runtime store.
// ===========================================================================

// checkRate(state, key, now, { windowMs, max })
//   state: a plain object map { key -> { count, resetAt } } (mutated + returned).
//   -> { allowed: boolean, remaining, retryAfterSec, state }
export function checkRate(state, key, now, { windowMs, max }) {
  const e = state[key];
  if (!e || now >= e.resetAt) {
    state[key] = { count: 1, resetAt: now + windowMs };
    return { allowed: true, remaining: max - 1, retryAfterSec: 0, state };
  }
  if (e.count >= max) {
    return {
      allowed: false,
      remaining: 0,
      retryAfterSec: Math.max(1, Math.ceil((e.resetAt - now) / 1000)),
      state,
    };
  }
  e.count += 1;
  return { allowed: true, remaining: max - e.count, retryAfterSec: 0, state };
}

// --- Runtime singleton store ----------------------------------------------
const _store = Object.create(null);

export function consume(key, opts) {
  return checkRate(_store, key, Date.now(), opts);
}
