#!/usr/bin/env sh
# ===========================================================================
# pi-system — Lighthouse one-shot wrapper (runs INSIDE the seo-lighthouse image)
# ---------------------------------------------------------------------------
# Runs a real, Chromium-based Lighthouse audit against one URL, writes the JSON to
# a temp file, then hands that JSON to the shared audit engine (audit.js) so the
# result is stored / scored / turned into recommendations EXACTLY like a probe run.
#
# Usage (set by scripts/seo.sh):   lh-audit.sh <name> <url>
# Honest note: this launches headless Chromium — heavy on a Pi. One-shot only.
# ===========================================================================
set -eu

NAME="${1:-}"
URL="${2:-}"
if [ -z "${NAME}" ] || [ -z "${URL}" ]; then
  echo "lh-audit.sh: usage: lh-audit.sh <name> <url>" >&2
  exit 2
fi

OUT="$(mktemp -t lhr.XXXXXX.json)"

# --no-sandbox is required for headless Chromium inside a container; we already run
# as a non-root user (see Dockerfile.lighthouse), which is the safe combination.
lighthouse "${URL}" \
  --quiet \
  --output=json \
  --output-path="${OUT}" \
  --only-categories=performance,accessibility,best-practices,seo \
  --chrome-flags="--headless --no-sandbox --disable-gpu --disable-dev-shm-usage"

# Ingest the Lighthouse JSON via the shared engine (same storage/rules/report path).
exec node /opt/seo/engine/audit.js audit --name "${NAME}" --url "${URL}" \
  --engine lighthouse --lh-json "${OUT}"
