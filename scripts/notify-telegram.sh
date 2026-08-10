#!/usr/bin/env bash
# ===========================================================================
# pi-system — outbound Telegram notifier (the operator's OWN channel)
# ---------------------------------------------------------------------------
# A tiny, reusable sender so the platform's swappable notifier seams can deliver to
# the SAME Telegram chat you already control the platform from. Point any of these at
# this script:
#     HEALTH_NOTIFY_CMD=./scripts/notify-telegram.sh        (host hardware health)
#     SEO_NOTIFY_CMD=./scripts/notify-telegram.sh           (SEO audit summaries)
#     PROSPECTS_NOTIFY_CMD=./scripts/notify-telegram.sh     (prospect analysis alerts)
#
# Contract (matches those seams): a short LABEL/verdict arrives as $1 and the message
# BODY on STDIN. It reads TELEGRAM_BOT_TOKEN + a chat id from .env WITHOUT sourcing it,
# then POSTs to the Telegram Bot API via curl.
#
# CHAT ID: TELEGRAM_ALERT_CHAT_ID if set, else the FIRST id in TELEGRAM_ALLOWED_IDS — so
# alerts land in the same chat you control the bot from. This is a message TO YOU (the
# operator); it is NEVER sent to a client/prospect.
#
# SAFE: the bot token is read from .env and is NEVER printed (the dry-run masks it; curl
# output is discarded). Best-effort — it exits 0 even if delivery fails, so a notifier
# can never break the job that called it. Honors TELEGRAM_NOTIFY_DRYRUN=1 (prints the
# plan, sends nothing) for testing without a token or network.
#
# Usage:   echo "the message" | ./scripts/notify-telegram.sh <LABEL>
# Verify:  echo "go-live test" | ./scripts/notify-telegram.sh TEST     (sends for real)
# ===========================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

# Read a value from .env WITHOUT sourcing it (never execute the env file).
env_get() {
  local key="$1" line val
  line="$(grep -E "^[[:space:]]*${key}=" .env 2>/dev/null | tail -n1 || true)"
  val="${line#*=}"
  val="${val%$'\r'}"
  val="${val#"${val%%[![:space:]]*}"}"
  val="${val%"${val##*[![:space:]]}"}"
  if [[ "${val}" == \"*\" && ${#val} -ge 2 ]]; then val="${val:1:${#val}-2}";
  elif [[ "${val}" == \'*\' && ${#val} -ge 2 ]]; then val="${val:1:${#val}-2}"; fi
  printf '%s' "${val}"
}

LABEL="${1:-alert}"
BODY="$(cat 2>/dev/null || true)"   # the message body arrives on stdin

TOKEN="$(env_get TELEGRAM_BOT_TOKEN)"
CHAT="$(env_get TELEGRAM_ALERT_CHAT_ID)"
if [[ -z "${CHAT}" ]]; then
  # Fall back to the first numeric id in the bot allowlist.
  CHAT="$(env_get TELEGRAM_ALLOWED_IDS | tr ',; ' '\n\n\n' | grep -E '^[0-9]+$' | head -n1 || true)"
fi

TEXT="pi-system [${LABEL}]"$'\n'"${BODY}"

if [[ -z "${TOKEN}" || -z "${CHAT}" ]]; then
  printf '[notify-telegram] not configured (need TELEGRAM_BOT_TOKEN + TELEGRAM_ALERT_CHAT_ID or TELEGRAM_ALLOWED_IDS) — skipping.\n' >&2
  exit 0
fi

if [[ "${TELEGRAM_NOTIFY_DRYRUN:-0}" == "1" ]]; then
  # NEVER print the token — mask it.
  printf '[dry-run] POST https://api.telegram.org/bot<token>/sendMessage  chat_id=%s  text=%q\n' "${CHAT}" "${TEXT}"
  exit 0
fi

if ! command -v curl >/dev/null 2>&1; then
  printf '[notify-telegram] curl not installed — cannot send (skipping).\n' >&2
  exit 0
fi

# Send. --data-urlencode keeps the body safe; output is discarded so the token (in the
# URL) never lands in a log. Best-effort: a failed send must not fail the caller.
if curl -fsS -m 15 \
     --data-urlencode "chat_id=${CHAT}" \
     --data-urlencode "text=${TEXT}" \
     "https://api.telegram.org/bot${TOKEN}/sendMessage" >/dev/null 2>&1; then
  printf '[notify-telegram] sent (%s).\n' "${LABEL}"
else
  printf '[notify-telegram] send FAILED (best-effort) — check the bot token, chat id, and network.\n' >&2
fi
exit 0
