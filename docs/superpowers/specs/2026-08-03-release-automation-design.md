# 릴리스 자동화 — 설계 스펙

**상태**: 설계 승인됨(사용자) · 적대적 리뷰 반영 완료 · **작성일** 2026-08-03
**선행**: Grok 독립 인프라 분석 + Grok 적대적 설계리뷰 + 직접 재검증(§2·§3의 실측은 전부 이 저장소·실제 GitHub API로 확인)

## 1. 문제

지금 릴리스는 **사람이 손으로 태그를 미는 것**이 유일한 트리거다. 사용자는 이걸 바꾸고 싶어 한다 — 소스가 최종 확정되고 "릴리스해도 좋다"는 확인이 끝나면, **그 이후는 자동화**하고 에이전트(Claude)가 수행할 수 있게.

문제는 "태그를 대신 밀어주기"가 아니다. 태그를 타이핑하는 행위 자체에는 아무 가치가 없다. 가치는 **무엇이 나가는지 보고 판단하는 순간**에 있고, 그 순간을 어디에 두느냐가 설계의 전부다. 동시에 이 저장소에는 자동화 이전에 이미 뚫려 있는 구멍이 있다(§2-A).

## 2. 실측 근거

### A. 태그는 아무 보호도 받지 않는다 — 지금 당장

```
$ gh api repos/xzawed/KeyCloakSDK/rulesets
[{"id":18882689,"name":"PRIMARY","target":"branch",...}]   ← 룰셋 하나, 브랜치 전용

$ gh api repos/xzawed/KeyCloakSDK/environments
{"total_count":0,"environments":[]}                         ← environment 0개
```

`main`은 `bypass_actors: []`로 소유자조차 못 뚫게 잠겨 있는데, **이 저장소에서 가장 되돌릴 수 없는 행위인 릴리스 태그 push에는 룰셋이 없다.** `contents: write`를 가진 어떤 자격증명이든(PAT·GitHub App·워크플로 토큰) 오늘 `go/v9.9.9`를 밀어 9개 레지스트리 중 회수가 유일하게 불가능한 게시를 일으킬 수 있다.

현재의 human-gate는 강제가 아니라 **스크립트의 자제**다 — `scripts/release-trigger.sh:3`:

> `# ⚠️ human-gate: 이 스크립트는 git tag/push를 절대 실행하지 않는다.`

즉 자동화 도입 여부와 무관하게 이 구멍은 닫아야 한다. 자동화는 그걸 닫는 계기다.

### B. `ruby-release.yml`이 참조하는 environment가 실존하지 않는다

`ruby-release.yml:115`가 `environment: release`를 선언하는데 위 API가 보여주듯 environment는 0개다. RubyGems Trusted Publisher 등록도 이 이름을 요구하므로(`DEPLOY.md:143`), 지금 상태로는 Ruby 릴리스 경로가 등록과 어긋난다.

### C. 릴리스 워크플로 9개의 트리거는 전부 태그 전용

`workflow_dispatch` 없음 · 브랜치 `push` 없음 · `release: published` 없음. 게시 잡은 전부 `needs:` 체인으로 게이트돼 있다. 다만 형태가 둘로 갈린다 — **별도 게이트 잡**(java·python·node·go·php·kotlin)과 **게시 잡 안에서 테스트 실행**(dotnet·rust·ruby). 후자는 자격증명을 이미 획득한 뒤에 실패하므로 자세가 다르다(게시는 안 되지만).

### D. 되돌림 비용은 언어마다 다르다 (`DEPLOY.md` §6)

yank/unlist 가능(python·dotnet·ruby·rust·node·php) < Central Portal 스테이징으로 방어(java·kotlin) < **회수 불가(go)**. `DEPLOY.md:362`가 Go를 이렇게 적는다: *"이 아홉 중 유일하게, 복구 시도가 원래 실수보다 더 해로운 레지스트리."*

**Go의 `verify`/`integration`은 아무것도 막지 못한다.** 태그가 GitHub에 존재하는 순간 `proxy.golang.org`는 워크플로 성패와 무관하게 요청 시 서빙한다. Go의 게이트 잡은 사후 참고자료일 뿐이다 — §3 D2가 보수주의가 아니라 **구조적 필연**인 이유다.

