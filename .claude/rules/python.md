---
paths:
  - "python/**"
  - "harness/apps/python/**"
  - "harness/install/consume/python*"
  - ".github/workflows/python-*.yml"
---

# Python 규칙

## 툴체인 (빌드 명령)

가상환경은 `python/.venv`에 있다(리포지토리에 커밋 안 함). 명령은 `python/`에서 실행하거나 절대경로의 venv 인터프리터를 직접 호출한다:
```bash
cd python && "${KCSDK_PY:-.venv/Scripts/python.exe}" -m pytest -m "not integration" --cov=keycloak_sdk   # 단위테스트 224개 + 커버리지 게이트 100%
cd python && "${KCSDK_PY:-.venv/Scripts/python.exe}" -m pytest -m integration            # 통합테스트 11개(Docker 필요, testcontainers)
cd python && "${KCSDK_PY:-.venv/Scripts/python.exe}" -m ruff check src tests examples     # 린트(보안 S/bandit 포함 확장 룰셋)
cd python && "${KCSDK_PY:-.venv/Scripts/python.exe}" -m ruff format --check src tests examples  # 포맷 검사
cd python && "${KCSDK_PY:-.venv/Scripts/python.exe}" -m mypy src                          # 정적 타입 검사(strict)
```
> 다른 PC에서는 `KCSDK_TOOLS`(포터블 툴 상위 디렉터리, 기본 `$HOME/tools`)·`KCSDK_PY`(venv 인터프리터 — POSIX는 `.venv/bin/python`)를 덮어쓰거나, 이미 PATH에 있으면 프리픽스를 생략한다. 설치·진단은 [development-setup.md](../../docs/guides/development-setup.md)(`node scripts/doctor.mjs python`).
- 로컬 배포 빌드 검증(업로드 없이): `cd python && "${KCSDK_PY:-.venv/Scripts/python.exe}" -m build` → `dist/keycloak_sdk-0.1.0-py3-none-any.whl` + `.tar.gz` 생성 확인
- 실제 PyPI 배포는 로컬에서 실행하지 않는다 — `py-v*` 태그 push 시 `.github/workflows/python-release.yml`에서 PyPI Trusted Publisher(OIDC, 저장 시크릿 없음)로 실행(사람 승인 게이트)
- 패키지 `keycloak_sdk`(배포명 `keycloak-sdk`)는 PEP 561 `py.typed` 마커를 포함 — 소비자 측 mypy도 타입 검사 가능

## 게차

`(Python)` 단일 언어 태그로 표시된 게차 항목은 현재 없다 — Python 관련 게차(JWKS DoS-안전 재조회·admin 타임아웃/자원정리 등)는 태그 없는 프로젝트 공통 항목이라 루트 `CLAUDE.md`의 `## 핵심 게차` 섹션에 전문이 남아있다.
