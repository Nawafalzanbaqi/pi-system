#!/usr/bin/env bash
# ===========================================================================
# pi-system — firewall hardening helper (UFW)
# ---------------------------------------------------------------------------
# Stages a strict, default-deny-incoming UFW ruleset for the Pi that allows
# ONLY the ports this platform actually needs from the outside world:
#   * SSH   (22/tcp, or --ssh-port / $SSH_PORT)  — so you keep remote access
#   * HTTP  (80/tcp)         — Caddy: HTTP->HTTPS redirect + ACME challenge
#   * HTTPS (443/tcp + udp)  — Caddy: TLS and HTTP/3 (the proxy binds 443/udp)
# Everything else inbound is denied by default. Outbound stays allowed.
#
# >>> SAFETY: this script DOES NOT enable the firewall. <<<
# It only configures (stages) the rules, then prints them for your review.
# Turning on a default-deny firewall over an SSH link can lock you out of the
# Pi, so enabling is left as a separate, deliberate step that YOU run:
#     sudo ufw enable
# after you have confirmed the SSH rule below is correct (see the warning block
# the script prints at the end, and the "Security hardening" section of
# docs/README.md).
#
# Usage:
#     sudo ./scripts/harden-firewall.sh [--ssh-port N] [-h|--help]
#
#   --ssh-port N   SSH port to allow (default: $SSH_PORT, else 22). The script
#                  ALSO auto-detects the port of your CURRENT SSH session and
#                  always allows that too, as an anti-lockout safeguard.
#
# Requires root (UFW needs it) — run with sudo. Re-running is safe/idempotent:
# UFW de-duplicates identical rules. Run from anywhere.
# ===========================================================================
set -euo pipefail

# --- Resolve project root (the parent of this scripts/ directory) ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

# --- Tiny coloured loggers -------------------------------------------------
log()  { printf '\033[0;32m[firewall]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[warn]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[0;31m[error]\033[0m %s\n' "$*" >&2; }

usage() {
  cat >&2 <<EOF
Usage: sudo ./scripts/harden-firewall.sh [--ssh-port N]

  --ssh-port N   SSH port to allow (default: \$SSH_PORT, else 22).
  -h, --help     Show this help and exit.

This stages a default-deny-incoming UFW ruleset allowing only SSH, 80 and 443
(tcp+udp). It DOES NOT enable the firewall — review the printed rules, then run
'sudo ufw enable' yourself. See docs/README.md "Security hardening".
EOF
}