## 3. 결정 사항 (사용자 승인)

| # | 결정 | 대안 | 근거 |
|---|---|---|---|
| D1 | **릴리스 PR 머지 = 승인** | GitHub Environment 승인 클릭 · 채팅 승인 후 Claude가 태그 push | 승인 시점에 **무엇이 나가는지 diff로 보인다**. 감사 흔적이 git에 영구 보존된다. Claude가 배포 권한을 전혀 갖지 않아 오동작 상한이 "PR 생성"이다 |
| D2 | **Go만 예외 — 사람이 직접 태그** | 9개 동일 자동화 · 판단 보류 | 태그가 곧 게시라 머지 이후에 게이트를 둘 수 없다(§2-D). `sum.golang.org`가 append-only라 태그 정정이 기존 소비자에게 `checksum mismatch / SECURITY ERROR`를 낸다 |

## 4. 설계

### 4.1 흐름

```
Claude                            사용자                  GitHub Actions
──────                            ──────                  ──────────────
릴리스 PR 준비
 · 버전 범프(수동범프 5개 언어)
 · .github/release-request.json
 · PR 본문에 검증 리포트
        │
        └─ PR 생성 ──────────────►  diff 검토 → [Merge]
                                        = 승인
                                            │
                                            └──► dispatch-release.yml
                                                  · 요청 스키마·언어 검증
                                                  · 태그를 lang+version에서 파생
                                                  · 매니페스트 대조
                                                  · lang=go → 하드 실패
                                                  · 태그 존재 → 스킵(멱등)
                                                  · 태그 룰셋 존재 확인(fail-closed)
                                                  · App 토큰으로 태그 push
                                                        │
                                                  기존 <lang>-release.yml (무수정)
                                                  → verify → integration
                                                  → install-smoke → 레지스트리
```

### 4.2 구성요소

**(a) `.github/release-request.json` — 승인의 대상**

```json
{ "lang": "python", "version": "0.1.0rc2" }
```

⚠️ **`tag` 필드를 두지 않는다.** 태그를 데이터로 받으면 `{"lang":"python","version":"0.1.0rc2","tag":"node-v0.2.0"}`처럼 **싼 언어를 선언하고 비싼 태그를 미는** 권한상승이 성립한다. 태그는 `lang`+`version`에서 `df_tag`(`scripts/lib/deploy-facts.sh:28-31`)로 **파생**한다 — `release-trigger.sh:22`가 이미 쓰는 그 방식이다.

이 파일 하나가 "무엇을 릴리스하는가"의 단일 진실원천이다. 사람이 머지 버튼을 누를 때 화면에 이 diff가 문자 그대로 보인다.

파일은 머지 후에도 저장소에 **남는다**(마지막 릴리스 요청의 기록). 다음 릴리스 PR이 이 파일을 덮어쓰고, 그 **변경**이 트리거다 — 파일의 존재가 아니라 전환이 의도를 나타낸다.

**(b) `.github/workflows/dispatch-release.yml` — 태그 커터**

⚠️ **파일명이 `dispatch-release.yml`인 것은 의도다.** `scripts/check-ci-permissions.mjs:259`의 `isRelease = (f) => /release\.ya?ml$/.test(f)`는 `release-dispatch.yml`을 **매칭하지 못한다**(실측 확인). 그러면 저장소에서 가장 특권적인 이 워크플로가 "모든 `write` 권한은 선언 지점에 근거 주석을 달아야 한다"는 규칙(rule 1·2·5)만 유일하게 면제받고, `--min-release=9`는 정확히 9로 충족돼 **아무 신호도 나지 않는다**. 이름을 바꾸면 규칙을 그대로 상속하고 카운트가 10이 된다.

트리거: `on: push: branches:[main], paths:['.github/release-request.json']` + 복구용 `workflow_dispatch`(입력 `lang`·`version`).

하는 일은 검증과 태그 생성뿐이고 **게시는 하지 않는다**. 권한 선언은 릴리스 워크플로 관용을 따른다(워크플로 레벨 블록 없이 잡마다 선언 + 근거 주석).

