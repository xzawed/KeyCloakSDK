# Contribution Guide (CONTRIBUTING)

This is the **single source of truth for the verification workflow** when contributing to the Keycloak polyglot SDK (Java + Python). It gathers in one place the gates you must pass before merging, the local run commands, how to add tests, and the PR checklist. (For project structure and architecture see [CLAUDE.md](CLAUDE.md), for deployment see [DEPLOY.md](DEPLOY.md), and for verification history see [docs/governance/](docs/governance/).)

> The machine-specific absolute-path commands for this repository (this developer's JDK/venv paths) live in [CLAUDE.md](CLAUDE.md). Below are the **portable commands that work on any machine**.

---

## 1. Gates you must pass before merging

CI (`.github/workflows/ci.yml`, `python-ci.yml`) runs automatically on every push/PR. **If any of the following is red, do not merge.**

### Java (`mvn -f java/pom.xml verify`)
| Gate | Tool | Enforcement |
|---|---|---|
| Compile | `maven-compiler` | Build turns red on failure |
| Unit tests (117) | surefire (`*Test`) | Red if even one fails |
| Integration tests (6, Docker) | failsafe (`*IT`, Testcontainers real Keycloak 26.6) | Runs in the CI `integration` job |
| **Coverage line ≥90% / branch ≥85%** | JaCoCo `jacoco:check` (bound to verify) | Build turns red if below threshold |
| Dependency convergence · Java/Maven version | maven-enforcer | Red on conflicts / version below minimum |

### Python (`python/`)
| Gate | Command | Enforcement |
|---|---|---|
| Lint (extended ruleset incl. security S/bandit) | `ruff check src tests examples` | Job turns red on violations |
| Format | `ruff format --check src tests examples` | Red if unformatted |
| **Coverage 100% on logic modules** | `pytest -m "not integration" --cov=keycloak_sdk` | `pyproject [tool.coverage.report] fail_under=100` — red if below |
| Types (strict) | `mypy src` | Red on errors |
| Integration tests (11, Docker) | `pytest -m integration` | Runs in the CI `integration` job |

> ⚠️ **Network-boundary modules are omitted from coverage** (Java: `AuthClient`/`AdminClient`, Python: `auth.py`/`admin/__init__.py` plus the aio counterparts). These have no unit-coverage floor and are verified **only by integration tests**, so whenever you change boundary code, run the integration tests along with it.

---

## 2. Running locally (portable commands)

### Java (requires JDK 21+ · Maven 3.9+)
```bash
mvn -f java/pom.xml verify                                   # Full: unit + coverage gate (plus integration if Docker is available)
mvn -f java/pom.xml test -DskipITs=true                      # Unit tests only (coverage gate included)
mvn -f java/pom.xml test -pl <module> -Dtest=<Class>#<method>  # Single test
```

### Python (3.10+ · Docker only needed for integration tests)
```bash
cd python
python -m pip install -e ".[dev]"
ruff check src tests examples          # ① Lint (security scan included)
ruff format --check src tests examples # ② Format
mypy src                               # ③ Types (strict)
pytest -m "not integration" --cov=keycloak_sdk   # ④ Unit + 100% coverage gate
pytest -m integration                  # ⑤ Integration (Docker required)
```
Run `ruff format` (without ‑‑check) to apply formatting automatically.

---

## 3. How to add tests

| | Java | Python |
|---|---|---|
| Unit test location | `java/<module>/src/test/java/...` | `python/tests/unit/` (async under `tests/unit/aio/`) |
| Integration test location | `java/keycloak-sdk/src/test/java/...` filename `*IT.java` | `python/tests/integration/` (async as `*_async_it.py`) |
| Naming convention | unit `*Test`, integration `*IT` (the surefire/failsafe split criterion) | `def test_*` / `async def test_*`, integration via `@pytest.mark.integration` |
| Real Keycloak fixture | `java/keycloak-sdk/src/test/resources/it-realm-realm.json` | Reuses the same file (`tests/integration/conftest.py`) |

- When you change **JWT / security-related code**, add negative tests alongside it (alg=none · unsigned · algorithm confusion · iss/aud · clock skew — follow the existing `JwtValidatorTest` / `test_jwt.py` patterns). Write **non-vacuous** assertions grounded in real signatures so accidental passes are ruled out.
- Attach tests to new branches so the 100% (Python) / 90·85% (Java) coverage gates stay intact.

---

## 4. PR checklist

- [ ] Work on a feature branch (no direct commits to main)
- [ ] Confirm all of the **section 1 gates** are green locally
- [ ] Add tests for new code (keep the coverage gate intact); include negative tests for security code
- [ ] Do not expose underlying library types in the public API (hide them behind the facade — a rule shared by Java/Python)
- [ ] Keep docs up to date: when structure/commands/test counts change, sync [CLAUDE.md](CLAUDE.md), the relevant `README`, and [docs/](docs/)
- [ ] (If it's a governance task) record the gate verdict in [docs/governance/verification-log*.md](docs/governance/)

---

## 5. ⚠️ Branch protection (requires action by the repository owner)

CI running and **CI blocking a merge** are two different things. In GitHub → Settings → Branches → the `main` protection rule, you must designate the following as **required status checks** for a red PR's merge to actually be blocked (this cannot be configured via a repository file):
- Java: `build` (matrix), `integration`
- Python: `test` (matrix), `integration`

> Designating a job skipped by a path filter (`java/**` · `python/**`) as required can leave it pending, so adjust the filters as needed or manage the required list per language.

---

## 6. Advisory quality roadmap (optional · not yet enforced in CI)

Coverage guarantees only that "the code ran," not that "the tests catch defects." The tools below help close that gap. When adopting them, first run them as **advisory (non-blocking)** and gate them once stabilized.

- **Mutation testing**
  - Java: [pitest](https://pitest.org) — `org.pitest:pitest-maven`. ⚠️ This project uses **JUnit 6.1.1**, so you must first confirm `pitest-junit5-plugin`'s JUnit Platform 6 compatibility (currently unverified).
  - Python: [mutmut](https://github.com/boxed/mutmut) — e.g. `pip install mutmut && mutmut run --paths-to-mutate src/keycloak_sdk/jwt.py`. ⚠️ **No native Windows support (requires WSL)** — run it in CI (ubuntu) or WSL.
  - Priority targets: **security-critical modules** such as `jwt.py` / `JwtValidator`.
- **Extended static analysis**: Python `ruff` already enforces security (S/bandit), bugginess (B), and modernization (UP) rules. Java currently only enforces enforcer (dependencies) — evaluate one of [SpotBugs](https://spotbugs.github.io) · Checkstyle · Spotless as an advisory profile.
- **Expanding mypy scope**: currently only `mypy src` is strict. Extending it to `tests` requires cleaning up test types first.
