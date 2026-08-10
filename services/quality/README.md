# Quality gate (`services/quality`)

A **lightweight, on-demand quality gate** for the projects you generate with
`scripts/new-project.sh`. It runs static analysis / linting, the relevant
compiler/analyzer checks, and a dependency vulnerability scan against a single
generated project, prints a clear **pass/fail per check**, and **exits non-zero
on any failure** — so it can act as a gate before you build and deploy.

> SonarQube and similar heavyweight analyzers are **deliberately not used** here:
> they are memory-hungry and not ARM-friendly, and an always-on analysis server
> would permanently eat RAM on the Pi 5. This gate uses only lightweight,
> ARM64-native tooling that already ships with the stacks the platform targets
> (.NET and Next.js).

## Why script-driven, not a profile-gated service

`services/cache` ships a `cache` Compose profile because a package cache is a
*long-lived* thing you start and leave running. A quality gate is the opposite:
a **short, one-shot run** against an arbitrary project, producing an exit code.
Two facts make a script the right shape for it (rather than a compose service):

1. **It needs two different toolchains** — the .NET SDK *and* Node — and runs
   the one(s) that match the project. Baking both into a single always-defined
   service image would be large and wasteful; instead the runner spins up the
   **exact, pinned, ARM64 SDK images the templates already build from**
   (`mcr.microsoft.com/dotnet/sdk:10.0`, `node:22-alpine`) as throwaway
   `docker run --rm` containers, only for the seconds the checks take.
2. **A gate is fundamentally a CLI that exits non-zero.** `./scripts/quality.sh
   <project>` *is* that gate — drop it into a deploy step and a failing check
   stops the line. There is no service to keep up, and **nothing consumes RAM
   when you are not running it** — exactly the Pi-aware property the platform
   requires.

So there is no `*.compose.yml` here on purpose. The whole gate is
[`scripts/quality.sh`](../../scripts/quality.sh); this folder documents it.

## What it checks

Checks are chosen per stack by detecting the project's files (a `*.csproj` ⇒
.NET; a `package.json` ⇒ Next.js/JS). A `fullstack` project runs both.

### .NET (`mcr.microsoft.com/dotnet/sdk:10.0`)

| Check | Tool | Fails when |
| ----- | ---- | ---------- |
| restore  | `dotnet restore` | packages can't be restored |
| analyze  | `dotnet build -c Release` with **`-p:TreatWarningsAsErrors=true -p:EnableNETAnalyzers=true -p:AnalysisMode=Recommended`** | the build, any compiler warning, or any Roslyn analyzer warning |
| format   | `dotnet format --verify-no-changes` | code is not formatted to the project's `.editorconfig`/defaults |
| audit    | `dotnet list package --vulnerable --include-transitive` | any package has a known vulnerability |

Warnings-as-errors can be relaxed with `QUALITY_DOTNET_WARN_AS_ERROR=false`
(see below) if you want analyzer findings reported without failing the build.

### Next.js / JS (`node:22-alpine`)

| Check | Tool | Fails when |
| ----- | ---- | ---------- |
| install | `npm ci` (falls back to `npm install` when there is no lockfile) | dependencies can't be installed |
| lint    | the project's `npm run lint` if defined, otherwise **ESLint (pinned) via `next lint`** with `eslint@8.57.1` + `eslint-config-next@15.5.18` and a `next/core-web-vitals` config | ESLint reports any error |
| audit   | `npm audit --audit-level=high` | a vulnerability at/above the level is found |

The base templates intentionally ship without an ESLint config (to stay
dependency-light); when none is present the gate installs a **pinned** ESLint +
`eslint-config-next` *inside the throwaway copy only* and lints with the
standard Next.js `core-web-vitals` rules. Your project on disk is never touched.

## Resource-aware by design (gentle on the Pi)

- **Checks run strictly sequentially** — never in parallel — so at most one SDK
  container is alive at a time and peak RAM stays bounded. On a Pi 5 this is the
  difference between "it just works" and an OOM-killed build.
- **Nothing is always-on.** Containers are `--rm` one-shots; when the gate
  finishes, zero quality-gate processes remain.
- **Your project is mounted read-only** (`/src:ro`); each check copies it into a
  disposable in-container working dir, so a run leaves **no `node_modules/`,
  `obj/`, `bin/` or generated lockfiles** behind in `services/<name>/`.

## Usage

```bash
# Run the gate against a generated project (services/<name>):
./scripts/quality.sh <name>

# Example:
./scripts/quality.sh happy-teeth
```

It prints each check's result and exits `0` only if **every** check passed.

### Environment knobs (all optional)

| Variable | Default | Effect |
| -------- | ------- | ------ |
| `QUALITY_DOTNET_WARN_AS_ERROR` | `true`  | `-p:TreatWarningsAsErrors=` for the .NET analyze step |
| `QUALITY_NPM_AUDIT_LEVEL`      | `high`  | `npm audit --audit-level=` threshold |

These belong in your shell or `.env` — see the **QUALITY GATE** section of
`.env.example`. The gate needs no secrets.

## Requirements

- Docker (the gate uses `docker run`); no .NET SDK or Node need be installed on
  the host — the pinned SDK images provide them.
- Outbound internet for the run (to restore packages and query the npm / NuGet
  vulnerability databases). It does **not** need any platform service to be up,
  though it happily coexists with the [package cache](../cache/README.md).
