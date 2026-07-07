# 설치·동작 검증 하네스 (Install-&-Operate Harness)

실배포(공개 레지스트리) 없이, **각 언어 SDK를 "게시된 패키지처럼" 로컬 레지스트리에서 설치하고 실제 Keycloak에 대해 동작까지 검증**한다. 기존 하네스(`harness/`)가 SDK를 **소스 경로**로 소비하는 것과 달리, 이 하네스는 실 배포 산출물의 **설치 경로**(매니페스트·파일목록·엔트리포인트·메타데이터·의존성 해석)를 검증한다.

- 설계: [docs/superpowers/specs/2026-07-07-install-operate-harness-design.md](../../docs/superpowers/specs/2026-07-07-install-operate-harness-design.md)
- 언어별 정확한 명령(권위 소스): [docs/superpowers/specs/2026-07-07-install-recipes-research.md](../../docs/superpowers/specs/2026-07-07-install-recipes-research.md)

## 실행

```bash
cd harness/install
./install-verify.sh                                  # 전 8개 언어(기본)
./install-verify.sh go python                        # 일부만
```

산출물: `report/INSTALL-MATRIX.md`(언어별 단계 상태 표) + `report/signals/<lang>.install.json`(원본 신호). 둘 다 git-ignored(생성물).

**한 언어의 실패는 격리**된다 — 해당 언어의 신호에 `error`로 기록되고 나머지 언어는 계속 진행한다(`install-verify.sh`는 항상 exit 0, 매트릭스가 결과 담체).

## 파이프라인 (언어별 4단계)

```
A. Publish   publish/<lang>.sh 가 실 배포 산출물을 빌드 → 로컬 레지스트리에 게시.
B. Install   consume/<lang>.Dockerfile(파일만) → 런타임 엔트리포인트 consume/<lang>-run.sh 가
             install-net에서: 레지스트리 설치 → quickstart 스모크 → 하네스 앱 기동.
             상태는 호스트 마운트 /status 의 마커 파일(installed.ok·quickstart.ok)로 회수.
C. Operate   설치된-패키지 앱에 대해 기존 conformance.mjs(계약 26체크) + security/probe.mjs(JWT 9프로브) 재실행.
D. Report    report/install-matrix.mjs 가 signals/*.install.json → INSTALL-MATRIX.md.
```

**최대 재사용**: 앱 코드(`harness/apps/<lang>`)·conformance·security·Keycloak realm은 그대로 재사용하고, **의존성 해석 소스만** 소스경로→로컬 레지스트리로 바꾼다. 통과/실패가 곧 "게시된 패키지가 실제로 설치·동작하는가"를 뜻한다.

## 언어별 로컬 레지스트리 (하이브리드 = 생태계 네이티브 로컬)

| 언어 | 로컬 소스 | 소비자 실명령(소스 URL만 로컬) |
|---|---|---|
| node | Verdaccio(실 npm 프로토콜) | `npm install @xzawed/keycloak-sdk@0.1.0 --registry …` |
| python | pypiserver(PEP 503 simple) | `pip install "keycloak-sdk==0.1.0"`(+`PIP_EXTRA_INDEX_URL`) |
| go | file GOPROXY(디렉터리 볼륨) | `GOPROXY=file:///proxy,… go get …/go@v0.1.0` |
| dotnet | BaGetter(NuGet V3) | `dotnet add package Xzawed.Keycloak.Sdk --version 0.1.0` |
| java | nginx 정적 staged .m2 | POM: `keycloak-sdk-bom:0.1.0`(import) + `keycloak-sdk` |
| ruby | 정적 gem repo(generate_index) | `gem install keycloak-sdk --version 0.1.0 --source …` |
| php | Satis(정적 type:composer) | `composer require xzawed/keycloak-sdk:^0.1` |
| rust | cargo-local-registry(소스 치환) | `cargo build --offline`(Cargo.toml `keycloak-sdk="0.1.0"`) |

호스트 포트: node 18090 · python 18091 · go 18092 · dotnet 18093 · java 18094 · ruby 18095 · php 18096 · rust 18097(앱 healthz 폴링용). go·rust는 레지스트리 서비스 없이 디렉터리 볼륨을 소비 컨테이너에 마운트한다.

## 리포트 해석 (INSTALL-MATRIX.md)

| 열 | 의미 |
|---|---|
| artifact | 실 배포 산출물 빌드 성공 |
| publish | 로컬 레지스트리 게시 성공 |
| install | 소비 컨테이너가 레지스트리에서 설치 성공(마커 installed.ok) |
| quickstart | 설치된 패키지로 quickstart 스모크 성공(마커 quickstart.ok) |
| app-boot | 하네스 앱 기동·healthz 응답 |
| conformance | 계약 준수 체크 통과/총 (26 기준) |
| security | JWT 하드닝 프로브 방어/총 (9 기준) |
| notes | 실패 사유(error) |

## ⚠️ 주의

- **전 컨테이너 Alpine/musl 베이스** — Windows Docker Desktop 내장 DNS 프록시가 Debian/glibc 리졸버에 레지스트리 CNAME 체인을 실패로 돌려주는 게차 회피. 소비자는 install-net에서 레지스트리를 **서비스명**으로 해석(임베디드 DNS).
- **로컬 Windows**: 가벼운 순수언어(node·go·python)는 로컬 실측 권장. 무거운 언어(java·dotnet·ruby·php·rust)는 빌드 시간이 길어 CI 1차 권장.
- **CI**: [.github/workflows/harness.yml](../../.github/workflows/harness.yml)의 `install-all` 잡(야간 03:00 UTC + 수동 `workflow_dispatch`, `timeout-minutes: 90`)이 8언어 전체를 실행하고 `INSTALL-MATRIX.md`+`signals/`를 아티팩트로 업로드한다. PR/푸시엔 미실행(무겁다).
- 실 레지스트리 배포는 여전히 사람 게이트([DEPLOY.md](../../DEPLOY.md)) — 이 하네스는 배포 전 최종 검증 역할.
