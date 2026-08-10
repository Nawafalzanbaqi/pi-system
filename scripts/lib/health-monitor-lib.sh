# shellcheck shell=bash
# ===========================================================================
# pi-system — host HEALTH-MONITOR library (pure logic + mockable seams)
# ---------------------------------------------------------------------------
# SOURCED by scripts/health-monitor.sh and by the test harness in
# tests/health-monitor/. It mirrors scripts/lib/preflight-lib.sh and
# scripts/lib/mem-budget-lib.sh exactly in spirit:
#
#   1. PURE functions — parse the raw text the Pi's sensors / df / free /
#      `docker stats` emit, and turn a measured value + thresholds into a
#      PASS / WARN / FAIL verdict. They take their inputs as arguments (or read
#      a given string), so the tests verify the parsing AND the threshold math
#      WITHOUT a real Pi, Docker, or root.
#
#   2. SEAM functions — thin wrappers around the only live inputs (the thermal
#      sensor, vcgencmd, df, du, free, `docker stats`). A test redefines any of
#      these to feed a fixture, so the same logic runs offline and on the Pi.
#
# DESIGN RULES (kept identical to the other two libs so they feel the same):
#   * READ-ONLY: nothing here starts/stops a container, writes a secret, or
#     mutates host/service state. It only reads sensors and runs read-only
#     `docker stats`. It never prints a secret (it reads none).
#   * NO `set -e` here — this is a library; the entrypoint owns shell options.
#   * Classifier functions print their verdict to stdout and `return 0`, so a
#     caller's `set -e` is never tripped by a verdict that happens to be FAIL.
#   * DEGRADE GRACEFULLY: a sensor that does not exist (e.g. running on a non-Pi
#     dev box, or no Docker) yields SKIP, never a hard crash or a false FAIL.
# ===========================================================================

# Guard against double-sourcing (the entrypoint and tests may both source it).
if [[ -n "${HM_LIB_SOURCED:-}" ]]; then return 0 2>/dev/null || true; fi
HM_LIB_SOURCED=1

# ---------------------------------------------------------------------------
# Verdict vocabulary. Severity order (worst wins when folding many sub-checks
# into one): FAIL > WARN > PASS > SKIP. SKIP means "could not measure here"
# (no sensor / no Docker) — it must never, on its own, look like a problem.
# ---------------------------------------------------------------------------
readonly HM_PASS="PASS"
readonly HM_WARN="WARN"
readonly HM_FAIL="FAIL"
readonly HM_SKIP="SKIP"

# Numeric severity of a verdict (higher = worse). Unknown => treated as WARN.
hm_severity() {
  case "$1" in
    "${HM_SKIP}") echo 0 ;;
    "${HM_PASS}") echo 1 ;;
    "${HM_WARN}") echo 2 ;;
    "${HM_FAIL}") echo 3 ;;
    *)            echo 2 ;;
  esac
}

# Fold two verdicts, returning the worse of the two (FAIL>WARN>PASS>SKIP).
hm_worst() {
  local a="$1" b="$2"
  if (( $(hm_severity "${a}") >= $(hm_severity "${b}") )); then echo "${a}"; else echo "${b}"; fi
}

# ===========================================================================
# SECTION 1 — PURE parsers / classifiers (the heart of the test surface)
# ===========================================================================

# --- Generic "more is worse" classifier (temperature, disk %, memory %) ----
# VALUE >= FAIL_AT => FAIL; VALUE >= WARN_AT => WARN; otherwise PASS.
# All three are plain integers in the same unit. A non-numeric VALUE => WARN
# (we measured something we cannot read — a soft problem, never a false FAIL).
hm_classify_high() {
  local v="$1" warn_at="$2" fail_at="$3"
  if ! [[ "${v}" =~ ^[0-9]+$ ]]; then echo "${HM_WARN}"; return 0; fi
  if   (( v >= fail_at )); then echo "${HM_FAIL}"
  elif (( v >= warn_at )); then echo "${HM_WARN}"
  else                          echo "${HM_PASS}"
  fi
}

# --- CPU temperature -------------------------------------------------------
# The Pi exposes its SoC temperature two ways; both parsers floor to whole °C
# so the verdict math stays in integers (matching the rest of the platform).