⚠️ **App 토큰이 필수인 이유**: 기본 `GITHUB_TOKEN`으로 만든 태그는 다른 워크플로를 트리거하지 않는다(GitHub의 재귀 실행 방지). 이 한 가지 제약이 GitHub App을 요구한다. App 자격증명 미설정은 **스킵이 아니라 실패**여야 하며, GitHub가 job-level `if:`에 `secrets`를 노출하지 않으므로 `php-release.yml:158-163`의 선례대로 **스텝 안에서 env-매핑된 값**으로 검사한다.

`concurrency: { group: dispatch-release, cancel-in-progress: false }` — 저장소에 `concurrency`를 쓰는 워크플로가 하나도 없어 선례가 없다. `cancel-in-progress`는 반드시 `false`다(태그 push 도중 취소가 곧 원자성 사고).

**(c) `.github/rulesets/tags.json` — 강제 장치이자 Go 정책의 진짜 집행자**

두 가지를 한다.

1. **릴리스 태그 생성을 제한한다** — §2-A의 구멍을 닫는다.
2. ⚠️ **Go 정책을 서버 상태로 옮긴다.** App의 우회 권한을 **Go가 아닌 8개 패턴에만** 부여하고 `go/v*`는 소유자 전용으로 남긴다.

2번이 핵심이다. Go 예외를 워크플로 안에만 두면 그 워크플로를 수정하는 머지 하나로 예외가 증발한다 — `on: push` 워크플로는 **밀린 커밋에 있는 그 버전이 실행**되고, `main.json`은 required 승인 0·CODEOWNERS 없음이라 이를 막지 못한다. 룰셋은 저장소 밖 서버 상태라 저장소 내용 변경으로 우회되지 않는다. 이렇게 하면 워크플로가 탈취돼도 **최악이 "회수 가능한 언어의 원치 않는 릴리스"**로 묶인다.

`deletion` 규칙도 함께 건다 — 릴리스 태그는 불변이어야 한다(§4.5).

`bypass_actors`는 `main.json`(`[]`, "소유자조차 우회 불가")과 **정반대**여야 한다. 비어 있으면 아무도 태그를 만들 수 없어 아홉 릴리스가 전부 잠긴다. CONTRIBUTING §4에 이 대비를 명시해 다음 사람이 "일관성" 명목으로 맞추다 저장소를 잠그지 않게 한다.

**(d) 기존 9개 릴리스 워크플로 — 한 줄도 고치지 않는다**

이미 실전 검증된 자산이다(php·python·dotnet이 실제 게시까지 통과). 태그가 붙는 **방식**만 바뀌고 태그 이후는 완전히 동일하다.

### 4.3 왜 머지 게이트가 약해도 되는가

`main.json`의 required 체크는 `doc-facts`·`shell-exec-bits` **둘뿐**이고 `required_approving_review_count: 0`이다. `CONTRIBUTING.md`가 이를 정직하게 인정한다: *"이 보호는 저장소 위생을 지키지 코드 정확성을 지키지 않는다."* 즉 **언어 CI가 빨간 채로도 릴리스 PR을 머지할 수 있다.**

그래도 설계가 성립하는 이유는 **게이트가 태그 이후에 다시 있기 때문**이다. 아홉 워크플로 중 어느 것도 브랜치 CI 상태를 참조하지 않고 **자기 `needs:` 그래프 안에서 테스트를 다시 돌린다**(실측 확인). 머지가 잘못돼도 **태그 이름 하나를 태울 뿐 레지스트리에는 아무것도 가지 않는다**.

이 성질이 성립하지 않는 유일한 언어가 Go이고(§2-D), 그래서 Go가 예외이며 그 예외를 룰셋이 집행한다(§4.2c).

### 4.4 오류 처리 — 전부 fail-closed

| 상황 | 동작 |
|---|---|
| 요청 파일 부재(리버트 등) | 파싱 대상 없음 → 깨끗한 no-op |
| JSON 스키마 위반 | 거부 |
| 미지 언어 | 거부(`df_known`) |
| 해당 레지스트리 표기에 맞지 않는 버전 | 거부(`df_version_re`) |
| `lang: "go"` | 거부 + **왜인지**를 설명하고 사람이 실행할 명령 출력(`release-trigger.sh:35`의 문구 재사용) |
| 요청 버전 ≠ 매니페스트 버전 | 태그 생성 전 중단(`check-versions.mjs --list`가 추출 SSOT) |
| 태그가 이미 존재 | 스킵(멱등) |
| 태그 룰셋이 없음 | **중단** — 강제 장치가 사라진 상태로 태그를 만들지 않는다(§4.6) |
| App 자격증명 미설정 | `::error::` + exit 1 |

