# tests/control-api — Control API test harness

Offline (**no Docker, network, Keycloak or jose**), like the other suites. Run:

```
./tests/control-api/run.sh        # exits non-zero on any failure
```

Two layers:

1. **Pure logic (`lib.test.mjs`, raw `node`).** Imports the dependency-free lib
   modules directly (never `authorize.js`/`verify-token.js`, which pull in jose)
   and proves the security-critical behaviour:
   - **Authz matrix** — `evaluateAuth`: no payload → 401; valid non-operator on a
     write/action → 403; operator → 200; `extractBearer`/`hasOperatorRole` (realm
     and client roles).
   - **Registry allowlist** — only manifest keys are editable; a real `.env` secret
     that is *not* listed (e.g. `REDIS_PASSWORD`, `KC_DB_PASSWORD`) is rejected;
     per-key shape validation (enum/url/digits/token) including the newline
     line-injection guard.
   - **Secrets never returned** — `describeKey`/`summarizeIntegrations` expose only
     set/empty/masked for secrets; the serialized output contains none of the
     secret values (nor unrelated `.env` secrets).
   - **Safe `.env` writer** — `setEnvValue` preserves comments/order and updates in
     place; `writeEnvKey` (mocked fs) backs up first, writes atomically (rename),
     returns no value, and a non-allowlisted/newline write touches no file.
   - **Audit** — the record carries key/identity/result and has no field a value
     could land in.
   - **Restart whitelist & no-shell** — `buildBridgeArgs` returns an ARRAY,
     whitelists restart services, rejects bad profiles/names/traversal;
     `assertSafeArgv` rejects shell metacharacters.
   - **Rate limit / config** consistency.

2. **Source + bridge (bash).** Static checks that **no endpoint/lib builds an
   arbitrary shell command** (only `execFile`, no `exec`/`execSync`/`sh -c`/
   `shell:true`), the registry JSON is valid and complete, the JS restart allowlist
   matches `bot-lib`'s `BOT_VALID_SERVICE`, the scripts parse, the compose declares
   **no host ports**, the Caddy `api.` block exists, and `bot-exec`'s `restart`
   action is whitelisted (dry-run: valid service accepted, unknown/injection/empty
   refused).

Keep this suite — and all prior suites — green when changing the Control API or
the bot-exec bridge.
