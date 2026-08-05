# PR 0 변이 증명 (I1)

> <!-- doc-status: complete -->
> **✅ 완료된 계획 — 기록이다. 실행하지 말 것.** 아래 체크박스는 **전부 미체크로 남아 있지만 할 일이
> 아니다** — 실행 당시 갱신되지 않았을 뿐 작업은 끝났다. 바로 아래의 "For agentic workers" 지시도
> 그때의 것이라 지금은 유효하지 않다. 지금 상태는 [CLAUDE.md](../../../CLAUDE.md) ·
> [구현 이력](../../governance/history.md) · [문서 지도](../../README.md)에 있다.

각 게이트를 고의로 깨뜨려 실제로 거부하는지 확인한 기록이다. 이 문서 없이 게이트를
신뢰하지 않는다 — CI가 초록인 이유가 코드 품질 때문인지 게이트 무력화 때문인지
구별할 수단이 이것뿐이다.

- 브랜치: `fix/pr0-verification-gates`
- 방식: 게이트 1~4는 컨테이너 없이 로컬(Windows) 직접 호출, 게이트 5는 실제 Docker E2E(`verify.sh node`).

## 요약

| 게이트 | 변이 | 기대 | 실제 | 통과 |
|---|---|---|---|---|
| 실행비트 가드 (Task 1) | `git update-index --chmod=-x harness/verify.sh` | 가드가 파일을 나열하고 exit 1 | `harness/verify.sh` 1줄 검출, 되돌림 후 0줄 | ✅ |
| 커버리지 크레딧 (Task 4) | `testsPassed: false` | coverage 0점, 등급 하락 | coverage 95→0, overall 99→80, 등급 A→B | ✅ |
| security 판정 (Task 6) | status 500 | `defended=false`, `verdict=crashed` | 500·502 crashed, 200 accepted, 404 unexpected 모두 `defended=false`, 400·401만 `true` | ✅ |
| install 매트릭스 (Task 8) | `published: false` | `failedLangs` = `["java"]` | `["java"]` 정확 검출, 정상만 `[]` | ✅ |
| verify.sh E2E (Task 9·5·4) | node 단위테스트 1개 실패 주입 | `exit 1`, node coverage 0 | `verify.sh exit=1`, `== [suite] 실패: node ==`, `testsPassed:false`, SCORECARD node coverage=0 | ✅ |

**5/5 게이트가 고의 파손에 대해 실제로 빨개졌다.** I1(게이트는 반증 가능해야 한다) 이행 완료.

## 원문 출력

### 게이트 1 — 실행비트 가드

```
$ git update-index --chmod=-x harness/verify.sh
$ git ls-files -s -- '*.sh' | awk '$1 == "100644" { print $4 }'
  harness/verify.sh
$ git update-index --chmod=+x harness/verify.sh    # 되돌림
되돌림 후 non-exec 수: 0
```

가드(`.github/workflows/repo-hygiene.yml`)는 이 `100644` 출력이 비어있지 않으면 exit 1 한다.

### 게이트 2 — 커버리지 크레딧 (`scoreLang`)

```
testsPassed=true  → coverage 95 overall 99 A
testsPassed=false → coverage 0  overall 80 B
✓ 통과 (coverage 0점 + 등급 A→B 하락)
```

> 계획서 예시는 `overall 79 / D`였으나 실제 산술은 `functional 100·0.30 + security 100·0.30 + coverage 0·0.20 + perfiso 100·0.20 = 80`(B)이다. 불변식(테스트 실패 → 커버리지 0 + 등급 하락)은 그대로 성립하며, 80/B가 정확한 값이다.

### 게이트 3 — security 판정 (`verdict.classify`/`isDefended`)

```
200  accepted    defended=false
400  rejected    defended=true
401  rejected    defended=true
404  unexpected  defended=false
500  crashed     defended=false
502  crashed     defended=false
✓ 통과 (5xx·200·404 모두 방어 아님, 400/401만 방어)
```

### 게이트 4 — install 매트릭스 (`failedLangs`)

```
정상만       → []
publish 실패 → ["java"]
✓ 통과 (✗ 언어를 정확히 집어냄)
```

### 게이트 5 — verify.sh E2E (가장 중요한 증명)

`node/test/unit/config.test.ts`에 반드시 실패하는 테스트(`expect(1).toBe(2)`)를 주입하고 `verify.sh node`(Docker, 실제 Keycloak+앱+suite 컨테이너)를 돌렸다.

```
MUTATION_VERIFY_EXIT=1              # verify.sh가 exit 1
== [suite node] ==
   -> node.suite.json : {"lang":"node",...,"testsPassed":false,"ran":true}
== [suite] 실패: node ==            # run-suite.sh가 실패 검출
== 스코어링 ==
wrote report/SCORECARD.md
== 완료 — report/SCORECARD.md ==
== 실패: suite  ==                  # verify.sh 최종 실패 블록
SCORECARD node 행: | node | 100 | 100 | 0 | 100 | **80** | B |   # 커버리지 0(fail-closed)
```

체인 전체가 증명됐다: 실패 테스트 → `node.sh`가 `testsPassed:false` emit → `run-suite.sh` exit 1 → `verify.sh`가 `FAILED_LANGS`에 누적 → exit 1, 동시에 `score.mjs`가 node 커버리지를 0점으로 부여(등급 하락). conformance·security는 앱이 정상 부팅해 통과(테스트 실패는 앱이 아니라 suite에만 영향).

## 되돌림 확인

- 게이트 1(exec-bit): `git update-index --chmod=+x`로 되돌림 → `git status` 클린 확인.
- 게이트 5(E2E): ⚠️ 자동 되돌림 스크립트가 `cd harness` 이후 상대경로로 `git checkout`을 실행해 잘못된 cwd(`harness/node/...`)를 참조, 되돌림에 **실패**했다. 주입된 테스트가 워킹트리에 남은 것을 발견하고 **리포 루트에서 `git checkout -- node/test/unit/config.test.ts`로 수동 복구**했다. 이후 `git status --short`는 의도한 `.github/workflows/harness.yml`만 표시(변이 잔재 없음).

최종 `git status --short` 결과: 변이 파일 잔재 없음(워킹트리 클린).
