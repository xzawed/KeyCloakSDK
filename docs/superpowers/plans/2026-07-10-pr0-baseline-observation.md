# PR 0 기준선 관측 (Task 3)

> <!-- doc-status: complete -->
> **✅ 완료된 계획 — 기록이다. 실행하지 말 것.** 아래 체크박스는 **전부 미체크로 남아 있지만 할 일이
> 아니다** — 실행 당시 갱신되지 않았을 뿐 작업은 끝났다. 바로 아래의 "For agentic workers" 지시도
> 그때의 것이라 지금은 유효하지 않다. 지금 상태는 [CLAUDE.md](../../../CLAUDE.md) ·
> [구현 이력](../../governance/history.md) · [문서 지도](../../README.md)에 있다.

- 실행: `gh run view 29294940225` · 브랜치 `fix/pr0-verification-gates` · 2026-07-14 (workflow_dispatch)
- 목적: 게이트를 조인 뒤 하네스가 실제로 무엇을 보고하는지 기록한다. PR 0는 게이트를 **무장**하는 작업이고, 무장된 게이트가 드러내는 결함은 후속 PR의 대상이다.
- ⚠️ 이 실행은 Task 1~9·2가 **모두 적용된 뒤** 돌렸으므로(구현을 먼저 하고 push), Task 3(관측)과 Task 11(최종 검증)이 사실상 한 실행으로 합쳐졌다 — 게이트가 완전히 무장된 상태의 관측이다.

## 잡 결과

| 잡 | 결론 | 비고 |
|---|---|---|
| mvp-go | skipped | 설계상 dispatch에선 미실행(push/PR 전용) |
| all-langs | **failure** | 레거시 `run.sh` k6 checks 임계 초과 — 기능 체크 실패(node admin 파급). PR 0 무관 |
| score-all | **failure** | verify.sh `--strict`(Task 9)가 node·ruby·suite 실패를 정확히 종료코드로 전파 — **최초 실행**(이전 3회는 exit 126) |
| install-all | **failure** | install-verify.sh `--strict`(Task 8)가 kotlin·node 실패를 종료코드로 전파 — **조용한 초록이 사라짐** |

**핵심: 세 잡의 RED는 게이트가 제대로 작동한 결과다.** 이전엔 verify.sh가 exit 126으로 즉사(score-all 3개월간 SCORECARD 미생성)했고, install-all은 무조건 exit 0으로 실패를 은폐했다.

## INSTALL-MATRIX.md (원문)

```
| lang | artifact | publish | install | quickstart | app-boot | conformance | security | notes |
|---|---|---|---|---|---|---|---|---|
| go     | ✓ | ✓ | ✓ | ✓ | ✓ | 26/26 | 9/9 | |
| dotnet | ✓ | ✓ | ✓ | ✓ | ✓ | 26/26 | 9/9 | |
| node   | ✓ | ✓ | ✓ | ✓ | ✓ | 10/26 | 9/9 | (admin 16개 실패) |
| python | ✓ | ✓ | ✓ | ✓ | ✓ | 26/26 | 9/9 | |
| java   | ✓ | ✓ | ✓ | ✓ | ✓ | 26/26 | 9/9 | (Task 2 수정 성공) |
| php    | ✓ | ✓ | ✓ | ✓ | ✓ | 26/26 | 9/9 | (Task 2 수정 성공) |
| rust   | ✓ | ✓ | ✓ | ✓ | ✓ | 26/26 | 9/9 | |
| ruby   | ✓ | ✓ | ✓ | ✓ | ✓ | 26/26 | 9/9 | |
| kotlin | ✗ | ✗ | ✗ | ✗ | ✗ | 0/0   | 0/0 | publish 소유권 실패 → 본 PR에서 수정 |
```

## SCORECARD.md (원문)