### 4.5 실패 후 복구 — 재시도는 새 버전으로만

릴리스 워크플로가 태그 이후에 실패하면(플레이키 테스트컨테이너·일시적 레지스트리 장애) `main`에는 버전 범프가 남고 태그는 산출물 없이 존재한다.

**이때 태그를 지우고 다시 미는 복구는 채택하지 않는다.** 두 가지 이유다. (1) 요청 파일 내용이 동일하면 재머지에 diff가 없어 트리거되지 않으므로, 결국 사람이 손으로 태그를 미는 — 없애려던 바로 그 행위로 돌아간다. (2) 태그 삭제가 일상 동작이 되는 순간 "태그 존재하면 스킵"이 멱등성 보장에서 **재생(replay) 프리미티브**로 뒤집힌다 — 릴리스 PR 이전에 만들어진 장수명 브랜치가 뒤늦게 머지되면 옛 요청 파일을 되살리고, 그 사이 태그가 삭제됐다면 디스패처가 그 태그를 다시 만든다.

그래서 **`deletion` 룰(§4.2c)로 릴리스 태그를 불변으로 만들고, 복구는 다음 버전으로 전진하는 것만 허용한다.** 이건 제약이 아니라 사실의 반영이다 — 태워버린 레지스트리 버전은 어차피 되돌릴 수 없다(`DEPLOY.md` §6).

⚠️ **"범프됐는데 게시되지 않은" 상태는 자동으로 감지되지 않는다.** `check-versions.mjs`의 언어 간 발산은 의도적으로 경고이지 오류가 아니고(독립 버저닝 정책), 매니페스트↔레지스트리 대조는 어디에도 없다. `deploy-facts.sh:81-90`의 `df_check_url`이 언어별 레지스트리 확인 URL을 이미 갖고 있으므로 이를 **게시 후 확인**으로 승격한다(후속 §10).

### 4.6 자기수정 위험과 그 경계

`on: push` 워크플로는 밀린 커밋의 버전이 실행되므로, `dispatch-release.yml`과 요청 파일을 **한 머지에 담으면 수정된 디스패처가 즉시 App 토큰을 들고 돈다**. required 승인 0·CODEOWNERS 부재라 머지 게이트는 이를 막지 못한다.

경계는 셋이다:

1. **`main.json:5`의 `bypass_actors: []`** — App은 `contents: write`를 갖고도 `main`에 push할 수 없다. 이 한 줄이 App 토큰이 기본 브랜치 전체 쓰기 권한이 되는 것을 막는다. "단순화" 명목으로 건드리면 안 된다.
2. **태그 룰셋의 패턴별 우회**(§4.2c) — 탈취된 디스패처도 Go를 태그할 수 없고, 릴리스 형태가 아닌 태그도 만들 수 없다.
3. **릴리스 워크플로의 자체 게이트**(§4.3) — 태그가 생겨도 `verify`·`integration`·`install-smoke`를 통과해야 게시된다.

셋을 합치면 최악의 결과가 **"회수 가능한 언어에서 원치 않는 릴리스 하나"**로 묶인다. 디스패처가 자기 푸시의 diff 범위를 검사하는 방어도 가능하지만(요청 파일과 해당 언어 버전 파일 외에는 거부), 그 검사 역시 수정된 워크플로 안에 있어 같은 공격에 함께 제거되므로 **주 방어로 세우지 않는다**. 서버 상태(1·2)와 파이프라인 게이트(3)만이 저장소 내용 변경에 견딘다.

## 5. 채택하지 않은 것

**게시 잡 아홉 개에 `environment:` + required reviewer 추가.** 두 가지 이유다.

1. **OIDC 클레임을 깨뜨린다.** PyPI·npm·RubyGems의 신뢰발행은 environment 이름까지 포함해 주체를 식별한다. python(`python-release.yml:110-141`)·node(`node-release.yml:115-151`)는 `environment:` 없이 등록됐고 Python은 `py-v0.1.0rc1`에서 이미 정상 발행됐다 — 여기에 environment를 추가하면 **동작 중인 발행이 깨진다**.
2. **같은 결정에 두 번 승인하면 형식화된다.** 정보량이 많은 쪽(diff)을 남긴다.

