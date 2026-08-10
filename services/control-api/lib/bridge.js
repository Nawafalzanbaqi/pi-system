// ===========================================================================
// pi-system Control API — BRIDGE TRANSPORT SEAM (host execution, no socket)
// ---------------------------------------------------------------------------
// Runs a VALIDATED bot-exec action on the host. The API container is NEVER given
// the Docker socket; it reaches the host EXACTLY like the Telegram bot does — over
// SSH using a DEDICATED key pinned to a forced command:
//
//   command="bash /PATH/scripts/bot-exec.sh --from-ssh",no-pty,... <key>
//
// so the key can ONLY ever launch bot-exec.sh; the requested "<action> <arg>"
// arrives in $SSH_ORIGINAL_COMMAND, which bot-exec tokenizes (no eval) and
// re-validates. We additionally:
//   * only ever send an ARGV that buildBridgeArgs already validated, and
//   * spawn the local `ssh` binary with an ARGV ARRAY (execFile, never `sh -c`),
//     so no local shell ever interprets the value.
//
// mode=local is provided for dev/tests against an explicitly mounted bot-exec.sh
// (still argv-based, still re-validated by bot-exec). NOTHING here builds a shell
// command from user input.
// ===========================================================================
import { execFile } from 'node:child_process';

// Defence in depth: every argv token must be a plain, shell-safe word. Anything
// outside this class means a validation bug upstream — refuse rather than send it.
const SAFE_TOKEN = /^[A-Za-z0-9._\/-]+$/;

export function assertSafeArgv(argv) {
  if (!Array.isArray(argv) || argv.length === 0) throw new Error('empty bridge argv');
  for (const t of argv) {
    if (typeof t !== 'string' || !SAFE_TOKEN.test(t)) {
      throw new Error('refusing to bridge an unsafe argument');
    }
  }
}

// The generation bridge additionally needs a COMMA — the create-project action
// passes its modules list as one `a,b,c` token (new-project.sh's `--modules`).
// A comma is inert in the shell (no expansion/splitting), so this stays strictly
// shell-safe; every other metacharacter (; | & $ ` space …) is still refused, and
// the bridge re-splits + re-validates each module against the allowlist on the host.
const SAFE_GENERATE_TOKEN = /^[A-Za-z0-9._\/,-]+$/;

export function assertSafeGenerateArgv(argv) {
  if (!Array.isArray(argv) || argv.length === 0) throw new Error('empty bridge argv');
  for (const t of argv) {
    if (typeof t !== 'string' || !SAFE_GENERATE_TOKEN.test(t)) {
      throw new Error('refusing to bridge an unsafe argument');
    }
  }
}

// runBridge(argv, config) -> Promise<{ rc, stdout, stderr }>
// argv is e.g. ["up","core"] from buildBridgeArgs (NEVER a shell string).
export function runBridge(argv, config) {
  assertSafeArgv(argv);
  const b = config.bridge;
  if (b.mode === 'local') {
    if (!b.botExec) return Promise.reject(new Error('bridge mode=local requires CONTROL_API_BRIDGE_BOT_EXEC'));
    // Positional invocation of the mounted bot-exec.sh (it re-validates).
    return run('bash', [b.botExec, ...argv], b.timeoutMs);
  }
  // Default: SSH forced-command. The remote command is the validated argv joined
  // with single spaces; bot-exec --from-ssh word-splits it safely on the host.
  if (!b.host || !b.user) {
    return Promise.reject(new Error('SSH bridge is not configured (CONTROL_API_BRIDGE_SSH_HOST/USER)'));
  }
  const remoteCommand = argv.join(' ');   // each token is SAFE_TOKEN-validated
  const sshArgs = [
    '-i', b.key,
    '-p', String(b.port),
    '-o', 'BatchMode=yes',
    '-o', 'StrictHostKeyChecking=accept-new',
    // The container user's HOME may be read-only; keep known_hosts in /tmp.
    '-o', 'UserKnownHostsFile=/tmp/control-api_known_hosts',
    '-o', 'ConnectTimeout=10',
    `${b.user}@${b.host}`,
    remoteCommand,
  ];
  return run('ssh', sshArgs, b.timeoutMs);
}

// runGenerateBridge(argv, config) -> Promise<{ rc, stdout, stderr }>
// argv is e.g. ["create-project","--name","noor", …] from buildGenerateArgs
// (NEVER a shell string). It targets the SIBLING bridge bot-exec-generate.sh over
// its OWN dedicated forced-command key (config.generateBridge) — the identical
// constrained pattern as runBridge, scoped to project creation.
export function runGenerateBridge(argv, config) {
  assertSafeGenerateArgv(argv);
  const b = config.generateBridge;
  if (b.mode === 'local') {
    if (!b.botExec) return Promise.reject(new Error('generate bridge mode=local requires CONTROL_API_GENERATE_BRIDGE_EXEC'));
    // Positional invocation of the mounted bot-exec-generate.sh (it re-validates).
    return run('bash', [b.botExec, ...argv], b.timeoutMs);
  }
  if (!b.host || !b.user) {
    return Promise.reject(new Error('generate SSH bridge is not configured (CONTROL_API_GENERATE_BRIDGE_SSH_HOST/USER)'));
  }
  const remoteCommand = argv.join(' ');   // each token is SAFE_GENERATE_TOKEN-validated
  const sshArgs = [
    '-i', b.key,
    '-p', String(b.port),
    '-o', 'BatchMode=yes',
    '-o', 'StrictHostKeyChecking=accept-new',
    '-o', 'UserKnownHostsFile=/tmp/control-api_known_hosts',
    '-o', 'ConnectTimeout=10',
    `${b.user}@${b.host}`,
    remoteCommand,
  ];
  return run('ssh', sshArgs, b.timeoutMs);
}

function run(file, args, timeoutMs) {
  return new Promise((resolve, reject) => {
    execFile(file, args, { timeout: timeoutMs, maxBuffer: 1024 * 1024, env: { ...process.env, NO_COLOR: '1' } },
      (error, stdout, stderr) => {
        if (error && typeof error.code !== 'number') return reject(error); // spawn failure / timeout
        resolve({ rc: error ? error.code : 0, stdout: String(stdout || ''), stderr: String(stderr || '') });
      });
  });
}
