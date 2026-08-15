# 문서 지도 (Documentation Map)

> **Looking for user documentation?** It is in English and lives in [`guides/`](guides/) — start with
> [Getting Started](guides/getting-started.md). The rest of this directory is the project's internal
> record and is written in Korean.

이 저장소의 `docs/` 아래 문서 **전부**를 한 곳에서 본다. 각 줄의 마지막 칸이 이 지도의 존재 이유다 —
**"여기서만 알 수 있는 것"**, 즉 그 문서를 열지 않으면 어디서도 얻을 수 없는 정보다. 다른 문서에도
있는 내용이라면 그 칸은 비어 있어야 하고, 비어 있어야 할 줄이 많아지면 문서를 합쳐야 한다는 신호다.

끝난 설계 스펙·WBS·검증 로그는 태그 `archive/docs-history-2026-08`에 있다.

**상태 표기**

| 표기 | 뜻 |
|---|---|
| 운영 | 지금도 갱신되는 살아있는 문서. 낡으면 고친다. |
| 완료 | 끝난 작업의 **기록**. 갱신하지 않는다 — 지금 상태는 [CLAUDE.md](../CLAUDE.md)에 있다. |
| 진행 | 아직 열려 있는 작업. 체크박스가 실제 할 일이다. |

---

## 1. 사용자 문서 (영문)

SDK를 **쓰는** 사람을 위한 문서다. 영문으로 유지하며 한글 미러를 두지 않는다.

| 문서 | 상태 | 여기서만 알 수 있는 것 |
|---|---|---|
| [Getting Started](guides/getting-started.md) | 운영 | Python `aio` / Node / .NET / Rust **async 변형**을 나란히 둔 것. **호환성 표**(각 행 머리의 게시본이 실은 기반 라이브러리). **Admin capability matrix**(언어별 직접 커버리지 — 루트 README는 요지만 적고 이 표를 가리킨다). |
| [Development environment setup](guides/development-setup.md) | 운영 | 새 PC에서 언어별 툴체인을 세우는 **절차**와 `node scripts/doctor.mjs` 사용법. 변수 이름(`KCSDK_*`)은 CLAUDE.md·rules에도 있으나, 설치 순서는 여기에만 있다. |
| [Deploying a Keycloak server](guides/deploying-keycloak-server.md) | 운영 | SDK가 아니라 **상대편 서버**를 세우는 법 — 단일 VM + Docker Compose + Caddy 자동 TLS 프로덕션 구성. |
| [Add-a-language playbook](guides/add-a-language-playbook.md) | 운영 | 10번째 언어를 추가할 때 밟는 순서. **코드 생성기도 저품질 티어도 두지 않는다**는 depth-first 원칙과 그 이유. **§4 계약의 진실 원천은 [CLAUDE.md](../CLAUDE.md)다**(원본 스펙이 아니라). |
| [Language support roadmap](roadmap/language-support.md) | 운영 | 다음에 어떤 언어를, 왜 그 순서로 하는지. 채택/기각된 후보와 판단 근거. |

## 2. 거버넌스

| 문서 | 상태 | 여기서만 알 수 있는 것 |
|---|---|---|
| [AI 거버넌스 프레임워크](governance/ai-governance-framework.md) | 운영 | 이 프로젝트의 작업 규약 — 정량 품질 게이트, 이중검증, 미달 시 루프 엔지니어링. §7이 *언어 SDK를 만드는* 루프(디스패치→TDD→G1–G6)다. 별도 검증 로그 파일은 새 언어의 필수 산출물이 아니다. |
| [작업 루프](governance/working-loop.md) | 운영 | **규칙이 아니라 순서.** 불변식을 증명하거나 가드를 들일 때 무엇을 어떤 순서로 밟는지, 그리고 **0단계에서 "만들지 않는다"로 나가는 기각 체크리스트** — 이미 기각된 제안과 되살릴 조건이 여기에만 있다. 변이 3요건 (a)(b)(c)가 각각 무엇을 답하는지도. |

## 3. 진행 계획

체크박스가 **실제 할 일**인 열린 작업만 둔다. 끝난 계획서는 위 아카이브 태그에 있다.

| 문서 | 날짜 | 상태 | 여기서만 알 수 있는 것 |
|---|---|---|---|
| [하네스 판정·출처 완결 계획](superpowers/plans/2026-08-12-harness-judgment-and-provenance-completion.md) | 08-12 | 진행 | 판정 층(`install-matrix.mjs`)·관측 층(`consume/*-run.sh`)·가드 층(`scripts/test/*`) 3계층을 순서대로 고치는 분해 — Phase A만 반영됐고 Phase B~E는 아직이다. ⚠️ S-B1(dotnet 레그 실패)은 git-ignored 로컬 산출물을 CI 상태로 오독한 것이라 **틀렸다**. |

---

## 이 지도의 유지

`scripts/check-docs.mjs`(검사 9)가 **양방향**으로 대조한다:

- `docs/**/*.md` 중 이 지도에 링크되지 않은 파일이 있으면 실패 — 문서를 추가하고 지도에 안 넣는 것을 막는다.
- 이 지도의 링크가 존재하지 않는 파일을 가리키면 실패 — 문서를 지우거나 옮기고 지도를 안 고치는 것을 막는다.

한쪽만 검사하면 반대 방향 드리프트가 그대로 통과한다. 새 문서를 넣을 때는 **마지막 칸을 반드시
채워라** — 채울 말이 없다면 그 문서는 기존 문서에 합쳐야 한다는 뜻이다.