```
| 순위 | 언어 | 기능30 | 보안30 | 커버리지20 | 성능·동형20 | 종합 | 등급 |
| 1 | go     | 100 | 100 | 96  | 100 | 99 | A |
| 2 | python | 100 | 100 | 100 | 58  | 92 | A |
| 3 | rust   | 100 | 100 | 87  | 73  | 92 | A |
| 4 | java   | 100 | 100 | 97  | 54  | 90 | A |
| 5 | kotlin | 100 | 100 | 95  | 52  | 89 | B |
| 6 | dotnet | 100 | 100 | 0   | 66  | 73 | C | (suite 0 테스트 → 커버리지 0)
| 7 | php    | 100 | 100 | 0   | 50  | 70 | C | (suite 0 테스트+린트 실패 → 커버리지 0)
| 8 | node   | 38  | 100 | 98  | 25  | 66 | D | (app admin conformance 10/26)
| 9 | ruby   | 8   | 11  | 10  | 6   | 9  | D | (app conformance 2/24 — 앱 거의 전부 실패)
```

> ⚠️ 이전 스코어카드가 광고하던 "A/97"은 게이트 무력화의 산물이었다. 게이트를 조이자 실제 상태(D 2개·C 2개)가 드러났다.

## 발견된 실제 실패 (각 항목의 소속 PR 표시)

| # | 결함 | 근거 | 원인 계층 | 처리 |
|---|---|---|---|---|
| A | **kotlin publish 소유권 실패** | `mkdir …/kotlin/staging-m2/io: permission denied` (CI 로그 실측) | 하네스(publish/kotlin.sh) — java와 동일 클래스 | **본 PR에서 수정**(Task 2 확장, 증거 확인) |
| B | **node admin conformance 16개 실패** | install 10/26·source 10/26, auth 10개 통과·admin 16개 전부 실패 | SDK/앱(node admin 경로) | **후속 PR** |
| C | **ruby app conformance 2/24** | ruby suite 단위테스트는 73개 통과(testsPassed:true)이나 앱이 거의 전부 실패 | 앱/하네스(ruby 앱 부팅·동작) | **후속 PR** |
| D | **dotnet suite 0 테스트** | `unit:0, testsPassed:false` — 툴체인 컨테이너가 테스트를 못 돌림(app conformance는 26/26 정상) | 하네스(suites/dotnet.sh CI 실행) | **후속 PR** |
| E | **php suite 0 테스트 + 린트 실패** | `unit:0, lintClean:false, testsPassed:false`(app conformance는 26/26 정상) | 하네스(suites/php.sh CI 실행) | **후속 PR** |
| F | **all-langs k6 checks 임계 초과** | 기능 체크 실패로 run.sh exit 1 — B(node admin)의 파급 | 레거시 run.sh(B의 하위 증상) | **후속 PR**(B 해소 시 동반 해소 가능) |

**중요 판정 — 회귀 없음**: 위 실패는 전부 **선행하던 결함**이다. verify.sh는 exit 126으로 CI에서 한 번도 완주한 적이 없어 이 결과들이 처음 드러난 것이다. dotnet/php의 `testsPassed:false`는 테스트가 실제로 0개 실행된 것(unit=0)이므로 "통과한 테스트를 실패로 오판"한 거짓음성이 아니라 fail-closed 정상 동작이다. Task 5의 testsPassed 파싱은 go/node/rust/java/kotlin/ruby 6개 언어에서 정상 unit 카운트 + testsPassed:true를 산출해 로직 정합성이 확인된다.

## 결론

- **PR 0의 목표(게이트를 진짜로 만들기)는 달성됐다.** 게이트가 무장되자 5개의 실제 결함(B~F)이 드러났고, 이는 예전엔 조용한 초록으로 숨어 있었다.
- **Task 2(java/php publish)는 CI에서 검증됐다** — 둘 다 ✓ 26/26 9/9. 같은 클래스인 kotlin(A)은 본 PR에서 동일 수정을 적용했다(CI 재확인 대기).
- **install-all·score-all은 결함 B~F가 고쳐지기 전까지 계속 RED다** — 이는 게이트가 제 역할을 하는 것이다. "최종 CI 초록"(원안 Task 11)은 결함 B~F(후속 PR)가 남아 있는 한 달성 불가하며, 그것이 정확히 이 감사가 예측한 상황이다("예상 밖 실패는 PR 1~6의 결함이며 여기서 발견한다").
- **다음 작업**: kotlin 수정 재검증(CI 재실행) 후, 결함 B~F를 후속 PR로 분리해 클래스 단위(I2)로 닫는다.
