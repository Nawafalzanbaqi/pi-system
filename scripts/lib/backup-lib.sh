#!/usr/bin/env bash
# pi-system — BACKUP pure-logic helpers (sourced; no Docker / age / network).
# ===========================================================================
# The trustworthy-restore logic that must be PROVABLE OFFLINE lives here, split
# out of scripts/backup.sh so it can be unit-tested directly against fixture
# manifests with NO Docker, NO age key and NO containers. Nothing in this file
# touches live data, spins up a container, or sends anything — it only reads a
# backup run directory + its manifest and reasons about whether that backup can
# be trusted BEFORE an operator relies on it.
#
# What it provides:
#   * bk_manifest_get   — read one "# key: value" header field from a manifest.
#   * bk_is_sha256      — is a string a well-formed 64-hex SHA-256?
#   * bk_plan_restore   — the planner: validate a run dir against its manifest
#                         (artifacts present, byte sizes + per-member checksums
#                         match, age key available, manifest schema known) and
#                         print a human-readable plan + a single authoritative
#                         "OVERALL: SAFE-TO-RESTORE / NOT-SAFE" line. Returns 0
#                         when SAFE, non-zero when NOT-SAFE.
#   * bk_notify_failure — best-effort failure notification through a swappable
#                         notifier seam (added for the failure-surfacing path).
#
# Usage:
#   . scripts/lib/backup-lib.sh
#   bk_plan_restore /path/to/data/backups/daily/<TS> present
# ===========================================================================

# The manifest schema version THIS toolchain understands. It MUST stay in lock-
# step with the "# schema:" line written by services/backup/do-backup.sh. A
# manifest written with a HIGHER schema (a newer toolchain) is read best-effort
# and WARNed about; a lower/equal known schema is trusted.
: "${BK_SUPPORTED_MANIFEST_SCHEMA:=1}"