# `vcgencmd measure_temp` prints e.g.  temp=47.2'C  -> 47
hm_parse_vcgencmd_temp() {
  local raw="${1:-}" num
  [[ "${raw}" =~ temp=([0-9]+)(\.[0-9]+)?\'?C ]] || return 1
  num="${BASH_REMATCH[1]}"
  echo "${num}"
  return 0
}

# /sys/class/thermal/thermal_zone0/temp prints milli-°C e.g.  47234  -> 47
hm_parse_thermal_zone() {
  local raw="${1:-}"
  raw="${raw//[[:space:]]/}"
  [[ "${raw}" =~ ^-?[0-9]+$ ]] || return 1
  echo $(( raw / 1000 ))
  return 0
}

# --- Pi throttling flags ---------------------------------------------------
# `vcgencmd get_throttled` prints  throttled=0x<hex>  whose bits mean:
#   bit  0  under-voltage NOW          bit 16  under-voltage has OCCURRED
#   bit  1  ARM frequency capped NOW   bit 17  freq-cap has OCCURRED
#   bit  2  currently THROTTLED        bit 18  throttling has OCCURRED
#   bit  3  soft temp limit NOW        bit 19  soft-temp-limit has OCCURRED
# An active ("now") bit is a real, present problem  -> FAIL.
# Only-historical ("occurred") bits mean it happened before but is fine now
# (worth knowing — bad PSU / hot spell)  -> WARN.  0x0 -> PASS.
HM_THROTTLE_NOW_MASK=$(( 0xF ))       # bits 0..3
HM_THROTTLE_PAST_MASK=$(( 0xF0000 ))  # bits 16..19

# Normalise the raw line to an integer; echoes the decimal value, or returns 1.
hm_throttled_value() {
  local raw="${1:-}" hex
  raw="${raw#*=}"; raw="${raw//[[:space:]]/}"
  [[ -n "${raw}" ]] || return 1
  if [[ "${raw}" =~ ^0[xX]([0-9a-fA-F]+)$ ]]; then hex="${BASH_REMATCH[1]}"
  elif [[ "${raw}" =~ ^[0-9a-fA-F]+$ ]];      then hex="${raw}"
  else return 1; fi
  echo $(( 16#${hex} ))
  return 0
}

hm_classify_throttled() {
  local val
  val="$(hm_throttled_value "${1:-}")" || { echo "${HM_SKIP}"; return 0; }
  if   (( val & HM_THROTTLE_NOW_MASK ));  then echo "${HM_FAIL}"
  elif (( val & HM_THROTTLE_PAST_MASK )); then echo "${HM_WARN}"
  else                                         echo "${HM_PASS}"
  fi
  return 0
}

# Human reasons for a throttled value (one short phrase per set bit), so the
# report can say WHY. Empty output means "nothing flagged".
hm_throttled_reasons() {
  local val
  val="$(hm_throttled_value "${1:-}")" || return 0
  (( val & (1<<0)  )) && printf 'under-voltage (now); '
  (( val & (1<<1)  )) && printf 'ARM frequency capped (now); '
  (( val & (1<<2)  )) && printf 'currently throttled; '
  (( val & (1<<3)  )) && printf 'soft temperature limit (now); '
  (( val & (1<<16) )) && printf 'under-voltage has occurred; '
  (( val & (1<<17) )) && printf 'frequency cap has occurred; '
  (( val & (1<<18) )) && printf 'throttling has occurred; '
  (( val & (1<<19) )) && printf 'soft temp limit has occurred; '
  return 0
}

# --- Disk usage ------------------------------------------------------------
# Parse the data line of `df -P <path>` (POSIX format guarantees ONE physical
# line per entry). We index from the RIGHT, because the last five fields are
# always:  <1K-blocks> <Used> <Available> <Capacity%> <Mounted-on>  — robust
# even when the Filesystem source contains spaces (which would split into extra
# leading fields). Capacity% = NF-1 (strip the %), Available = NF-2, Used = NF-3.
hm_parse_df_pct() {
  awk 'NR==2 { p=$(NF-1); gsub(/%/,"",p); print p; found=1 } END { if(!found) exit 1 }'
}
hm_parse_df_avail_kb() { awk 'NR==2 {print $(NF-2); found=1} END{ if(!found) exit 1 }'; }
hm_parse_df_used_kb()  { awk 'NR==2 {print $(NF-3); found=1} END{ if(!found) exit 1 }'; }

# Given "label<TAB>bytes" lines on stdin, echo the label with the most bytes
# (the dominant consumer). Ties resolve to the first seen. Empty input => "".
hm_largest() {
  awk -F'\t' '
    { if ($2 ~ /^[0-9]+$/ && $2+0 > max) { max=$2+0; lbl=$1 } }
    END { print lbl }
  '
}

# Integer percentage A is of B (floored). B<=0 => 0 (avoids divide-by-zero).
hm_pct_of() {
  local a="$1" b="$2"
  [[ "${a}" =~ ^[0-9]+$ && "${b}" =~ ^[0-9]+$ ]] || { echo 0; return 0; }
  (( b <= 0 )) && { echo 0; return 0; }
  echo $(( a * 100 / b ))
}

# --- Live memory & swap ----------------------------------------------------
# Read one field from a `free` table (any unit; we only do ratios). ROW is the
# row label without the colon (Mem|Swap); COL is total|used|free|available.
# Swap has no "available" column -> echoes "" for it. Missing row -> returns 1.
hm_free_field() {
  local row="$1" col="$2"
  awk -v row="${row}:" -v col="${col}" '
    $1==row {
      # free column order: total used free shared buff/cache available
      if      (col=="total")     print $2;
      else if (col=="used")      print $3;
      else if (col=="free")      print $4;
      else if (col=="shared")    print $5;
      else if (col=="available") print $7;
      found=1; exit
    }
    END { if(!found) exit 1 }
  '
}

# Memory pressure verdict from total + available (both same unit). We classify
# on USED% = (total-available)/total, which is the figure that matters on a Pi
# (available accounts for reclaimable cache). total<=0 => SKIP (unreadable).
hm_classify_mem() {
  local total="$1" avail="$2" warn_at="$3" fail_at="$4" usedpct
  [[ "${total}" =~ ^[0-9]+$ && "${avail}" =~ ^[0-9]+$ ]] || { echo "${HM_SKIP}"; return 0; }
  (( total <= 0 )) && { echo "${HM_SKIP}"; return 0; }
  usedpct=$(( (total - avail) * 100 / total ))
  (( usedpct < 0 )) && usedpct=0
  hm_classify_high "${usedpct}" "${warn_at}" "${fail_at}"
}

# Swap verdict from total + used. Heavy swap on a Pi (SD/SSD-backed) means RAM
# pressure / thrashing, so it is "more is worse". total<=0 => PASS: a box with
# NO swap configured is not a problem (it just has no swap to be full).
hm_classify_swap() {
  local total="$1" used="$2" warn_at="$3" fail_at="$4" usedpct
  [[ "${total}" =~ ^[0-9]+$ && "${used}" =~ ^[0-9]+$ ]] || { echo "${HM_SKIP}"; return 0; }
  (( total <= 0 )) && { echo "${HM_PASS}"; return 0; }
  usedpct=$(( used * 100 / total ))
  hm_classify_high "${usedpct}" "${warn_at}" "${fail_at}"
}

# --- Container resource usage (`docker stats --no-stream`) -----------------
# Convert one `docker stats` size token to integer MiB. Docker formats these
# with binary units (B, KiB, MiB, GiB, TiB); we also tolerate the decimal
# spellings (kB, MB, GB, TB) just in case. Floors. Unparseable => returns 1.
hm_size_to_mib() {
  local raw="${1:-}" num unit mult
  raw="${raw//[[:space:]]/}"
  [[ "${raw}" =~ ^([0-9]+(\.[0-9]+)?)([A-Za-z]+)$ ]] || return 1
  num="${BASH_REMATCH[1]}"; unit="${BASH_REMATCH[3],,}"
  case "${unit}" in
    b)            mult="0.00000095367431640625" ;;  # 1/1048576
    kb|kib)       mult="0.0009765625" ;;            # 1/1024
    mb|mib)       mult="1" ;;
    gb|gib)       mult="1024" ;;
    tb|tib)       mult="1048576" ;;
    *)            return 1 ;;
  esac
  awk -v n="${num}" -v m="${mult}" 'BEGIN { printf "%d", n*m }'
  return 0
}

