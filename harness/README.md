# Virtual-User Test Harness

A **virtual-user load / regression testing + comprehensive verification & scoring harness** for the polyglot Keycloak SDK (Go/C#/Node/Python/Java/PHP/Rust/Ruby/Kotlin — 9 languages). It brings up a real Keycloak 26.6 (`it-realm` — the same realm as the per-language integration tests) via Docker Compose, and exposes sample apps written with each language's SDK to the same spec (all 9 languages complete, [`contract/CONTRACT.md`](contract/CONTRACT.md) v2) over a common HTTP contract, verifying along two axes: (1) a k6-based driver measures and compares isomorphic load scenarios (legacy `run.sh`), and (2) it runs contract conformance, security-hardening probes, and each SDK's own suite (unit + coverage + lint) per language and aggregates them into a 4-dimensional score (`verify.sh` → `report/SCORECARD.md` — see the "Verification & Scoring" section below).

Each app consumes the SDK through that language's **idiomatic framework** — so the performance measurements are not pure SDK cost but "SDK-in-idiomatic-app" (framework overhead included) measurements.

| Language | Framework | App directory | Host port |
|---|---|---|---|
| go | net/http | [`apps/go/`](apps/go/) | 8090 |
| dotnet | ASP.NET Core | [`apps/dotnet/`](apps/dotnet/) | 8091 |
| node | Express 5 | [`apps/node/`](apps/node/) | 8092 |
| python | FastAPI | [`apps/python/`](apps/python/) | 8093 |
| java | Spring Boot | [`apps/java/`](apps/java/) | 8094 |
| php | Slim 4 | [`apps/php/`](apps/php/) | 8095 |
| rust | axum | [`apps/rust/`](apps/rust/) | 8096 |
| ruby | Rack(Puma) | [`apps/ruby/`](apps/ruby/) | 8097 |
| kotlin | Ktor(Netty) | [`apps/kotlin/`](apps/kotlin/) | 8098 |

Every app uses container-**internal 8090** (to simplify the contract), and only maps differently to the host as 8090–8098.

> ⚠️ **App build images use an Alpine (musl) base.** With Debian/glibc build images, Docker Desktop's (Windows) built-in DNS proxy returns the package registries (nuget/pypi/maven, and npm's Fastly CNAME chain) to the glibc resolver as failures, so `dotnet restore`/`pip install`/Maven downloads get blocked by DNS errors. The musl resolver works fine in the same environment and has no problems on Linux-native Docker (CI) either, making this the fundamental fix that works portably without per-host `extra_hosts`/IP pinning (the shared compose file has no hardcoded IPs).

## Layout

```
harness/
├─ docker-compose.yml     # keycloak(default) + app-{go,dotnet,node,python,java,php,rust,ruby,kotlin}(profile: apps)
├─ keycloak/
│  └─ harness-realm.json  # reuses go/testdata/it-realm-realm.json (realm import)
├─ contract/
│  └─ CONTRACT.md         # common HTTP contract (source of truth, v2) — every language app implements it identically
├─ apps/
│  ├─ go/                 # Go sample app (net/http)
│  ├─ dotnet/             # C# sample app (ASP.NET Core)
│  ├─ node/               # Node sample app (Express 5)
│  ├─ python/             # Python sample app (FastAPI)
│  ├─ java/               # Java sample app (Spring Boot)
│  ├─ php/                # PHP sample app (Slim 4)
│  ├─ rust/               # Rust sample app (axum)
│  ├─ ruby/               # Ruby sample app (Rack/Puma)
│  └─ kotlin/             # Kotlin sample app (Ktor/Netty)
├─ driver/                # k6 load driver (scenarios.js)
├─ conformance/
│  └─ conformance.mjs     # contract-conformance checks (per-endpoint asserts from CONTRACT.md) → signals/<lang>.conformance.json
├─ security/
│  └─ probe.mjs           # JWT-validation hardening attack probes (alg=none·HS/RS confusion·flood, etc.) → signals/<lang>.security.json
├─ suites/
│  ├─ run-suite.sh        # orchestrator that runs each language's suites/<lang>.sh
│  └─ <lang>.sh           # runs each SDK's own unit tests + coverage + lint in the toolchain image → signals/<lang>.suite.json
├─ report/
│  ├─ score.mjs           # 4-dimensional weighted scoring → SCORECARD.md
│  ├─ aggregate.mjs       # (for the legacy run.sh) k6 results → RESULTS.md
│  └─ signals/            # conformance/security/suite signal JSON (generated, not committed)
├─ run.sh                 # legacy: k6 performance comparison only (one command) → report/RESULTS.md
└─ verify.sh              # comprehensive pipeline: KC→apps→conformance+security+k6→suites→score → report/SCORECARD.md
```