# bk_manifest_get <manifest_file> <field> — echo the trimmed value of the first
# "# <field>: <value>" header line (empty if absent). Only the FIRST ':' is the
# separator, so values that themselves contain ':' (e.g. an ISO timestamp) are
# preserved intact.
bk_manifest_get() {
  local f="$1" key="$2" line
  [[ -f "${f}" ]] || { printf ''; return 0; }
  line="$(grep -E "^#[[:space:]]*${key}:" "${f}" 2>/dev/null | head -n1 || true)"
  [[ -z "${line}" ]] && { printf ''; return 0; }
  line="${line#*:}"                                   # drop "# <field>:"
  line="${line#"${line%%[![:space:]]*}"}"             # ltrim
  line="${line%"${line##*[![:space:]]}"}"             # rtrim
  printf '%s' "${line}"
}

# bk_is_sha256 <string> — 0 iff it is exactly 64 hex chars (a real SHA-256).
bk_is_sha256() { [[ "$1" =~ ^[0-9a-fA-F]{64}$ ]]; }

# _bk_filesize <path> — byte size, GNU stat then BSD stat, '?' if neither works.
_bk_filesize() { stat -c '%s' "$1" 2>/dev/null || stat -f '%z' "$1" 2>/dev/null || echo '?'; }

# bk_plan_restore <run_dir> <key_state> [decrypt_state]
#   key_state     : "present" (the age identity is available to decrypt) | anything
#                   else (treated as MISSING — a hard blocker).
#   decrypt_state : optional out-of-band proof from the caller that the key really
#                   decrypts this backup — "ok" | "failed" | "skipped" (default).
#                   This keeps the (Docker/age-dependent) decrypt probe OUT of this
#                   pure function while still letting its result drive the verdict.
#
# Reads <run_dir>/manifest.txt and, for every artifact the manifest records as
# "ok", confirms the file is present on disk and that its byte size + SHA-256
# match the manifest (corruption / truncation / tampering -> NOT-SAFE). Prints a
# clear plan, any WARN lines (e.g. an unknown schema, a member that failed at
# backup time) and any PROBLEM lines, then ONE "OVERALL:" verdict line.
#
# Returns 0 when SAFE-TO-RESTORE (no PROBLEMs; WARNs do not block), 1 otherwise.
bk_plan_restore() {
  local run_dir="${1%/}" key_state="${2:-present}" decrypt_state="${3:-skipped}"
  local manifest="${run_dir}/manifest.txt"
  local -a problems=() warnings=() plan=()

  if [[ ! -d "${run_dir}" ]]; then
    printf 'Restore plan for: %s\n' "${run_dir}"
    printf '\nPROBLEM: backup run directory not found.\n'
    printf '\nOVERALL: NOT-SAFE\n'
    return 1
  fi
  if [[ ! -f "${manifest}" ]]; then
    printf 'Restore plan for: %s\n' "${run_dir}"
    printf '\nPROBLEM: no manifest.txt in the run directory — cannot validate this backup.\n'
    printf '\nOVERALL: NOT-SAFE\n'
    return 1
  fi

  # --- Schema: known/equal is trusted; absent or newer is a (non-blocking) WARN.
  local schema; schema="$(bk_manifest_get "${manifest}" schema)"
  if [[ -z "${schema}" ]]; then
    warnings+=("manifest has no schema header (legacy backup) — validated best-effort.")
  elif ! [[ "${schema}" =~ ^[0-9]+$ ]]; then
    warnings+=("manifest schema '${schema}' is not a recognized version — validated best-effort.")
  elif (( schema > BK_SUPPORTED_MANIFEST_SCHEMA )); then
    warnings+=("manifest schema ${schema} is NEWER than supported (${BK_SUPPORTED_MANIFEST_SCHEMA}) — written by a newer toolchain; upgrade this checkout before relying on it.")
  fi

  # --- The age key is the one thing that can never be reconstructed.
  if [[ "${key_state}" != "present" ]]; then
    problems+=("age identity not available — WITHOUT it NO backup can be decrypted. Restore your offline copy of the age key (secrets/backup/age-identity.key) and retry.")
  fi

  # --- Walk every artifact the manifest claims succeeded.
  local kind label file status bytes sha f actual_bytes actual_sha
  local member_count=0 ok_count=0
  while IFS='|' read -r kind label file status bytes sha; do
    [[ -z "${kind}" || "${kind}" == \#* ]] && continue
    case "${status}" in
      ok)
        member_count=$((member_count+1))
        f="${run_dir}/${file}"
        if [[ ! -f "${f}" ]]; then
          problems+=("artifact '${file}' is listed ok but is MISSING on disk.")
          continue
        fi
        actual_bytes="$(_bk_filesize "${f}")"
        if [[ "${bytes}" =~ ^[0-9]+$ && "${actual_bytes}" =~ ^[0-9]+$ && "${actual_bytes}" != "${bytes}" ]]; then
          problems+=("size mismatch for '${file}': manifest ${bytes} bytes, on disk ${actual_bytes} (corrupt/truncated).")
          continue
        fi
        if ! bk_is_sha256 "${sha}"; then
          problems+=("checksum for '${file}' is missing/short/malformed in the manifest — integrity cannot be verified.")
          continue
        fi
        actual_sha="$(sha256sum "${f}" 2>/dev/null | cut -d' ' -f1 || true)"
        if [[ -z "${actual_sha}" ]]; then
          warnings+=("could not compute a checksum for '${file}' (sha256sum unavailable) — integrity left unverified.")
          plan+=("${kind}/${label}  ->  ${file}  (${bytes} bytes, checksum UNVERIFIED)")
        elif [[ "${actual_sha}" != "${sha}" ]]; then
          problems+=("checksum MISMATCH for '${file}' — the artifact is corrupt or has been tampered with.")
          continue
        else
          ok_count=$((ok_count+1))
          plan+=("${kind}/${label}  ->  ${file}  (${bytes} bytes, checksum OK)")
        fi
        ;;
      failed)
        warnings+=("'${file}' was recorded as FAILED at backup time — it is not restorable from this run.")
        ;;
    esac
  done < "${manifest}"

  if (( member_count == 0 )); then
    problems+=("the manifest lists no successful artifacts — there is nothing to restore.")
  fi

  # --- Decrypt proof handed in by the caller (host-side, never a container).
  case "${decrypt_state}" in
    failed) problems+=("decrypt check FAILED — the available age key does NOT decrypt this backup (wrong key?).") ;;
  esac

  # --- Print the plan ------------------------------------------------------
  printf 'Restore plan for: %s\n' "${run_dir}"
  [[ -n "${schema}" ]] && printf '  manifest schema : %s (supported: %s)\n' "${schema}" "${BK_SUPPORTED_MANIFEST_SCHEMA}"
  local run created recip
  run="$(bk_manifest_get "${manifest}" run)";          [[ -n "${run}" ]]     && printf '  backup run      : %s\n' "${run}"
  created="$(bk_manifest_get "${manifest}" created_at)";[[ -n "${created}" ]] && printf '  created at      : %s\n' "${created}"
  recip="$(bk_manifest_get "${manifest}" age_recipient)"; [[ -n "${recip}" ]] && printf '  age recipient   : %s\n' "${recip}"
  printf '  age identity    : %s\n' "$([[ "${key_state}" == "present" ]] && echo 'available (can decrypt)' || echo 'MISSING (cannot decrypt)')"
  case "${decrypt_state}" in
    ok)     printf '  decrypt check   : OK (key decrypts a sample artifact)\n' ;;
    failed) printf '  decrypt check   : FAILED (key does not decrypt this backup)\n' ;;
    *)      printf '  decrypt check   : skipped (host has no age CLI — run ./scripts/backup.sh verify for the full drill)\n' ;;
  esac

  printf '\nWould restore %d of %d artifact(s):\n' "${ok_count}" "${member_count}"
  local item
  for item in "${plan[@]:-}"; do [[ -n "${item}" ]] && printf '  • %s\n' "${item}"; done

  if (( ${#warnings[@]} )); then
    printf '\n'
    for item in "${warnings[@]}"; do printf 'WARN: %s\n' "${item}"; done
  fi
  if (( ${#problems[@]} )); then
    printf '\n'
    for item in "${problems[@]}"; do printf 'PROBLEM: %s\n' "${item}"; done
  fi

  printf '\n'
  if (( ${#problems[@]} )); then
    printf 'OVERALL: NOT-SAFE\n'
    return 1
  fi
  printf 'OVERALL: SAFE-TO-RESTORE\n'
  return 0
}

# bk_notify_failure <notifier_cmd> <label> <body>
#   Surface a backup/offsite FAILURE through a swappable notifier seam — the SAME
#   contract the platform's other seams use (LABEL on argv, BODY on stdin), so the
#   bundled scripts/notify-telegram.sh delivers it to the operator's own chat.
#
#   The worst backup failure is the one discovered only when the backup is needed;
#   this makes a silent scheduled-backup or offsite-push failure impossible to miss.
#
#   notifier_cmd : path to the notifier; "" or "off" disables it (a clean no-op).
#   BEST-EFFORT: a notifier that is unconfigured, missing, or fails MUST NOT fail
#   the backup — this function ALWAYS returns 0.
bk_notify_failure() {
  local cmd="$1" label="$2" body="$3"
  [[ -z "${cmd}" || "${cmd}" == "off" ]] && return 0
  if command -v "${cmd}" >/dev/null 2>&1 || [[ -f "${cmd}" ]]; then
    printf '%s\n' "${body}" | bash "${cmd}" "${label}" >/dev/null 2>&1 || true
  fi
  return 0
}
