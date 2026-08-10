// ===========================================================================
// pi-system Control API — BRIDGE CORE (PURE — the constrained execution path)
// ---------------------------------------------------------------------------
// The API NEVER runs arbitrary host commands and is NEVER given the Docker
// socket. Every control/restart action is mapped to a FIXED, named bot-exec
// action and validated here BEFORE it is handed to the transport (lib/bridge.js).
//
// This module is PURE: it maps an API action -> a bot-exec ARGV ARRAY and
// validates the single argument against an allowlist. Crucially it returns an
// ARRAY (e.g. ["up","core"]) — NEVER a concatenated shell string — so the
// transport spawns argv directly and no shell ever interprets the value. bot-exec
// itself re-validates everything (defence in depth).
//
// IMPORTANT — keep in sync with scripts/lib/bot-lib.sh, which is the canonical
// reference for the action set, the profile allowlist and (now) the restart
// SERVICE allowlist. tests/control-api cross-checks this JS list against that
// bash file so they cannot silently drift.
// ===========================================================================

// API action  ->  bot-exec action  (the fixed, whitelisted set this API may run).
// The monitoring/* + growth/* + backup-status entries are READ-ONLY panel-data
// feeds: each maps to a bot-exec read action that runs scripts/panel-read.sh,
// which only READS the producers' status/log/store files (no mutation).
export const ACTION_MAP = Object.freeze({
  // read-only
  status: 'status',
  'system-health': 'health',
  projects: 'projects',
  checks: 'check',
  // read-only panel-data feeds (Monitoring + Growth)
  monitoring: 'monitor_metrics',
  'monitoring-alerts': 'monitor_alerts',
  'backup-status': 'backup_status',
  'growth-seo': 'seo_audits',
  'growth-prospects': 'prospects_list',
  // state-changing
  up: 'up',
  down: 'down',
  'project-up': 'project_up',
  'project-down': 'project_down',
  'restart-service': 'restart',
});

export const READONLY_ACTIONS = Object.freeze([
  'status', 'system-health', 'projects', 'checks',
  'monitoring', 'monitoring-alerts', 'backup-status', 'growth-seo', 'growth-prospects',
]);

// Argument rules per API action.
const ARG_RULE = Object.freeze({
  status: 'none',
  'system-health': 'none',
  projects: 'none',
  checks: 'none',
  monitoring: 'none',
  'monitoring-alerts': 'none',
  'backup-status': 'none',
  'growth-seo': 'none',
  'growth-prospects': 'none',
  up: 'profile',
  down: 'profile',
  'project-up': 'project',
  'project-down': 'project',
  'restart-service': 'service',
});

// Allowlists — mirrors scripts/lib/bot-lib.sh.
export const VALID_PROFILES = Object.freeze(['core', 'dev', 'auth', 'automation']);
export const DEFAULT_PROFILE = 'core';
// Services bot-exec may restart (each maps to its up/down helper on the host).
export const VALID_RESTART_SERVICES = Object.freeze([
  'automation', 'analytics', 'auth', 'dashboard', 'cache', 'control-api',
]);
const PROJECT_NAME_RE = /^[a-z][a-z0-9-]{0,38}[a-z0-9]$/;

export function isValidApiAction(action) {
  return typeof action === 'string' && Object.prototype.hasOwnProperty.call(ACTION_MAP, action);
}
export function isReadonlyAction(action) {
  return READONLY_ACTIONS.includes(action);
}
export function isValidProfile(p) {
  return VALID_PROFILES.includes(p);
}
export function isValidProjectName(n) {
  return typeof n === 'string' && PROJECT_NAME_RE.test(n);
}
export function isAllowedRestartService(s) {
  return VALID_RESTART_SERVICES.includes(s);
}

// Build the bot-exec ARGV for an action + optional argument.
//   -> { ok: true, argv: ["<action>", "<arg>?"], class: "readonly"|"state-changing" }
//   -> { ok: false, status, error }
// `arg` shape is validated per rule; profiles default to "core". The returned
// argv is what the transport passes to bot-exec --from-ssh; it is an ARRAY, so
// the value is never spliced into a shell command line.
export function buildBridgeArgs(action, arg) {
  if (!isValidApiAction(action)) {
    return { ok: false, status: 400, error: `unknown action '${action}'` };
  }
  const botAction = ACTION_MAP[action];
  const rule = ARG_RULE[action];
  const klass = isReadonlyAction(action) ? 'readonly' : 'state-changing';

  switch (rule) {
    case 'none':
      if (arg != null && String(arg).length > 0) {
        return { ok: false, status: 400, error: `action '${action}' takes no argument` };
      }
      return { ok: true, argv: [botAction], class: klass };
    case 'profile': {
      const p = arg == null || arg === '' ? DEFAULT_PROFILE : String(arg);
      if (!isValidProfile(p)) {
        return { ok: false, status: 400, error: `invalid profile '${p}'` };
      }
      return { ok: true, argv: [botAction, p], class: klass };
    }
    case 'project': {
      const n = String(arg ?? '');
      if (!n) return { ok: false, status: 400, error: 'a project name is required' };
      if (!isValidProjectName(n)) {
        return { ok: false, status: 400, error: `malformed project name '${n}'` };
      }
      return { ok: true, argv: [botAction, n], class: klass };
    }
    case 'service': {
      const s = String(arg ?? '');
      if (!s) return { ok: false, status: 400, error: 'a service name is required' };
      if (!isAllowedRestartService(s)) {
        return { ok: false, status: 400, error: `service '${s}' is not in the restart allowlist` };
      }
      return { ok: true, argv: [botAction, s], class: klass };
    }
    default:
      return { ok: false, status: 400, error: 'unsupported action rule' };
  }
}
