#!/usr/bin/env bash
# ===========================================================================
# pi-system — PANEL READ helper  (READ-ONLY data exposure for the control panel)
# ---------------------------------------------------------------------------
# The Control API's Monitoring + Growth views need the data the platform's own
# producers already write to disk. This helper is the ONE read-only door to that
# data: it READS the existing status/log/store files and prints a small JSON
# envelope on stdout. It NEVER mutates anything — only `cat`/`tail` of data files
# (plus a read-only `docker stats --no-stream` snapshot for current per-container
# memory). There is no write, no start/stop, no config change, no `eval`.
#
# It is reached ONLY through the audited bot-exec bridge, which whitelists these
# as READ-ONLY actions and runs this script as an ARGV array over the SSH forced
# command (no Docker socket given to the API). This script re-validates the
# subcommand against its own fixed allowlist (defence in depth).
#
#   SUBCOMMANDS (anything else is refused):
#     monitor_metrics   data/health/last-health.json + tail of health.log
#                       + current per-container memory (docker stats, read-only)
#     monitor_alerts    recent health.log lines + the current last-alert.txt
#     backup_status     data/backups/status/{last-backup,last-verify}.json
#     seo_audits        tail of each data/seo/audits/<name>.jsonl
#     prospects_list    data/prospects/prospects.json (verbatim)
#
# A MISSING source file is NOT an error — the field is emitted as null / [] so the
# panel shows an honest empty state (never a 500). Output is always valid JSON.
#
# ENV: PANEL_DATA_DIR overrides the data root (tests point it at a fixture dir).
# Exit codes: 0 success (incl. missing data), 2 = unknown/missing subcommand.
# Run from anywhere — paths resolve relative to the project root.
# ===========================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

DATA_DIR="${PANEL_DATA_DIR:-${PROJECT_ROOT}/data}"
HEALTH_DIR="${DATA_DIR}/health"
BACKUP_STATUS_DIR="${DATA_DIR}/backups/status"
SEO_AUDITS_DIR="${DATA_DIR}/seo/audits"
PROSPECTS_FILE="${DATA_DIR}/prospects/prospects.json"

# How many trailing lines of the history/log to surface (bounds the payload).
HISTORY_LINES="${PANEL_HISTORY_LINES:-800}"
SEO_LINES="${PANEL_SEO_LINES:-60}"

err() { printf '[panel-read][error] %s\n' "$*" >&2; }

# --- Tiny, safe JSON emitters (no jq; sources are already JSON) -------------
# Emit a JSON file verbatim if it exists and is non-empty, else the literal null.
# (We trust our own producers' JSON; we never reformat it.)
json_file_or_null() { local f="$1"; if [[ -s "${f}" ]]; then cat -- "${f}"; else printf 'null'; fi; }

# Escape one line for embedding inside a JSON string (backslash, quote, tab).
json_escape() { local s="${1-}"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\t'/ }"; printf '%s' "${s}"; }

# Emit the last N non-empty lines of a text file as a JSON array of strings.
emit_lines_array() {  # emit_lines_array <file> <n>
  local f="$1" n="$2" first=1 line
  printf '['
  if [[ -s "${f}" ]]; then
    while IFS= read -r line; do
      [[ -n "${line}" ]] || continue
      (( first )) || printf ','; first=0
      printf '"%s"' "$(json_escape "${line}")"
    done < <(tail -n "${n}" -- "${f}" 2>/dev/null || true)
  fi
  printf ']'
}

# Coerce to a JSON number, or 0 if not numeric (so the envelope never breaks).
numify() { [[ "${1-}" =~ ^[0-9]+([.][0-9]+)?$ ]] && printf '%s' "$1" || printf '0'; }

# Current per-container memory as a JSON array, via a READ-ONLY docker stats
# snapshot. Reuses the health-monitor lib's robust MemUsage parser. If Docker is
# not available it is simply an empty array (honest empty state). No history is
# persisted per container, so this is the CURRENT level only.
emit_perservice() {
  printf '['
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    local rows first=1 name used limit mp cp
    rows="$( { source "${SCRIPT_DIR}/lib/health-monitor-lib.sh"; hm_docker_stats | hm_stats_rows; } 2>/dev/null || true )"
    while IFS=$'\t' read -r name used limit mp cp; do
      [[ -n "${name}" ]] || continue
      (( first )) || printf ','; first=0
      printf '{"name":"%s","memMiB":%s,"limitMiB":%s,"pct":%s,"cpuPct":%s}' \
        "$(json_escape "${name}")" "$(numify "${used:-0}")" "$(numify "${limit:-0}")" \
        "$(numify "${mp:-0}")" "$(numify "${cp:-0}")"
    done <<< "${rows}"
  fi
  printf ']'
}

# Concatenate the last N records of every per-site SEO audit JSONL into one JSON
# array. Each line is already a complete audit object (carries its own `name` +
# `timestamp`), so the adapter groups by site itself.
emit_seo_audits() {
  printf '{"audits":['
  local first=1 f line
  shopt -s nullglob
  for f in "${SEO_AUDITS_DIR}"/*.jsonl; do
    while IFS= read -r line; do
      [[ -n "${line}" ]] || continue
      (( first )) || printf ','; first=0
      printf '%s' "${line}"
    done < <(tail -n "${SEO_LINES}" -- "${f}" 2>/dev/null || true)
  done
  shopt -u nullglob
  printf ']}'
}

SUB="${1:-}"
case "${SUB}" in
  monitor_metrics)
    printf '{"lastHealth":'; json_file_or_null "${HEALTH_DIR}/last-health.json"
    printf ',"history":';    emit_lines_array "${HEALTH_DIR}/health.log" "${HISTORY_LINES}"
    printf ',"perService":'; emit_perservice
    printf '}\n'
    ;;
  monitor_alerts)
    printf '{"history":'; emit_lines_array "${HEALTH_DIR}/health.log" "${HISTORY_LINES}"
    printf ',"alert":';   emit_lines_array "${HEALTH_DIR}/last-alert.txt" 100
    printf '}\n'
    ;;
  backup_status)
    printf '{"lastBackup":'; json_file_or_null "${BACKUP_STATUS_DIR}/last-backup.json"
    printf ',"lastVerify":'; json_file_or_null "${BACKUP_STATUS_DIR}/last-verify.json"
    printf '}\n'
    ;;
  seo_audits)
    emit_seo_audits; printf '\n'
    ;;
  prospects_list)
    json_file_or_null "${PROSPECTS_FILE}"; printf '\n'
    ;;
  ""|-h|--help)
    err "usage: panel-read.sh <monitor_metrics|monitor_alerts|backup_status|seo_audits|prospects_list>"
    [[ "${SUB}" == "-h" || "${SUB}" == "--help" ]] && exit 0 || exit 2
    ;;
  *)
    err "unknown subcommand: '${SUB}'"
    exit 2
    ;;
esac