# From a `docker stats` MemUsage cell "412MiB / 768MiB" pull each side in MiB.
hm_stats_used_mib()  { hm_size_to_mib "${1%%/*}"; }
hm_stats_limit_mib() { local r="${1#*/}"; hm_size_to_mib "${r}"; }

# Percentage cell "53.65%" -> integer 53 (floored). Bad input => returns 1.
hm_pct_int() {
  local raw="${1:-}"
  raw="${raw//[[:space:]]/}"; raw="${raw%\%}"
  [[ "${raw}" =~ ^([0-9]+)(\.[0-9]+)?$ ]] || return 1
  echo "${BASH_REMATCH[1]}"
  return 0
}

# Normalise raw `docker stats` lines on stdin into tidy rows. Each input line is
# TAB-separated:  NAME <TAB> MEMUSAGE <TAB> MEMPERC <TAB> CPUPERC
# (the exact --format the entrypoint requests). Emits, per line:
#   name <TAB> used_mib <TAB> limit_mib <TAB> mempct_int <TAB> cpupct_int
# Unreadable fields become 0 so the row still sorts/classifies safely.
hm_stats_rows() {
  local name musage mperc cperc used limit mp cp
  while IFS=$'\t' read -r name musage mperc cperc; do
    [[ -n "${name}" ]] || continue
    used="$(hm_stats_used_mib "${musage}" 2>/dev/null || echo 0)"
    limit="$(hm_stats_limit_mib "${musage}" 2>/dev/null || echo 0)"
    mp="$(hm_pct_int "${mperc}" 2>/dev/null || echo 0)"
    cp="$(hm_pct_int "${cperc}" 2>/dev/null || echo 0)"
    printf '%s\t%s\t%s\t%s\t%s\n' "${name}" "${used:-0}" "${limit:-0}" "${mp:-0}" "${cp:-0}"
  done
}