## Usage (legacy — k6 performance comparison only)

A one-command pipeline — `run.sh` brings up Keycloak (waiting for health) → builds and starts each language app (waiting for healthz) → runs the k6 load (containers inside the compose network) → aggregates the report → runs compose down, in that order, and exits non-zero if the functional gate (checks 100%) fails. Use it **when you only need k6 performance measurement/comparison** — for comprehensive verification that also includes conformance/security/suite/scoring, use `verify.sh` below.

```bash
cd harness
./run.sh go                                    # run just the Go app → report/RESULTS.md (go is also the default)
./run.sh go dotnet node python java            # run and compare 5 languages (legacy targets) sequentially — any of the 9 languages can be passed as args
cat report/RESULTS.md                          # functional correctness gate + cross-language performance table
```

`report/RESULTS.md` produces both (1) a **functional correctness gate** (each language's checks PASS rate — 100% required, exits non-zero if below) and (2) a **performance comparison table** (validate p95 · admin CRUD p95 · RPS · error rate). The performance numbers are for measurement/comparison (not enforced thresholds) and, as noted above, include framework overhead — they are relative comparison values that vary by host/load.

The resulting `report/RESULTS.md` (and the `report/<lang>.json` k6 summaries) are generated artifacts and are not committed (`report/.gitignore`).

Running the steps manually (for debugging):

```bash
docker compose up -d keycloak                  # bring up only Keycloak (including realm import)
docker compose --profile apps up -d --build    # bring up the language sample apps too
docker compose down -v
```

## Verification & Scoring (verify.sh)

`verify.sh` includes the k6 performance comparison but is a broader **comprehensive verification & scoring pipeline** — it aggregates, with a language-neutral scorer, whether each language SDK implements the contract correctly (functional), validates JWTs safely (security), keeps its own tests green (coverage/quality), and how completely it implements the contract surface (isomorphism approximation, with performance to follow), producing `report/SCORECARD.md`.

```bash
cd harness
./verify.sh go dotnet node python java php rust ruby kotlin   # all 9 languages (this same 9 is also the default)
./verify.sh go node                                     # just 1–2 languages for a local smoke test
cat report/SCORECARD.md
```

Pipeline stages (repeated per language): bring up Keycloak once (wait for health) → build and start each language app (wait for healthz) → **conformance** ([`conformance/conformance.mjs`](conformance/conformance.mjs), per-endpoint asserts from CONTRACT.md v2) → **security** ([`security/probe.mjs`](security/probe.mjs), JWT-validation hardening attack probes — alg=none · HS/RS confusion · unknown/missing kid · malformed · flood, etc.) → **k6 performance** (`driver/scenarios.js`, inside the compose network) → stop the app → after all languages complete, **suites** ([`suites/run-suite.sh`](suites/run-suite.sh), runs each SDK's own unit tests + coverage + lint in the language toolchain image — not a reimplementation) → **score** ([`report/score.mjs`](report/score.mjs)). A single language's app-build/health-check/probe failure is isolated into `report/signals/<lang>.error.json` and the remaining languages continue (`|| true` applied throughout).

### 4-dimensional Scorecard

| Dimension | Weight | Source signal | Formula |
|---|---|---|---|
| functional | 30% | `signals/<lang>.conformance.json` `{passed,failed,checks[]}` | `passed / (passed+failed) * 100` |
| security | 30% | `signals/<lang>.security.json` `{defended,total,probes[]}` | `defended / total * 100` |
| coverage/quality | 20% | `signals/<lang>.suite.json` `{coverageLine,coverageBranch,lintClean,ran,unit,testsPassed}` | **0 unless `ran && testsPassed === true`** (fail-closed — a broken suite must not still earn full coverage marks); then for languages where branch is measured (>0), `line*0.6+branch*0.3+lint*0.1`; for unmeasured languages, fall back to `line*0.9+lint*0.1` (so as not to penalize the unmeasured with 0%) |
| performance/isomorphism (perfiso) | 20% | `report/<lang>.json` (k6 summary, `validate_duration` p95) + conformance pass rate | `perf*0.5 + iso*0.5` when k6 data is present; otherwise `iso` only (no penalty for unmeasured languages). `perf = min(100, (bestP95 / p) * 100)` — fastest language scores 100, one k× slower scores 100/k |

The overall score is the weighted sum of the 4 dimensions; grades are `overall≥90 → A` · `≥80 → B` · `≥70 → C` · otherwise `D`. `report/SCORECARD.md` contains a table sorted by overall score descending, plus per-language rule-based remediation feedback (which probe failed, which coverage is lacking, etc.).

> **Performance/isomorphism (20%)** is wired to k6. `score.mjs` reads the k6 summary at `report/<lang>.json`, extracts `metrics.validate_duration.values["p(95)"]`, and scores each language relative to the fastest in the run (`perf = min(100, (bestP95 / p) * 100)`). The dimension is then `perf * 0.5 + iso * 0.5` (iso = conformance pass rate). Languages with no k6 data fall back to isomorphism only — no penalty for unmeasured languages. Missing signals (e.g., app build failure) are scored as 0 without crashing.

### Signal files (`report/signals/`)

Generated artifacts (not committed, `report/.gitignore`) that `verify.sh`/`suites/run-suite.sh` write per language and `score.mjs` reads:

- `<lang>.conformance.json` — produced by conformance.mjs (§functional)
- `<lang>.security.json` — produced by probe.mjs (§security)
- `<lang>.suite.json` — the last-line JSON from `suites/<lang>.sh` (§coverage/quality). Coverage credit is given only when `ran && testsPassed === true`; otherwise the dimension scores 0 (fail-closed — a broken suite must not still earn full coverage marks). Falls back to `{"ran":false}` if `suites/<lang>.sh` is missing or violates the convention (a single last line of JSON).
- `<lang>.error.json` — an isolated record written on app-build/startup failure (that language then skips conformance/security/k6 and may only reflect coverage/quality).

### Execution scope — CI first, local for smoke

Running the full `verify.sh` across 9 languages is heavy (tens of minutes), since it includes pulling each language's toolchain image + installing dependencies + running the tests. **CI is the primary execution vehicle** — the `score-all` job in `.github/workflows/harness.yml` runs the full 9 languages nightly (`schedule` 03:00 UTC) and on demand (`workflow_dispatch`) and uploads `SCORECARD.md` + `report/signals/` as artifacts (`timeout-minutes: 60`). **Locally (especially on Windows Docker Desktop) it is recommended to limit to a 1–2 language smoke** — the Alpine (musl) base (see the warning above) solves the DNS gotcha, but a full 9-language build + test is inefficiently heavy for the local iterative development loop.

## Contract

Every language sample app implements the endpoints, request/response schemas, and error mappings defined in [`contract/CONTRACT.md`](contract/CONTRACT.md) identically (only the port differs via `APP_PORT`; v2 adds auth extensions, 5 admin resources, and error paths). The k6 driver, conformance, and security probes all need to know only this single contract to drive and verify every language app identically.
