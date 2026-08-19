# 문서 지도 (Documentation Map)

> **Looking for user documentation?** It is in English and lives in [`guides/`](guides/) — start with
> [Getting Started](guides/getting-started.md). The rest of this directory is the project's internal
> record and is written in Korean.

이 저장소의 `docs/` 아래 문서 **전부**를 한 곳에서 본다. 각 줄의 마지막 칸이 이 지도의 존재 이유다 —
**"여기서만 알 수 있는 것"**, 즉 그 문서를 열지 않으면 어디서도 얻을 수 없는 정보다. 다른 문서에도
있는 내용이라면 그 칸은 비어 있어야 하고, 비어 있어야 할 줄이 많아지면 문서를 합쳐야 한다는 신호다.

끝난 설계 스펙·WBS·검증 로그는 아카이브 태그에 있다 — `archive/docs-history-2026-08`(설계·WBS 일괄, #191)과
`archive/docs-history-2026-08b`(하네스 판정·출처 완결 계획서, #213). **기각 항목의 근거는 거기에만 남는다.**

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
| [Getting Started](guides/getting-started.md) | 운영 | 언어마다 설치→퀵스타트를 한 흐름으로 밟는 유일한 자리. Python `aio` / Node / .NET / Rust **async 변형**을 나란히 둔 것. 언어별 런타임 하한이 `doc-guard`로 빌드 파일과 대조되는 자리이기도 하다. |
| [Compatibility reference](reference/compatibility.md) | 운영 | 각 **게시본**이 실제로 어떤 Keycloak 서버 범위·기반 라이브러리·런타임으로 나갔는가. `main`이 아니라 그 릴리스의 값이라는 것이 이 표의 요지다. 버전 칸은 `df_published_version`과 기계 대조된다. |
| [Admin capability reference](reference/admin-capability.md) | 운영 | 언어별 admin 직접 커버리지 5×5 표와, 편의 메서드가 없을 때 무엇을 대신 부르는가. **U 열은 아홉 소스와 기계 대조된다**(`check-admin-capability.mjs`) — 표를 찾는 세 줄은 문구가 곧 조준점이다. |
| [Development environment setup](guides/development-setup.md) | 운영 | 새 PC에서 언어별 툴체인을 세우는 **절차**와 `node scripts/doctor.mjs` 사용법. 변수 이름(`KCSDK_*`)은 CLAUDE.md·rules에도 있으나, 설치 순서는 여기에만 있다. |
| [Deploying a Keycloak server](guides/deploying-keycloak-server.md) | 운영 | SDK가 아니라 **상대편 서버**를 세우는 법 — 단일 VM + Docker Compose + Caddy 자동 TLS 프로덕션 구성. |
| [Add-a-language playbook](guides/add-a-language-playbook.md) | 운영 | 10번째 언어를 추가할 때 밟는 순서. **코드 생성기도 저품질 티어도 두지 않는다**는 depth-first 원칙과 그 이유. **§4 계약의 진실 원천은 [CLAUDE.md](../CLAUDE.md)다**(원본 스펙이 아니라). |
| [Language support roadmap](roadmap/language-support.md) | 운영 | 다음에 어떤 언어를, 왜 그 순서로 하는지. 채택/기각된 후보와 판단 근거. |

## 2. 거버넌스

| 문서 | 상태 | 여기서만 알 수 있는 것 |
|---|---|---|
| [작업 프로세스](governance/process.md) | 운영 | **모든 작업의 6단계**(기획→계획→검토→일정→수행→검증)와 각 단계의 나가는 조건. **WBS 규약**(상태 표기·계층·"끝나는 조건은 명령이어야 한다"). **PM의 중재 규칙** — 라우팅·Grok 독립 레그·결과 재검증·갈릴 때의 재정. 품질 게이트 G1–G6. **기각 체크리스트 7**과 이미 기각된 제안·되살릴 조건(여기에만 있다). 변이 3요건 (a)(b)(c)가 각각 무엇을 답하는지도. |

## 3. 진행 계획

| 문서 | 날짜 | 상태 | 여기서만 알 수 있는 것 |
|---|---|---|---|
| [문서 IA 재설계 SDD](superpowers/plans/doc-ia-sdd.md) | 2026-08-18 | 진행 | 문서 354KB·소스 243파일·집행장치 55종을 4개 에이전트로 훑어 확정한 **결함 목록과 그 우선순위**. 문서별 **가드 결합도**(README 55 ↔ playbook 0)와 그것으로 산정한 PR 분할 순서. 릴리스 런북이 정식 게시 뒤에도 "정식 없음"이라 말한 P0와 그것을 놓친 앵커의 구조적 이유. 사실별 **단일 소유자 표**와, 언어를 1차 축으로 두면 안 되는 근거. |

열린 계획서는 `docs/superpowers/plans/`에 두고 위 표에 한 줄을 넣는다 —
`| 문서 | 날짜 | 상태 | 여기서만 알 수 있는 것 |` 네 칸이고, 검사 9가 마지막 칸의 길이까지 본다.

두는 기준은 하나다: **체크박스가 실제 할 일인 것.** 전 항목이 닫히면 `doc-status`를 `complete`로
내리고(가드가 강제한다), 아카이브 태그로 내린 뒤 이 절에서 지운다.

---

## 이 지도의 유지

`scripts/check-docs.mjs`(검사 9)가 **양방향**으로 대조한다:

- `docs/**/*.md` 중 이 지도에 링크되지 않은 파일이 있으면 실패 — 문서를 추가하고 지도에 안 넣는 것을 막는다.
- 이 지도의 링크가 존재하지 않는 파일을 가리키면 실패 — 문서를 지우거나 옮기고 지도를 안 고치는 것을 막는다.

한쪽만 검사하면 반대 방향 드리프트가 그대로 통과한다. 새 문서를 넣을 때는 **마지막 칸을 반드시
채워라** — 채울 말이 없다면 그 문서는 기존 문서에 합쳐야 한다는 뜻이다.