# Worst container memory verdict, reading tidy rows (from hm_stats_rows) on
# stdin and classifying each row's mempct as "more is worse". A container at or
# above WARN% of its own limit is "near its limit". No rows => SKIP.
hm_containers_verdict() {
  local warn_at="$1" fail_at="$2"
  awk -F'\t' -v w="${warn_at}" -v f="${fail_at}" '
    { rows++
      mp=$4+0
      if (mp>=f)      { v=3 }
      else if (mp>=w) { if (v<2) v=2 }
      else            { if (v<1) v=1 }
    }
    END {
      if (rows==0)   { print "SKIP"; exit }
      if (v>=3)      { print "FAIL"; exit }
      if (v>=2)      { print "WARN"; exit }
      print "PASS"
    }'
}

# List the containers AT OR ABOVE warn% of their limit, "name (mempct%)" each,
# reading tidy rows on stdin. Used to name the offenders in the report.
hm_containers_near_limit() {
  local warn_at="$1"
  awk -F'\t' -v w="${warn_at}" '$4+0 >= w { printf "%s (%s%%)\n", $1, $4 }'
}

# ===========================================================================
# SECTION 2 — Notifier DECISION logic (pure; the test surface for alerting)
# ===========================================================================

# Should an alert fire for this overall verdict? Returns 0 (yes) ONLY for WARN
# or FAIL — PASS and SKIP are silent. This is the single rule the scheduled run
# uses to decide whether to touch the notifier, so a PASS is never noisy.
hm_should_notify() {
  case "$1" in
    "${HM_WARN}"|"${HM_FAIL}") return 0 ;;
    *)                         return 1 ;;
  esac
}

# Map a verdict to an Uptime-Kuma push status. A FAIL is "down" (page me);
# WARN and PASS are "up" (the heartbeat still lands, carrying the verdict in its
# message, so a WARN is visible without being treated as an outage). SKIP also
# reports "up" (we simply could not measure on this host).
hm_kuma_status() {
  case "$1" in
    "${HM_FAIL}") echo "down" ;;
    *)            echo "up" ;;
  esac
}

# Sanitise an arbitrary string into a short, URL-safe slug for a Kuma "msg="
# query param (mirrors do-backup.sh). Never carries a secret — callers only
# pass the verdict + counts.
hm_slug() {
  local s="${1:-}"
  s="${s//[^A-Za-z0-9]/-}"
  s="${s:0:80}"
  printf '%s' "${s}"
}

# ===========================================================================
# SECTION 3 — SEAMS (the only live inputs; redefined by tests to feed fixtures)
# ===========================================================================

# Is a command available on PATH?
hm_have_cmd() { command -v "$1" >/dev/null 2>&1; }

# Raw thermal-zone reading (milli-°C) or empty if the sysfs node is absent.
hm_read_thermal_zone() {
  local node="${HM_THERMAL_ZONE:-/sys/class/thermal/thermal_zone0/temp}"
  [[ -r "${node}" ]] && cat "${node}" 2>/dev/null || true
}

# Raw `vcgencmd measure_temp` / `get_throttled` output, or empty if no vcgencmd.
hm_vcgencmd_temp()      { hm_have_cmd vcgencmd && vcgencmd measure_temp  2>/dev/null || true; }
hm_vcgencmd_throttled() { hm_have_cmd vcgencmd && vcgencmd get_throttled 2>/dev/null || true; }

# Raw `df -P PATH` (POSIX 1K-block format). READ-ONLY.
hm_df() { df -P "$1" 2>/dev/null || true; }

# Apparent size of a directory in bytes (for "what is filling the disk"). Uses
# -s -b; empty if the path is missing/unreadable. READ-ONLY.
hm_du_bytes() {
  local path="$1"
  [[ -e "${path}" ]] || { printf ''; return 0; }
  du -sb "${path}" 2>/dev/null | awk '{print $1; exit}' || true
}

# Raw `free` table (default unit is fine — we only take ratios). READ-ONLY.
hm_free() { free 2>/dev/null || true; }

# Is the Docker daemon reachable for a read-only `stats`?
hm_docker_available() { hm_have_cmd docker && docker info >/dev/null 2>&1; }

# One-shot `docker stats` as TAB-separated NAME/MEMUSAGE/MEMPERC/CPUPERC lines.
# --no-stream takes a single sample and exits (no always-on watcher). READ-ONLY.
hm_docker_stats() {
  docker stats --no-stream \
    --format '{{.Name}}'$'\t''{{.MemUsage}}'$'\t''{{.MemPerc}}'$'\t''{{.CPUPerc}}' \
    2>/dev/null || true
}