⚠️ **Ruby는 비대칭이다.** `ruby-release.yml:115`가 이미 `environment: release`를 선언하므로 그 OIDC 주체에는 이미 environment가 들어 있다. **required reviewer를 붙여도 주체 클레임은 바뀌지 않는다**(클레임은 `environment:` 선언 여부에 달렸지 보호 규칙에 달리지 않았다). 즉 Ruby만은 OIDC 위험 없이 승인 게이트를 얻을 수 있다 — 다만 RubyGems 퍼블리셔가 실제로 어떤 environment로 등록됐는지는 저장소에서 확인 불가하므로 **사람이 등록 상태를 먼저 확인한 뒤** 결정한다.

역방향이 진짜 함정이다: 나중에 누군가 "아홉 개를 일관되게" 맞추려 하면 **동작하는 둘을 깨뜨린다.** 이 비대칭을 워크플로 주석과 DEPLOY.md에 명시한다.

`release` environment 자체는 **생성한다** — 새 게이트 도입이 아니라 §2-B의 깨진 참조 해소다.

## 6. 테스트 전략

`scripts/test/` 관용(`assert.sh` 소싱 · `--lib`로 순수 함수 분리 · `assert_report`)을 따라 `test-dispatch-release.sh`를 둔다.

⚠️ **검증 대상은 실제로 배포되는 그 문자열이어야 한다.** `test-release-prerelease.sh`가 이미 세운 원칙이다 — 워크플로 안의 로직을 테스트 파일에 복사해두면 워크플로만 고쳤을 때 조용히 통과한다. 같은 방식으로 디스패처의 검증 블록을 마커로 추출해 실행한다.

고정할 불변식:

- **Go 거부** — 회귀하면 조용히 위험해지는 유일한 항목
- **태그 파생** — 요청에 `tag`를 넣어도 무시하거나 거부할 것(§4.2a의 권한상승 차단)
- **멱등성** — 이미 존재하는 태그에 재실행이 무해할 것
- **버전 불일치 거부 · 미지 언어 거부 · 깨진 JSON 거부**(파싱 실패를 통과로 처리하지 않을 것)
- **파일 부재 = 깨끗한 no-op**

⚠️ **환경 의존 어서션을 쓰지 않는다** — `test-deploy-md.sh`·`test-release-readiness.sh`가 각각 실제 태그·게시 상태에 기대다가 뒤집혔다. 판정 함수에 stub을 물린다.

⚠️ **CI에 배선하지 않은 자가테스트는 가드가 아니라 문서다.** `repo-hygiene.yml:81-86`의 `doc-facts` 잡이 네 개 배포 자가테스트를 이름으로 나열하므로 새 테스트를 그 블록에 추가하고, `shell-exec-bits` 체크 때문에 **`100755`로 커밋**한다.

## 7. 계정 소유자 작업

### A. 자동화를 켜기 위해 필요 (신규)

1. **GitHub App 생성·설치** — Settings → Developer settings → GitHub Apps → New. 권한은 **Contents: Read and write 하나만**. `xzawed/KeyCloakSDK`에 설치 후 App ID·private key를 시크릿으로 등록.
2. ✅ **태그 룰셋 적용 — 완료(2026-08-04).** `RELEASE-TAGS-CREATE`(20384703)·`-CREATE-GO`(20384702)·`-IMMUTABLE`(20384704) 전부 `enforcement: active`. **§10 N5도 함께 해소** — `target: "tag"`가 브랜치 룰셋에만 있던 서버 관리 필드를 돌려줘 `SERVER_FIELDS` 확장이 필요할지가 열린 질문이었는데, `apply` 직후 `check`가 확장 없이 그대로 통과했다(불필요). ⚠️ 셋 다 bypass가 admin이라 **사람이 손으로 태그를 미는 경로는 닫히지 않았다**(적용 후 라이브 API로 확인).
3. ✅ **`release` environment 생성 — 완료(2026-08-05).** §2-B의 깨진 참조가 해소됐다(`ruby-release.yml`의 `environment: release`가 이제 실존 대상을 가리킨다). 실측: `protection_rules: []` · `deployment_branch_policy: null` — 규정대로 **보호 규칙 없는 빈 environment**다. Ruby에 required reviewer를 붙이는 건 RubyGems 등록 상태를 사람이 확인한 뒤의 **별도 결정**으로 그대로 남는다(§5).

   > 부수 효과로 §2-B가 관측했던 "environment 0개" 상태도 끝났다. 이 environment는 현재 `ruby-release.yml` 한 곳만 참조한다 — **다른 여덟 릴리스 워크플로에 `environment:`를 추가하지 말 것**(§5의 비대칭 경고: Python은 environment를 비운 채 OIDC 발행에 성공했고, 일관성 명목의 추가가 동작 중인 신뢰발행 주체 클레임을 깨뜨린다).