# --- Parse arguments -------------------------------------------------------
# SSH port: default from $SSH_PORT (if exported), else 22; --ssh-port overrides.
SSH_PORT="${SSH_PORT:-22}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ssh-port)
      if [[ $# -lt 2 ]]; then
        err "--ssh-port requires a value."
        usage
        exit 1
      fi
      SSH_PORT="$2"
      shift 2
      ;;
    --ssh-port=*)
      SSH_PORT="${1#*=}"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      err "Unknown argument: '$1'."
      usage
      exit 1
      ;;
  esac
done

# Validate the SSH port is an integer in the valid range.
if ! [[ "${SSH_PORT}" =~ ^[0-9]+$ ]] || (( SSH_PORT < 1 || SSH_PORT > 65535 )); then
  err "Invalid SSH port: '${SSH_PORT}'. Must be an integer 1-65535."
  exit 1
fi

# --- Preconditions ---------------------------------------------------------
# UFW must run as root, and so must this script (it issues ufw commands).
if [[ "${EUID}" -ne 0 ]]; then
  err "This script must run as root (UFW requires it)."
  err "Re-run with sudo:  sudo ./scripts/harden-firewall.sh"
  exit 1
fi

if ! command -v ufw >/dev/null 2>&1; then
  err "UFW is not installed."
  err "Install it first:  sudo apt-get update && sudo apt-get install -y ufw"
  exit 1
fi

# --- Detect the SSH port of the CURRENT session (anti-lockout safeguard) ----
# $SSH_CONNECTION = "<client_ip> <client_port> <server_ip> <server_port>".
# If we are connected over SSH we ALWAYS allow that exact port too, so a wrong
# --ssh-port can't silently cut the link the operator is using right now.
DETECTED_SSH_PORT=""
if [[ -n "${SSH_CONNECTION:-}" ]]; then
  DETECTED_SSH_PORT="$(awk '{print $4}' <<<"${SSH_CONNECTION}")"
fi

# Informational: what port(s) sshd is configured to listen on (best-effort).
CONFIGURED_SSH_PORTS=""
if [[ -r /etc/ssh/sshd_config ]]; then
  CONFIGURED_SSH_PORTS="$(awk 'tolower($1)=="port"{print $2}' /etc/ssh/sshd_config | tr '\n' ' ')"
fi

# Is UFW already active? Adding rules to a LIVE firewall takes effect at once,
# so we add the SSH allow first (below) and warn the operator here.
UFW_ACTIVE=0
if ufw status 2>/dev/null | grep -qi '^Status: active'; then
  UFW_ACTIVE=1
fi

log "Planned inbound allow-list:"
log "  - SSH    ${SSH_PORT}/tcp"
if [[ -n "${DETECTED_SSH_PORT}" && "${DETECTED_SSH_PORT}" != "${SSH_PORT}" ]]; then
  log "  - SSH    ${DETECTED_SSH_PORT}/tcp   (auto-detected from your active session)"
fi
log "  - HTTP   80/tcp        (Caddy)"
log "  - HTTPS  443/tcp       (Caddy)"
log "  - HTTP/3 443/udp       (Caddy)"
log "Default policy: deny (incoming), allow (outgoing)."

if [[ -n "${CONFIGURED_SSH_PORTS// }" ]]; then
  log "sshd_config Port directive(s): ${CONFIGURED_SSH_PORTS}"
fi

# Loud heads-up if the SSH port we're allowing doesn't match the live session.
if [[ -n "${DETECTED_SSH_PORT}" && "${DETECTED_SSH_PORT}" != "${SSH_PORT}" ]]; then
  warn "Your active SSH session is on port ${DETECTED_SSH_PORT}, but --ssh-port is ${SSH_PORT}."
  warn "Both are being allowed so you won't be locked out, but double-check which"
  warn "port you actually want before you enable UFW."
fi

if [[ "${UFW_ACTIVE}" -eq 1 ]]; then
  warn "UFW is ALREADY ACTIVE. New rules below take effect immediately. The SSH"
  warn "allow rule is added first so your current session is preserved."
fi

# --- Stage the rules -------------------------------------------------------
# Order matters when UFW is already active: add the SSH allow BEFORE switching
# the default to deny, so an already-running firewall never drops SSH mid-change.
log "Staging UFW rules ..."

# SSH first (the lifeline).
ufw allow "${SSH_PORT}/tcp" comment 'pi-system: SSH'
if [[ -n "${DETECTED_SSH_PORT}" && "${DETECTED_SSH_PORT}" != "${SSH_PORT}" ]]; then
  ufw allow "${DETECTED_SSH_PORT}/tcp" comment 'pi-system: SSH (active session)'
fi

# Caddy edge ports.
ufw allow 80/tcp  comment 'pi-system: HTTP (Caddy)'
ufw allow 443/tcp comment 'pi-system: HTTPS (Caddy)'
ufw allow 443/udp comment 'pi-system: HTTP/3 (Caddy)'

# Default-deny posture (applied last; harmless while UFW is inactive).
ufw default deny incoming
ufw default allow outgoing

log "Rules staged."

# --- Show the resulting ruleset for review ---------------------------------
echo
log "Configured rules (preview — 'ufw show added'):"
echo "---------------------------------------------------------------------------"
ufw show added || true
echo "---------------------------------------------------------------------------"
echo
log "Current firewall status:"
echo "---------------------------------------------------------------------------"
ufw status verbose || true
echo "---------------------------------------------------------------------------"

# --- Docker / UFW bypass caveat (informational) ----------------------------
echo
warn "Docker can BYPASS UFW: it writes its own iptables rules, so a container"
warn "that publishes a port to 0.0.0.0 may be reachable even when UFW says it"
warn "is blocked. This platform only publishes 80/443 (via Caddy), so you are"
warn "safe today — keep it that way: do NOT publish container ports to 0.0.0.0."
warn "See docs/README.md \"Security hardening\" for the full caveat + mitigation."

# --- The deliberate manual-enable step + lockout warning -------------------
cat <<EOF

===========================================================================
  !!  FIREWALL IS NOT YET ENABLED — THIS IS INTENTIONAL  !!
===========================================================================
The rules above are STAGED only. Nothing changed about what the Pi accepts
until you turn UFW on yourself:

      sudo ufw enable

>>> SSH LOCKOUT WARNING <<<
Enabling a default-deny firewall over SSH can permanently cut your session if
the SSH port is not actually allowed. Before you run 'sudo ufw enable':

  1. Confirm an SSH rule for YOUR port appears in the preview above
     (you are allowing: ${SSH_PORT}/tcp${DETECTED_SSH_PORT:+ and ${DETECTED_SSH_PORT}/tcp}).
  2. Keep this SSH session OPEN as a safety net.
  3. Enable UFW, then open a SECOND, NEW SSH connection to verify you can still
     get in BEFORE you close this one.

>>> RECOVERY IF YOU GET LOCKED OUT <<<
You will need LOCAL / console access to the Pi (it cannot be fixed over SSH if
SSH is what's blocked):
  - Attach a monitor + keyboard (or use the serial console) and log in locally.
  - Then run:   sudo ufw disable      (turns the firewall off), or
                sudo ufw allow <your-ssh-port>/tcp   (add the missing rule).

To undo the staged rules entirely:  sudo ufw reset   (then reconfigure).
===========================================================================
EOF

log "Done. Review the rules above, then run 'sudo ufw enable' when you are ready."
