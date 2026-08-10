#!/usr/bin/env bash
# pi-system — portable single-flight LOCK helpers (sourced; safe to source twice).
# ===========================================================================
# Guarantees only ONE instance of a named host operation (e.g. an SEO audit, a prospect
# analysis) runs at a time, so a SCHEDULED run and a MANUAL run — or two scheduled runs
# — can never overlap and clobber the same store / interleave the same JSONL appends.
#
# Mechanism: an ATOMIC `mkdir` lock (POSIX-portable; works with OR without flock(1),
# including dev boxes that lack flock). The holder records its PID + a start timestamp
# inside the lock dir, so a STALE lock — the holder died, or the lock is older than the
# max age — is safely RECLAIMED on the next attempt. A crash can never wedge runs forever.
#
# NON-BLOCKING by design: if the lock is held by a LIVE, fresh holder, acquisition FAILS
# (returns non-zero) so the caller SKIPS this run. That IS the single-flight contract —
# one runs, the rest bow out (a clean skip, not an error).
#
# Usage:
#   . scripts/lib/lock-lib.sh
#   if lock_acquire "${DATA_DIR}/audit.lock"; then
#     trap 'lock_release "${DATA_DIR}/audit.lock"' EXIT
#     ... critical section ...
#   else
#     echo "another run is in progress — skipping"; exit 0
#   fi
# ===========================================================================

# Max seconds a lock may be held before it is considered stale and reclaimable, even if
# its PID still looks alive (guards against PID reuse wedging the lock). Override with
# PI_LOCK_MAX_AGE. An audit/analysis run is expected to finish well within this.
: "${PI_LOCK_MAX_AGE:=3600}"

# _lock_now: current epoch seconds (date is universally available; 0 on the rare failure).
_lock_now() { date +%s 2>/dev/null || echo 0; }

_lock_write_meta() {
  local dir="$1"
  printf '%s\n' "$$" > "${dir}/pid" 2>/dev/null || true
  printf '%s\n' "$(_lock_now)" > "${dir}/start" 2>/dev/null || true
}

# _lock_is_stale <dir> -> 0 (true) if the lock is reclaimable: metadata is unreadable
# (an aborted acquire), OR the holder PID is dead, OR the lock is older than the max age.
_lock_is_stale() {
  local dir="$1" pid start now age
  pid="$(cat "${dir}/pid" 2>/dev/null || true)"
  start="$(cat "${dir}/start" 2>/dev/null || true)"
  [[ -z "${pid}" ]] && return 0                       # no/partial metadata -> stale
  if ! kill -0 "${pid}" 2>/dev/null; then return 0; fi # holder process is gone -> stale
  if [[ -n "${start}" ]]; then                         # even a live (maybe reused) PID
    now="$(_lock_now)"; age=$(( now - start ))         # cannot hold past the max age
    if (( age > PI_LOCK_MAX_AGE )); then return 0; fi
  fi
  return 1
}

# lock_acquire <lockfile> -> 0 if acquired (caller MUST lock_release), non-zero if held
# by a live, fresh holder. The `mkdir` is the atomic primitive (only one racer wins).
lock_acquire() {
  local lock="$1" dir; dir="${lock}.d"
  mkdir -p "$(dirname "${lock}")" 2>/dev/null || true
  if mkdir "${dir}" 2>/dev/null; then
    _lock_write_meta "${dir}"; return 0
  fi
  # Held — reclaim only if the current holder is stale, then retry the atomic create once.
  if _lock_is_stale "${dir}"; then
    rm -rf "${dir}" 2>/dev/null || true
    if mkdir "${dir}" 2>/dev/null; then
      _lock_write_meta "${dir}"; return 0
    fi
  fi
  return 1
}

# lock_release <lockfile> — release ONLY if THIS process owns it, so a run that already
# reclaimed the lock from us (after we were declared stale) is never torn down by us.
lock_release() {
  local lock="$1" dir owner; dir="${lock}.d"
  owner="$(cat "${dir}/pid" 2>/dev/null || true)"
  if [[ -z "${owner}" || "${owner}" == "$$" ]]; then
    rm -rf "${dir}" 2>/dev/null || true
  fi
}