### B. 자동화와 무관하게 필요 (issue #105)

이름 소유 확인 6건 · `CARGO_REGISTRY_TOKEN` · Ruby pending publisher(⚠️ **12시간 만료** — 등록과 태그를 같은 자리에서) · npm 부트스트랩 1회(`npm trust`가 패키지 선존재를 요구) · Maven Central 네임스페이스+토큰+GPG 키서버 배포(java·kotlin 8개 시크릿) · 사고대응 로그인/2FA 확인.

### C. 끝까지 사람만 가능 — 자동화 대상 아님

Central Portal의 Publish 클릭(java·kotlin) · PyPI yank(웹 UI 전용) · npm 2FA 작업. 이건 결함이 아니라 **마지막 방어선**이다.

## 8. 적용 순서

태그 룰셋 → App → **python `0.1.0rc2`로 첫 검증**(오늘 고친 aio FD 누수를 실어 보낼 실물이 있고, yank로 되돌릴 수 있다) → node·rust·php → java·kotlin(Portal 클릭이 받침대) → **Go는 계속 수동**.

## 9. 성공 기준

- 사용자가 릴리스를 위해 하는 행위가 **PR diff 검토 + 머지 버튼** 하나로 줄어든다(Go 제외).
- 승인 근거가 git 이력에 영구 보존된다.
- Claude가 어떤 배포 자격증명도 보유하지 않는다 — 오동작 상한이 "PR 생성".
- 승인 없이 릴리스 태그가 생성되는 경로가 **룰셋으로 차단**된다(현재는 무방비).
- **Go는 워크플로를 수정해도 자동 태그가 불가능하다**(서버 상태로 집행).

## 10. 알려진 한계와 후속

- **N5 (미확인)**: `repo-config.mjs`의 `SERVER_FIELDS`(L28-37)는 브랜치 룰셋 응답에서 유도됐다. `target: "tag"`에서 GitHub이 추가 서버 관리 필드를 준다면 `check`가 영구 드리프트를 보고한다. 적용 직후 `check`를 돌리고, 드리프트가 나면 `pull`로 diff해 필드를 추가한다.
- **B4 (구조적)**: `repo-config.mjs`는 orphan 룰셋을 감지하지 못하고(`desiredFiles()`만 순회, DELETE 경로 없음 — 실측 확인) `repo-hygiene.yml`은 `check`가 아니라 자가테스트만 돌린다. 즉 **룰셋이 github.com에서 삭제돼도 저장소 어디에서도 신호가 나지 않는다.** 완화: 디스패처가 태그 push 직전에 `gh api .../rulesets`로 룰셋 존재를 자체 확인하고 없으면 중단한다(§4.4). 근본 해결(orphan 감지·CI 배선)은 별건.
- **S5**: "범프됐는데 게시되지 않은" 상태의 자동 감지(`df_check_url` 승격)는 이 스펙 범위 밖 후속이다. 그 전까지 DEPLOY.md가 상태와 복구(전진만)를 문서화한다.
- **기존 부작용(이 설계가 초래한 것 아님)**: 태그 push에 `dotnet-ci`·`kotlin-ci`·`php-ci`·`ruby-ci`·`rust-ci`·`harness`·`repo-hygiene`가 이미 실행된다(오늘 태그 ref 실행에서 실측). `branches:` 필터 없이 `paths:`만 둔 워크플로들이다. 자동화가 이를 바꾸지 않지만, 릴리스마다 중복 연산이 보이는 이유이므로 기록해 둔다.
