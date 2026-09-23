<!-- doc-status: active -->
<!-- doc-budget: max-bytes=193187 -->
<!-- 192968 → 193187 (2026-09-23 저녁, +219B). 규약 (1) — 사슬의 마지막 칸을 닫는 가드
     (`check-published-jvm-floor.mjs`, 변이 7/7 CAUGHT + OFF 짝, **그중 하나는 실제 repo1
     바이트**로 CAUGHT)가 검증 가능성을 사 왔다. 교환한 것: 「(2) 선언 ≠ 방출된 바이트」의
     닫힌 서사 — 로컬 산출물 호출 지점 둘의 실측은 그 주장이 열려 있을 때의 근거였고, 이제
     가드가 그 자리를 소유한다. 남긴 것은 **서술 규칙**(전수를 주장하지 말고 호출 지점을
     세라)뿐이다. ⚠️ 설계 판정 (a)~(e) 의 정정은 **블록 주석 안**이라 계상되지 않는다 —
     그중 (b) 는 어제 적은 규칙이 **틀렸음을 기록한 것**이라 지우면 안 된다. -->
<!-- 192725 → 192968 (2026-09-23, +243B). 규약 (1) — 새 가드 하나(`check-jvm-api-surface-pins.mjs`,
     변이 7/7 CAUGHT + OFF 짝)가 검증 가능성을 사 왔고, **같은 커밋이 오늘 릴리스가 거짓으로
     만든 문장들을 지웠다** — 「릴리스는 하지 않는다」(2026-09-06 판정) · 「compatibility.md 와
     양쪽 README 는 21 을 게시본 값으로 명시한다」 · 릴리스 시 내려야 할 자리 목록(전부 내렸다) ·
     「PR 이 아닌 것」 목록의 이 항목(선행이 도착했다).
     ⚠️ 순증이 1,071B 였다가 198B 로 줄어든 것은 **판정 방법을 깎아서가 아니다** — 새 항목의
     설계 판정 (a)~(e)를 **블록 주석**으로 옮겼다(주입되지 않아 계상되지 않는다). 그 판정을
     실제로 읽어야 하는 것은 그 항목을 착수하는 세션 하나뿐이고, 상시 표면에 필요한 것은
     「봉인 단계 없이는 못 닫는다」 한 줄이다. 경위 산문은 PR #548 로 보냈다. -->
<!-- 192677 → 192725 (2026-09-23, +48B). 규약 (1) — 가드 무결성 셋을 닫으면서 **다음 세션이
     재현할 판정 방법**만 남긴다. 순증은 두 항목의 진행 기록이고(어느 프로브가 SILENT 였고
     무엇을 넣어 CAUGHT 이 됐는가), 닫은 둘의 사후 서사 1,218B 는 **PR 번호로 갈음했다**
     (#540 — 완료 서사는 git 이 소유한다). 그래서 −1,218 +1,266 = +48 이다. -->
<!-- 192593 → 192677 (2026-09-22, +84B). 규약 (1) — 2 라운드 21 건이 닫히면서 **열린 1 건을
     별건 항목으로 분리**했다(사람 판정: 「등록만 하고 별건으로」). 늘어난 것은 그 항목의
     **착수 정보**뿐이다 — 언어별 실측(7 언어 1,214 줄 · java·dotnet 은 0), 왜 언어당 PR 이
     최소 단위인지, 어디부터인지(rust·node = 417 줄).
     교환: 같은 스플라이스가 2 라운드 항목의 **닫힌 21 건 나열을 PR 번호로** 줄였다(닫힌 것의
     서사는 git 이 소유한다). 순증은 +84B 다. -->
<!-- 192335 → 192593 (2026-09-22, +258B). 규약 (1) — 증가분이 **기계 검증**을 사 온다.
     `## A–D` 네 절 헤더의 「N건 (열림 M)」이 **넷 다 틀렸다**(A 12/2→12/1 · B 27/20→49/15 ·
     C 67/66→74/56 · D 46/44→56/49). 같은 커밋이 `test-remaining-work-shape.sh` 에 헤더↔체크박스
     대조를 넣어 그 수가 다시 썩지 못하게 했고(기대 상수 없음 — 항목 하나가 닫히면 양변이
     함께 움직인다 · 절을 0 개 세면 공허 실패), 실제로 **이 커밋의 새 항목을 그 가드가 즉시
     잡았다**(D 55→56).
     교환: 초안은 +4,802B 였다. 닫힌 high 여섯의 사후 서사(3,052B)를 **PR 번호로 갈음**하고
     (규칙: 완료 서사는 git 이 소유한다 — 이 파일이 246 KB 까지 자란 원인이 그것이다),
     2 라운드 항목을 4,387 → 2,906B 로 압축했다. 남긴 것은 **열린 6 건의 착수 정보**와
     「에이전트가 더티 워킹트리를 읽는다」는 다음 감사용 단서뿐이다. -->
<!--
  신규(2026-09-22). 이 파일에는 예산이 **없었다** — 그래서 256,624 B 까지 자랐고, 전체 문서
  바이트의 31%(2 위의 3 배)를 차지했다. 옵트인이라 한 번도 안 덮인 것이 원인이므로 이 경로에는
  선택 사항이 아니다. 값은 **이관 후 크기**로 박는다(256 KB 가 아니라). ⚠️ **조이는 것은 되고
  올리는 것은 안 된다** — 올려야 한다면 그 자체가 사람 판정이고, 같은 PR 에서 판정을 적는다.
-->

# 잔여작업 등록부 — 2026-09-03 전수 감사 후속

**이 문서가 답하는 것 하나** — 「감사가 남긴 것 중 무엇이 아직 열려 있고, 각각을 **어떤 명령으로** 닫았다고 말할 수 있는가」.

> ⚠️ **닫힌 항목의 사후 서사는 여기 없다 — 아카이브 태그에 있다.**
> `git show archive/docs-history-2026-09:docs/superpowers/plans/remaining-work.md`
>
> 이 파일은 256,624 B 까지 자랐고 그중 **닫힌 70 건의 하위 서사가 65,347 B**(25.5%)였다.
> 저장소 규약이 「완료된 작업의 서사는 이력으로 보내고, 매 세션 읽는 파일에 쌓지 않는다」이므로
> 2026-09-22 에 그 서사만 태그로 이관했다. **표제줄은 남겼다** — 닫힌 슬러그 66 개 중 **47 개가
> 이 파일 안에서 참조되고**(열린 항목이 선례로 인용한다), 통째로 빼면 선례를 살리려 표제를 도로
> 인라인하게 되어 절감이 0 이하가 된다(실측: 표제 36,826 B vs 서사 65,347 B).
>
> **닫은 항목에 하위 서사를 다시 붙이지 말 것** — `scripts/test/test-remaining-work-shape.sh` 가
> 「닫힌 항목이 소유한 줄 수 == 닫힌 항목 수」를 단언한다. 정상적인 닫기는 정확히 한 줄만
> 소유하므로 양변이 함께 움직이고, 서사가 돌아오면 좌변만 움직여 빨개진다.

## 왜 이 문서가 있는가

2026-09-03 전수 감사(`main` @ `deb2bbd`)는 **아무것도 커밋하지 않았다.** 원장은 `~/.claude/projects/` 아래에만 있었고 git 이력·저장소 파일 어디에도 흔적이 없었다 — 그 파일이 사라지면 209건을 통째로 잃는 상태였다. 같은 일이 이미 한 번 있었다(`docs/superpowers/plans/` 아카이브 후 지도가 가리키는 경로가 사라졌다).

그래서 **등록부를 저장소 안으로 옮긴다.** 이 문서가 열린 항목의 진실 원천이고, 항목이 전부 닫히면 `doc-status` 를 `complete` 로 내리고 아카이브 태그로 내린 뒤 지도 §3 에서 지운다.

## 규모

| | |
|---|---|
| 원장 고유 발견 | **209** (conf 12 · pend 37 · weak 3 · low 157) — 감사 시점 전부 미수정 |
| 작업 패키지 | **183** (원장 유래 104 · 원장 밖 46 · 재스캔 신규 2 · 문서감사 신규 17 + 계수차 1 · 재판정 신규 3 · 후속 분할 신규 4 · **H1 파생 신규 1** · 하네스 신규 1 · 프로세스감사 신규 2 · **야간 사고 신규 1** · **부류 재스캔 신규 1**) — 열림 **115** · 닫힘 **68** (2026-09-16 재측정) |
| 심각도 | high 27 · medium 78 · low 48 |
| 작업량 | S 69 · M 72 · L 12 |

<!-- doc-guard: kind=count source=work-packages -->
⚠️ **이 표를 판정에 쓰지 말 것 — 세 줄이 서로 맞지 않는다.** 체크박스 전수는 `194`(2026-09-23 기준 열림 120 · 닫힘 72)인데 심각도·작업량 행의 합은 **150**이다. 어긋난 채로 커밋돼 있었고(2026-09-06 확인), 어느 쪽이 옳은지는 원장을 다시 세야 정해진다. ⚠️ **그리고 그 문장이 「위 두 명령을 돌린다」로 끝나 있었는데 위에는 명령이 없었다** — 세는 법을 지운 채 「세라」만 남은 자리였다(2026-09-16 정정). 세는 명령은 이것이다:

```sh
grep -c '^- \[ \]' docs/superpowers/plans/remaining-work.md   # 열림
grep -c '^- \[x\]' docs/superpowers/plans/remaining-work.md   # 닫힘
```

⚠️ 그리고 **「열려 있다」가 「아직 참이다」는 아니다** — 2026-09-07 재판정에서 20건 중 11건이 변동했다(진입점 참조).

### 재개 절차 (다른 PC 포함)

이 저장소 밖에 남는 상태는 없다 — 아래 넷이면 직전 세션과 같은 조건이 된다.

```sh
git clone https://github.com/xzawed/KeyCloakSDK && cd KeyCloakSDK
node scripts/doctor.mjs                 # 이 PC에 무엇이 없는지. 설치·환경변수는 docs/guides/development-setup.md
node scripts/check-docs.mjs . --strict --min-facts=76 --min-anchors=26 --min-anchor-links=24 --min-blob-refs=5 --min-count-anchors=4
git branch --show-current               # ⚠️ 아래 함정 (e)
```

⚠️ **`main` 이 아닌 브랜치에서 시작했다면 먼저 `main` 으로 간다** — 함정 (e)가 그것이다. ⚠️ **에이전트의 세션 메모리는 PC를 넘어가지 않는다.** 넘어가야 하는 것은 전부 이 문서와 `.claude/rules/*.md`·`docs/guides/development-setup.md` 에 있어야 하고, 새로 배운 것도 거기 적는다.

### 다음 세션 진입점 (2026-09-10 · #421–#463 반영)

⚠️ **이 절은 2026-09-07 에 통째로 다시 썼다 — 이전 판은 이미 닫힌 배치 3 으로 다음 세션을 보내고 있었다.** 등록부 작성(2026-09-03) 이후 46건이 병합돼 추적파일 110개가 바뀌었고, **인용 파일이 그 사이 바뀐 열린 항목이 70/137** 이었다(재측정 시점). 그중 **20건을 재판정**한 결과 **11건(55%)이 변동**했다 — 닫힘 2 · 서술이 넓어짐 7 · 계수 어긋남 3(둘은 악화). 그 셋에 #438·#440·#442 가 닫은 것까지 반영해 **그 시점의** 열림은 132 였다(⚠️ 2026-09-07 측정치다 — 지금 수는 위 「규모」 표와 체크박스 전수를 본다). **나머지 50건은 아직 재판정하지 않았다** — 「열려 있다」를 액면가로 읽지 말고, 손대기 전에 그 항목의 주장을 먼저 재라.

순서는 **① 지금 초록이 거짓인 것 → ② 게시본에서 소비자가 겪는 것 → ③ 잠복 → ④ 완결성** 이다(2026-09-07, 독립 레그 둘이 1~5위에서 일치).

1. ✅ **`kotlin-osv-audit-fail-open` [H] — #438 이 닫았다.** 유일하게 **활성**이던 fail-open 이었다(dep-tree 생산자 3 · 게이트 1). 가드 `test-osv-audit-gate.sh` 가 사본 갈림을 대신 센다.
2. ✅ **rust JWKS 두 건 — #440 이 닫았다.** 상태 미검사와 바이트 상한을 같은 PR 로. ⏸ 크기 상한은 **php·ruby 가 남는다**(그 항목 참조 — php 는 상태 검사보다 **먼저** 본문을 슬러프한다).
3. ✅ **`rust-public-client-empty-secret` — #441 이 닫았다.** 세 자리였다(생성부·logout·`token_provider`). 남은 파생은 `public-client-confidential-grants-not-refused` 이고 **실 Keycloak 실측이 선행**이다.
4. ✅ **`python-sync-authorization-url-unencoded` — #442 가 닫았다.** 상류 `auth_url` 이 `format()` 한 줄이라 `redirect_uri` 의 `&` 가 파라미터를 주입했다. sync 를 `aio` 미러와 동형으로 맞췄다.
5. ✅ **`sweeps-without-vacuity-floor` [H] — #443 이 닫았다.** 하한은 **60일 창 최저 실측치**(44/47)다 — 오늘 값에 래칫으로 붙이면 정당한 삭제가 우회 불가 required 를 막는다.
6. ✅ **`security-invariant-use-site-scope` [H] — #444 가 닫았다.** 다섯 중 둘(python·dotnet)은 축 1b 가 이미 값으로 잡고 있었고, **진짜 무보호는 kotlin 셋**이었다. required 손 표를 늘리지 않고 **언어 로컬 파생 테스트**로 닫았다. 남은 부류는 `node-php-use-site-skew-defaults`.
7. ✅ **`operator-commands-that-do-not-work` [H] — #446 이 닫았다.** 릴리스 도구가 인쇄하던 사전점검이 **이미 게시된 버전**의 답을 주고 있었다.

**⟶ 2차 재판정(2026-09-09 · 앞의 20건과 겹치지 않는 10건)으로 다시 짠 순서.** 위 1~7 이 전부 닫혀 다음을 잇는다. ⚠️ **여기서도 계수가 셋 어긋났다** — 아래 각 항목이 그 정정을 담는다.

8. ✅ **`stale-release-comments` [H] — #447 이 닫았다.** 다섯이 아니라 **여섯**이었고, 가장 비싼 하나는 「락스텝을 강제한다」는 문단이었다(실제로는 경고 + exit 0). 규칙 7c 가 양방향으로 대조한다.
9. ⏸ **`irreversible-publish-no-reentry` [H/M] — 지금 하지 않기로 판정했다(2026-09-09, 독립 레그 + 재현).** 그 항목 본문에 근거를 적었다.
10. ✅ **`go-tokenprovider-injection-missing` — #449 이 닫았다.** 철회가 아니라 **구현**이었다 — SPI 셋이 이미 공개라 문장만 지우면 넣을 데 없는 공개 API 가 남는다.

**⟶ 3차(2026-09-10) — 「단언이 속성이 아니라 존재를 센다」 갈래.** 위 1~10 이 전부 닫히거나 보류로 판정돼, 이 세션이 반복해 값을 치른 **부류** 를 정면으로 쳤다. ⚠️ **방법이 도중에 교정됐다** — 처음 계획이던 「그 부류의 전수 목록」을 독립 레그가 **「이름 붙인 변이는 증거가 아니다」**로 반박했고 그게 맞았다. 목록 대신 **상위 셋을 실제로 돌려** 셋 다 `SILENT` 임을 확인한 뒤 닫았다.

11. ✅ **시크릿 빈값 검사가 `exit 1` 로 이어지는지 안 봤다 — #461.** 한 줄만 지우면 미설정이 경고로 끝나고 잡은 초록이었다. 판정을 그 `run:` 블록으로 좁혔다(수렴 실측 28/28, 오탐 0).
12. ✅ **프리릴리스 플래그를 「파일 어딘가」에서 찾았다 — #462.** 주석에만 남겨도 통과했고, 결과는 **RC 가 Latest**(`php-v0.1.0-rc.1` 실제 사고). `gh release create` **명령 하나**로 좁혔다(세 모양 수렴 3/3).
13. ✅ **마스킹 카나리아가 엉뚱한 파일을 `***` 로 겨눴다 — #463.** python 하나가 아니라 **여섯 언어**였다. 게시본이 토큰을 로그에 원문으로 찍어도 못 잡는 상태였다. **이제 아홉 전부 테스트 이름 앵커**다.

**⟶ 그리고 이 세션에서 함께 닫힌 것**: #450 vitest 4 이관(경보 2건 해소 · `main` open **0**) · #458 전송오류 분류기 무측정 · #459 보안 기본값 자가테스트 **음성 대조군**(옛 스크립트는 추출기를 `echo 30` 상수로 바꿔도 213 전부 통과했다) · #460 이 항목의 조준 정정.

**⟶ 다음 대상은 아직 측정되지 않았다(2026-09-10 기준).** 이 갈래가 닫혔고 진입점 1~13 이 전부 해소됐다. ⚠️ **등록부의 「열려 있다」를 액면가로 읽지 말 것** — 이 세션에서 재판정한 30건 중 **절반 이상이 변동**했다(닫힘·서술 과대·계수 오류). 다음 세션은 **재판정부터** 시작한다. 아직 재판정하지 않은 항목이 다수다.

**⟶ 4차(2026-09-11) — 「게시본에서 소비자가 겪는 것」 갈래.** 독립 레그(Grok)와 순서를 교차검토해 ①초록이 거짓 → ②게시본 소비자 → ③잠복 → ④완결성 축을 그대로 쓰되, **두 곳에서 레그를 실측으로 기각**했다: `go-release-persist-credentials` 의 「10/24 수치가 낡았다」는 틀렸고(`git grep -l persist-credentials .github/workflows` → **정확히 10**, `ls *.yml` → **24**, 그리고 `contents: write` 릴리스 넷 중 **go 하나만** 0) `php-sensitiveparameter-methods-missing` 는 4위가 아니라 2위였다.

14. ✅ **JWKS 응답 크기 상한이 php·ruby 에 없었다 — PR #466.** php 는 **상태 검사보다 먼저** 본문을 슬러프했다. 교차언어 축 신설(변이 6/6 `CAUGHT`). ⚠️ node·python·dotnet 은 **하위 라이브러리에 위임**해 미측정으로 남았다 — 그 축의 초록을 「셋도 안전」으로 읽지 말 것.
15. ✅ **php 의 비밀 인자가 스택트레이스에 원문으로 샜다 — PR #467.** 등록부는 「여섯 메서드」라 했으나 **아홉 파라미터**였다(반사 가드가 `TokenSet::__construct($idToken)` 을 찾아냈다 — 생성자인데도 빠져 있었다). **손 목록을 쓰지 않은 것이 그 계수를 고쳤다.**
16. ✅ **공백 스코프 하나가 Nimbus 예외를 공개 API 로 흘렸다(java·kotlin) — PR #468.** `Scope.isEmpty()` 가 원소 **수**를 센다. `KeycloakConfig` 에 scope 검증이 0건이라 도달 가능하다.
17. ✅ **python sync `admin.close()` 가 no-op 이었다 — PR #469.** `test_close_is_noop` 이 **결함을 의도로 고정**하고 있어 테스트를 먼저 뒤집었다. ⚠️ `async_s` 는 sync 경로에서 못 닫는다 — 과대광고하지 않았다.
18. ✅ **재판정 두 건은 이미 참이 아니었다 — 이 PR.** `deploy-md-omits-release-request`(#416 이 닫음) · `keycloak-image-tag-fiction`(두 문서 정정 + 트리 9/9 실측).

⚠️ **이 세션이 또 확인한 계측 함정 셋** — 다음 세션은 이것부터 읽는다. (g) **`sed` 변이가 착지하지 않았는데 `SILENT` 로 보였다**(백슬래시 이스케이프). `git diff` 가 비어 있는 것으로 잡았다 — 「침묵」을 읽기 전에 **변이가 실제로 착지했는지**를 먼저 본다. (h) **gradle 을 연속으로 돌리면 데몬 락 경합(「3 busy and 3 incompatible」)으로 빌드가 죽고, 그 비영 종료가 「변이를 잡았다」와 구분되지 않는다** — 복원 뒤 **기준선까지 False** 로 나와서 들켰다. 하나씩 돌려 **명명된 테스트 실패**를 확인한다. (i) **컴파일되지 않는 변이는 `CAUGHT` 가 아니라 `INVALID` 다**(kotlin `scope = scope`). ⚠️ 그리고 **`scripts/probe.sh` 는 php·node 를 못 잰다**(워크트리에 `vendor/`·`node_modules` 가 없어 기준선 실패 → `INVALID`) — 열린 항목 `probe-cannot-run-node-php-in-worktree` 가 **여전히 참**임을 실행으로 확인했다.



### 재발 원인 분석 — 2026-09-13 (독립 레그와 공동, 산출물 기반)

⚠️ **직전 회고(2026-09-11)가 「이미 있는데 어긴 것」으로 적은 다섯 중 넷이 바로 다음 세션에 재발했다.** 셋은 동일하게, 하나는 「했으나 잘못 쟀다」로. 회고를 쓰는 것 자체가 구속하지 않는다는 **직접 증거**다.

**재발하지 않은 하나가 신호다.** 항목 4(「아홉 언어 축은 하나라도 미측정이면 닫지 않는다」)만 살아남았다. 차이는 명확하다 — 그것은 **절차를 잘 수행하라**가 아니라 **산출물 집합이 완성되기 전에는 결론을 못 쓴다**였다. 빠진 것이 **빈 칸으로 보인다.** 나머지 넷은 싼 대체 경로가 **이미 결과처럼 생긴 것**(종료코드·CAUGHT·수치·복구 가능한 실패)을 내놓는다.

> **존재를 요구하는 규칙은 구속하고, 정확성을 요구하는 규칙은 구속하지 않는다.**

**원인 넷**(증상이 아니라 원인으로 묶음)
  1. **행위와 그 행위의 검증이 같은 단계다** — 읽는 점수가 작업 자신이 낸 출력이라, 깨진 계측기·틀린 변이·동어반복 테스트·위치 편향이 전부 「적을 수 있는 수」를 낸다.
  2. **싼 경로와 안전한 경로가 갈리고, 싼 쪽이 이미 진척처럼 보인다** — 툴체인 없이 친 첫 명령, 읽고 쓴 주장, `node -e`, LF 정규식, `git checkout -- .`.
  3. **도구를 의식처럼 부르고 제약만 벗긴다** — 옆에 러너를 만들고, 부르되 `>/dev/null` 로 감싸고, 고친 뒤엔 `tail` 로 본다.
  4. **의도를 파일의 언어가 아닌 언어로 적용한다** — bash→perl/`node -e`→JS 템플릿, CRLF 트리의 LF 정규식. 「착지했다」와 「의도한 것이 됐다」가 갈린다.

⚠️ **핵심 판정**: 문제는 도구가 **없는** 것도, **안 부르는** 것도 아니다 — **부르고도 그 출력을 믿지 않거나 안 읽는 것**이다. 사슬이 증거다: 안전한 도구가 있었고(우회) → 불렀고(침묵시킴) → 고쳤고(꼬리만 읽음). 도구를 하나 더 만들거나 「불러라」를 한 줄 더 적는 것은 같은 방식으로 흡수된다.

**그래서 이번에 한 것은 도구에 「거부」를 더한 것이다** — `scripts/probe.sh --site` 는 변이가 **선언한 자리를 안 담으면 판정하지 않는다**(INVALID). 「diff 를 눈으로 본다」를 기계로 옮겼다. ⚠️ 잔여는 정직하게 남는다 — 첫 명령의 싸구려성(원인 2)·동어반복 초록(원인 1)·인터프리터가 파일을 먹는 것(원인 4)은 이것으로 안 닫힌다.
### 세션 회고 — 2026-09-11 (독립 레그와 공동 감사)

⚠️ **이 절은 규칙을 새로 만드는 자리가 아니다.** 이 세션의 낭비 대부분은 **이미 적혀 있는 규칙을 안 지켜서** 났다. 그래서 「어긴 것」과 「없던 것」을 나눠 적는다 — 없는 규칙을 또 쓰는 것은 이 등록부가 커지는 방식이지 고쳐지는 방식이 아니다.

**A. 이미 있는데 어긴 셋** (다음 세션은 이것부터 본다)

1. ⚠️ **변이 3요건 중 (c) 를 한 번도 안 돌렸다**(`process.md:271` 이 정의한다 — 「가드 OFF + 같은 변이 → 통과」). 이 세션의 변이 판정은 전부 (a)+(b) 뿐이었다. 대가: #471 의 첫 테스트가 **거짓 초록**이었다 — 거대 본문을 쓰레기 바이트로 만들었더니 상한이 없어도 JSON 파싱이 실패해 「거부됐다」가 통과했다. TDD 의 RED 단계가 우연히 잡아 줬을 뿐 (c) 를 돌렸다면 바로 나왔다.
2. ⚠️ **언어 툴체인 블록을 실패한 뒤에 읽었다.** `kotlin.md` 는 「별도 gradle 설치 금지, 래퍼로 돈다」와 「gradle 동시 실행 금지」를 적어 두었는데 둘 다 어겼다 — 전자는 9.6.1/9.5.0 이중 측정, 후자는 데몬 락 경합이 **거짓 `CAUGHT`** 를 만들어 복원 뒤 기준선까지 False 로 나왔다. `ci.md` 의 「CRLF 트리에서는 바뀐 파일만 LF 사본으로 포맷 검사」도 어겨 #467 이 CI 에서 빨개졌다(잡음 54파일이 진짜 위반 1건을 덮었다).
3. ⚠️ **「손대기 전에 그 항목의 주장을 먼저 재라」**(이 문서의 진입점)를 **계수에 적용하지 않았다.** 코딩 중에 재서 두 번 틀린 것이 드러났다 — 「여섯 메서드」→ 실제 **아홉 파라미터** · 「넷」→ 실제 **셋**(등록부가 주석 산문을 셌다).

**B. 없던 것 둘** (이것만 새로 지킨다)

4. ⚠️ **아홉 언어 공동 축의 보안 항목은 하나라도 「미측정」이면 닫지 않는다.** #466 은 node·python·dotnet 을 「우리 소스에 선언이 없다」고 잘라내고 머지했고, 재 보니 **2/2 가 실제 구멍**이었다(jose 무상한 · python 무상한). 결과로 한 부류가 PR 넷(#466·#471·#477 + 미착수 python)으로 쪼개졌고 python 의 진짜 크기(목 **70곳**)는 마지막에야 드러났다. **먼저 아홉을 다 재고 이음매별로 항목을 쪼갠 뒤 착수한다.**
5. ⚠️ **변이의 diff 가 「의도한 자리」를 담는지 본다** — 착지 여부만으로는 부족하다. #472 1차 프로브는 파일의 *첫* `persist-credentials: false` 를 지웠는데 그것이 대상 잡의 것이 아니어서 셋이 `SILENT` 로 보였다. 변이는 착지했으므로 함정 (g)로는 안 걸린다. **잡·함수 이름으로 범위를 좁혀 변이하고, diff 에 그 심볼이 있는지 확인한다.**

**C. 유지할 것** — 독립 레그는 값을 했다. 이 세션에서 레그가 **내 주장을 실제로 반증**한 것이 셋이다(「10/24 수치가 낡았다」는 틀렸고 · 검사 8b 의 통과 경로가 거짓임을 지목했고 · dotnet 라이브러리 내부를 **추측하지 않고** 「미측정」이라 답했다). ⚠️ 반대로 레그의 제안을 **실측으로 기각**한 것도 둘이다(`rejected.md` 블록 주석 우회 · python `certs()` 이탈 비용 과소평가). **레그를 액면가로 받지 않는 것이 레그를 쓰는 것과 같은 무게다.**
**⟶ 5차(2026-09-12) — 후보 다섯을 재판정하고 「거짓 초록」 하나를 쳤다.** 독립 레그와 **순위에서 갈렸고 실측이 갈랐다**: 나는 python JWKS 를 먼저 봤으나, JWKS 크기상한 축은 `assert_eq "6"` 으로 **여섯만 단언**하고 주석이 python 미완을 명시한다(`test-security-defaults.sh:140,184`) — 그 초록은 **정직**하다. 반면 H1 의 초록은 거짓이었다. 축 ①이 ②를 이기고, 레그가 옳았다. ⚠️ 반대로 레그를 **실측으로 기각**한 것도 하나 — 「aio 백채널이 무보호」라는 함의는 틀렸다(httpx 기본 `follow_redirects=False` + 저장소가 이미 **행동으로** 고정).

19. ✅ **`H1-conformance-authz-vacuous` — 이 PR 이 닫았다.** 공허가 셋이었고 파생 신규 하나(`authz-redirect-uri-not-per-call`)가 나왔다.
20. ⚠️ **재판정이 셋을 고쳤다**(전부 그 항목 본문에): python JWKS 비용 「70곳」은 **단어 언급 줄** 수였다(실제 목 30·단언 20·고유 테스트 **28**) · 그 항목의 aio 설계는 **세션을 잘못 지목**했다(`_s` 아니라 `async_s`) · `python-aio-security-test-asymmetry` 는 테스트 하나가 아니라 **보안 단언 여섯**이다.

21. ✅ **`jwks-response-size-unbounded-python` — 같은 세션이 닫았다.** 9언어 JWKS 크기상한 부류가 **완결**됐다(축 6 → 7). ⚠️ 여기서도 등록부의 서술이 틀렸다 — aio 설계가 세션을 잘못 지목했고, 비용 「70곳」은 단어 언급 수였다(실제 33곳 재배선). 대량 재배선은 독립 레그가 하고 내가 diff 를 검수했다(단언 계수 1:1 보존).

22. ✅ **`lenient-parsing-yields-false-success` — 같은 세션이 닫았다.** ⚠️ **rust 하나가 아니라 다섯**이었다(rust·python·ruby·php·dotnet). 회고 B4 대로 **먼저 아홉을 다 재고** 착수했고, 그 측정이 없었다면 dotnet 을 통째로 놓쳤을 것이다 — 읽기로는 「SDK 가 빈값을 거부한다」로 보이는데 **Duende 가 그 앞에서 강제변환**하기 때문이다. 축 1c 신설(9언어·하한 9).

⚠️ **이 세션이 세 번 어긴 것 하나 — 「편집한 뒤 그 게이트를 다시 돌린다」.** (1) 규칙 파일을 고치고 `check-docs` 를 안 돌려 예산 위반 커밋을 push 했고, (2) 압축 수정을 미커밋 상태에서 변이 돌려 잃었고, (3) ruby 생성자를 **추가한 뒤** rubocop 을 안 돌려 CI 를 빨갛게 만들었다(로컬은 추가 **전에** 돌린 초록이었다). 셋 다 「초록을 봤다」와 「지금 초록이다」를 혼동한 것이다. **게이트 결과는 마지막 편집 뒤의 것이어야 한다.**

23. ✅ **`python-aio-security-test-asymmetry` — 같은 세션이 닫았다.** 재판정이 **또** 넓혔다(6 → 8). aio 프로덕션은 이미 옳았고 **고정**만 없었다. 변이 6/6 `CAUGHT`.

**⟶ 다음 대상(2026-09-12 기준).** `rust-msrv-leg-vs-manifest-unguarded`(⚠️ **한 방향만 침묵** — 매니페스트를 내리면 `check-docs` 가 잡고, **CI 레그만 올리면** 아무도 안 잡아 MSRV 레그가 조용히 사라진다. S/S) · `authz-redirect-uri-not-per-call`(php·rust — **§4 와 양립하는지 사람 판정이 선행**) · `H3-harness-image-and-lock-pins` · `guard-detection-surface-hand-narrowed`[H](required **밖**에서 오탐 0 선행). ⚠️ **재판정부터** 시작한다 — 이 세션에서 손댄 항목 넷 중 **넷 다** 등록부 서술이 틀렸다(범위 셋·계수 하나).

**⟶ 6차(2026-09-12) — 「감사한 것과 도는 것이 다르다」 갈래.** 5차가 남긴 넷을 재판정했고 **또 서술이 틀렸다**(아래 24). 순서는 축 ①(지금 초록이 거짓인 것)이 정했다 — 넷 중 **거짓 초록은 하나뿐**이었고 그것이 1위였다. ⚠️ 독립 레그와 **순위에서 일치**했으나, 레그가 「세 자리」로 센 것 중 **둘은 설계였다**(install 경로의 락 재기입) — 실측이 갈랐다.

24. ✅ **`H3-harness-image-and-lock-pins` + `rust-msrv-leg-vs-manifest-unguarded` — 이 PR 이 둘을 함께 닫았다.** 같은 불변식이라 가드가 하나다. 야간 `cargo audit` 이 **빌드되지 않는 락**을 6주째 감사하고 있었다(락 `keycloak-sdk` 0.1.0 ↔ 매니페스트 1.0.0).
25. ⚠️ **재판정이 넷 중 넷을 고쳤다** — `H3` 는 「세 자리」가 아니라 한 파일의 둘(install 둘은 설계) · `rust-msrv` 는 지목 줄이 `:21`→**`:24`** · `guard-detection-surface-hand-narrowed` 는 「축 9 중 손 표 7」이 아니라 **축 11 중 손 표 9**(또 늘었다 — 그 항목 참조) · `authz-redirect-uri-not-per-call` 만 서술이 정확했다(7:2 그대로).

**⟶ 7차(2026-09-16) — 「야간이 여드레 빨갰는데 아무도 몰랐다」 갈래.** 이 세션은 등록부의 항목이 아니라 **지금 빨간 것**에서 시작했다. 축 ①(지금 초록이 거짓인 것)의 극단이다 — 초록이 거짓인 것보다 **빨강이 읽히지 않는 것**이 먼저다.

26. ✅ **`harness-orphan-container-reads-as-build-failure` — PR #506 이 닫았다(부류를 넓혀서).** 항목은 「이름 충돌 하나」를 적었으나 참인 부류는 **「실패 신호가 증상만 담고 원인을 안 담는다」**였다. 사고 자체는 상류가 냈고 상류가 닫았다(`json` 3.0.0 → `faraday` 2.14.3 불일치 → 2.14.4 가 수정). 그 항목 본문에 타임라인·통제 실험·실측을 적었다.
27. ⚠️ **신규 `nightly-failure-reaches-nobody` [H/M]** — 여드레 동안 **두 개의 독립 실패**가 같은 창에서 나고 사라졌는데 둘 다 조치가 없었다. 아래 그 항목.
28. ⚠️ **이 「다음 대상」 문단이 또 낡아 있었다 — 세 번째다.** 아래 6차 목록의 다섯 중 셋이 이미 닫혔고(`authz-redirect-uri-not-per-call` #485 · `H4` · `H8`), 그중 한 문장은 **쓰인 그날 참이었다가 같은 날 거짓이 됐다**: 「하네스 conformance 가 php 25/26 으로 이미 빨갛다」는 #483(09-12)이 쓸 때 참이었고(09-12 야간 install 실측 php·rust **25/26**), 같은 날 #485 가 고쳐 **09-13 밤부터 26/26**이다. ⚠️ **살아 있는 다음 대상은 다섯**이다 — `guard-detection-surface-hand-narrowed`[H] · `H2` · `H5` · `H6` · `H7`. 나머지는 아래에서 읽지 말 것.

**⟶ 다음 대상(2026-09-12 6차 기준 · ⚠️ 위 28 이 이 목록의 셋을 지웠다).** `authz-redirect-uri-not-per-call`(⚠️ **§4 사람 판정은 아직 열려 있다** — 2026-09-12 세션은 **범위에서 뺀** 것이지 판정한 것이 아니다. 재판정 결과 서술은 정확했다: 인가요청에 `redirect_uri` 를 호출당 받는 것이 **일곱**, 못 받는 것이 **둘**(php `AuthClient.php:48` 인자 0 · rust `auth.rs:106` 생성 시 config 값). 하네스 conformance 가 php 25/26 으로 이미 빨갛고, 초록으로 되돌리는 길은 **검사를 약하게 하는 것이 아니라 API 를 맞추는 것**이다 — php 선택적 인자 · rust 새 메서드로 둘 다 가산적이라 semver 파괴는 아니다) · `guard-detection-surface-hand-narrowed`[H](required **밖**에서 오탐 0 선행 — ⚠️ 이번 재측정에서 **축이 또 늘었다**) · `H2-harness-judgment-module-no-test` · `H4`~`H8`. ⚠️ **재판정부터** 시작한다 — 5차·6차 연속으로 손댄 항목 넷 중 넷이 틀렸다.

**⟶ 옛 목록(이제 닫힘): ~~`lenient-parsing-yields-false-success`~~(닫힘 — rust 하나가 아니라 다섯이었다: `token_provider.rs:71,86-89` 가 **문자열이 아닌 `access_token` 을 빈 토큰 성공으로 캐시**한다. `auth.rs` 는 `CoreTokenResponse` 라 fail-safe이고 **`expires_in` 누락만** 공유한다) · `python-aio-security-test-asymmetry`(범위 6 으로 확대됨) · `rust-msrv-leg-vs-manifest-unguarded`(⚠️ **한 방향만 침묵**이다 — 매니페스트를 내리면 `check-docs` 가 잡고, **CI 레그만 올리면** 아무도 안 잡아 MSRV 레그가 조용히 사라진다) · `authz-redirect-uri-not-per-call`(사람 판정 선행). ⚠️ 여전히 **재판정부터** 시작한다.

**PR 이 아닌 것**(선행이 빠져 있다): `guard-detection-surface-hand-narrowed` 의 파생화(required **밖**에서 오탐 0 선행) · `integration-admin-surface-uneven`(9×capability 결정 — php 가 roles/groups/realms 를 **0/3 계열** 부른다) · `integration-coverage-never-measured`(9개 설계) · `registry-truth-check`(레지스트리별 **버전** 오라클 + 전파 404 규칙 — ⚠️ 순진한 라이브 폴링은 「첫 404 로 실패 결론」 함정을 되살린다) · `published-bytes-have-no-oracle`(Portal 게시 후 실제 jar 페치) · `security-invariant-not-required`(룰셋 apply — ⚠️ **required 이름을 늘리지 말고** `doc-facts` 안으로 접는 쪽이 PR 크기다).

⚠️ **예산 정책은 정해졌다(#418) — 배치 2·3 은 그 위에서 돈다.** 문서 여럿이 상한에 붙어 있어 **정확성 수정 한 줄도 예산을 넘긴다**(배치 1 실측: 네 번, +300·236·120·84B). 이제 규칙은 「인상은 **교환**이고, 앵커 주석에 `옛값 → 새값` 을 적으며, **+300B 초과만 사람 판정**」이고 `check-docs.mjs` **검사 8b** 가 `main` 과 대조해 강제한다. **매 건 사람에게 올리지 말 것** — 상한 안이면 기록하고 진행한다. ⚠️ 반대로 **깎아서 맞추지도 말 것**: 압축이 「다시 재는 명령」을 지우면 그건 교환이 아니라 손실이고, 그때가 인상해야 하는 자리다.

⚠️ **`jvm-17-floor-never-shipped` [H] 는 여기 없다 — 남은 것이 릴리스뿐이었기 때문이다**(2026-09-06 사람 판정 「릴리스는 하지 않는다」 → **2026-09-23 사람 판정으로 뒤집혀 태그 둘이 나갔다**). 문서는 #413 이, **가드는 #415 가** 닫았다: `kind=runtime` 이 트리와 최신 릴리스 태그를 함께 읽어 격차가 기록되지 않으면 fail-closed 한다. **그 가드가 설계대로 반대 방향으로 실패했다** — 태그가 생기자 `published=21` 두 개를 지워야 통과했고, 자리를 정확히 한 건씩 지목했다(#545·#547).

⚠️ **다만 「릴리스뿐」이 곧 「릴리스하면 끝」이 아니었다.** 2026-09-06 실측(게시본 **91/91 major 65**)이 같은 자리에서 **아무 가드도 게시된 바이트를 읽지 않는다**를 드러냈다 — `published-bytes-have-no-oracle`. 그 항목은 2026-09-23 릴리스 세션이 설계까지 열었다.

**#415 가 남긴 부류 시험**(다른 주장에도 적용한다): **「소비자가 틀릴 수 있는데 HEAD 는 맞다면, 오라클은 트리가 아니라 태그·레지스트리다.」** 후보 — 게시된 공개 API 표면 · 게시 매니페스트의 의존성 하한 · 릴리스 바이너리에 컴파일된 기능 · 배포 아티팩트의 라이선스 · 「vX 에 포함됨」류 CHANGELOG 결속.

⚠️ **직전 세션들이 반복해서 밟은 함정**(전부 실측으로 잡혔다) — 착수 전 읽는다. (a)~(d) 는 2026-09-05, (e)(f) 는 2026-09-06.
   (a) **「사본이면 지운다」를 네 번 잘못 적용**했다. 지우려던 것이 **인접 판정의 입력**이었다(`18/20` 을 지우면 다음 줄의 「two branches」가 `20−18` 을 잃는다). 지우기 전에 앞뒤 문장의 유도 관계와 `git blame -L n-1,n+1` 로 같은 커밋인지 본다.
   (b) **계측기가 네 번 고장났다.** 줄단위 정규식이 **인라인 플로우 맵**을 놓치고(`matrix: { java: [...] }`), `git log -S'<속성이름>'` 은 **값만 바뀐 커밋을 못 잡는다**(개수가 안 변한다). 「N 개가 전부」를 말하기 전에 전수를 세고, 알려진 정답으로 계측기를 먼저 잰다.
   (c) **가드가 초록인 것은 삭제·안전의 근거가 못 된다.** 그 값을 읽는 스크립트가 0건이면 「안전」이 아니라 **「문서가 유일한 소재지」**다.
   (d) **서브에이전트가 리포 git 을 하이재킹했다** — 실제 `.git/config` 에 `core.worktree` 를 써서 `git status` 가 거짓 clean 을 냈다. 워크플로 직후 `git rev-parse --show-toplevel` 을 먼저 찍는다.
   (e) **미머지 PR 브랜치 위에서 새 브랜치를 팠다.** 세션이 `main` 에서 시작한다고 가정했는데 HEAD 가 열린 PR(#414)의 브랜치였고, 그 diff 가 #415 에 통째로 실려 나갔다(무해했으나 **PR 본문이 자기 범위를 틀리게 말했다**). 파기 전에 `git branch --show-current` + `gh pr list --head "$(git branch --show-current)" --state open` 를 찍는다. ⚠️ **스쿼시 저장소라 `git merge-base --is-ancestor` 로는 판정할 수 없다** — 머지돼도 NOT ancestor 다. 답을 주는 것은 PR 머지 상태와 「내용이 트리에 있는지」(`git log -S'<고유 문자열>' origin/main`)다.
   (f) **Grok 이 빈 디렉터리·150단어에서도 타임아웃했다.** `grok_build_verify` 가 붙이는 자가검증 체크리스트가 추론량을 배로 만든다. **진단 순서**: 타임아웃 → `grok_build_delegate` 로 `"PONG"` 한 번(연결과 추론량을 가른다) → 같은 질문을 delegate 로. 실측: verify 240s·300s 두 번 실패 → delegate 로 즉시 성공.
   ⚠️ **「delegate 면 된다」는 틀렸다(2026-09-16 정정).** delegate 도 **300s·420s 두 번 타임아웃**했다 — 둘 다 「파일 여럿을 읽고 판단하라」였다(첫 번째는 8개 파일 목록, 두 번째는 `git diff main...HEAD` + 5파일). 같은 세션에서 PONG 은 즉답했고, **읽을 파일을 하나로 못박은 질문**과 **사실을 프롬프트에 넣고 아무것도 안 읽게 한 질문**은 셋 다 완주했다. 즉 비용은 도구가 아니라 **탐색량**이다. 규약: 레그에게는 (i) 읽을 파일을 열거하고 그 수를 1~2로 묶거나, (ii) 사실을 인라인으로 주고 「읽지 말라」고 쓰고, (iii) 답 길이를 단어 수로 못박는다.

⚠️ **기각 11건은 이 등록부에 없다 — 의도적이다.** 게시 잡의 `environment:` 부재 · `workflow_dispatch` 우회 · admin-capability D열 무보호는 문서화된 설계이거나 되살릴 조건이 적힌 기각이다. 착수 전 [기각 레지스트리](../../governance/rejected.md)를 먼저 읽는다.

⚠️ **되살리면 안 되는 것 둘.** `harness-consume-pin-unsupported` 의 `scripts/check-versions.mjs` 확장분과 `public-registry-install-smoke` 의 `harness/install/install-verify.sh:44` 는 각각 기각된 자리다. `rust-rustdoc-jwks-refetch-says-60` 은 **주석 문자열만** 고친다 — 두 줄 아래 `with_jwks_min_refetch_secs` 에 0 강제를 넣으면 또 다른 기각을 되살린다.

## 닫힌 항목 (2026-09-03)

권장 우선순위 1~5번과 그 후속을 밟아 18건이 `main` 에 들어갔다. 체크박스만 두면 「어떻게 닫혔는지」가
사라지므로 PR 을 함께 적는다.

⚠️ **닫을 때마다 원장의 「범위」를 먼저 의심한다.** 2026-09-04 재검증에서 손댄 7항목이 **전부** 범위를
틀리게 적고 있었고, 방향이 양쪽이었다 — 축소(`jwks-cold-cache-ungated` 1→7언어 · `boundary-…` 2→6 ·
`selftest-…` 1→26)뿐 아니라 **과장**(`python-sync-admin-close-noop` 의 「영영 안 닫힌다」)도 있었다.
지목 줄이 틀린 것도 둘이다(`kotlin-ci.yml:70` 은 `java-version`, `boundary-…` 의 Ruby 줄은 clean).

| PR | 닫은 항목 | 한 줄 |
|---|---|---|
| #381 | `post-1-0-registry-missing` | 이 등록부 자체. 가드가 실제로 보는지 A/B 로 확인했다(파일을 옮기면 `check-docs` 가 세 경로로 실패) |
| #380 | `go-admin-lane-bypasses-redirect-ban` · `go-postform-treats-3xx-as-success` · `go-jwks-fetch-ignores-status-and-empty-keyset` · `jwks-fetch-ignores-http-status` | 백채널 3xx 가 SSRF 와 fail-open 을 함께 열고 있었다. ⚠️ 리다이렉트를 막자 gocloak 이 302 에 `("", nil)` 을 돌려주는 **두 번째 결함**이 드러났다(독립 검증 레그가 착수 전에 지목) |
| #382 | `dotnet-authzrequest-tostring-leaks-pkce-verifier` · `authorization-request-verifier-unmasked` · `php-default-serializers-bypass-masking` | PKCE verifier 와 토큰이 기본 직렬화기로 샜다. 가리는 범위는 Rust `Debug` impl 과 동형으로 맞췄다 |
| #383 | `ruby-admin-path-segment-unescaped` | `../` 가 경로를 재작성하고 공백이 stdlib 예외를 냈다. 부류 재스캔이 `@realm` 20곳을 더 찾아 총 35곳 |
| #385 | `ci-perms-flow-style-permissions-bypass` · `check-coverage-arg-parsing-silently-disarms-gate` · `guard-neutering-wiring-unprotected` | 가드 셋이 「거짓말하는 방향」으로 고장나 있었다 — 임계값이 사라지고, 표기 하나로 상승이 안 보이고, `continue-on-error` 로 무력화됐다 |
| #387 | (교차가드 신설) · `authorization-request-verifier-unmasked` 의 **Go 절반** | 마스킹 **바닥 계약**(기본 문자열/디버그 표현이 비밀을 `***` 로 낸다)을 9언어 축으로 켰다. ⚠️ #382 가 그 항목을 닫았다고 표시했으나 Go·Node 중 **Node 만** 고쳤었다 — Go 는 `TokenSet.String()` 이 포인터 리시버라 값이 새고 `AuthorizationRequest` 에는 String 이 없었다(프로브 실측). 기각돼 있던 `go-tokenset-json-unmasked` 는 **기각 사유가 지목한 대안**(`slog.LogValuer`)으로 구현했다 |
| #388 | (런타임 커버리지) | 하한을 건드리지 않고 위로 넓혔다 — php **8.5**(composer.json 이 이미 약속한 범위) · python 3.14 · node 26 · ruby 4.0 · JDK 25 · .NET SDK 10. ⚠️ CI 가 두 가지를 답했다: ruby 4.0 은 **SDK 가 아니라 테스트**가 `CGI.parse` 제거로 깨졌고, go 1.27 은 `staticcheck` 가 못 읽어 레그를 뺐다(되살릴 조건 워크플로 주석) |
| #389 | `runtime-eol-support-window` | JVM 소비자 하한 21 → **17**. 2026-07-03 의 반대 판정을 되돌린 것이고, **그 커밋이 스스로 「소스 무변경」이라 적어** 21 이 기술적 필요가 아니었음을 증명한다. 가드 둘을 함께 세웠다 — 산출물 바이트코드 하한(`check-jvm-bytecode-floor.mjs`)과 `check-docs` 의 추출기(`jvmToolchain` → `JvmTarget`) |
| #395 | (dependabot 정책) | rust `keycloak` 의 마이너 상향 차단 — 그 숫자는 semver 가 아니라 **대상 서버 라인**이다. ⚠️ #394 의 「실제 26.6 서버 integration」이 **초록이었는데도** 받지 않았다(그 초록은 테스트가 밟는 경로까지만 증명한다) |
| #397 | `rust-logout-ignores-http-status` | `reqwest` 의 `send()` 는 전송 실패에만 `Err` 를 줘서 400/401/404 가 `Ok(())` 였다 — 세션이 살아있는데 호출자는 로그아웃 성공으로 믿는다. ⚠️ 지운 주석이 「다른 SDK와 동형」이라 적고 있었으나 자매 여덟을 읽으면 **Rust 만 혼자**였다. 상태코드를 특별대우하지 않는다(404 를 삼키면 오설정이 안 보이고, 400 을 통과시키면 진짜 클라이언트 오류도 함께 통과) |
| #398 | `rust-rustdoc-jwks-refetch-says-60` · `python-config-comment-says-60` | 주석 3곳이 JWKS 기본값을 60 이라 말했다(실제 30). rust 둘은 **공개 rustdoc** 이라 docs.rs 에 렌더된다. ⚠️ 문서 축이 `SD_DOCS`(README·docs)만 봐서 **소스 파일이 목록에 없었다** — 아홉 언어 소스 전체를 훑는 2b 축을 세웠다(테스트 제외: `JwtValidatorTest.kt:515` 의 "캐시 TTL(기본 5분)" 이 실측 오탐) |
| #399 | `php-tokenset-null-expiry-treated-as-fresh` (+ **Ruby**) | 만료 시각 미상을 「안 만료됨」으로 읽었다. ⚠️ 원장은 「PHP만」이라 적었으나 재스캔 결과 **7 fail-safe / 2 fail-open**. PHP 는 provider 캐시가 죽은 토큰을 무한 재사용하고, Ruby 는 공개 API 만 틀리다. ⚠️ **두 언어 다 테스트가 결함을 의도로 고정**하고 있었다(`…AndNeverExpired` · `"is never expired"`) |
| #417 | `jvm-cold-cache-unmeasured` | 재고 나니 **고칠 것이 없었다** — java·kotlin 은 콜드 캐시 + IdP 503 에서 이미 요청 2건이다(일곱은 수정 전 20). Nimbus 가 *source* 를 rate-limit 해 콜드 로드까지 덮는다. ⚠️ **상한 단언만으로는 하드닝 삭제를 못 잡는다** — `.rateLimited(...)` 를 지워도 Nimbus 기본 30초가 대신 걸려 상한이 그대로 2고, 무너지는 것은 **대조군**(interval 0 이 20→2)이다 |
| #416 | `doc-audit-batch1-remainder` | 7건 수정 · 2건 반박 확정. 최고가치는 문서 오류가 아니라 **보안 위험**이었다 — 백업 가이드가 realm export 를 「패스워드 제외」라 가르치는데 실서버 실측상 argon2 해시가 평문 JSON 으로 나온다(대조군 `--users skip` → 0건) |
| #415 | `registry-contract-claims-use-tree-oracle` · `consumer-floor-change-needs-release-or-registered-gap` | 가드가 **작업 트리**만 오라클로 써서 소비자에게 거짓을 집행했다 — `kind=runtime` 에 최신 릴리스 태그를 두 번째 오라클로 붙였다. ⚠️ 공허 경로 둘을 실측으로 막았다: 빈 태그를 보간하면 `git show ":path"` 가 **인덱스**를 읽고, 버전 문자열 정렬은 **RC 를 정식 뒤에** 세운다. ⚠️ 본문 대조를 맨 `includes` 로 두면 `>=2` 가 `>=24` 에 걸린다(독립 검증 레그 지목) |
| #400 | `java-kotlin-jwks-response-size-unbounded` | SSRF 하드닝용 리트리버를 주입하는 **행위 자체가** Nimbus 의 51200 상한을 지웠다(바이트코드: 2-arg 가 `iconst_0`, 빌더는 `ldc 51200`). `JWKSourceBuilder.DEFAULT_HTTP_SIZE_LIMIT` 참조로 복원. ⚠️ 재스캔에서 **Go 가 이미 갖고 있었다** — 주석이 출처를 그 Nimbus 상수라 밝힌다 |

곁가지로 **#384**(php API 게이트 정밀도)가 필요했다 — `php-semver-checker` 가 `implements`
절 하나에 오탐을 내고 `final` 클래스의 메서드 추가를 파괴로 세어 #382 를 막았다. 사람 판정으로
게이트에 정밀도를 넣었고, 면제는 전부 **소스로 반증 가능한 술어**다.

⚠️ **되돌린 것 하나** — Ruby admin 리소스 셋을 모듈로 추출하는 리팩터를 비차단 SonarCloud 중복
때문에 넣었다가, 그것이 **required 인 `doc-facts` 를 깨뜨려**(가드가 「리소스 하나 = 파일 하나」를
전제한다) 되돌렸다. 그 중복은 아직 남아 있고 비차단이다 — 정리 방법 둘은 `repo-settings-ssot-gap`
옆에 적지 않고 여기 남긴다: (a) 리팩터 + 두 가드를 모듈 인지형으로, (b) `sonar.cpd.exclusions`.

## 착수 순서

1. **이 등록부를 저장소에 남긴다** — 나머지 149개의 전제.
2. **Go 전송 하드닝** — 게시본에서 활성인 SSRF + fail-open. (PR #380)
3. **시크릿 평문 노출**(.NET·Node·PHP) — 소비자 손에 이미 가 있다. ⚠️ 같은 결함의 Go 판이 기각돼 있어, 교차언어 가드를 켜기 전에 그 비대칭을 사람이 판정해야 한다.
4. **Ruby admin 경로 무이스케이프** — 실행으로 재현됨. 참조 구현이 저장소 안에 있다(`go/admin_realms.go` 의 `url.PathEscape`).
5. **가드 무력화 3종** — 잠복이나 S 이고, 자가테스트가 이미 배선돼 있어 가장 싸다.
6. **런타임 지원 창** — 기한이 붙은 유일한 항목. 코드 수정이 아니라 **소비자 절단 여부의 사람 판정**이다.

⚠️ 5번을 1순위로 올리자는 판단이 인벤토리 과정에서 나왔으나(「가드가 거짓말하면 이후 검증이 전부 무효」), 독립 검증 레그가 기각했고 실측이 그 기각을 지지했다 — 두 가드 결함은 **잠복**이다(실 호출부는 공백형 인자를 쓰고, 저장소에 플로우 표기 `permissions` 는 없다). 「무효」는 과장이다.

## 읽는 법

각 항목은 근본원인 하나에 대응한다 — 같은 결함이 여러 줄·여러 언어에 걸친 것은 한 줄로 접혀 있다. `[H/M/L]` 은 심각도, `[S/M/L]` 은 작업량. **가드 없는 수정은 완료가 아니다** — 항목을 닫을 때 「다시 깨지면 CI 가 어떻게 잡는가」를 함께 남긴다([작업 프로세스](../../governance/process.md) ⑤⑥).

전체 근거·수정안·동반 가드·검증 명령은 기계용 원장에 있다: `ledger-dedup.json`(원장 209건) · 인벤토리 산출물(패키지 150건). 이 문서는 **무엇이 열려 있는가**만 소유한다.

---

## A. 확정 결함 — 12건 (열림 1)

3렌즈 만장일치 + 오케스트레이터 재실행 확인.

### 확정 + weak — 12

- [x] `dotnet-authzrequest-tostring-leaks-pkce-verifier` **[H/S]** .NET AuthorizationRequest가 positional record라 ToString이 PKCE code_verifier를 그대로 찍는다 · `dotnet/src/Xzawed.Keycloak.Sdk/Tokens.cs:66`
- [x] `go-admin-lane-bypasses-redirect-ban` **[H/M]** Go admin 레인이 SDK의 리다이렉트 금지를 통째로 우회한다 — client_secret을 실은 로그인이 3xx를 따라간다 · `go/admin.go:47`
- [x] `rust-logout-ignores-http-status` **[H/S]** Rust logout이 응답 상태를 보지 않아 400/401/404에도 Ok(())를 돌려준다 — 「다른 SDK와 동형」 주석은 거짓 · `rust/src/auth.rs:236`
- [x] `ci-perms-flow-style-permissions-bypass` **[H/S]** 플로우 스타일 `permissions: {contents: write}`가 CI 권한 가드에 통째로 안 보인다 — 실측으로 「상승 1건」이 0건이 됐다 · `scripts/check-ci-permissions.mjs:100`
- [x] `rust-rustdoc-jwks-refetch-says-60` **[M/S]** Rust 공개 API의 doc 주석 두 곳이 JWKS 최소 재조회 기본값을 60초라 말한다(코드는 30) — 문서 축이 소스 주석을 안 본다 · `rust/src/config.rs:18`
- [x] `java-kotlin-jwks-response-size-unbounded` **[M/S]** Java·Kotlin의 NoRedirectResourceRetriever가 Nimbus의 51200바이트 상한을 지웠다 — JWKS 응답이 무제한으로 메모리에 들어온다 · `java/keycloak-sdk-auth/src/main/java/io/github/xzawed/keycloak/auth/NoRedirectResourceRetriever.java:24`
- [x] `php-tokenset-null-expiry-treated-as-fresh` **[M/S]** ⚠️ **원장이 「PHP만」이라 적었으나 Ruby 도 같았다**(실측: 9개 중 7 fail-safe / 2 fail-open). 만료 시각 미상을 「만료 안 됨」으로 읽어 PHP 는 client-credentials 캐시가 죽은 토큰을 영원히 재사용한다 · `php/src/Token/TokenSet.php:59` + `ruby/lib/keycloak_sdk/tokens.rb:21`
- [x] `go-jwks-fetch-ignores-status-and-empty-keyset` **[M/S]** Go JWKS fetch가 상태코드도 키 유무도 안 본다 — 오류 본문 JSON이 빈 키셋으로 파싱돼 캐시를 덮는다 · `go/jwt.go:167`
- [x] `check-coverage-arg-parsing-silently-disarms-gate` **[M/S]** check-coverage.mjs의 인자 파싱이 임계값을 조용히 0/NaN으로 만든다 — 실측으로 `--min-line=99`가 「임계 0/0」으로 통과했다 · `scripts/check-coverage.mjs:29`
- [x] `php-default-serializers-bypass-masking` **[M/S]** [weak·채택] PHP는 마스킹을 __toString에만 걸어 json_encode()가 accessToken·refreshToken·clientSecret을 원문으로 뱉는다 · `php/src/Token/TokenSet.php:9`
- [x] `java-rules-close-scope-ambiguous` **[L/S · 닫힘 2026-09-06 #423]** [weak·채택] .claude/rules/java.md가 close()의 정리 범위를 java/README.md와 반대로 읽히게 적는다 · `.claude/rules/java.md:33`
- [ ] `auto-bump-manifest-crosscheck-skip` **[L/M]** [weak·보류] auto 범프 4개 언어의 매니페스트 대조 스킵 — 기각 근거가 유효하다(잔여는 버전 역행뿐) · `.github/workflows/dispatch-release.yml:194`

## B. 재검증 대상 — 51건 (열림 15)

3렌즈 통과, 원장은 개별 재실행을 하지 않았다. 이번 인벤토리에서 전량 파일 확인 — 기각 권고 0건.

### 재검증 · 언어 소스 — 15

- [x] `jwks-fetch-ignores-http-status` **[H/S]** JWKS fetch가 HTTP 상태 코드를 보지 않는다 — Go는 게이트웨이 오류 JSON으로 키 캐시가 오염된다 · `go/jwt.go:181`
- [x] `ruby-admin-path-segment-unescaped` **[H/M]** Ruby admin 5개 리소스가 경로 세그먼트를 무이스케이프 보간한다 — 엔드포인트 우회 + stdlib 예외 누출 · `ruby/lib/keycloak_sdk/admin/users.rb:18`
- [x] `go-postform-treats-3xx-as-success` **[H/S]** Go postForm이 3xx를 성공으로 읽는다 — Logout이 세션이 살아있는데 nil을 돌려준다 · `go/auth.go:210`
- [x] `jwks-cold-cache-ungated` **[M/M→재분류]** 콜드 캐시 JWKS 로드가 rate-limit 게이트 밖 · `rust/src/jwks.rs:61`
- [x] `jvm-cold-cache-unmeasured` **[M/S · 신규 2026-09-05 · 닫힘 2026-09-06 #417]** java·kotlin 의 콜드 캐시 + IdP 장애 동작이 한 번도 측정되지 않았다 — 나머지 일곱은 20→1 로 닫혔는데 이 둘만 미지수다 · `java/keycloak-sdk-auth/src/main/java/io/github/xzawed/keycloak/auth/JwtValidator.java`
- [x] `dependabot-ignore-kinds-uncounted` **[M/S · 신규·닫힘 2026-09-05]** 「올려선 안 되는 핀 N 종류」가 두 곳에 손으로 적혀 이틀 만에 두 번 어긋났다(ci.md 셋 · CLAUDE.md 넷 · 실측 `ignore` 8건) · `.github/dependabot.yml`
- [x] `php-readiness-no-api-claim` **[M/S · 신규·닫힘 2026-09-05]** `.claude/rules/php.md` 가 「미러·Packagist 는 API 로 확인할 수 없다」고 적었으나 스크립트는 둘 다 조회한다 — 저장소가 스스로 「거짓이었다」고 기록한 문장이 정본 규칙에 남아 있었다 · `.claude/rules/php.md:38`
- [ ] `node-rules-history-prose` **[S/S · 신규 2026-09-05]** `.claude/rules/node.md` 에 「무엇이 일어났는가」형 사후분석 산문 약 800B(예산 6,255B 의 13%)가 행동 지침을 밀어내고 있다 · `.claude/rules/node.md:26,32,38`
  - 삭제 대상: `17 type errors passed CI: 12 × … 5 × …`(이미 고쳐진 과거 계수) · `is a product of its history` 로 시작하는 `26.7.0 → ~26.6.4 → ~26.7.0` 왕복 서술(마지막 행동 규칙 한 문장만 남긴다) · `it had four entries while this line listed three`(해소된 드리프트 기록).
  - ⚠️ **보존 대상과 섞지 말 것** — `13 × TS6059`(include 에 test 를 넣으면 무슨 일이 나는가)와 `~4.5 min / wait 45 seconds`(재현 절차)는 이력이 아니라 **다음 세션이 다시 잴 한계**다. 지우면 손실이다.
- [x] `doc-audit-2026-09-05-confirmed-six` **[M/M · 신규·닫힘 2026-09-05]** 고정 스냅샷 문서감사가 확정한 6건 — 전부 「가드받는 SSOT 의 사본이 갈렸다」 부류다 · `.claude/rules/`
- [x] `harness-gradle-version-copies-unguarded` **[M/S · 신규·닫힘 2026-09-05]** 하네스의 gradle 버전 사본이 어느 가드도 안 읽고, **그중 하나는 이미 낡았다** · `harness/install/install-verify.sh:906`
- [x] `rulefile-matrix-vs-workflow-unguarded` **[M/M · 신규·닫힘 2026-09-05]** 규칙 파일이 적는 CI 매트릭스를 워크플로의 `strategy.matrix` 와 대조하는 기계가 없다 · `.claude/rules/{java,ruby}.md`
- [x] `rust-msrv-leg-vs-manifest-unguarded` **[S/S · 닫힘 2026-09-12]** ⚠️ **지목 줄이 빗나가 있었다** — `rust-ci.yml:21` 은 주석이고 실제 레그는 **`:24`** 다. 주장 자체는 참이었다(실측: 매트릭스 레그만 올리면 **아무 검사도 실패하지 않는다** — `check-docs.mjs` 의 `MATRIX` 는 java·ruby 둘뿐이라 rust 는 표에 없다). `H3-harness-image-and-lock-pins` 와 **같은 불변식**이라 한 가드로 닫았다(`check-versions.mjs` 의 툴체인 리터럴 축). ⚠️ **산문을 조준하지 않는 것이 이 가드가 required 안에서 사는 조건이다** — CHANGELOG 의 「MSRV 1.88 그대로」는 **이력**이라 MSRV 가 올라도 바뀌면 안 되고, README·getting-started 의 「1.88+」는 `check-docs.mjs:544` 의 kind=runtime 앵커가 이미 소유한다. 그래서 대상은 **지시어 행 둘**뿐이다(매트릭스 축 · `^FROM rust:<ver>`). 변이 M3/M4 양방향 `CAUGHT` + OFF 짝 `SILENT`.
- [x] `matrix-fail-fast-cancels-floor-leg` **[M/S · 신규·닫힘 2026-09-05]** 매트릭스 워크플로 8개 중 **6개에 `fail-fast: false` 가 없어** 최신 레그가 깨지면 소비자 하한 레그가 취소된다 · `.github/workflows/`
- [ ] `jvm-17-floor-never-shipped` **[H/M · 신규 2026-09-06 · 2026-09-23 태그 나감, 게시 미확인]** 하한 21→17 이 게시된 적이 없었다. 태그 둘이 나가고 워크플로도 둘 다 초록이나 **Portal Publish 는 사람 클릭이라 아직 안 눌렸다** — repo1 실측 둘 다 404 · `java/pom.xml:61` · `kotlin/build.gradle.kts:50`
  - 실측: `git show v1.0.0:java/pom.xml` → `<maven.compiler.release>21`. `kotlin-v1.0.0` 은 `jvmToolchain(21)` 만 있고 `jvmTarget`·`-Xjdk-release` 가 **없어** 바이트코드도 21(트리 주석 `kotlin/build.gradle.kts:47` 이 그 인과를 적는다). 태그 `v1.0.0` 2026-09-01 · 하향 커밋 `6a9d620` 2026-09-04 · **그 뒤 JVM 릴리스 0건**(`git tag -l 'v*' 'kotlin-v*'`).
  - ⚠️ **남은 둘, 이 순서로.** (a) 사람이 Portal 에서 **Publish 를 누른다**(java·kotlin 각각). (b) repo1 에서 실물을 본 **뒤에야** API 기저선(`japicmp.baseline`·kotlin-ci `BASELINE`)을 올린다(DEPLOY §4 8→9). 태그가 무엇을 핀했는지 다시 재는 명령은 `compatibility.md` 의 JVM 경고가 소유한다.
  - ⚠️ 이 항목을 닫기 전에 아래 `registry-contract-claims-use-tree-oracle` 를 먼저 볼 것 — 같은 부류가 다른 주장에도 있다.
  - **레지스트리 오라클로 확정(2026-09-06).** 지금까지 이 주장의 근거는 **태그의 빌드 설정**이었다(추론). Maven Central 에서 게시본을 직접 받아 클래스파일 major 를 읽었다 — `keycloak-sdk` · `-core` · `-auth` · `-admin` · `-kotlin` 다섯 jar, **클래스 91개 전부 major 65(JDK 21)**. `major > 61` 이 **91/91** 이므로 JDK 17 소비자는 한 클래스도 못 읽는다. 나머지 셋은 **서로 다른 이유로** jar 가 없다(독립 검증 레그가 「404 는 pom-only 의 증거가 아니다」로 지목해 pom 을 직접 읽었다): `-bom`·`-parent` 는 `<packaging>pom</packaging>` 이고, **`-examples` 는 `1.0.0` 자체가 없다**(그 좌표에는 `0.1.0`·`0.1.0-RC1` 뿐 — 부모의 `<excludeArtifacts>` 가 그때부터 걸렸다. 경위는 `java/keycloak-sdk-examples/pom.xml` 주석). 재현: `curl -sSL $B/<artifact>/1.0.0/<artifact>-1.0.0.jar` 후 각 `.class` 의 6~7바이트를 읽고, jar 가 없으면 **pom 의 `<packaging>` 과 버전 목록을 함께 본다**.
  - ⚠️ **kotlin 은 이 측정으로 추론이 사실이 됐다** — 그전 근거는 「`kotlin-v1.0.0` 에 `jvmTarget` 이 없으니 툴체인 21 이 타깃일 것」이었고, 이제 배포된 바이트가 그렇다고 말한다.
- [x] `jvm-api-surface-pin-unguarded` **[H/S · 신규·닫힘 2026-09-23]** `-Xjdk-release`·`options.release` 를 읽는 가드가 0 개였다(부르는 다섯 자리가 **전부 주석**) — 지우면 major 는 61 그대로라 바이트코드 가드도 초록인데 JDK 17 소비자만 런타임에 죽는다 · `scripts/check-jvm-api-surface-pins.mjs`(변이 7/7 CAUGHT + OFF 짝 · 그중 둘은 독립 레그가 낸 구멍)
- [x] `published-jar-bytes-never-read` **[H/M · 신규·닫힘 2026-09-23]** 게시된 jar 를 받아 바이트를 읽는 호출 지점이 **0 개**였다 — 사슬이 태그에서 끊겨, 릴리스가 다른 JDK 로 빌드했거나 업로드가 부분 실패해도 저장소는 전부 초록이었다 · `scripts/check-published-jvm-floor.mjs` + `published-floor.yml`(예약·required 밖 · 변이 7/7 CAUGHT + OFF 짝 · 그중 하나는 **실제 repo1 바이트**로 CAUGHT · 실측 274 클래스, 1.0.0 부분만 세면 91 로 손측정과 일치)
- [ ] `published-bytes-have-no-oracle` **[M/M · 신규 2026-09-06 · 범위 축소 2026-09-23]** 남은 것은 **다이제스트 동일성**이다 — 게시 바이트를 읽는 것은 위 항목이 닫았고, 「우리가 올린 그 바이트인가」는 못 닫았다 · `scripts/check-published-jvm-floor.mjs`
  - ⚠️ **선행이 있다 — 봉인 단계 없이는 못 닫는다.** 설계 판정 2026-09-23(바로 아래 블록 주석 · 경위는 PR #548·#549).

<!-- 설계 판정 2026-09-23 (독립 레그 + 재판정). 예산에 계상되지 않는 자리에 둔다 — 이 항목을
     실제로 착수하는 세션만 읽으면 되는 판정이고, 상시 표면에 둘 것은 위 한 줄이면 족하다.

     (a) **이 이름이 뜻하는 것은 다이제스트 동일성이다.** 업로드한 바이트의 다이제스트를 남기는
         릴리스 워크플로가 없고 두 빌드 다 `outputTimestamp` 가 없어(재현 불가) **대조 대상
         자체가 없다.** 다시 재는 법:
             grep -rn 'outputTimestamp\|sha256sum\|sha512sum' .github/workflows java/pom.xml kotlin/build.gradle.kts
         ⚠️ 봉인 단계를 먼저 넣지 않으면 이 이름은 닫히지 않는다. 「게시 jar 를 받아 클래스
         major 를 읽는다」는 **더 약한 별건**이므로 그것으로 이 항목을 닫지 말 것.

     (b) ⚠️ **2026-09-23 저녁에 이 줄을 고쳤다 — 앞서 적은 규칙이 틀렸다.**
         틀린 규칙: 「SSOT(`df_published_version`)가 「게시됨」이라 말하는 좌표가 전파 창을
         넘겨서도 404 면 SSOT 가 거짓이므로 실패」. **틀린 이유**: `df_published_version` 은
         런북 §4 **1단계**에서 태그보다 **먼저** 올라간다 — 그것은 *의도*이지 현재 사실의
         주장이 아니고, 레지스트리를 앞서는 것이 설계다. 그 규칙대로면 사람이 Portal 을 누르기
         전 구간 내내 거짓 빨강이 난다(독립 레그가 「결함」으로 판정했고 그 판정이 옳다).
         **바른 규칙(구현됨)**: 검사 대상을 `maven-metadata.xml` 이 **실제로 싣는 버전**으로
         잡는다. 그러면 타이머도, Portal 상태도, 전파 창도 필요 없다 — 미게시는 애초에 대상이
         아니고, 게시된 것은 전부 대상이다. ⚠️ 그래도 **미결을 초록으로 저장하는 부류**는
         남으므로 (d) 의 공허 규칙이 그것을 맡는다.

     (c) **어디서 도는가**: required 밖 · 스케줄 워크플로. 릴리스 워크플로 안의 단계로 넣으면
         Publish 가 사람 클릭이라 **언제나 스테이징을 보고 공허해진다**. required 에 넣으면
         네트워크 의존 검사가 저장소를 잠근다(CLAUDE.md).

     (d) **공허 하한은 상수가 아니라 규칙**(구현됨): 좌표가 하나라도 있으면 **(아티팩트, 버전)
         쌍을 하나 이상 실제로 읽어야** 한다(`vacuous-run`). jar 에 클래스가 0 개인 것도 실패
         (`vacuous-jar`). `-bom` 은 `<packaging>pom</packaging>` 이라 **jar 를 요청하지 않고**,
         `-examples` 는 자기 metadata 에 그 버전이 없어 건너뛴다 — 둘 다 **파생**이지 손으로
         적은 예외가 아니다. ⚠️ java 는 **집합 모듈만 보면 공허하다**(실측: `keycloak-sdk` 의
         jar 는 버전당 클래스가 **1 개**다) — 형제 목록을 그 버전의 태그에서 뽑고, 0 개를 뽑으면
         `no-siblings` 로 실패한다.
         ⚠️ **경계값 대조군이 없으면 환산식이 한 칸 느슨해져도 안 보인다** — 변이 증명에서
         `feature + 44` → `+ 45` 가 **SILENT** 이었다(65 대 61 처럼 먼 케이스만 있었다).
         하한 17 의 상한은 정확히 major 61 이므로 **62 는 실패하고 61 은 통과**해야 한다.

     (e) ⚠️ **이 오라클은 상수풀을 끝내 읽지 않으므로 `jvm-api-surface-pin-unguarded` 를 대신할
         수 없다** — major 가 61 이어도 `--release` 없이 컴파일하면 상수풀이 빌드 JDK 의 API 를
         가리키고, 그 사고는 바이트를 아무리 받아 봐도 안 보인다. -->

  - 독립 검증 레그(Grok)가 「릴리스만 남았다」를 검증하다 낸 것이고, 셋은 실측으로 확인했다.
  - ⚠️ **독립 검증 레그가 (1)을 「오버스테이트」로 판정했으나 그건 맥락 부족이었다** — 「릴리스 후 `published=21` 을 **지워야** 통과한다」는 규칙은 실제로 구현돼 있다(`check-docs.mjs:1252` + 자가테스트 (f)). 나머지 둘(위 (2)의 「어떤 가드도」, `-examples` 의 「pom-only」)은 **레그가 옳았고 고쳤다**. 레그의 판정도 액면가로 받지 않는다 — 양방향이다.
  - **(1) 태그 ≠ Central.** `kind=runtime` 의 오라클 B 는 `git show <태그>:<매니페스트>` 다. 사람이 태그를 밀면 트리·태그가 함께 17 이 되어 `published=21` 을 **지워야 통과**하는데, 그 시점에 Portal Publish 가 안 됐거나 실패했거나 일부 모듈만 올라갔어도 가드는 초록이다 — 소비자는 여전히 21 짜리 `1.0.0` 을 받는다. ⚠️ `CLAUDE.md` 가 이미 「워크플로 초록 ≠ 게시」를 경고하나 **그 경고를 집행하는 것은 없다**.
  - **(2) 선언 ≠ 방출된 바이트.** ✅ **닫혔다** — `published-jar-bytes-never-read`. ⚠️ 남긴 서술 규칙: 「**어떤** 가드도 안 읽는다」처럼 전수를 주장하지 말 것(레그가 지목했다). 참인 진술은 「게시 jar 를 받아 바이트를 읽는 **호출 지점**이 0 개」였고, 그 수를 세는 것이 판정이다.
  - **(3) 「최신 태그」 ≠ 소비자가 고정한 좌표.** 가드는 최신 태그만 본다. `1.0.1` 이 17 로 나가도 `1.0.0` 에 핀한 소비자는 계속 21 이 필요하고, 그때 문서를 현재형으로 고쳐 쓰면 그 사실이 지워진다.
  - **되살릴 조건이 아니라 착수 조건**: JVM 릴리스를 낼 때 이 항목을 함께 본다 — 그 순간이 (1)이 실현되는 유일한 창이다. 최소 형태는 「게시 후 `repo1` 에서 jar 를 받아 major 를 재는 스텝」이고, 재는 법은 위 재현 명령이 이미 갖고 있다.
- [x] `registry-contract-claims-use-tree-oracle` **[H/L · 신규 2026-09-06 · 닫힘 2026-09-06 #415]** `doc-guard: kind=runtime` 이 **작업 트리**를 오라클로 썼다 — 소비자가 받는 것은 태그·레지스트리라, 트리가 맞는 동안 소비자에게 거짓을 **집행**할 수 있다 · `scripts/check-docs.mjs:526-545`
- [x] `consumer-floor-change-needs-release-or-registered-gap` **[M/S · 신규 2026-09-06 · 닫힘 2026-09-06 #415]** 소비자 가시 하한을 바꾸는 PR 이 릴리스 없이 머지되면 문서가 즉시 거짓이 된다 — 기각 체크리스트에 항목이 없었다 · `docs/governance/process.md`
- [x] `doc-audit-batch1-remainder` **[H/L · 신규 2026-09-06 · 닫힘 2026-09-06 #416]** 소비자 문서 배치 1(10개) 감사의 **잔여 9건** — 인용 181건 전건 실재(계측기 5/5 자가검증), 반박 10건 중 2건 refuted · `docs/guides/` · `docs/reference/`
- [x] `doc-audit-batch2-3-not-started` **[M/L · 신규 2026-09-06 · 닫힘 2026-09-07]** 문서 41개 중 20개가 미검증이었다 — 배치 2(언어별 README 9 + `language-support.md`) #421 · **배치 3 의 10문서도 감사·수정이 끝났다**. ⚠️ **재측정(2026-09-07)에서 이 항목이 낡은 채 열려 있는 것이 드러났다** — 하위 `doc-audit-batch3-fixes-outstanding` 은 이미 `[x]`(50/50, #433)인데 상위가 열려 있어 진입점이 **이미 끝난 일**로 다음 세션을 보내고 있었다. 남은 범위 **0**
- [x] `doc-audit-batch3-fixes-outstanding` **[M/M · 신규 2026-09-06 · 닫힘 2026-09-06 #433]** 배치 3 발견 **50건 전부 처리**. rules 10(#423) · 계수 3(#425) · 플레이북 11(#426, 재스캔 1 포함) · 지도 7 + 하네스 9(#429) · 계약 2(#431) · `process.md` 3(#432) · `rejected.md` 8(#433). 방법·전제·기각 판정은 `git show b273f67:docs/superpowers/plans/2026-09-06-doc-fact-oracles.md`
- [ ] `masking-type-enumeration-has-no-oracle` **[M/M · 신규 2026-09-06]** 언어 README 가 **마스킹하는 타입을 손으로 열거**하는데 소스와 대조하는 가드가 없다 — 넷이 동시에 하나씩 모자랐다 · `scripts/test/test-security-defaults.sh:322`
  - **선행 실측 완료(2026-09-06) — 부모는 `guard-detection-surface-hand-narrowed` 이고 그 주장은 아직 참이다.** `test-security-defaults.sh` 의 마스킹 축(1c)은 **`sd_mask_src` 에 `TokenSet` 경로 아홉을 손으로** 적는다. 그 파일 전체에서 **리터럴 11 : 파생 2**(파생은 `SD_DOCS`·`SD_SRC` 의 `git ls-files` 둘뿐이고, `DEPLOY_LANGS` 언급은 **0**).
  - **구멍의 실증**: `php/src/Token/AuthorizationRequest.php` 는 `TokenSet` 과 **같은 바닥 계약**(`__toString` 으로 PKCE 검증자를 `***`)인데 `sd_mask_src` 에 없다(`git grep` 그 경로 → 0건). go 는 `AuthorizationRequest.String()` 이 있는데 `sd_mask_hook` 은 `func (t TokenSet) String() string` 만 안다. **그 훅을 지워도 `_mask_seen` 은 9 라 초록이다.**
  - **변이 프로브로 판정했다 — 구멍은 둘이 아니라 전부다(2026-09-06, `scripts/probe.sh` 8회).** 형제 타입의 마스킹을 **원문 노출로 되돌리는** 변이를 여덟 언어에 넣었더니 **8/8 이 `SILENT`**(kotlin·go·php·rust·ruby·python·node·dotnet). 소스 경로가 이미 목록 안인 다섯(kotlin·go·dotnet·rust·ruby)도 못 잡는다 — 훅 앵커가 `TokenSet` 전용(go·rust)이거나 **generic**(`override fun toString()`·`def inspect`·`public override string ToString()`)이라 **`TokenSet` 의 훅 하나가 그 grep 을 만족시키기 때문**이다. 「파일이 목록에 있으니 덮인다」는 이 축에서 거짓이다.
  - java 는 변이 대상이 아니다 — `AuthorizationUrlRequest` 는 `record` 가 아닌 **plain final class** 라 `Object.toString()` 이 애초에 필드를 안 찍는다(훅이 없어서 위험한 게 아니라 **없어도 안전**). 그래서 java 의 겨눌 불변식은 훅의 존재가 아니라 **「`record` 로 바뀌지 않았다」**다(.NET 이 positional record 라 `ToString` 을 손으로 덮어야 했던 것의 뒷면).
  - ⚠️ **하한이 방향을 하나만 본다** — `assert_eq "9" "$_mask_seen"` 은 **목록이 줄면** 잡지만 **새 타입·새 파일이 늘어야 할 때는 침묵**한다. 다른 축의 `9`·`7`·`2`·`-ge 8` 도 같다.
  - ⚠️ **손으로 짠 프로브가 또 틀렸다(2026-09-06)** — 「가드가 그 파일을 아는가」를 파일 경로 문자열로 물었더니 **다른 축**(nonce 의 `auth.ts` · config 의 `config.go`)에 걸려 12개 중 11개를 「가드가 안다」로 보고했다. **축을 지정하지 않은 포함검사는 이 가드에서 무효다** — `sd_mask_src` 의 `case` 표만 물어야 한다.
- [ ] `rules-command-reference-existence-guard` **[M/M · 신규 2026-09-06 · 계획서에서 이관]** `.claude/rules/*.md` 의 펜스 블록이 부르는 대상(`npm run X` · `./gradlew X` · `"$PY" -m X` · `mvn -pl M` · `cargo test --test T` · `bundle exec X`)이 매니페스트에 **실재하는지** 보는 가드가 없다
  - **채택 근거**: 실행하지 않고도 참조 실재성은 툴체인 없이 판정된다. `-m build` 가 그 부류였고 #423 은 그것을 **사람이** 잡았다(그 셋은 이미 고쳐졌으므로 이 가드가 사는 것은 **예방**이다).
  - ⚠️ **보류 사유(독립 레그, 두 번 같은 판정)**: 아홉 rules 파일의 **펜스-명령 파서**는 저장소의 **유일한 required 체크 안**에서 돌고 그 룰셋은 `bypass_actors: []` 다 — **오탐 하나가 모든 PR 을 막는다.** 이번 세션에 상수 하나로 픽스처 75건을 깨 그 직전까지 간 실측이 있다.
  - **되살릴 조건**: required 체크 **밖**에서 먼저 돌려 오탐 0 을 실측하거나(nightly 등), 파서가 여섯 문법에서 수렴함을 알려진 정답으로 증명할 때. 탐지 표면은 `scripts/probe.sh` 로 잰다.
  - `[mask]` 축은 **`TokenSet` 하나만** 겨눈다(`sd_mask_src` 가 언어당 파일 하나). `AuthorizationRequest` 는 어느 축도 안 본다 — 그래서 go·dotnet·php·kotlin 넷의 README 가 PKCE 검증자를 마스킹하는 타입을 빠뜨린 채 CI 초록이었다(#421 에서 문서만 고쳤다).
  - ⚠️ **가드를 손으로 짜지 말 것 — 이번에 두 번 실패했다.** `***` 리터럴 grep 은 마스킹 헬퍼·상수를 쓰는 언어(java·python·node·dotnet·php)를 전부 놓치고, 타입 선언 grep 은 node 의 `MaskedAuthorizationRequest` 같은 별칭에 걸린다. **탐지 표면을 검증하지 못한 가드는 `guard-detection-surface-hand-narrowed` 를 하나 더 만드는 것**이므로, 먼저 9언어의 마스킹 훅 표를 실측으로 세우고 그 위에 얹는다.
  - ✅ **형제 타입(인가요청)은 #437 이 닫았다** — 축 1d 신설. 앵커는 훅 이름이 아니라 **마스킹 자체**(`***` 이거나 그 필드의 mask 호출)이고, java 는 훅이 **없어서 안전**하므로 「`record` 로 바뀌지 않았다」는 **음성 앵커**다. 같은 변이가 옛 스크립트에서 8/8 `SILENT` → 새 스크립트에서 9/9 `CAUGHT`. 세우자 rust 만 빨개졌고 그것이 진짜 결함이라 테스트를 썼다(`fn debug_masks_code_verifier`).
  - ⏸ **남은 것은 「파생 열거」다 — 보류(2026-09-06).** 표는 여전히 손으로 적혀 있고, **세 번째** 비밀 보유 값 타입이 생기면 침묵한다. 파생을 이 자리에 넣지 않은 이유는 `rules-command-reference-existence-guard` 와 같다 — 이 자가테스트는 required 체크 **`doc-facts`** 안에서 `paths:` 필터 없이 돌고 룰셋 `PRIMARY` 는 `bypass_actors: []` 라, **오탐 하나가 모든 PR 을 막는다**(실측: `git grep -n 'test-security-defaults' .github/` → `repo-hygiene.yml` 의 `doc-facts` 잡 한 곳).
  - **되살릴 조건**: 비밀 필드를 쥔 값 타입을 소스에서 파생하는 열거를 **required 밖**(nightly 등)에서 먼저 돌려 오탐 0 을 실측할 때. 후보 신호의 노이즈는 이미 쟀다 — 9언어 비테스트 소스에서 비밀 이름을 언급하는 파일은 **83개**(java 12·kotlin 9·python 12·node 8·go 7·dotnet 9·php 9·rust 9·ruby 8)이고 대부분 클라이언트·프로바이더라 **그대로는 쓸 수 없다**. 값 타입으로 좁히는 축이 먼저다.
- [ ] `php-upgrade-note-omits-isexpired-flip` **[L/S · 신규 2026-09-06]** PHP 의 「0.1.0 에서 올리기」는 옳으나, **`1.0.0` 이후의 소비자 가시 동작 변경이 어디에도 없다** · `php/README.md:97`
  - 실측: `TokenSet::isExpired()` 가 만료 시각 미상을 `false`(유효) → `true`(만료)로 뒤집은 커밋 `0fde597` 은 **`php-v1.0.0` 뒤**다. 그래서 :97 의 「Nothing else changed」는 거짓이 아니고(문장이 admin 식별자 넷으로 한정된다), 빠진 것은 **아직 없는 「1.0.0 에서 올리기」 절**이다. `json_encode` 마스킹 확대도 같은 창에 있다.
  - **다음 PHP 릴리스가 닫는다** — 그때 절을 새로 만들지 않으면 소비자는 API 표면이 같다는 이유로 이 변경을 못 본다(README 자신이 「게이트는 표면만 본다」고 적는 바로 그 경우다).
  - 방법은 배치 1과 동일: 고정 스냅샷(`git worktree` · **커밋된 상태로**) · 구조화 인용 `(path,line,exact_quote)` · 인용 게이트 선실행 · **렌즈 하나 + 실행강제**(「X 가 소유한다」·「N 개가 전부」는 조회를 실행해 출력을 붙일 것) · 서브에이전트에 `git config` 금지 명시.
  - 회수율 실측: 배치 1 은 10개 문서에서 **H 4건 포함 전건 지적**, 그중 최고가치는 **가드가 소비자에게 거짓을 집행하던 것**이었다(`jvm-17-floor-never-shipped`). 소비자 문서가 내부 규칙 파일보다 안전할 것이라는 사전 가정은 **틀렸다**.
- [x] `openid-scope-fallback-empty-only` **[M/S · 닫힘 2026-09-11]** `Scope.isEmpty()` 는 **원소 수**를 세므로 공백 원소 하나가 폴백을 건너뛰고 `IllegalArgumentException("The value must not be null or empty string")` 이 §4 경계를 넘었다. 도달 가능: `KeycloakConfig` 에 scope 값 검증이 **0건**이다. 생성 전에 공백 원소를 거르도록 Java·Kotlin 을 함께 고쳤다. 변이 3/3 `CAUGHT`(명명된 테스트 실패로 확인). ⚠️ **`scope = scope` 변이는 컴파일이 안 돼 `INVALID` 였다** — 「BUILD FAILED」를 「가드가 잡았다」로 읽으면 안 된다.
- [ ] `boundary-exception-conversion-incomplete` **[M/M]** 경계 변환의 catch 목록이 하위 라이브러리가 실제로 던지는 예외 집합보다 좁다 · `kotlin/src/main/kotlin/io/github/xzawed/keycloak/jwt.kt:91`
  - ⚠️ **범위 정정**: 원장은 「Kotlin·Ruby」 2개라 적었으나 **Java·Node·.NET 을 빠뜨렸다**. ⚠️ 그리고 **원장이 지목한 Ruby 줄은 clean 이다** — `ruby/lib/keycloak_sdk/jwt_validator.rb:36` 의 `rescue JWT::DecodeError` 는 이미 JWKError 를 잡는다(실측: 설치된 `jwt-3.2.0/lib/jwt/error.rb:53` 이 `class JWKError < DecodeError`). **고치기 전에 지목부터 다시 잡을 것** — 안 그러면 clean 한 자리를 건드린다.
- [x] `rust-public-client-empty-secret` **[M/S · 닫힘 2026-09-07 #441]** Rust AuthClient가 퍼블릭 클라이언트에도 빈 시크릿을 강제해 Basic 인증을 켰다 · `rust/src/auth.rs:67`
- [ ] `public-client-confidential-grants-not-refused` **[M/M · 신규 2026-09-07]** 공개 클라이언트가 기밀 그랜트를 부를 때 **아홉이 갈린다** — java·kotlin 만 거부하고 나머지 일곱은 그냥 보낸다 · `java/keycloak-sdk-auth/src/main/java/io/github/xzawed/keycloak/auth/AuthClient.java:279`
  - **실측(2026-09-07, 독립 레그 + 재현)**: java·kotlin 은 `clientAuth()` 가 `KeycloakConfigException` 을 던져 `clientCredentials`·`refresh`·`introspect`·`logout` 을 **거부**한다. rust·go·node·python·php·ruby·dotnet 은 요청을 보내고 서버 오류를 그대로 올린다.
  - ⚠️ **이것은 「rust 를 java 에 맞춘다」가 아니라 계약을 정하는 문제다** — 어느 쪽이든 **일곱 언어의 소비자에게 보이는 동작이 바뀐다**(성공하던 호출이 로컬 예외가 되거나, 그 반대). #441 은 「빈 시크릿을 보내지 않는다」까지만 하고 여기서 멈췄다.
  - **착수 조건**: 실 Keycloak 으로 공개 클라이언트가 그 넷을 불렀을 때 서버가 무엇을 돌려주는지 먼저 잰다. 서버가 이미 명확한 오류를 준다면 로컬 거부는 **진단을 좋게 할 뿐 필수가 아니고**, 그렇다면 아홉을 흔들 값이 아니다.
- [x] `go-tokenprovider-injection-missing` **[M/M · 닫힘 2026-09-09 #449]** Go의 TokenProvider 주입점이 문서에만 있고 실제로는 존재하지 않았다 · `go/tokenprovider.go:11`
- [x] `python-sync-admin-close-noop` **[M/S · 닫힘 2026-09-11]** sync `close()` 가 `return None` 이라 `requests.Session` 둘이 GC 까지 살아 있었다(aio 미러는 같은 자리에서 닫는다). ⚠️ **`test_close_is_noop` 이 그 결함을 「의도」로 고정**하고 있었으므로 테스트를 먼저 뒤집었다. 매니저 둘(`connection._s` · `connection.keycloak_openid.connection._s`)을 `finally` 계약으로 닫는다. ⚠️ **`async_s` 는 닫지 못한다** — sync 경로에서 `await` 가 불가하므로 과대광고하지 않는다. 변이 3/3 `CAUGHT`. ⚠️ 「중첩 매니저 부재」는 **도달 불가**라 테스트하지 않는다 — `harden_admin` 이 생성자에서 지연 프로퍼티를 실체화하며 fail-closed 한다(그 예제를 써 보니 `AdminClient(...)` 생성 자체가 거부됐다).
- [x] `python-sync-authorization-url-unencoded` **[M/S · 닫힘 2026-09-07 #442]** Python 동기 authorization_url이 퍼센트 인코딩 없이 URL을 조립했다 — async 미러는 `urlencode`를 쓴다 · `python/src/keycloak_sdk/auth.py:151`
- [x] `php-sensitiveparameter-methods-missing` **[M/S · 닫힘 2026-09-11 · 계수 정정]** PHP `#[\SensitiveParameter]` 가 생성자에만 붙어 있었다. ⚠️ **「여섯 메서드」가 아니라 아홉 파라미터였다** — 손 목록 대신 반사 가드를 세우자 `TokenSet::__construct($idToken)` 이 드러났다(생성자인데도 빠져 있었다). 가드 `tests/Unit/SensitiveParameterTest.php` 는 `php/src` 를 반사해 **문자열 타입 + 비밀 이름** 파라미터를 스스로 찾으므로 새 자리가 생겨도 목록을 고칠 필요가 없다. 변이 5/5 `CAUGHT`(공허 대조군 포함). 실측: 속성 없는 인자는 스택트레이스에 원문(`refresh('SUPER-SECRET-RE...')`), 있으면 `Object(SensitiveParameterValue)`.
- [x] `authorization-request-verifier-unmasked` **[M/M]** AuthorizationRequest.codeVerifier가 마스킹 없이 평문 출력된다 (Go·Node) — 같은 파일의 TokenSet은 마스킹한다 · `go/tokens.go:86`
- [ ] `coverage-exclusion-hides-untested-branches` **[M/M]** 네트워크 경계 커버리지 제외가 손으로 쓴 실패 분기와 미호출 공개 메서드를 숨긴다 (Kotlin·PHP) · `kotlin/src/main/kotlin/io/github/xzawed/keycloak/admin/Users.kt:47`
- [x] `redirect-uri-signature-parity` **[L/M · 닫힘 2026-09-12 · 중복이었다]** ⚠️ **이 항목은 `authz-redirect-uri-not-per-call` 과 같은 것을 다른 이름으로 적은 것이다** — 등록부에 한 부류가 두 행으로 있었고(이름·심각도·지목줄이 달라 서로를 못 알아봤다: 여기는 `rust/src/auth.rs:96` · 저기는 `:106`), 그래서 **한쪽만 보면 범위를 절반으로 읽는다**. 실제로 그렇게 됐다 — 「다음 대상」에 오른 쪽은 인가요청만 적었고 `exchangeCode` 비대칭은 이 행에만 있었다. 같은 PR 이 둘을 닫는다. ⚠️ **교훈**: 새 항목을 적기 전에 **부류로** 검색할 것(이름으로만 찾으면 중복이 남는다).
- [x] `python-config-comment-says-60` **[L/S]** python config 주석이 JWKS 재조회 기본값을 60초라고 적었다 — 두 줄 아래 실제 값은 30.0 · `python/src/keycloak_sdk/config.py:23`

### 재검증 · 가드/CI/문서 — 10

- [x] `selftest-enforcer-cannot-guard-itself` **[H/M]** 자가테스트 종료코드 규약의 집행자가 자기 자신과 '실패 삼킴'을 못 본다 · `scripts/test/test-selftest-hygiene.sh:19`
- [ ] `guard-detection-surface-hand-narrowed` **[H/M · 계수 정정 2026-09-07 · 손 목록 셋 닫힘 2026-09-23]** 가드의 탐지 표면이 손으로 좁혀져 있어 새 자리·새 문법이 조용히 통과한다 · `scripts/test/test-security-defaults.sh:311`
  - ✅ **대조 없는 손 목록 셋을 닫았다(#542).** `scripts/` 의 9 언어 손 목록을 전수로 재니 파생과 대조되는 것은 `SD_LANGS` 하나뿐이었다. 나머지 셋(`SD_TOKEN_TYPE_LANGS` · `_GS_ORDER` · 출처 게이트 루프)은 **아무와도 대조되지 않아 열 번째 언어가 그 축을 조용히 건너뛴다**. 각각 `SD_LANGS`·`DEPLOY_LANGS`·(consume 파생 ↔ `DEPLOY_LANGS`)와 대조하게 했다. ⚠️ 출처 게이트를 **파생 하나로만** 두지 않았다 — 그러면 스크립트를 지우는 것이 곧 축을 줄이는 길이 된다. 변이 3/3 CAUGHT.
  - ⚠️ **파생으로 바꾼 첫 축 — 「언어 집합」(2026-09-12).** 되살릴 조건이 요구한 오탐 실측을 **nightly 한 창이 아니라 `main` 이력 전수로** 답했다: 커밋 475 중 `SD_LANGS` 가 존재한 **281 건에서 불일치 0**(kotlin 이 아홉째로 들어온 구간 포함). 재현 `sh scripts/measure-lang-universe-fp.sh`(자가테스트 양성·음성·공허 8/8, repo-hygiene 배선). ⚠️ **대조군이 `9 == 9` 라 구조적으로 공허했다** — `assert_eq "9" "$_seen"` 의 `_seen` 은 `SD_LANGS` 자신을 센 수다. 실측 프로브: 최상위에 빌드파일을 가진 디렉터리를 하나 주입해도 `244 passed, 0 failed`(열 번째 언어는 보안 기본값 커버리지 0 으로 들어온다). ⚠️ **파생 원천 선택이 이 항목의 핵심이고, 내 첫 직관이 틀렸다** — 독립 레그가 `.claude/rules/*.md` 를 기각했다(이미 비언어 둘을 얻었다: `ci.md` 2026-08-06 · `security.md` 2026-08-17 · 삭제 이력 0 — 다음 횡단 규칙 파일 하나가 **모든 PR 을 막는다**). `harness/apps/*/` 는 플레이북 Stage 5 라 구조적으로 늦고(아홉 전부 SDK 디렉터리가 먼저 · kotlin 하루·java 사흘), `check-versions.mjs --list` 는 설계상 **7** 이라 오늘 main 을 빨갛게 한다. 채택은 **최상위 디렉터리 중 자기 루트에 빌드 매니페스트를 가진 것**(오늘 정확히 아홉). 잔여 오탐 하나(`website/package.json` 류 — 같은 커밋에서 목록을 늘리면 된다)와 잔여 거짓음성(매니페스트가 목록에 없는 Swift·Elixir)은 축 주석이 적는다.
  - ⚠️ **재도전 결과(2026-09-13) — 다섯 주장 모두 실재하나, 내가 기록한 증거는 위치 편향이었다.** 감사가 「구조적으로 볼 수 없다」고 한 모드를 표본으로 쳤다. `assert.sh` 는 fail-fast 가 아니라 **누적**하고 `probe.sh` 는 꼬리만 찍었으므로, 한 변이가 여러 축을 넘어뜨릴 때 **물리적으로 마지막** 단언이 범인으로 기록됐다. 실측: `SD_LANGS` 에서 java 를 빼면 **7건**이 함께 실패하는데(새 단언은 132행, 마스킹 축은 563행) 꼬리는 마스킹만 보여 **과소** 평가했고, `DEPLOY_LANGS` 에서 php 를 빼면 **10건**이 실패하는데 새 단언이 280행(마지막)이라 9행이 잡은 것을 새 단언의 공으로 **과대** 평가했다. **양방향 편향이다.** ⚠️ 그래서 중간에 「다른 단언이 잡았다」고 낸 내 결론도 **같은 깨진 계측기로 낸 과잉 정정**이었다. 고친 뒤 격리 변이로 다시 재니 **6/7 이 실패 단언 정확히 1건**이고 그것이 의도한 단언이었다(⑦ ruby 는 `assert.sh` 형식이 아니라 계수 없음 — probe 가 그것을 명시한다). **다섯 축은 전부 실재한다.**
  - ✅ **(A) 부류의 마지막 손 목록도 닫았다 — 소스 주석 축의 글롭 아홉(2026-09-12).** ⚠️ **독립 레그가 지목했고 실측이 맞다고 했다** — `SD_LANGS` 를 파생으로 바꿔도 `SD_SRC` 는 `git ls-files 'java/*.java' … 'kotlin/*.kt'` 로 **경로 글롭 아홉을 손으로** 적고 있어 열 번째 언어의 소스는 이 축에 못 들어왔다. **더 나쁜 것은 기존 언어도 조용히 빠졌다는 것**이다: `scripts/probe.sh` 로 kotlin 글롭 하나를 지우니 **SILENT**(셋을 지워야 비로소 걸렸다 — 총 히트 하한이 `-ge 8` 인데 아홉이 기여하므로 하나가 빠져도 8 이 남는다). 처방은 하한을 올리는 것이 **아니다**(정당한 삭제에 오탐이 난다) — 스캔 집합을 `SD_LANGS` 에서 파생하고 **언어별 기여(파일 ≥ 1)** 를 따로 단언한다. 총 히트 하한 8 은 **그대로 둔다**(다른 양을 센다: 스캔된 파일 vs 값을 말하는 주석 줄 — 레그의 지적). 변이 재측정: 확장자 필터에서 `kt` 제거 `CAUGHT` · 파생 루프가 kotlin 건너뜀 `CAUGHT`(수정 전 같은 계급은 `SILENT`). 파생은 `node/src`·`rust/src` 로만 좁혀 두었던 비대칭도 없앤다 — 확장으로 더해지는 넷(examples 둘 · vitest 설정 둘)은 축의 대상 패턴을 **한 번도 담지 않는다**(required 체크라 확인).
  - ✅ **(A) 부류 완결 — 뿌리였던 `DEPLOY_LANGS` 를 트리에 못 박았다(2026-09-12).** ⚠️ **직전 판에 내가 적은 「하네스 손목록 둘이 무보호」는 절반 틀렸다** — `test-deploy-facts.sh:264-269` 의 `check_langset` 이 **네 사본**(`harness/verify.sh` 의 `LANGS=` 와 Usage 주석 · `install-verify.sh` 의 `DEFAULT_LANGS` 와 Usage 주석)을 이미 `DEPLOY_LANGS` 와 대조하고 있었다. 진짜 구멍은 **뿌리**였다: `DEPLOY_LANGS` 자신이 트리와 대조되지 않아, 열 번째 언어가 들어와도 **다섯이 서로 정합한 채 조용하다**(실측: 추적된 `zig/` 를 심고 아무 목록도 안 고치니 `probe.sh` → `SILENT`). `scripts/lib/deploy-facts.sh` 에 `df_tree_langs` 를 두고 `test-deploy-facts.sh` 가 뿌리를 대조한다 — 사본 넷은 기존 `check_langset` 이 전파한다. ⚠️ **파생은 `git ls-files`(index 인지)여야 한다** — 처음 쓴 `git ls-tree HEAD` 는 커밋된 것만 봐서 스테이징된 새 언어를 놓쳤다(실측). 자매 가드와 같은 관용이어야 둘이 같은 순간에 말한다. ⚠️ **음성 대조군이 또 필요했다** — 파생을 정답 상수로 바꾸면 `SILENT` 였다(보안 가드에서 난 것과 **같은 구멍이 같은 방식으로** 났다). 변이 3/3 `CAUGHT`(10번째 언어 · 뿌리에서 언어 제거 · 파생 no-op).
  - ✅ **(B) 부류의 첫 자리를 닫았다 — 설정 타입의 마스킹(2026-09-12).** ⚠️ **비밀 보유 타입은 `TokenSet`·인가요청 둘이 아니었다 — 셋째가 `KeycloakConfig`(client_secret)이고 아홉 언어 전부다.** 독립 레그의 공개타입 전수가 지목했고 실측이 확인했다: config 마스킹을 원문 노출로 되돌리는 변이가 **4/4 `SILENT`**(go·kotlin·python·ruby) — 1d 가 닫은 것과 **같은 모양의 구멍**이다(1c/1d 앵커가 각자의 타입 전용이라 설정 타입은 어느 축에도 없었다). 소비자가 기동 시 설정을 로깅하는 것이 흔해 노출 경로가 넓다. ⚠️ **처방대로 「그 파일에 축을 더하지」 않았다** — 별도 가드 `scripts/test/test-config-masking.sh`(repo-hygiene 배선, 30 단언). 언어 집합은 `df_tree_langs` 로 **파생**해 손 목록을 또 만들지 않았다(열 번째 언어는 표가 비어 실패한다). ⚠️ **java 는 계약이 다르다** — 마스킹 훅이 없고 안전 근거가 「필드를 안 찍는 기본 `toString`」이라, 겨눈 것은 훅이 아니라 **「record 로 바뀌지 않았다」**(1d 가 java `AuthorizationUrlRequest` 에 쓰는 것과 같은 모양). 변이 **9/9 `CAUGHT`**(수정 전 같은 변이 4/4 `SILENT`) + 음성 대조군(앵커를 지운 사본에서 안 잡히는지).
  - ⏸ **(B) 에 남은 것 — 레그가 함께 찾은 자리들.** ⚠️ **`ClientCredentialsTokenProvider` 의 기본 덤프가 캐시된 액세스 토큰을 찍는다**(ruby 기본 `inspect` 가 `@cached` 를 원문 String 으로 · php `var_dump` 가 private `$cached->accessToken` 과 중첩 `$config->clientSecret` 을) — 나머지 일곱은 기본 경로로 안 찍는다. 그리고 java 의 `Pkce`(verifier 보유) · `KeycloakConfig.Builder`(char[] secret) · `InMemoryTokenStore` 가 전부 「기본 toString 이 필드를 안 찍는다」에만 기대고 있어 record 화가 조용히 통과한다. ⚠️ **그리고 덮은 타입에도 바닥 밖 경로가 남는다** — python `asdict` · php `var_dump` · go `%#v`/`json.Marshal` · .NET Serilog `{@}`. 이것들은 「축이 정한 바닥(기본 문자열/디버그 표현)」 **밖**이므로 바닥을 넓힐지부터 사람이 판정해야 한다.
  - ✅ **(B) 잔여 java 타입들은 오경보였다 — 실측이 그렇게 갈랐다(2026-09-13).** 등록부가 「java `Pkce`·`KeycloakConfig.Builder`·`InMemoryTokenStore` 가 기본 toString 에만 기대 record 화가 조용히 통과한다」고 적었는데, **record 화만으로는 새지 않는다**. JDK 21 실행 측정: `record R(char[] s)` 는 `Arrays.toString` 이 아니라 **배열 identity**(`[C@7c41…`)를 찍고, `CodeVerifier` 와 상위 `Secret` 은 **`toString` 을 선언하지 않으며**(바이트코드 확인), `TokenSet` 을 담은 타입은 중첩 마스킹이 탄다. kotlin provider 의 `cached` 는 **본문 프로퍼티**라 `data class` toString 에 애초에 안 들어간다. **원문을 찍는 것은 비밀이 `String` 인 경우뿐이고, 그 타입(`AuthorizationUrlRequest`)은 이미 1d 가 가드한다.** ⚠️ **가드를 하나 더 세울 뻔했고 그것은 required 체크의 오탐이 됐을 것이다** — 「record 가 아니다」는 대리지표라, 위 넷에 걸면 **안 새는 변경을 빨갛게** 내고 「record + 마스킹 toString」이라는 **정당한 해법까지 막는다**(독립 레그 지목, 내가 실행으로 확인).
  - ⚠️ **그 과정에서 내 가드의 거짓 전제가 드러났다** — `test-config-masking.sh` 의 java 분기가 「record 가 되면 컴파일러 toString 이 clientSecret 을 찍는다」고 적었는데 **거짓이다**(`char[]` 이라 identity 다). 단언은 남기되(진짜 위험은 **record + 비밀을 String 으로** 바꾸는 **조합**이고 모양 변화가 그 보이는 절반이다) 근거를 정정했다. 1d 의 같은 문장은 `AuthorizationUrlRequest.codeVerifier` 가 `String` 이라 **참이다**.
  - ✅ **대신 행위 검열을 언어 로컬에 세웠다** — `KeycloakConfigTest#toString_doesNotLeakClientSecret` · `#builderToString_doesNotLeakClientSecret`(java 16 → 18). 모양이 아니라 **비밀이 찍히는가**를 본다. 프로브 확인: **모양은 그대로 둔 채 손으로 쓴 누출 `toString`** 을 심으면 `CAUGHT`(모양 단언은 그것을 못 잡는다). `Builder` 는 가변이라 record 가 될 수 없어 모양 단언 자체가 무의미하고, 행위 검열만이 유일한 장치다.
  - ⚠️ **그 축의 첫 판은 `SILENT` 였다 — 파생이 no-op 여도 통과했다.** `sd_tree_langs` 를 **정답 상수**로 바꾸면 초록이다(`scripts/probe.sh` 실측). 「지금 일치한다」만 보는 단언의 고질이고, 이 파일이 `sd_default`·`sd_skew` 에 대해 이미 적어 둔 부류다. 언어 집합이 **다른** 임시 저장소에서 파생이 다른 답을 내는지 보는 음성 대조군으로 닫았다(재측정 `CAUGHT`). ⚠️ **그 SILENT 에 닿기까지 변이 둘이 `CAUGHT` 로 위장했다** — perl 이 치환문의 `$SD_LANGS` 를 **자기 변수로 보간**해 빈 문자열을 만들었고(공허 가드가 잡아 `CAUGHT` 로 보였다), `q{}` 는 **perl 문법을 셸 파일에** 그대로 써 넣었다. 셋째 변이에서야 참값이 나왔다. **변이는 착지 여부가 아니라 「무엇이 됐는지」를 봐야 한다**(함정 (i)).
  - ⏸ **남은 것은 (B) 부류다 — 「기존 언어에 새 자리가 생겼다」.** 이번에 닫은 것은 (A)「새 언어가 손 목록에 안 들어왔다」뿐이다. (B) 가 83파일 노이즈를 가진 그 부류이고, 되살릴 조건도 그쪽을 겨눈 것이다. ⚠️ **독립 레그가 (B) 의 자리를 하나 더 찾았다**: `SD_SRC`(`test-security-defaults.sh` 의 소스 주석 축)는 `git ls-files` 지만 **아홉 개 글롭이 손으로 박혀 있다** — 열 번째 언어의 주석은 `SD_LANGS` 를 고쳐도 그 축에 못 들어온다. 같은 모양이 `harness/verify.sh:5` · `harness/install/install-verify.sh:37` 에도 있다.
  - ✅ **(B) 부류의 첫 자리를 닫았다 — 2차 정의 자리를 파생으로(2026-09-16).** 축 3 은 앵커 **넷**(go·php·ruby·ruby-skew)만 봤고, 1절은 언어당 한 파일 한 줄을 `sed | head -1` 로 읽어 **둘째 줄을 구조적으로 못 본다**. 실측: `node/src/jwt.ts` 에 `probeJwksMinRefetchSeconds = 60` 을 심으면 **SILENT**. 처방은 「정의 자리는 하나」가 아니라 **「어디에 적히든 값은 같다」**다 — SDK 소스 전체에서 두 파라미터에 숫자 리터럴을 대입하는 자리를 찾아 1절이 합의시킨 값과 대조한다(정당한 2차 자리를 막지 않는다). 합의값은 숫자로 안 적는다 — 그러면 **이 축 자신이 2차 정의 자리**가 된다. **오탐 실측**: 최근 **300 커밋**(2026-08-14~09-16 = 30 합의 이후 전 구간) **0 건**. **계측기 대조군**: 전 이력 1102 커밋으로 넓히면 **664 커밋이 60 으로 걸린다**(합의 이전 시기) — 침묵이 아니라 오늘 갈림이 없는 것이다. 오늘 히트 **20**(9언어 전부 기여), 공허 하한은 **창 최저값 20**(오늘 값이 아니다 — #443 판정). 변이 4/4 `CAUGHT` + OFF 짝(main 판 가드) `SILENT`.
  - ⚠️ **같은 PR 이 손 표 하나를 지웠다 — 중복이 됐기 때문이다.** `sd_skew_secondary`(dotnet·python)는 파생이 같은 두 자리를 값으로 잡는다(손 표를 죽이고 python 을 60 으로 → `CAUGHT`). 반대로 **손 표만 죽이면 `SILENT`** 였고 그것이 중복 게이트의 정의다. 그 표의 지식(**dotnet 은 1절이 읽는 `JwtValidator.cs` 가 아니라 `KeycloakConfig.cs` 가 소비자 값**)은 주석으로 남겼다.
  - ⏸ **(B) 의 잔여** — 닫은 것은 **1절·3절이 소유한 두 파라미터**(JWKS 재조회 · clock skew)뿐이다. 나머지 축(크기상한·nonce·백오프·마스킹 둘·토큰타입)은 **여전히 손 표**라 같은 부류가 그대로 있다. 다음 자리는 그 축들에 같은 「값 동형」 파생을 적용할 수 있는지다.
  - ⚠️ **또 늘었다 — 축 9 중 손 표 7 → 축 11 중 손 표 9 → 축 12 중 파생 3 · 혼합 1 · 손 8**(재측정 2026-09-16 · 직전 판 2026-09-12 는 독립 레그와 일치했다). 그 사이 추가된 축 둘(JWKS 크기상한 · 토큰응답 타입검증)이 **둘 다 손 표**다. 파생은 여전히 `git ls-files` 둘뿐. 배너 전수: `grep -cE '^# [0-9]+[a-z0-9]*\) ' scripts/test/test-security-defaults.sh` → **11**. ⚠️ `'^# [0-9]'` 로 세면 **15** 가 나온다 — 숫자로 시작하는 산문 넉 줄(「30초로…」 등)이 섞인다. ⚠️ 그리고 **축 이름이 이미 충돌한다**(`1b` 셋 · `1c` 둘) — 「축 N」으로 지목하지 말고 줄번호로 지목할 것. ⚠️ **처방은 그대로다**(이 파일에 축을 더하지 않는다) — 이번 PR 도 새 불변식을 여기가 아니라 `check-versions.mjs` 로 냈다.
  - **축 7 중 손 표 5 → 축 9 중 손 표 7 로 늘었다**(실측 2026-09-07, 독립 레그 둘). 그 사이 추가된 축 둘 — 1b2 콜드캐시 백오프 · 1d 형제 마스킹(#437) — 이 **둘 다 손 표**다. 파생은 여전히 `git ls-files` 둘(문서 축·소스 주석 축)뿐이다.
  - ⚠️ **그런데 지금 파생으로 바꾸는 것이 옳은 수가 아니다.** 이 파일은 required 체크 `doc-facts` 안에서 `paths:` 필터 없이 돌고 룰셋은 `bypass_actors: []` 다 — 오탐 하나가 모든 PR 을 막고 소유자도 못 푼다. **되살릴 조건**: required **밖**(nightly 등)에서 먼저 돌려 오탐 0 을 실측할 것. 노이즈는 이미 쟀다 — 9언어 비테스트 소스에서 비밀 이름을 언급하는 파일이 **83개**라 그 신호를 그대로 쓸 수 없다.
  - ⚠️ **당장의 처방은 「이 파일에 축을 더 늘리지 않는 것」이다** — 두 번 늘어난 것이 그 증거다. 새 불변식은 별도 가드로 내고(예: `test-osv-audit-gate.sh`), 언어별 값은 언어 로컬 테스트로 민다.
  - ⚠️ **지목이 마스킹 축 하나를 가리키지만 체계적이다** — 가드의 **7축 중 5축**(1 코드/skew · 1b nonce · 1c 마스킹 · 3 2차자리 · 4 소유자)이 언어별 파일·앵커를 손으로 열거한다. 새 언어·새 자리가 생기면 `_seen == 9` 류의 대조군이 함께 늘지 않는 한 조용히 통과한다.
  - 참고: 2026-09-04 에 추가한 2b(소스 주석) 축은 `git ls-files` 로 전체를 훑어 이 부류를 피했다 — 같은 형태가 나머지 축의 목표다.

- [x] `jwks-response-size-unbounded-non-jvm` **[M/M · php·ruby 닫힘 2026-09-11]** JWKS 응답 크기 상한이 Go·Java·Kotlin 에만 있었다(rust 는 #440). php·ruby 에 51200 상한을 넣고, php 는 **상태 검사보다 먼저 본문을 슬러프하던 순서**도 함께 뒤집었다. 가드는 `test-security-defaults.sh` 의 「JWKS 크기상한」 축 — 변이 6/6 `CAUGHT`. ⚠️ **미측정으로 남겼던 셋을 그 다음에 쟀고, 둘이 실제 구멍이었다** — node 는 닫혔고(아래) python 은 열려 있다: `jwks-response-size-unbounded-python` 참조. **「측정되지 않았다」를 「아마 괜찮다」로 읽지 말 것 — 재 보니 2/2 가 구멍이었다.**
- [x] `node-jwks-response-size-unbounded` **[M/S · 닫힘 2026-09-11]** jose 에는 상한이 **없다**(6.2.12 실측 · `dist/webapi/jwks/remote.js:10-26`: `GET` → status 200 → `response.json()` 이 전부. `Content-Length` 검사도 최대 바이트 옵션도 없고 유일한 중단은 `AbortSignal.timeout` 5초). `createRemoteJWKSet` 의 `[customFetch]` 이음매로 우리가 상한을 건다 — **JWKS 전용**이라 토큰·introspect 경로는 그대로다. 변이 4/4 `CAUGHT`. ⚠️ **첫 판 테스트가 거짓 초록이었다** — 거대 본문을 쓰레기 바이트로 만들었더니 상한이 없어도 JSON 파싱이 실패해 「거부됐다」가 통과했다. 본문을 **유효한 JWKS + 패딩**으로 바꿔야 상한 없이는 검증이 성공하고, 그때 비로소 거부가 증거가 된다.
- [x] `jwks-response-size-unbounded-python` **[M/M · 닫힘 2026-09-12 · 부류 완결]** ⚠️ **9언어 JWKS 크기상한 부류의 마지막 이음매**였다(축 6 → **7**). 구현 `_internal/jwks_fetch.py`(sync·aio 공용) — 상류를 우회해 JWKS **요청 하나만** 스트리밍 GET 한다. ⚠️ **여기 적혀 있던 aio 설계가 틀렸다**(아래 (iii) 정정): `harden_openid` 는 `_s`(requests)만 겨누고 aio 는 `async_s`(httpx)로 나가므로 aio 계약은 「하드닝된 세션」이 아니라 **`follow_redirects=False` 명시**다. ⚠️ **`_wrap` 은 상류 `KeycloakError` 하나만 잡는다** — 직접 HTTP 를 부르면 `requests`/`httpx`/`json` 예외가 §4 를 위반하며 새므로 모듈이 스스로 전부 번역한다. ⚠️ **계약 변화**: JWKS 레인의 3xx·비200 이 `KeycloakAuthError` → `KeycloakTransportError`(**차단 자체는 불변** — `trap.hits == []` 와 「공격자 JWKS 미캐시」 유지). 변이 **9/9 `CAUGHT`** + OFF 짝 2/2. ⚠️ **프로브와 독립 레그가 구멍을 **둘** 찾았다**(둘 다 같은 PR 에서 닫음) — (1) aio JWKS 레인에 리다이렉트 거부 단언이 **없었다**, (2) **압축폭탄이 aio 에서 실제로 통했다**(20MB 폭탄에서 피크 **84MB** 실측). ⚠️ (2)의 교훈이 크다: `Accept-Encoding: identity` 만으로는 **무시하는 서버**를 못 막고, **청크 크기를 넘겨도 소용없다**(httpx 는 디코더가 청킹보다 앞이라 통째로 팽창시킨 뒤 우리 루프가 돈다). 답은 `aiter_raw` 로 **해제 전** 바이트를 세고 `zlib` 로 상한 안에서 직접 푸는 것이다. **sync·go·node 는 원래 안전했다**(urllib3 `max_length` · `io.LimitReader` · 스트리밍 리더) — **aio 만 갈라져 있었다.** ⚠️ **변이 하나가 `CAUGHT` 로 위장했다** — `sed` 가 `if` 한 줄만 지워 `IndentationError` 를 냈고, 그 실패는 함정 (i)대로 **INVALID** 다. 컴파일 검사를 프로브에 넣고 다시 쟀다. 아래는 착수 전 서술이다 — python 은 JWKS 본문에 상한이 없다 — `certs()` → `raw_get` → `self._s.get(...)`(`connection.py:336`)가 `stream=True` 없이 본문을 올린 뒤 `.json()` 한다. **설계는 실측으로 정해졌다**: (i) `certs()` 를 스트리밍으로 못 만든다 — `raw_get` 이 `**kwargs` 를 `params=` 로 보내므로 `stream=True` 가 **쿼리 파라미터**가 된다(`connection.py:338`). (ii) 세션 전체에 거는 것은 안 된다 — 그 `_s` 는 token·introspect·logout 이 함께 쓰고(`redirects.py:95`) 역할 많은 토큰은 정당하게 크다. (iii) ⚠️ **이 설계는 sync 에만 성립한다 — aio 는 세션이 다르다**(정정 2026-09-12, 독립 레그 지목 + 실측). `harden_openid` 가 겨누는 것은 `connection._s`(requests) 하나이고(`_internal/redirects.py:45` 의 `_SESSION_ATTR = "_s"`), **aio 의 JWKS 는 `async_s`(httpx)로 나간다**(상류 `connection.py:135,460`). aio 쪽 하드닝은 우리가 건 훅이 아니라 **httpx 기본값 `follow_redirects=False`** 이고, 저장소는 그것을 속성이 아니라 **행동으로** 고정해 뒀다(`python/tests/unit/aio/test_redirects_async.py`, 대조군 포함). 따라서 aio 구현은 `async_s` 로 스트리밍 GET 하되 **`follow_redirects` 를 켜지 않는 것이 계약**이고, 그 한 줄이 sync 와 다른 이음매다. sync 는 원안대로 `auth.py:286` 의 `_load_jwks` 에서 **기존 하드닝된 세션으로 `_endpoints.jwks` 를 직접 스트리밍 GET** 한다 — 세션을 그대로 쓰므로 `resolve_redirects` SSRF 훅과 retry 어댑터가 유지된다. ⚠️ **비용은 「70곳」이 아니다 — 그 수는 `certs` 라는 *단어가 나오는 줄* 을 센 것이었다**(정정 2026-09-12, 독립 레그 둘이 따로 셈). 실측: 목 설정 **30**(sync 18 `openid.certs.return_value`/`side_effect` + aio 12 `openid.a_certs = AsyncMock`) · 단언 **20**(`call_count`/`await_count`/`assert_*`) · **재배선이 필요한 고유 테스트 28**. ⚠️ sync 만 보고 정규식을 쓰면 aio 가 **0 으로 나온다**(aio 는 `return_value` 가 아니라 `AsyncMock` 대입형이다) — 세는 방법이 언어별로 갈리는 것이 이 계수 오류의 원인이다. ⚠️ 그리고 `raw_get` 의 `except Exception` 이 상한 예외를 「Can't connect to server」로 삼키므로(`connection.py:344`) **세션 래핑 방식은 메시지가 뭉개진다**. 상한을 실제로 태우는 테스트는 `conftest.py:55-78` 의 실 HTTP 서버 하네스로 쓴다(목 경계 아래라 기존 목으로는 못 잰다).
- [x] `jwks-response-size-unbounded-dotnet` **[M/M · 닫힘 2026-09-11]** `IDocumentRetriever` 를 직접 구현해(`BoundedDocumentRetriever`) discovery·JWKS 만 51200B 로 묶었다. ⚠️ **`MaxResponseContentBufferSize` 를 쓰지 않은 이유**: 그 `HttpClient` 은 `AuthClient` 와 **공유**라(`KeycloakClient.cs:10`) 토큰·introspect 응답까지 함께 묶인다 — 역할이 많은 액세스 토큰은 정당하게 크다. 라이브러리 내부 상한 여부는 **여전히 미측정**이나(컴파일된 패키지) 우리가 거는 상한은 그것과 무관하다. 대체한 `HttpDocumentRetriever` 에서 이 SDK 가 쓰던 유일한 옵션 `RequireHttps` 는 테스트로 고정했다. 변이 4/4 `CAUGHT`(상한 상향 · 상태검사를 상한보다 앞으로 · RequireHttps 제거 · 교차언어 축).
- [x] `kotlin-osv-audit-fail-open` **[H/S · 닫힘 2026-09-07 #438]** Kotlin OSV 감사 두 잡이 해석 실패 좌표를 통과시켜 아무것도 감사하지 않고 초록이 됐다 · `.github/workflows/kotlin-ci.yml:72-83` · `security-audit.yml:80-89`
- [ ] `docs-commands-that-do-not-work` **[M/S · 범위 축소 2026-09-07 · php 한 건 닫힘 2026-09-11]** 소비자 문서가 적은 명령·환경변수가 실제로는 동작하지 않는다 · `docs/guides/development-setup.md:77`. ⚠️ **php 한 건은 실사용 중 잡혔다** — `.claude/rules/php.md` 가 「디렉터리 이름에 버전 접미사가 붙는다(`php-8.3`)」고 적고 `KCSDK_PHP` 기본값도 그 경로였는데, 이 PC 의 실제 디렉터리는 `~/tools/php` 다(ruby.md 가 이미 같은 정정을 안고 있다 — **부류다**). 남은 것을 찾는 방법은 산문 검토가 아니라 **그 명령을 돌려 보는 것**이고, 그 일반형은 `rules-command-reference-existence-guard` 가 소유한다.
  - **인용한 자리는 저장소 루트에서 동작한다**(실측 2026-09-07: `KCSDK_PY` 기본값 `python/.venv/Scripts/python.exe` 는 루트 기준 실재). 같은 표의 썩은 JDK 폴백과 `.claude/rules` 의 죽는 명령 셋은 **#423 이 닫았다**. **남은 것은 부류가 비었음이 증명되지 않은 것**이다 — `docs/guides/` 와 아홉 README 의 명령을 전수로 돌린 적이 없다. 형제 `docs-kcsdk-env-ssot` 와 함께 본다.
- [x] `deploy-md-omits-release-request` **[M/S · 재판정으로 닫힘 2026-09-11]** **이미 참이 아니었다** — #416(`aab1d67`)이 닫았는데 체크박스만 남아 있었다. §4 는 `DEPLOY.md:415–451` 이고 그 안 `:433`·`:440` 이 `.github/release-request.json` 을 트리거로 명시하며 「머지가 트리거가 아니다」까지 경고한다. 재현: `git log -S'Merging is not the trigger' -- DEPLOY.md`.
- [ ] `stale-prose-contradicts-source` **[M/S · 절반 닫힘 2026-09-07]** 산문 주석이 자기가 서술하는 값·전제·코드보다 낡았고 대조가 없다 · `python/src/keycloak_sdk/config.py:23`
  - **인용한 주석 셋은 #398 이 고쳤다** — 그 자리는 지금 「기본 30」이라 적고 축 2b 가 소스 주석의 JWKS 기본값을 대조한다(실측 2026-09-07). **남은 것은 부류다**: JWKS 기본값 **밖의** 산문에는 오라클이 없다. 형제 항목 `stale-comments-nobody-collates` 와 함께 본다.
- [ ] `compat-table-library-cells-drift` **[M/M]** compatibility.md Node 행의 라이브러리 셀 세 개가 태그 시점 락파일과 다르다 · `docs/reference/compatibility.md:22`
- [ ] `tokenprovider-cache-contract-untested` **[M/M]** TokenProvider 캐시 계약(만료 재조회·single-flight)이 Rust·Ruby 에서 단언되지 않는다 · `rust/src/token_provider.rs:113`
- [ ] `facade-wiring-close-contract-unasserted` **[M/S]** 파사드의 §4 계약(provider 배선·close)이 무단언 테스트 뒤에 있고 커버리지 게이트에서도 빠져 있다 · `rust/src/client.rs:65`
- [x] `python-aio-security-test-asymmetry` **[M/M · 닫힘 2026-09-12 · 범위 6 → 8]** 착수 전 재판정이 **또 넓혔다** — `security.md` 가 명시한 백오프 두 성질(**성공이 카운터를 되돌린다**·**클레임 실패는 재조회가 아니다**)이 DoS 속성인데 1차 재판정에서 비보안으로 분류돼 있었다. ⚠️ **aio 프로덕션 코드는 여덟을 이미 갖고 있었다** — 이 PR 은 행동을 바꾸지 않고 **고정**한다(고정되지 않은 성질은 다음 리팩터에서 조용히 사라진다). 변이 6/6 `CAUGHT`(alg 핀에 ES256 몰래 추가 · rate-limit 게이트 삭제 · 백오프 성공리셋 제거 · 클레임실패 억제 제거 · verifier 마스킹 제거 · urlencode 무인코딩화). ⚠️ **남은 비보안 비대칭 넷은 열어 둔다**(`constructs_real_openid_when_not_injected`·`injected_openid_is_used_verbatim`·`wrap_passes_through_successful_result`·`wrap_translates_error_with_response_code_but_no_json_body`) — 보안 축이 아니고, 그 넷까지 미러링하는 것은 **동형성 항목**이지 이 항목이 아니다. 옛 서술:

## C. 품질 부채 — 74건 (열림 54)

low 강등분 + 아무 배치도 담당하지 않았던 harness 사각지대 14건.

### 9언어 소스 — 21

- [x] `authz-redirect-uri-not-per-call` **[M/M · 닫힘 2026-09-12 · 사람 판정 (a)]** php·rust 만 인가요청의 `redirect_uri` 를 호출당 받지 못했다(나머지 일곱은 인자로 받는다). ⚠️ **범위가 두 배였다 — 비대칭은 `exchangeCode` 에도 있었다.** OAuth 는 토큰 교환의 `redirect_uri` 가 인가 때 쓴 값과 **같기를** 요구하므로(RFC 6749 §4.1.3) 인가 URL 만 고치면 교환이 config 값을 보내 Keycloak 이 거부한다. 등록부는 인가요청만 적었다. **§4 사람 판정(2026-09-12): API 를 맞춘다.** 근거 — §4 가 「개념·계층은 동형이고 **표기만** 갈린다」고 하는데 이것은 표기가 아니라 **능력**의 차이다(일곱은 클라이언트 하나가 콜백 N 개를 섬기고 둘은 1 개만). ⚠️ §4 에 선례가 있으나(admin 토큰 소유 비대칭) 그것은 **하위 라이브러리가 강제한** 것이고 이건 우리 파사드가 인자를 안 받기로 한 것뿐이라 고칠 수 있다. 구현은 **둘 다 가산적**이다 — php `?string $redirectUri = null`(두 메서드 후행 인자) · rust `create_authorization_request_with_redirect` / `exchange_code_with_redirect`(기본 인자가 없으므로 새 메서드). ⚠️ rust 는 §4 대로 하위 타입을 숨긴다 — `&str` 을 받고 `RedirectUrl` 파싱 실패는 `KeycloakError::Config` 로 번역한다(경계 테스트로 고정). 하네스 앱 둘도 함께 고쳤다 — rust 앱은 주석이 「**쿼리파라미터는 받되 사용하지 않는다**」라고 적고 있었다(H1 이 드러낸 그 공허). php 138 tests/phpstan 0/cs-fixer 0 · rust 82 tests/clippy/fmt 통과.

- [x] `jwks-refetch-budget-overclaimed` **[M/M · 닫힘 2026-09-07]** JWKS 재조회 예산 문서가 실제보다 강하게 약속했다 — cold 로드가 예산을 안 쓴다 · `rust/src/jwks.rs:34-49`
- [x] `jwks-response-not-validated` **[M/M · 닫힘 2026-09-07 #440]** JWKS 응답을 검증 없이 신뢰했다 — JVM 둘의 본문 크기 무제한은 #400 이 `DEFAULT_HTTP_SIZE_LIMIT` 를 되살려 닫았고, **Rust 의 상태코드 미확인은 #440 이 닫았다**(그 전 실측: `error_for_status`·`.status()` **0건**) · `rust/src/jwks.rs:34`
- [ ] `authcode-flow-verification-defeated` **[M/L]** 인가 코드 흐름의 검증이 무력하거나 오적용된다 — azp 미검증·iss 자기주입·공유 검증기 · `java/keycloak-sdk-auth/src/main/java/io/github/xzawed/keycloak/auth/AuthClient.java:135-149`
- [x] `lenient-parsing-yields-false-success` **[M/M · 닫힘 2026-09-12 · 부류 다섯]** ⚠️ **rust 하나가 아니라 다섯이었다** — 아홉 전수 측정 뒤 rust·python·ruby·php·**dotnet** 을 함께 고쳤다(아래 표가 근거). 불변식: **`access_token` 이 비어 있지 않은 JSON 문자열이 아니면 TokenSet 을 만들지 않는다.** ⚠️ **dotnet 은 문자열 검사로 못 잡는다** — Duende 가 이미 강제변환한 뒤라 원본 JSON 의 `ValueKind` 를 봐야 한다. ⚠️ **`expires_in` 의 문자열 허용은 건드리지 않았다**(php·ruby 가 테스트로 고정한 의도된 관용). ⚠️ **팩토리만 지키면 우회된다 — 재스캔이 이음매를 셋 더 찾았다**(독립 레그가 첫 둘을 지목): **ruby·php 의 AuthClient 경로는 팩토리를 지나지 않고 생성자를 직접 부른다**(`auth_client.rb` 의 `to_token_set` · `AuthClient.php` 의 `toTokenSet`) → 검증을 **생성자로** 내렸다. 그리고 **rust `auth.rs:to_token_set` 은 타입은 안전하나 빈 문자열을 통과**시켜 `exchange_code`/`refresh` 가 쓸 수 없는 토큰으로 성공했다 → `Result` 로 바꿨다. python·dotnet 은 생성 자리가 하나뿐임을 재스캔으로 확인했다. 가드: `test-security-defaults.sh` 축 1c(9언어·공허 하한 9). 변이 7/7 `CAUGHT`. ⚠️ **축 앵커가 두 종류인 것은 의도다** — 고친 다섯은 행동 테스트, 이미 옳던 넷은 집행 기제(소스 철자를 겨누면 동작이 같은 리팩터에도 빨개진다: 실측 rust `Value::as_str` → `|v| v.as_str()`).
- [ ] `nimbus-type-on-public-surface` **[L/M]** JWSAlgorithm이 두 JVM SDK의 공개 팩토리 시그니처에 올라 있다 — §4 은닉 위반 · `java/keycloak-sdk-auth/src/main/java/io/github/xzawed/keycloak/auth/JwtValidator.java:27-28`
- [ ] `configured-timeout-not-propagated` **[L/M]** 설정한 타임아웃·취소 토큰이 JWKS/검증 경로에 도달하지 않는다 · `node/src/jwt.ts:47-51`
- [ ] `close-path-leaks` **[L/M]** 정리 경로가 자원을 놓친다 — 실패 시 중단·생성 중 누락·미소유 executor · `go/admin.go:66-68`
- [ ] `node-nonsdk-error-escapes` **[L/S]** Node의 두 공개 경로가 SDK 예외 계층 밖의 오류를 던진다 · `node/src/admin/call.ts:13-26`
- [ ] `rust-admin-error-cause-flattened` **[L/M]** Rust에서 admin 토큰 실패의 원인이 가짜 401로 뭉개져 사라진다 · `rust/src/admin.rs:29-40`
- [ ] `error-message-surface-unspecified` **[L/M]** 오류 메시지 표면에 규약이 없다 — 서버 본문 원문 삽입과 한글 메시지 · `dotnet/src/Xzawed.Keycloak.Sdk/Admin/AdminClient.cs:95-101`
- [ ] `config-validation-gaps` **[L/M]** 설정 진입점이 값을 검증하지 않고 잘못된 기본값으로 대체한다 · `node/src/config.ts:74-87`
- [ ] `token-provider-cache-invariants` **[L/S]** 토큰 프로바이더 캐시가 설정을 무시하거나 중복 발급한다 · `go/tokenprovider.go:36-60`
- [ ] `coverage-omit-hides-security-paths` **[L/L]** "네트워크 경계"라는 이름의 파일 단위 커버리지 제외가 보안·오류분류 로직까지 무측정으로 만든다 · `dotnet/src/Xzawed.Keycloak.Sdk/AuthClient.cs:110`
- [ ] `cross-language-surface-divergence` **[L/L]** 같은 개념의 공개 표면이 언어마다 갈린다 — 필드·타입명·메서드명·정규화 위치 · `java/keycloak-sdk-auth/src/main/java/io/github/xzawed/keycloak/auth/IntrospectionResult.java:5-9`
- [ ] `php-oauth2-delegation-drift` **[L/S]** PHP가 league 프로바이더에 위임하면서 요청 모양이 다른 SDK와 갈린다 · `php/src/AuthClient.php:161-166`
- [ ] `discovery-roundtrip-divergence` **[L/S]** 엔드포인트를 조립하지 않고 discovery로 왕복하는 자리가 남아 있고 문서에 없다 · `node/src/auth.ts:227-258`
- [ ] `manifest-comment-drift` **[L/S]** 빌드 매니페스트의 주석이 바로 옆 줄의 실제 핀과 다른 값을 말한다 · `java/pom.xml:84-104`
- [ ] `packaging-surface-hygiene` **[L/M]** 게시되는 아티팩트에 불필요·깨진 것이 실리거나 재현되지 않는다 · `java/pom.xml:112-143`
- [ ] `example-and-readme-publication-drift` **[L/S]** 예제·언어 README가 게시 상태와 검증 방법을 틀리게 말하고 아무 게이트도 안 본다 · `kotlin/examples/QuickStart.kt:9-10`
- [ ] `dotnet-admin-path-escaping` **[L/S]** .NET admin 파사드의 경로 이스케이프 규약이 리소스 클래스마다 다르다 · `dotnet/src/Xzawed.Keycloak.Sdk/Admin/ClientsResource.cs:16`

### 테스트·커버리지 — 8

- [x] `selftest-hygiene-textual-rules` **[H/M]** '존재'가 아니라 '실행'을 센다던 규칙이 주석·비활성화·`|| true`를 실행으로 센다 · `scripts/test/test-selftest-hygiene.sh:20`
- [ ] `coverage-exclusions-swallow-pure-logic` **[H/L · 계수 정정 2026-09-09]** '네트워크 경계' 커버리지 제외가 I/O 없는 순수 로직까지 삼켰다 — **세 언어** · `node/src/transport.ts:38`
  - ⚠️ **다섯이 아니라 셋이다**(재판정 2026-09-09): node(`transport.ts` + `admin/call.ts`) · php(`ErrorTranslation.php`) · ruby(`version.rb`).
  - ✅ **node `transport.ts` 는 #458 이 닫았다**(2026-09-10). ⚠️ **그리고 「테스트 파일 0」이라던 내 계측이 틀렸다** — `git grep -l isTransportError -- node/test` 는 **이름 grep** 이고, 실동작은 호출 자리(auth·admin 경계)에서 이미 구동되고 있었다. 진짜 결함은 「테스트 없음」이 아니라 **「측정되지 않아 일부 팔이 죽어도 초록」**이었다: 경계 테스트가 치는 팔은 `AbortError`·`ECONNREFUSED` **둘뿐**이고 나머지 15개 코드는 커버리지 제외 때문에 측정되지 않아, `CERT_HAS_EXPIRED` 를 지워도 **107 전부 통과**했다(변이 `SILENT`). 전수 표 테스트 + 제외 해제로 셋 다 `CAUGHT`.
  - ⏸ **남은 둘은 부류가 다르다**(실측 2026-09-10): php `ErrorTranslation.php` 는 `tests/Unit/Admin/ErrorTranslationTest.php` 가 이미 전수를 치고 있고 제외를 풀면 **실 I/O 가 게이트에 딸려 들어온다**. ruby `version.rb` 는 상수 한 줄이다. ⚠️ **node `admin/call.ts` 의 `requireFound` 는 여전히 순수 헬퍼이고 테스트 언급 0** — 그것이 이 항목의 진짜 잔여다.
  - ✅ **node `admin/call.ts` 를 닫았다(2026-09-15). ⚠️ 그런데 이 항목이 지목한 잔여가 틀렸다.** 등록부는 「`requireFound` 는 순수 헬퍼이고 테스트 언급 0 — 그것이 진짜 잔여」라고 적고 있었다. 실측: `requireFound` 의 널 검사를 무력화하면 **admin 위임 테스트 다섯이 실패한다**(`CAUGHT`). ⚠️ **`transport.ts` 때와 똑같은 「이름 grep」 오류다** — #458 이 그 함정을 적어 뒀는데 같은 항목의 다음 줄에서 또 밟았다.
  - **진짜 잔여는 `statusOf`·`messageOf` 였고 독립 레그가 지목했다.** Grok 이 코드만 읽고 순수 함수를 **셋**으로 세고(`requireFound`·`statusOf`·`messageOf`) `call` 도 `fn` 을 주입받아 catch 분기가 단위테스트 가능하다고 했다. 실측 3/3 `SILENT`: `statusOf` 의 `typeof status === 'number'` 제거 · `messageOf` 의 `?? record['error']` 폴백 제거 · 기본 문구 변경. 전수 표 테스트(`test/unit/admin-call.test.ts`, 21 케이스) + 제외에서 `call.ts` 를 빼 **3/3 `CAUGHT`** · 가드 OFF `SILENT`. 커버리지 분모 144 → 164 줄, 35 → 39 함수.
  - ⚠️ **제외는 글롭이 아니라 손 목록으로 남겼다** — 새 `src/admin/*.ts` 는 목록에 없어 **측정되는** 쪽으로 빠진다(글롭이면 조용히 제외된다). 측정이 시끄럽고 제외가 조용하니 이 방향이 옳다.
  - ⚠️ **워크트리에 `node_modules` 가 없다 — 프로비저닝은 변이가 아니라 검사 명령이 해야 한다.** 변이 쪽에 두면 기준선만 없는 채로 돌아 `INVALID: 기준선이 이미 실패한다` 가 난다(실측).
  - ⚠️ **`--assume-relevant` 가 필요한 첫 실제 사례였다** — 검사 스크립트가 워크트리 밖에 있고 `npm test` 는 `src/**` 를 **런타임에** 로드하므로 정적 근사가 의존성을 못 본다. 계측기가 `INVALID` 로 막았고 면제를 **명시적으로** 선언해야 통과했다(#499 가 의도한 동작).
  - ⚠️ **내 첫 단언이 틀렸고 테스트가 그것을 잡았다** — `toThrow('')` 는 빈 문자열을 `/^$/` 로 해석해 실제 문구 `HTTP 500: ` 와 안 맞는다. 표를 **정확일치**(`err.message === 'HTTP 500: ' + want`)로 바꿔 더 강해졌다.
- [x] `security-invariant-use-site-scope` **[H/M · 닫힘 2026-09-09 #444]** 보안 불변식의 '2차 정의 자리 금지'가 아홉 중 셋만 봤다 · `scripts/test/test-security-defaults.sh:297`
- [x] `node-php-use-site-skew-defaults` **[M/S · 신규·닫힘 2026-09-09 #445]** node·php 의 사용처 skew 기본값이 config 값과 대조되지 않았다 · `node/src/token-provider.ts:23` · `php/src/Token/TokenSet.php:73`
- [ ] `probe-cannot-run-node-php-in-worktree` **[M/S · 범위 정정 2026-09-12 · 악화]** `scripts/probe.sh` 가 node·php **·python** 변이를 못 잰다 — 워크트리에 `node_modules`·`vendor`·`.venv` 가 없어 기준선이 실패한다(`INVALID`) · `scripts/probe.sh:57`
  - ⚠️ **손 프로브로 대신할 때 반드시 넣어야 하는 검사 둘**(2026-09-12 실측으로 둘 다 걸렸다): **(1) 변이가 착지했는가**(`git diff` 가 그 심볼을 담는가) · **(2) 변이가 컴파일되는가**. (2)가 없어 `sed` 가 `if` 한 줄만 지운 변이가 `IndentationError` 를 냈고 그 실패를 하마터면 `CAUGHT` 으로 기록할 뻔했다 — 함정 (i)가 말하는 그것이다. ⚠️ 그리고 **검사 명령에 파일을 인자로 명시했으면 그 파일을 지우는 방식으로 (c)를 하지 말 것** — pytest 가 「파일 없음」으로 죽어 `FAIL` 이 나오고 「다른 단언이 잡았다」로 오독된다(실측). 비우되 남긴다.
  - ⚠️⚠️ **정션을 만들었으면 `git worktree remove --force` 가 그 대상까지 지운다.** 실측 2026-09-10: 그렇게 본 트리의 `node/node_modules` 가 **비었다**(추적 파일은 무사, `npm ci` 로 복구). 이 저장소가 이미 기록한 `git checkout -- .` 사고와 같은 부류다 — **가능하면 정션 대신 워크트리에서 직접 설치하라**.
  - **우회는 확인했다**(2026-09-09): 워크트리를 **같은 드라이브**에 만들고 `node_modules` 는 정션으로 붙이면 된다(위 위험을 감수할 때만). ⚠️ `vendor` 는 **정션이면 안 된다** — composer autoload 의 `$baseDir = dirname($vendorDir)` 가 본 트리를 가리켜 **워크트리 변이가 로드되지 않는다**(실측: php 변이 셋이 전부 거짓 `SILENT`). php 는 `vendor` 를 **복사**해야 한다.
  - ⚠️ `cmd /c mklink /J` 는 MSYS 가 `/J` 를 경로로 바꿔 깨진다 — `MSYS_NO_PATHCONV=1` 과 **단일 슬래시** `cmd /c` 를 함께 써야 한다(`//c` 는 그 변수와 같이 쓰면 거부된다).
  - **되살릴 조건**: 위 우회를 `probe.sh` 에 옵션으로 넣을지, 언어별 프로브 러너를 따로 둘지 판정. 지금은 그 절차를 손으로 밟았고 본 트리 불변·기준선·변이 적용 셋을 같은 방식으로 지켰다.
  - ⚠️ **넷이 아니라 다섯이고, 그 하나는 등록부를 쓴 뒤에 생겼다** — 이 부류는 **지금도 늘고 있다**(실측 2026-09-07, 독립 레그 둘): kotlin 3(`tokens.kt:18`·`tokenprovider.kt:18`·`jwt.kt:126`) · python 1(`_internal/jwt.py:43`) · dotnet 1(`KeycloakConfig.cs:29`). 축 3 은 `sd_no_literal` 호출 **4**(go·php·ruby·ruby-skew)로 그대로다. 값이 아직 안 갈렸다고 안전한 것이 아니다 — **자리가 늘고 있는 것**이 JWKS 가 10/30/60 으로 갈리기 직전과 같은 모양이다.
  - ⚠️ **required 손 표에 다섯 줄을 더하는 것이 답이 아니다** — 그것이 곧 `guard-detection-surface-hand-narrowed` 를 악화시킨다(그 파일은 `doc-facts` 안에서 `paths:` 없이 돈다). **언어 로컬 테스트**(그 언어의 2차 기본값이 config 값과 같은가)로 닫고, `test-security-defaults.sh` 는 건드리지 않는다.
- [x] `selftest-assert-counter-subshell` **[M/M · 닫힘 2026-09-23 #540]** 어서션 카운터가 서브셸에서 증발한다 — 자가테스트 프레임워크의 구조적 맹점 · `scripts/test/assert.sh:10`
- [ ] `guard-paths-never-exercised` **[M/M]** 자가테스트가 가드의 한 경로만 태워, 나머지 경로를 지워도 초록이다 · `scripts/test/test-check-coverage.sh:41`
- [ ] `selftests-with-no-negative-case` **[M/L]** 일곱 자가테스트가 라이브 상태만 단언한다 — 판정기가 나쁜 입력을 거부한다는 증거가 없다 · `scripts/test/test-deploy-md.sh:7`
- [ ] `probes-that-discard-the-result` **[M/M]** 프로브가 결과를 버린다 — 예외 타입 미단언·반환값 미단언 · `php/tests/Unit/Jwks/JwksStoreTest.php:188`
- [ ] `wall-clock-ordering-in-tests` **[M/M]** 동시성·시간창 테스트가 벽시계에 매달려 있다 — 조용한 퇴화와 거짓 실패 · `go/jwt_test.go:322`

### 가드·CI — 16

- [x] `selftest-exit-code-contract-two-leaks` **[H/M · 닫힘 2026-09-23 #540]** 자가테스트의 「실패하면 비영 종료」 계약이 한 곳에서 샜다 — 탐지기는 #405, 계수기는 #540(파일 눈금 오라클) · `scripts/test/test-selftest-hygiene.sh:20`
- [x] `sweeps-without-vacuity-floor` **[H/M · 닫힘 2026-09-08 #443]** 스윕/스캔이 0건을 훑고 통과했다 — 이 저장소의 하한 관용이 적용되지 않았다 · `.github/workflows/repo-hygiene.yml:234`
- [ ] `seven-selftests-have-no-negative-control` **[H/L · 계수 정정 2026-09-09 · 조각 셋째 2026-09-23]** **여섯** 자가테스트가 라이브 상태만 단언한다 — 검출기를 지워도 통과한다 · `scripts/test/test-deploy-md.sh:7`
  - ✅ **셋째 조각(#541) — 게시-수 축의 수사 변환기.** 항목이 처방한 대로 세지 않고 `scripts/probe.sh` 로 쟀다: `en() { echo nine; }` · `ko() { echo 아홉; }` 둘 다 **SILENT**(240 단언 전부 통과) — 랜딩 문서 축이 「문서가 그 낱말을 담는가」만 보므로 변환기가 상수가 되면 **자기충족**이었다. 점 고정 + **서로 다른 입력이 서로 다른 낱말을 내는가**까지 넣어 둘 다 CAUGHT. ⚠️ 점 고정만 두면 `case` 를 지우고 `echo nine` 으로 바꿔도 통과한다.
  - ⚠️ **일곱이 아니라 여섯이다**(재판정 2026-09-09): `test-deploy-md` · `test-harness-registries` · `test-provenance-gate` · `test-publication-claims` · `test-release-prerelease` · `test-security-defaults`. 엄격히 「라이브 grep 만」으로 좁히면 **넷**이다(뒤의 둘은 `assert_eq` 로 케이스를 먹인다). 이름이 말하는 7 은 어느 셈에도 맞지 않는다.
  - ⚠️ `test-osv-audit-gate.sh`(#438)는 이 부류가 **아니다** — 라이브 grep 이지만 게이트를 지우면 실패한다(변이로 확인).
  - ⚠️ **`assert_fails` 개수로 세지 말 것 — 내가 그렇게 재서 또 틀렸다**(2026-09-10). 그것은 「별도 실패 서브프로세스가 있는가」를 셀 뿐 「알려진 나쁜 입력을 거부하는가」가 아니다. 여섯 중 둘은 **이미 음성 케이스를 먹인다**: `test-release-prerelease.sh:94-126` 이 15행 표(`1.0.0+incompatible=false` 등)를, `test-provenance-gate.sh:100-103` 이 합성 provenance(공개 레지스트리 한 줄 · 빈 파일)를 넣는다. 실제 대상은 **넷 이하**다.
  - **베낄 모형**: 가드 바이너리가 따로 있으면 `test-check-jvm-bytecode-floor.sh:40-45`(나쁜 픽스처 + `assert_fails` + 메시지 핀), 자가테스트 자신이 검출기면 `test-osv-audit-gate.sh:36-44`(파생 대조 + 공허 하한). ⚠️ 메시지 핀 없는 `assert_fails` 는 그 자체가 다시 「존재 검사」다.
  - ✅ **첫 조각은 #459 가 했다** — `test-security-defaults.sh` 에 음성 대조군을 붙였다(213 → 217). **요건 (c) 실증**: 옛 스크립트는 추출기를 `sd_default() { echo 30; }` 상수로 바꿔도 **213 전부 통과**했다. 즉 그 파일은 아무것도 안 보면서 초록일 수 있었다.
  - **베낀 모양**: 트리 전체가 아니라 **추출기가 읽는 파일 하나**만 값을 바꿔 같은 상대경로로 TMP 에 놓고 `SD_ROOT` 로 가리킨다(트리 복사는 required 체크 안에서 실패할 자리를 늘린다). **양성 대조**를 함께 둬 「늘 다른 값을 낸다」와 구분한다.
  - ⏸ **남은 대상을 다시 쟀다(2026-09-10) — 남은 둘은 이 부류가 아니다.** 입력 문서를 빈 파일로 바꾸면 `test-deploy-md`·`test-harness-registries` 둘 다 **실패한다**(변이 `CAUGHT`). 즉 「빈 입력이 통과한다」는 공허는 없다.
  - ⚠️ **그래서 항목의 서술이 너무 거칠다.** 실제 위험은 「라이브 상태만 단언한다」가 아니라 **「깨진 대상에 대해서도 참인 단언」**이다 — #446 이 그 실물이었다(`assert_contains "scripts/release-readiness.sh"` 가 `--version` 빠진 **깨진 명령**에도 참이었다). 그 부류는 일반 프로브로 못 가리고 **단언마다** 「이 문장이 참이면서 대상이 깨져 있을 수 있는가」를 물어야 한다.
  - ✅ **그 형태로 실행했다(2026-09-10)** — 후보를 목록으로 만들지 않고 **상위 셋을 실제로 돌렸다**(독립 레그가 「이름 붙인 변이는 증거가 아니다」로 자기 산출물을 반박했고 그게 맞았다). 셋 다 **`SILENT`**: ① `check-ci-permissions.mjs` 의 시크릿 프리플라이트(`exit 1` 한 줄만 지우면 통과) · ② `test-release-prerelease.sh:72`(`--prerelease` 플래그를 빼고 토큰만 주석에 남기면 통과) · ③ `test-security-defaults.sh` 의 python 마스킹 카나리아(`test_repr_masks` 를 지워도 통과).
  - ①은 **#461 이 닫았다** — 판정을 그 `run:` 블록으로 좁혔다(#438 과 같은 처방). 수렴 실측: 빈값 검사를 담은 블록 **28/28** 이 같은 블록에 `exit 1` 을 갖는다(오탐 0). ⚠️ `exit 1` 은 **인라인 형태**(`|| { …; exit 1; }`)도 세야 한다 — 줄 단독으로만 세면 정당한 두 자리를 거짓 양성으로 잡는다.
  - ②는 **#462 가 닫았다** — `assert_contains` 를 파일 전체가 아니라 **`gh release create` 명령 하나**(연속행 이어붙임)로 좁혔다. 세 호출자의 모양이 갈리지만 수렴한다(실측 3/3, 오탐 0: `run:` 한 줄 · 백슬래시 연속행 · 인자만 한 줄). 명령을 못 뽑으면 검사가 무의미하므로 공허 방지 단언을 함께 뒀다.
  - ③은 **#463 이 닫았다** — 그리고 파고드니 **python 하나가 아니라 여섯 언어**였다. 축 1c 의 카나리아가 kotlin·python·node·dotnet·php·ruby 에서 **엉뚱한 파일**(`Masking*`)을 가리키고 있었다: 그 파일들이 단언하는 것은 `mask()` 헬퍼이거나 `AuthorizationRequest` 이지 `TokenSet` 의 기본 표현이 아니다. 앵커도 `***` 라 그 파일의 아무 마스킹 테스트나 만족시켰다.
  - **결과**: 게시된 SDK 의 `TokenSet` 이 access/refresh 토큰을 로그에 원문으로 찍어도 가드가 못 잡는다 — 아홉 언어 공통 바닥 계약이 무보호였다. 파일과 앵커를 **함께** 실제 테스트로 옮겼고(여섯 다 히트 1 로 유일), **이제 아홉 전부 테스트 이름 앵커**다.
  - ⚠️ **`***` 같은 리터럴을 앵커로 쓰지 말 것** — 같은 파일의 다른 테스트가 그 문자열을 가지면 겨누던 카나리아가 사라져도 참이다. #437 이 형제 축(1d)에 쓴 원칙을 1c 에도 적용했다.
  - **다음 조각의 올바른 형태**: 파일 단위가 아니라 **단언 단위**로 고른다. 후보는 `assert_contains` 로 **이름·문자열의 등장**만 보는 자리들이다(#438 `exit 1` · #443 하한 마커 · #446 스크립트 이름 · 그리고 내 `assert_fails` 계수와 `isTransportError` 이름 grep — 이 세션에만 다섯 번이다). ⚠️ **이 파일의 남은 축들**(문서 축·소유자 문서 축)이 바로 그 모양이다.
  - ⏸ 이번 조각(#459)은 **코드 축 둘**만 덮었다. ⚠️ **여섯을 한 PR 로 묶지 말 것** · ⚠️ 그 파일에 라이브 grep 행을 더 늘리지 말 것(`guard-detection-surface-hand-narrowed`).
  - ⚠️ **음성 대조군 자체를 지우면 아무도 안 잡는다**(변이 `SILENT`, 실측). 그것을 「존재 검사」로 막으면 같은 병을 한 층 위에 만드는 것이라 **하지 않았다** — 대신 양성 대조로 대조군이 무의미해지는 쪽을 막았다.
  - ✅ **둘째 조각 — 문서 축(2026-09-14).** 항목이 지목한 「이 파일의 남은 축들」 중 문서 축을 **단언 단위**로 닫았다. ⚠️ **축 하나에 단언이 둘이라 대조군도 둘이었다** — 값 비교(`_bad=`)와 히트 하한(`_enough=`). 실측: 대조군 전 **둘 다 `SILENT`** → 대조군 후 **둘 다 `CAUGHT`**, 각각 의도한 단언 **1건**만 울린다. 가드 OFF 레그도 각각 `SILENT` 로 확인했다.
  - ⚠️ **대조군 안에 탐지를 다시 구현하면 대조군이 아니다 — 첫 판이 그랬고 변이가 여전히 `SILENT` 였다.** 축의 비교가 아니라 **나란한 제3의 grep** 을 태웠기 때문이다(이 세션이 이미 카탈로그한 「병행 경로를 검사한다」와 같은 부류인데 대조군을 쓰면서 또 밟았다). 고친 판은 `sd_doc_axis` **자신**을 값이 틀린 사본 트리에 태우고 `_A_FAIL` 이 늘었는지 본다.
  - ⚠️ **복제가 곧 구멍이었다.** JWKS 문서 축은 `sd_doc_axis` 를 **복사한 인라인 루프**였다 — 같은 비교가 두 벌이니 한 벌을 죽여도 다른 벌이 초록을 냈다. 복제를 지운 것이 수정이다(단언 총수 252 → 252 · 라벨 대조 손실 0 · 교체 2). 인라인일 때 실패 문구가 하한 `9` 를 **`10건 미만`** 이라 말하고 있던 것도 함께 사라졌다(상수만 고치고 문구를 안 고친 자리다).
  - ⚠️ **「실패가 늘었는가」만 보는 대조군은 단언이 둘 이상인 함수에서 공허해질 수 있다** — 어느 단언이 울었는지 구분하지 않으므로, 값 비교가 살아 있으면 하한이 죽어도 통과한다. 독립 레그(Grok)가 코드만 읽고 이 자리를 지목했고 프로브가 `SILENT` 로 확인했다. 처방: **대조군은 단언 하나에 하나씩** 세우고, 각각 **그 단언만 울릴 수 있는 입력**을 쓴다(하한 대조군은 빈 문서 → 히트 0).
  - ⚠️ **이 조각을 하며 splice 가 인접 가드 가족(`sd_negative_control`)을 통째로 지웠다** — 범위를 느슨한 패턴으로 잡은 탓이고, 스위트는 **249 passed, 0 failed** 로 초록이었다. 잡은 것은 **단언 라벨 전수 대조**(구/신 `sh -x` 로 뽑아 `comm`)다. **단언 수가 줄어든 것을 초록이 알려주지 않는다** — 편집 후에는 수가 아니라 **라벨 집합**을 대조할 것.
  - ✅ **셋째 조각 — 소유자 문서 축(2026-09-14).** ⚠️ **단언이 셋이었고 셋 다 공허했다** — 실측: 존재 검사(`_exists=0`)·히트 하한(`-ge 0`)·값 비교(`_bad=""`) 를 각각 무력화하니 **셋 다 `SILENT`**. 대조군 셋 + 양성 대조 하나를 세워 **3/3 `CAUGHT`**(각각 의도한 단언 1건) · 가드 OFF 레그 `SILENT`. 각 대조군은 **그 단언만 울릴 수 있는 입력**을 쓴다(값=정책값만 바꾼 사본 · 하한=그 줄만 지운 사본 · 존재=빈 루트).
  - ⚠️ **`probe.sh --site` 를 내가 주입한 마커로 선언하면 자리 검사가 공허해진다.** `--site 'OWNER-NEUTERED'` 는 내가 넣는 문자열이라 **어느 줄에 넣든 항상 ✓** 다. 그래서 순번(`NTH=2`)을 잘못 세어 **소유자 축 대신 소스 주석 축**을 변이시키고도 통과했고, 「소유자 축 값 비교 `SILENT`」라는 **거짓 측정**을 얻었다(같은 파일에 `_bad=` 가 셋). **처방 둘**: (1) `--site` 는 **지워지는 줄**에 있는 문자열로 선언한다(diff 는 `-` 행도 담으므로 `SD_POLICY` 로 선언했으면 잘못된 자리에서 `INVALID` 가 났다) · (2) 변이 대상은 순번이 아니라 **내용**으로 지정한다.
  - ⚠️ **메시지 없는 `assert_ok` 는 실패해도 무엇이 틀렸는지 안 알려준다.** 하한을 `-ge 2` 로 올린 변이가 낸 전부가 `FAIL expected success: test 1 -ge 2` **세 줄**이었다 — 호출이 셋인데 세 줄이 똑같아 어느 파일인지 없다. 메시지 있는 `assert_eq` 로 바꿨다(라벨 대조: 손실 3 → 교체 3 + 신규 4).
  - ⚠️ **`set -eu` 아래서 `cmd; v=$?` 로 반환값을 받으면 스위트가 출력 한 줄 없이 죽는다**(실측: `exit 1`, 표준출력·표준오류 모두 빈 채). 반드시 `|| v=1` 조건 문맥으로 받는다.
  - ⚠️ **독립 레그가 내 주석 하나를 반박했고 실측이 그쪽을 편들었다** — 하한 대조군에서 「값 비교는 아예 안 돈다」고 적었으나, 실제로는 **돌지만 침묵**한다(`_lines=""` → `printf` 가 빈 줄 하나 → `grep -v` 가 그것을 고르지만 명령치환이 끝 개행을 깎아 `_bad=""`). 격리된다는 결론은 같아도 **이유가 틀리면 다음 사람이 틀린 모형으로 고친다**. 주석을 정정했다.
  - ⏸ **남은 축 하나 — 소스 주석 축**(`SD_SRC` 루프). 실측으로 값 비교가 **`SILENT`** 임을 확인했고, 문서 축이 그랬듯 **`sd_doc_axis` 를 복사한 인라인 루프**다. 다음 조각.
  - ✅ **넷째 조각 — 소스 주석 축(2026-09-14). 이 항목이 지목한 「이 파일의 남은 축들」이 모두 닫혔다.** 단언이 **넷**이었고 **넷 다 변이에 `SILENT`** 였다(목록 비었나 · 언어별 기여 · 값 비교 · 히트 하한).
  - ⚠️ **이 축도 `sd_doc_axis` 를 복사한 인라인 루프였다** — 다른 점은 코퍼스(`SD_SRC`)와 주석 줄만 남기는 중간 필터 둘뿐이라 **인자 둘로 접었다**. 그 결과 값 비교와 히트 하한이 **한 벌**이 됐고, 한 변이가 **두 코퍼스의 대조군을 동시에** 울린다(실측). 하한 대조군은 **하나로 두 축을 덮는다** — 복제를 지운 값이 여기서 나온다. 라벨 전수 대조: 접기 단계에서 **완전 동일**(손실 0 · 추가 0).
  - ⚠️ **「변이가 `SILENT`」와 「그 단언이 불필요」는 다르다 — 그리고 대조군을 세울 수 없는 단언이 있다.** `_hassrc`(소스 목록이 비었나)는 죽여도 `SILENT` 지만 **구멍이 아니라 중복**이다: 실측으로 코퍼스를 비우면 **셋이 동시에** 운다(이 단언 · 언어별 기여 · 하한). 이 단언이 우는 입력은 전부 다른 둘도 우는 입력이라 **격리 입력이 존재하지 않고**, 따라서 「no-op 이 아니다」를 보일 방법이 없다. 남긴 이유는 **메시지**다(「하한 미달」보다 「목록이 비었다」가 원인을 곧장 가리킨다). ⚠️ **판정은 변이가 아니라 「그 단언이 막는 상태를 만들어 무엇이 우는가」로 한다.**
  - **언어별 기여 검사는 값을 한다** — 실측: `go` 만 스캔에서 빼면 **그 단언만 단독으로** 운다(하한 8 은 안 걸린다). 대조군을 세우려 **최상위 인라인을 함수로 뺐다**(인라인이면 자신을 태울 수가 없다).
  - ⏸ **부류는 아직 안 닫혔다** — 이 항목이 세는 **여섯 자가테스트** 중 `test-security-defaults.sh` 하나가 끝났을 뿐이다. 나머지 다섯은 「엄격히 라이브 grep 만」으로 좁힌 넷 안에서 다시 판정해야 한다.
  - ✅ **다섯째 조각 — `test-deploy-md.sh`(2026-09-15). 부류의 둘째 파일이다.** ⚠️ **2026-09-10 판정은 틀리지 않았지만 좁았다** — 「입력 문서를 빈 파일로 바꾸면 실패한다」는 참이다. 그러나 공허는 **입력 쪽이 아니라 SSOT 쪽**에 있었다: `assert_contains "$body" ""` 는 **항상 참**이라, `df_tag`·`df_secrets` 를 빈 값으로 만들거나 `DEPLOY_LANGS` 를 비우는 변이가 **셋 다 `SILENT`** 였다(실측).
  - ⚠️ **그러나 구멍은 아니었다 — 셋 다 자매 가드 `test-deploy-facts.sh` 가 잡는다**(실측 3/3 `CAUGHT`). 참인 진술은 **「이 파일이 자기 전제를 스스로 못 지키고 옆 파일에서 빌려 쓴다」**이고, 이 파일만 돌리면 공허하다. 빚을 갚는 단언 둘을 세웠다: **기대값이 비었는지**(값을 쓰기 전에 단언) · **언어 우주를 트리에서 파생해 대조**(`df_tree_langs` — `DEPLOY_LANGS` 자신을 세면 그것이 빌 때 하한도 0 이 되어 같이 무너진다). 3/3 `CAUGHT` · 가드 OFF `SILENT` · 라벨 대조 손실 0(54 → 65 단언).
  - ⚠️ **시크릿은 「비었나」로 못 센다 — 정당하게 0개인 언어가 있다**(OIDC/none). 그래서 언어별이 아니라 **아홉을 통틀어 하나라도 나왔는가**를 센다.
  - ⚠️ **`ok_if` 가 두 자가테스트에 복제돼 있고 `assert.sh` 에는 없었다** — 세 번째 파일에서 쓰려다 없는 채로 호출해 `actual: []` 로 **열 건이 거짓 실패**했다. `assert.sh` 로 올리고 복제 둘을 지웠다(라벨 대조: 두 파일 다 손실 0 · 추가 0).
  - ⚠️ **가드 OFF 레그를 한 번 무효로 측정했다** — 단언 두 줄만 지워야 하는데 값 **대입까지** 지워 `set -u` 로 스크립트가 죽었고, 그 `exit 1` 을 「잡혔다」로 읽었다(`CAUGHT` 오판). **가드 OFF 는 단언만 지운다 — 그 단언이 읽는 값의 계산은 남긴다.** 고쳐 재측정하니 `SILENT` 였다.
  - ✅ **여섯째 조각 — `test-harness-registries.sh` + 계측기 보강(2026-09-15).** 독립 레그(Grok)가 코드만 읽고 **1순위로 지목한 자리**를 실측이 확인했다: `TBL` 을 만드는 awk `END` 를 **고정 3행**으로 바꾸면 `verdaccio.yaml` 을 아예 안 읽고도 통과한다(**SILENT**). 기존 대조군 `blocks >= 3` 은 **행 수**만 세므로 못 본다. ⚠️ **다만 「가드가 실물을 못 잡는다」는 아니다** — 자기 스코프에 `proxy:` 를 실제로 붙이면 **CAUGHT**(의도한 단언 1건). 공허는 **가드 자신을 고칠 때만** 열린다. 파서를 `hr_table()` 로 빼고 **그 파서를 결함 있는 사본에 태우는** 대조군을 세웠다(3요건: a CAUGHT · c SILENT · 라벨 손실 0, 65 → 67).
  - ⚠️ **`probe.sh` 에 세 번째 사각이 있었다 — 「검사가 그 파일을 읽는가」.** 실측: `DEPLOY_LANGS` 를 비우는 변이를 **그 변수를 아예 안 쓰는** `test-release-prerelease.sh` 로 검사해 **SILENT** 를 얻었다(자리 검사는 통과했다 — 변이가 선언한 줄을 쳤으므로). 읽지 않는 것을 바꾼 뒤의 통과는 「가드가 침묵했다」가 아니라 **아무 일도 없었다**이고, 그것을 구멍으로 쓰면 **없는 결함**을 보고한다. 이제 `SILENT` 직전에 관련성을 보고 아니면 `INVALID` 로 거부한다(면제는 `--assume-relevant`, `--no-site` 와 같은 관용). 자가테스트 13 → 16, 계측기 변이 2/2 `CAUGHT`.
  - ⚠️ **관련성 전이는 소싱(`.`/`source`)만 따라가야 한다.** 첫 판은 「파일명 언급」을 3단계 전이시켰는데, **가드 전부를 돌리는 워크플로 하나**를 거쳐 모든 파일이 서로 연결돼 검사가 통째로 공허해졌다(같은 무관 변이가 그대로 SILENT 로 통과 — 실측).
  - ⚠️ **`test-provenance-gate.sh` 는 이 부류가 아니다(재판정 2026-09-15).** 추출기를 죽이면 **단언 55건이 실패**하고, 자체 대조군까지 꺼도 여전히 시끄럽게 실패한다(실측). 독립 레그도 코드만 읽고 같은 결론을 냈다. **등록부가 이 파일을 여섯에 넣은 것은 이제 거짓이다.**
  - ⚠️ **`test-release-prerelease.sh` 의 SILENT 는 거짓 신호였다** — 그 파일은 `DEPLOY_LANGS` 를 쓰지 않는다(`deploy-facts` 언급 0건). **아직 제대로 재지 않았다** — 열린 채로 둔다.
  - ⚠️ **Grok 이 이름 붙인 변이를 그대로 쓰면 안 된다 — 첫 재현이 `awk` 문법 오류로 죽어 `CAUGHT` 으로 위장했다**(내 `\t`·`\n` 이 왕복 해석기에서 반으로 줄었다). `probe.sh` 가 「잡은 근거 — 단언 형식이 아니다」를 찍은 덕에 걸렀다. **백슬래시는 `String.fromCharCode(92)` 로 우회한다.**
  - ✅ **일곱째 조각 — `test-publication-claims.sh`(2026-09-15).** 독립 레그가 **2순위로 지목**한 자리를 실측이 확인했다: 펜스 값비교(`_bad=""`)와 프리릴리스 옵트인 플래그 추출(`_flag=""`)이 **둘 다 SILENT**. 기존 대조군(`FENCE_SEEN >= 4` · `n >= 9`)은 **건수**만 세고 값 일치는 안 본다. ⚠️ **다만 「가드가 실물을 못 잡는다」는 아니다** — 실측: 펜스 핀 `1.0.0 → 1.0.1` **CAUGHT**, 정식 게시 뒤 `--prerelease` **CAUGHT**. 공허는 **가드 자신을 고칠 때만** 열린다(`harness-registries` 와 같은 모양). 축 `pc_fence_axis()` 를 추출하고 **그 축을 결함 사본에 태우는** 대조군을 세웠다(a 2/2 CAUGHT · c SILENT · 라벨 손실 0, 227 → 234).
  - ⚠️ **추출만 함수로 빼면 대조군이 비교를 못 태운다 — 실측이 내 첫 판을 반증했다.** 추출(`pc_fence_versions`·`pc_fence_flags`)만 함수화하고 대조군을 붙였더니 **추출 고정 변이는 CAUGHT** 인데 **비교 무력화 둘은 그대로 SILENT** 였다. 대조군은 **자기가 겨눈 단언 자체**를 태워야 한다(#495 가 문서 축에서 배운 것과 같은 부류인데, 「함수로 뺐으니 됐다」고 한 단계 일찍 멈춰서 또 밟았다).
  - ⚠️ **픽스처가 비현실적이면 SILENT 가 거짓 신호가 된다.** 펜스에 `9.9.9` 를 심고 SILENT 를 얻었는데, `PIN_RE` 는 SSOT 파생 `[0-PIN_MAXMAJ]` 이고 지금 `PIN_MAXMAJ=1` 이라 **애초에 패턴 밖**이다(파일 주석이 이미 「의도한 교환」이라 적은 자리다). 현실적 값(`1.0.1`)으로 다시 재니 **CAUGHT**. **구멍을 주장하기 전에 픽스처가 그 가드의 사정거리 안인지 확인할 것.**
  - ⚠️ **부분문자열로 겨눈 splice 가 축 함수를 무한 재귀로 만들었다** — `_fence=` 를 찾았는데 새로 넣은 함수 안의 `_pfa_fence=` 에 걸렸고, 스위트가 **멈춰서** 드러났다(단언 실패가 아니라 정지라 초록/빨강으로는 안 보인다). **삽입과 교체를 한 스크립트에서 할 때는 교체를 먼저 하고, 앵커는 줄 전체 정확일치로 잡을 것.**
  - ✅ **여덟째 조각 — `test-release-prerelease.sh`(2026-09-15). 이 부류의 마지막 파일이다.** ⚠️ **독립 레그는 이 파일을 「가장 덜 공허하다」로 4순위에 뒀고, 실측은 그 순위를 지지하면서도 구멍 둘을 찾았다** — 공허 방지선이 **비었는지**만 보기 때문이다(`test -s` · `test -n "$_cmd"`): `gh_create_cmd` 를 **플래그가 든 고정 문자열**로 바꾸면 **SILENT**, `extract` 가 인자를 무시하고 **한 파일만** 읽게 하면 **SILENT**(그러면 세 블록이 구조적으로 같아져 `cmp -s` 가 무의미해지고 dotnet·php 블록이 갈라져도 안 보인다).
  - ⚠️ **여기서도 「가드가 실물을 못 잡는다」는 아니다** — 실측: dotnet 블록을 실제로 갈라놓으면 **CAUGHT**, php 명령에서 플래그를 떼면 **CAUGHT**. **부류 전체가 같은 모양이었다**(`harness-registries`·`publication-claims`·여기 셋 다): 실물 결함은 잡고, 공허는 **가드 자신을 고칠 때만** 열린다. 처방도 같다 — **추출기 자신을 결함 사본에 태우는** 음성 대조군 + 「늘 참」과 구분하는 양성 대조군(37 → 41, a 2/2 CAUGHT · c SILENT · 라벨 손실 0).
  - ⚠️ **독립 레그가 내가 재지 않은 셋째 구멍을 냈고, 실측이 확인했다 — 「행수 하한」이 못 막는 부류다.** `classify()` 는 서브셸이라 **루프 변수 `want` 를 상속**한다. `printf '%s' "$PRERELEASE"` 를 `"$want"` 로 바꾸면 표가 **자기 자신과 대조**하게 되고 열다섯 행이 전부 통과한다(**SILENT**). ⚠️ **행수 하한(`rows == 15`)은 이것을 못 잡는다 — 루프는 열다섯 번 다 돌기 때문이다.** 공허한 것은 **행수가 아니라 오라클**이었다. Grok 이 코드만 읽고 이 자리를 지목했고(내 프로브 둘은 추출기만 덮고 있었다) 프로브가 SILENT 로 확인했다.
  - **처방은 둘이고 하중은 대조군이 받는다**: (1) 구조 — `classify` 안에서 `want`·`ROWS` 를 비워 **기대값을 볼 수 없게** 한다. (2) 행동 — **정식과 프리릴리스에 다른 답이 나오는지** 보는 음성 대조군(+ 정식이 `false` 인지 보는 양성 대조군). 실측: (1)만 빼면 여전히 **CAUGHT**(대조군이 잡는다), **둘 다 빼야 SILENT**. 37 → 43.
  - ⚠️ **「이 파일은 케이스를 먹이니 안전하다」로 넘기지 말 것** — 케이스를 먹여도 **기대값이 실측값의 원천이 되는 경로**가 있으면 표 전체가 공허해진다. 하한은 「몇 번 돌았는가」만 세므로 이 부류에 무력하다.
  - ⚠️ **문맥 없는 `assert_ok cmp` 를 고쳤다** — 실제 갈라짐 변이가 낸 것은 `FAIL expected success: cmp -s /tmp/tmp.XXX/...` **두 줄**뿐이라 어느 워크플로인지 알 수 없었다. 이제 파일명을 말한다(`[소유자축]` 에서 한 것과 같은 수정).
  - ⚠️ **라벨 전수 대조에 tmp 경로가 섞이면 거짓 손실이 난다** — 실행마다 `mktemp -d` 가 달라 같은 단언이 다른 라벨로 보인다(실측: 거짓 손실 3건). 경로를 정규화하고 비교할 것.
  - ⚠️ **크래시 덤프가 `main` 에 들어갔다** — 무한 재귀로 죽은 셸이 `sh.exe.stackdump` 를 남겼고 `git add -A` 가 쓸어담았다(#500). 지우고 `.gitignore` 에 `*.stackdump` 를 넣었다. **`git add -A` 전에 `git status` 를 읽을 것.**
- [ ] `irreversible-publish-no-reentry` **[H/M · 착수 보류 판정 2026-09-09]** 비가역 게시 뒤 재진입 경로가 없다 — 세 레인의 gh release create와 php 미러 순서 · `.github/workflows/go-release.yml:156`
  - ⏸ **지금 하지 않기로 판정했다**(독립 레그 + 재현). 근거: **13/13 성공**(`gh run list` — dotnet 4 · go 4 · php 5, 실패 0 · 재실행 0). 릴리스는 사람이 태그를 미는 저빈도 경로이고, **소비자 설치는 GitHub Release 를 거치지 않는다**(php 는 Packagist, dotnet 은 nuget.org, go 는 태그 자체가 게시). 실패해도 잃는 것은 Release **페이지**뿐이고 손으로 하나 만들면 된다.
  - ⚠️ **잘못 고치면 닫힌 설계를 다시 연다.** `--skip-duplicate` 는 이미 기각(DEPLOY.md §2-C: 「이미 태워버린 버전을 성공으로 위장」). 「존재하면 계속」을 자동화하려면 **이 실행이 게시한 것**과 **남이 태운 것**을 가르는 판정이 있어야 한다 — 가능한 신호는 잰다: NuGet nuspec 의 SourceLink `commit` 이 `dotnet-v1.0.0` SHA 와 일치 · php 미러 태그 SHA(단, subtree split 재현성 미확인) · GitHub Release 는 **커밋에 묶이지 않는다**(`target_commitish` 는 태그가 이미 있으면 무시된다).
  - **PR 크기인 조각은 있다**: 비가역 스텝과 `gh release create` 를 **잡으로 분리**하면 「실패한 잡만 재실행」이 create 만 재시도한다. ⚠️ 다만 `gh release create` 멱등화만 떼어내면 php·dotnet 은 여전히 nuget/태그에서 죽어 **거짓 닫힘**이 된다 — 그 조각을 이 항목의 종결로 팔지 말 것.
  - ⚠️ **실제로 물린 것은 반대 부류다** — 게시 **전** fail-closed(rust 이메일 미인증 · node 403 2FA: 태그는 썼고 좌표는 살았다)와 파이프라인 초록인데 GitHub 플래그가 틀린 것(`php-v0.1.0-rc.1` Latest 오표기). 「게시 후 create 실패」 기록은 **0건**이다.
- [x] `operator-commands-that-do-not-work` **[H/S · 닫힘 2026-09-09 #446]** 저장소가 사람에게 시키는 명령 둘이 실제로는 원하는 답을 주지 않았다 · `scripts/release-trigger.sh:53` · `DEPLOY.md:231`
- [x] `guard-neutering-wiring-unprotected` **[H/M]** [세션 발견·원장 밖] 가드 스텝을 무력화하는 배선이 무보호다 — 워킹트리에 continue-on-error가 살아 있다 · `.github/workflows/repo-hygiene.yml:119`
- [ ] `guard-probes-count-mentions-not-declarations` **[M/S · 절반 닫힘 2026-09-07]** 가드 프로브가 「선언」이 아니라 「문자열 등장」을 센다 — **배선 규칙 3 은 #405 가 닫았고 node update 프로브가 남았다** · `scripts/test/test-selftest-hygiene.sh:84`
  - 재측정 2026-09-07: 규칙 3 의 `mjs_wired` 는 이제 단어 경계 정규식이고 대조군이 같은 함수를 부른다(`scoreXtest.mjs`·`score.test.mjs.disabled` 를 거부). **`npm update` 프로브는 여전히 히트 0** — 그 자리가 어디였는지 원 감사에서도 특정되지 않았다. ⚠️ 규칙 3 에 남은 `grep -q` 를 옛 「등장 계수기」로 오인하지 말 것 — 단어 경계 패턴이거나 주석이다.
  - **절반 닫힘(#405) — 배선 규칙 3 만.** `grep -q "node $m"` 의 두 누수를 규칙 2 와 같은 엄격도로 맞췄다(실측: 경로 미이스케이프로 `install-matrixXtest.mjs` 가 매치 · 단어경계 없어 `node <path>.disabled` 도 배선으로 계수 — 3파일 × 2형태 = 6건).
  - ⚠️ **「node update 프로브」를 찾지 못했다 — 그래서 닫지 않는다.** 다음 검색이 전부 0건이다: `grep -rn "npm update\|node update" scripts/test/*.sh` · `grep -rn "grep -q \"" scripts/test/*.sh`(자가테스트 2건은 무관: LICENSE 문자열·주석). 원장의 그 절반이 **다른 파일을 가리키거나 서술이 부정확**하다 — 착수 전 기계용 원장(`ledger-dedup.json`)에서 이 항목의 원문을 먼저 볼 것.
- [ ] `guards-outside-their-own-pr-signal` **[M/M]** 자기를 고친 PR에서 신호를 못 내는 가드 — 규칙 5의 스윕 글롭 밖과 harness의 paths 필터 · `scripts/gradle/osv-audit-init.gradle:1`
- [ ] `selftests-miss-the-real-callsite` **[M/M]** 자가테스트가 CI의 실제 호출 형태를 타지 않는다 — 무인자 경로·다중 리포트·호출부 seam · `scripts/test/test-check-php-mirror.sh:29`
- [ ] `stale-comments-nobody-collates` **[M/S]** 주석에 박힌 실측값·게이트 서술이 낡았고 대조 대상이 아니다 · `.github/workflows/dotnet-ci.yml:36`
- [ ] `symmetry-guards-cover-a-subset` **[M/M]** 9언어 대칭을 주장하는 가드가 하드코딩 목록으로 부분집합만 본다 · `scripts/test/test-security-defaults.sh:297`
- [ ] `check-versions-java-child-pom-blind-spot` **[M/S]** check-versions.mjs가 자식 POM의 자체 선언 버전을 볼 수 없다 · `scripts/check-versions.mjs:76`
- [ ] `default-root-percent-encoding` **[M/S]** 무인자 기본 루트가 percent 이스케이프를 디코드하지 않아 공백 경로에서 죽는다 · `scripts/check-versions.mjs:27`
- [ ] `repo-config-apply-exit0-on-security-drift` **[M/S]** repo-config.mjs apply가 보안 설정 드리프트를 알리고도 exit 0으로 끝난다 · `scripts/repo-config.mjs:288`
- [ ] `rust-token-in-argv` **[L/S]** rust publish가 env로도 넘긴 토큰을 --token으로 argv에 한 번 더 싣는다 · `.github/workflows/rust-release.yml:127`
- [ ] `push-trigger-branches-asymmetry` **[L/S]** 여섯 워크플로의 push 트리거에 branches가 없어 PR 브랜치에서 레인이 두 번 돈다 · `.github/workflows/dotnet-ci.yml:3`

### 문서·규칙 — 15

- [ ] `docs-kcsdk-env-ssot` **[M/S]** KCSDK_* 환경변수 규약이 세 곳으로 갈려 있고 두 곳이 실측으로 부정된 경로를 가리킨다 · `CLAUDE.md:66`
- [x] `keycloak-image-tag-fiction` **[M/M · 재판정으로 닫힘 2026-09-11]** **이미 참이 아니었다** — `SECURITY.md:90` 과 `docs/reference/compatibility.md:32` 가 둘 다 「아홉이 같은 태그를 핀한다 · 언어별 분기는 없다」로 정정돼 있고, 후자는 「예전에 그렇게 주장했다」까지 적는다. 트리 실측 2026-09-11: 아홉 언어 **9/9** 가 `keycloak:26.6` 을 핀한다(이탈 0 — `keycloak:25.0.4` 히트는 `python/.venv` 안 라이브러리 문서화 문자열이라 우리 소스가 아니다). ⚠️ **다만 그 사실을 보는 가드는 없다**(두 문장 어디에도 `doc-guard` 앵커가 없다) — 한 언어가 드리프트하면 두 문서가 조용히 거짓이 된다. 그 구멍은 이 항목이 아니라 `keycloak-server-tag-ssot` 가 소유한다.
- [ ] `php-jwt-headers-rationale` **[M/S]** 세 곳이 반복하는 firebase/php-jwt 근거가 핀된 원본과 정반대다 · `.claude/rules/php.md:49`
- [ ] `deploy-narrative-stale` **[M/M]** DEPLOY.md 본문 다섯 자리가 워크플로·룰셋 개정을 못 따라갔다 · `DEPLOY.md:36`
- [ ] `deploy-php-mirror-gap` **[M/S]** PHP 미러 쪽 장치가 저장소에 실재하는데 런북이 그것을 모른다 · `DEPLOY.md:212`
- [ ] `deploy-readiness-verdict` **[M/S]** §5가 서술하는 release-readiness 판정 둘이 스크립트 개정 뒤 낡았다 · `DEPLOY.md:444`
- [ ] `governance-dead-actor` **[M/M]** 품질 게이트 G5가 저장소에 존재하지 않는 주체를 지목하고, 기각 레지스트리는 상주 진입점이 없다 · `docs/governance/process.md:204`
- [ ] `readme-mirror-contract` **[M/S]** 루트 README 영한 미러가 §4 계약을 두 자리에서 실제 코드보다 느슨하게 말한다 · `README.md:117`
- [ ] `hand-counted-enumerations` **[L/S]** 설정 파일을 손으로 센 열거 넷이 실제와 어긋나고, 그중 하나는 내부 문서끼리 모순이다 · `.claude/rules/ci.md:82`
- [ ] `doc-rule-self-violation` **[L/M]** 문서가 선언한 세 규약을 그 문서 자신이 어긴다 — 선언은 있고 계측기가 없다 · `CLAUDE.md:333`
- [ ] `contributing-gate-table` **[L/S]** '머지 전 통과할 게이트' 표의 세 칸이 실제 CI 잡과 다르다 · `CONTRIBUTING.md:47`
- [ ] `crossdoc-line-citations` **[L/M]** 문서가 다른 문서를 줄 번호로 인용하는데 그 인용을 보는 검사가 없다 · `docs/governance/process.md:46`
- [ ] `new-language-deliverables` **[L/M]** 10번째 언어 체크리스트가 필수 게이트·등록을 빠뜨렸고, 그 구멍이 .NET에 이미 결과로 남았다 · `docs/guides/add-a-language-playbook.md:69`
- [ ] `admin-capability-vestigial` **[L/S]** 25/25가 된 표를 감싼 산문이 빈 칸 시절 문장으로 남았고 두 항목이 서로 모순한다 · `docs/reference/admin-capability.md:16`
- [ ] `roadmap-vestigial` **[L/S]** 로드맵이 출처 없는 CVE를 확정 사실로 적고, 후보가 0행인 표에 '후보 전용 caveat'를 건다 · `docs/roadmap/language-support.md:11`

### harness 사각지대 — 8

- [x] `H1-conformance-authz-vacuous` **[M/M · 닫힘 2026-09-12 · 범위 확대]** ⚠️ **공허가 하나가 아니라 셋이었다.** 요청↔응답 미대조 외에 `/code_challenge=/` 가 **빈 값**을 통과시켰고, URL 의 `state` 와 돌려준 `state` 를 **존재만 따로** 보고 대조하지 않았다. 판정을 `harness/conformance/authz-url.mjs` 로 뽑아 **Docker 없이** 픽스처로 재게 했다(그 판정이 오래 공허했던 이유가 「시험할 수 없다」였다). 가드 `scripts/test/test-conformance-authz-url.sh`(픽스처 8종, `doc-facts` 배선). 변이 6/6 `CAUGHT` + OFF 짝 3/3. ⚠️ **프로브가 구멍 하나를 실제로 찾았다** — 모듈을 부르되 `v.ok` 를 버리면 침묵했다(같은 PR 에서 닫음). ⚠️ 파생 신규: `authz-redirect-uri-not-per-call`(php·rust).
- [x] `H3-harness-image-and-lock-pins` **[M/S · 닫힘 2026-09-12 · 범위 정정]** ⚠️ **「세 자리」가 아니라 한 파일의 두 결함이었고, 그중 하나는 거짓 초록이었다.** (1) `security-audit.yml:277` 이 `cargo audit -f harness/apps/rust/Cargo.lock` 으로 감사하는 그 락을 `harness/apps/rust/Dockerfile` 은 **COPY 하지 않았다** — 게다가 락이 `keycloak-sdk` **0.1.0** 을 고정한 채였고 매니페스트는 **1.0.0** 이다(4ed3298, 2026-08-30). 락은 2026-08-01 이후 안 움직였으므로 야간 감사는 **1.0 이전 그래프**를 6주째 감사하며 초록을 냈다. (2) `FROM rust:alpine` 은 하네스 아홉 앱 중 **유일한 무버전 태그**였다(install 경로 둘은 이미 `rust:1.88-alpine`). ⚠️ **install 경로의 락 처리는 결함이 아니다** — consume 은 registry 의존으로 재기입하고 publish 는 클로저 미러링용으로 `generate-lockfile` 하는 것이 설계다(주석이 그렇게 적는다). 부류 재스캔: `git ls-files harness/apps | grep -Ei 'lock|\.sum$'` → **1건** · `cargo audit -f` 전수 → **1건** · 무버전 `FROM` 전수(9앱) → **1건**. 형제 언어에 같은 결함 없음. ⚠️ **락 재생성에 MSRV 인지 해석이 필요했다** — cargo 가 `Locking 253 packages to latest Rust 1.88 compatible versions` 로 reqwest 0.13·matchit 0.8.6 을 눌렀다. edition 2021 은 resolver v2 라 기본이 아니고, 플래그 없이 재생성했으면 `--locked` 빌드가 1.88 에서 깨졌다(`scripts/regen-harness-rust-lock.sh` 가 소유). **Docker 실빌드로 확인**(107s, `rust:1.88-alpine` + `--locked`). 변이 6/6 `CAUGHT` + OFF 짝 6/6 `SILENT`.
- [x] `ruby-token-provider-inspect-leaks-token` **[M/S · 닫힘 2026-09-12 · 실행 재현]** ⚠️ **가드 부재가 아니라 실제 노출이었다.** `ClientCredentialsTokenProvider` 의 기본 `inspect` 가 캐시된 **액세스 토큰을 원문으로** 찍었다 — `@cached` 가 `ts.access_token`(원시 String)이라 `TokenSet#inspect` 의 마스킹이 닿지 않는다. 형제인 `Config`·`TokenSet` 은 `inspect` 재정의가 있는데 **이 타입만 없던** 불일치다. **실행으로 재현**했다(읽기 아님): `p provider` → `@cached="AT-CENSUS-TOKEN-…"`. 고친 뒤 재측정 → `cached="***"`. ⚠️ 캐시 **유무는 남긴다**(빈 캐시에 `***` 를 찍으면 「토큰이 있다」는 거짓 신호다 — 대조군 spec 이 고정). ruby 123/123 · 커버리지 99.61/96.72 · rubocop 청정 · 변이 `CAUGHT`(수정 전 상태로 되돌리는 변이). ⚠️ **아홉 전수는 실행으로 갈랐다** — node 는 안전(`#cached` 비노출 실측) · python 은 공개 캐싱 provider 없음 · java·kotlin·dotnet·rust 는 기본 표현이 필드를 안 찍음 · go 는 provider 가 미노출 타입.
- [x] `php-var-dump-bypasses-all-masking` **[M/M · 닫힘 2026-09-12 · 범위 재정의]** ⚠️ **「덤프 경로를 마스킹한다」는 아홉 언어 균일 계약으로 불가능하다** — 정밀 실측(독립 레그 census + 내 실행 검증)이 그것을 갈랐다. 그래서 **할 수 있는 것만 하고 못 하는 것은 경계로 적었다**. **훅 가능·저렴(구현함)**: php `__debugInfo`(`var_dump`·`print_r`·`debug_zval_dump`) · go `GoStringer`(`%#v` 만 — `%v`·`%+v`·`%s` 는 `String()` 그대로, 대조군이 고정) · ruby `pretty_print`(⚠️ 이것은 **바닥 안**이었다 — `pp` 는 표시 경로인데 `Data` 타입은 PP 가 멤버를 직접 찍어 `inspect` 를 건너뛴다. 일반 클래스인 `Config` 는 폴백해 안전). **훅 불가(경계로 문서화)**: python `asdict`/`astuple`/`vars`(필드를 직접 훑는다 — `__getstate__` 무시됨, 실측) · node 객체 스프레드(열거 가능 프로퍼티를 훅보다 먼저 복사) · .NET Serilog `{@}`(소비자가 정책을 등록해야 한다) · php `var_export`(private 까지 원문, 실측) · java/kotlin Jackson·Gson(게터 기반 — java core 는 **의존성 0** 이라 `jackson-annotations` 가 첫 컴파일 의존이 된다) · **아홉 전부의 공개 필드/게터 읽기**. ⚠️ **왕복 훅은 일부러 안 넣었다** — go `MarshalJSON`·rust `Serialize` 를 마스킹하면 소비자가 세션·캐시에 `***` 를 저장한다(덤프는 단방향, JSON 은 왕복이라 부류가 다르다). ⚠️ **저장소 주석 셋이 거짓이 됐다가 정정됐다** — 「`var_dump`/`print_r` 은 여전히 프로퍼티를 직접 읽는다」(php 8.3.32 에서 `print_r` 은 `__debugInfo` 를 **존중한다**, 실측). 계약은 `SECURITY.md` 가 소유한다 — **기밀 경계가 아니라 우발적 로깅에 대한 심층 방어**라고 적었다.
- [x] `harness-orphan-container-reads-as-build-failure` **[L/S · 닫힘 2026-09-16 · 부류로 넓혀서]** 중단된 하네스 런이 남긴 컨테이너가 다음 런을 막는데, 신호가 **원인을 잘못 가리킨다** · `harness/verify.sh:30`
- [ ] `H2-harness-judgment-module-no-test` **[L/M]** harness 판정 모듈에 「테스트가 있어야 한다」 규칙이 없다 — conformance.mjs 는 Docker 전체 런 없이는 시험 불가 · `harness/conformance/conformance.mjs:1`
- [x] `H4-runsh-network-divergence` **[L/S · 닫힘 2026-09-15]** verify.sh 가 배운 것을 run.sh 는 못 받았다 — compose 네트워크명을 아직 리터럴로 박는다 · `harness/run.sh:6`
- [ ] `install-harness-fixed-host-ports` **[M/M · 신규 2026-09-16 · 부류 재스캔]** install 하네스가 호스트 포트 **아홉**을 박아, 그중 하나라도 쥔 PC 에서는 파이프라인이 기동조차 못 한다 · `harness/install/compose.install.yml:15`
  - **실측(2026-09-16)**: 퍼블리시 9개 — keycloak `8080:8080`·`9000:9000` · verdaccio `4873` · pypiserver `18892` · bagetter `18180` · mvn-repo `18080` · mvn-repo-kotlin `18081` · gemserver `18808` · satis-web `18099`. 이 PC 에서 **8080 은 실제로 다른 프로젝트가 쥐고 있다**(`sillok-api-1` → `127.0.0.1:8080->8080/tcp`) — verify 하네스가 같은 이유로 막혔고 그것이 PR #506 이 닫은 자리다.
  - ⚠️ **compose 만 바꾸면 안 된다 — 리터럴이 두 곳이다.** `install-verify.sh` 의 `wait_healthy` 가 `http://localhost:18180/...` 류를 **5곳**에서 직접 적는다. verify 하네스는 `docker compose port` 로 읽고 있어 compose 한 곳만 고치면 됐지만(그래서 #506 이 쌌다), 여기는 **두 소스가 함께 움직여야** 한다.
  - ⚠️ **로컬 실측 비용이 크다** — `install-verify.sh` 는 9종 레지스트리 + 9언어 Docker 파이프라인이라 한 번 도는 데 길다(야간 `install-all` 타임아웃이 90분). 그래서 이 세션은 **재지 않고 등록만** 한다. 착수하는 세션은 8080 을 비우거나 그 변수를 먼저 만든다.
- [ ] `H5-install-version-class-drift` **[L/M]** install 하네스의 「버전을 무엇이 정하는가」 분류가 코드·산문·SSOT 셋에서 갈렸다 — dotnet 이 정반대 · `harness/install/lib/verify-lib.sh:56`
- [ ] `H6-kotlin-consume-pin-audits-old-artifact` **[L/S]** kotlin 소비자 앱의 0.1.0 리터럴이 야간 OSV 감사가 실제로 해석하는 좌표다 · `harness/install/consume/kotlin-app/build.gradle.kts:36`
  - ⚠️ **재판정 2026-09-15 — 서술 둘이 틀렸다(실측).** (1) **「야간」이 아니라 주간**이다: `.github/workflows/security-audit.yml:20` 이 `cron: '0 4 * * 1'`(매주 월 04:00 UTC)이고, 주석이 「harness 야간 03:00 과 겹치지 않게」라 적고 있다 — **야간인 것은 harness 쪽**이고 OSV 감사가 아니다. (2) 나머지는 **참이다**: `build.gradle.kts:36` 의 `implementation("io.github.xzawed:keycloak-sdk-kotlin:0.1.0")` 이 그 잡이 컨테이너 **밖**에서 해석하는 좌표이고(`kotlin-run.sh` 의 `sed` 치환을 안 탄다), SDK SSOT 는 `1.0.0` 이다. 즉 **주간 감사가 옛 좌표를 잰다**.
  - ⚠️ **다만 「그냥 1.0.0 으로 바꾸면 된다」가 아니다** — 그 줄 바로 위 주석이 「**Central 에 실재하는 버전이어야** 한다(그 잡은 미해결 좌표에 fail-closed 다)」고 적는다. 바꾸기 전에 `1.0.0` 이 Central 에 있는지 **재고**, 소비자 앱이 그 버전으로 **빌드되는지**도 재야 한다(형제 항목 `harness-consume-pin-unsupported` 와 같은 자리다 — 둘을 함께 본다).
- [ ] `H7-harness-readme-vs-tree` **[L/S]** harness/README.md 가 실제 트리와 갈렸다 — install/ 64파일이 지도에 없고 ruby 프레임워크가 틀렸다 · `harness/README.md:16`
  - ⚠️ **재판정 2026-09-15 — 절반이 거짓이다(실측).** **「ruby 프레임워크가 틀렸다」는 거짓**이다: `harness/README.md:16` 이 `| ruby | Sinatra 4 (Puma) |`, 40행이 `Sinatra 4, served by Puma` 이고, `harness/apps/ruby/Gemfile` 이 `sinatra "~> 4.0"`·`puma ">= 8.0.2"` 다 — **일치한다**. 독립 레그가 먼저 짚었고 실측이 확인했다. ⚠️ **내 세션 메모리도 같은 오류(「Rack/Puma」)를 들고 있었고 함께 고쳤다.**
  - ⚠️ **「install/ 64파일이 지도에 없다」는 그 형태로는 반증 불가다** — README 의 Layout 은 **디렉터리 개요**이지 파일 목록이 아니다(`install/` 은 한 노드로 접혀 자체 README·`compose.install.yml`·`install-verify.sh`·`publish/`·`consume/`·`registries/` 만 가리킨다). 「빠진 N 개」는 그 구조에서 셀 수 없다 — **주장을 다시 쓰거나**(예: 「개요가 가리키는 노드와 실제 하위 디렉터리 집합이 어긋난다」) 닫아야 한다.
- [x] `H8-root-config-never-rederived` **[L/M · 닫힘 2026-09-15]** 리포 루트 설정 둘이 언어·락파일이 늘 때 한 번도 다시 도출되지 않았다 · `.dockerignore:2`

## D. 원장 밖 — 57건 (열림 50)

감사가 보지 않은 축 — 유예·미완 마커·로드맵 갭·CI/릴리스·테스트 실행·1.0 이후 운영·완전성 비평.

### 유예·되살릴 조건 — 9

- [x] `go-release-persist-credentials` **[M/S · 닫힘 2026-09-11 · 계수 정정]** ⚠️ **「넷」이 아니라 셋이었다** — `contents: write` **이면서 체크아웃하는** 잡은 `dotnet-release:release` · `go-release:release` · `php-release:split` 뿐이다. ruby-release 의 `contents: write` 두 히트는 **헤더 주석의 산문**이고(「불필요하다」는 설명), 그것을 세는 것이 바로 열린 항목 `guard-probes-count-mentions-not-declarations` 가 말하는 부류다 — **등록부 자신이 그 오류를 저질렀다.** 기각은 살아 있다(전 워크플로 강제는 여전히 기각): 규칙 1b 의 범위를 기각이 지목한 **그 조인**(write 토큰 + 체크아웃)으로만 좁혔다. 가드 `check-ci-permissions.mjs` 규칙 1b + 공허 하한 `--min-write-checkout=3`. 변이 3/3 `CAUGHT`.
- [ ] `revive-conditions-unmeasured` **[M/M]** 되살릴 조건을 「돌아가는 명령」으로 적어 두고, 그 명령을 아무도 돌리지 않는다 — 기각 22건이 전부 수동 감시다 · `docs/governance/rejected.md:44`
- [ ] `sonar-tests-revive-instrument` **[M/M]** sonar.tests 되살릴 조건이 「색인 수가 유지되는가」인데 그 수를 아무도 기록하지 않는다 — 공허한 초록을 판별할 계측기가 없다 · `.github/workflows/sonarcloud.yml:22`
- [ ] `dependabot-ignore-joins` **[M/M]** 조건부 `ignore` 셋의 해제 조건이 다른 파일의 사실에 묶여 있는데 조인이 없다 — kotlin 하나만 기계가 본다 · `.github/dependabot.yml:79`
- [ ] `gate-substitutes-unasserted` **[M/L]** 기계 게이트가 없는 자리마다 「대신 이것이 본다」가 적혀 있는데, 그 대체물의 존재는 아무도 검사하지 않는다 · `sonar-project.properties:30`
- [ ] `sonar-suppression-premises` **[M/M]** sonar 억제 셋의 근거가 트리 안의 다른 사실에 묶여 있는데, 그 사실이 바뀌면 억제가 오탐이 아니라 진짜를 숨긴다 · `sonar-project.properties:200`
- [x] `vitest-v4-migration` **[L/M · 닫힘 2026-09-10 #450]** vitest 3에 묶인 유일한 이유가 테스트 두 파일의 `vi.mock` 클래스 팩토리 셋이었다 · `node/test/unit/client.test.ts:1`
- [ ] `tenth-language-deferrals` **[L/S]** 「10번째 언어가 들어올 때」가 여러 유예의 공통 트리거인데, 그때 무엇을 함께 해야 하는지가 한 곳에 없다 · `docs/guides/add-a-language-playbook.md:105`
- [ ] `release-readiness-remote-tag-print` **[L/S]** 릴리스 준비도 도구가 로컬 클론의 태그만 보고 「태그 없음」을 답한다 — 되살릴 조건은 두 값을 나란히 인쇄하는 것 · `scripts/release-readiness.sh:93`

### 미완 마커 — 3

- [ ] `harness-suites-untested-here-marker` **[M/M]** 하네스 스위트 4종(python·rust·ruby·kotlin)이 「미실행 검증(untested-here)」 마커를 단 채 스코어카드를 만든다 · `harness/suites/python.sh:6`
- [ ] `release-yml-unpaid-measurement` **[M/S]** release.yml 헤더의 「미납 실측」 블록이 전제(태그 미푸시)가 무너진 뒤에도 그대로 남아 있다 · `.github/workflows/release.yml:16`
- [ ] `install-verify-not-implemented-wording` **[L/S]** install-verify.sh의 유일한 TODO — not_implemented가 원인을 「언어 태스크 대기 중」으로 오귀속한다 · `harness/install/install-verify.sh:100`

### 로드맵·기능 갭 — 7

- [ ] `admin-relations-role-mapping-group-membership` **[H/L]** 역할 부여·그룹 가입이 9개 언어 어디에도 없다 — CRUD만 있고 리소스 간 연결이 없다 · `docs/reference/admin-capability.md:18`
- [ ] `admin-client-roles-and-user-subresources` **[H/L]** roles 파사드는 realm role 전용 — client role·client secret·user credential/session이 0/9 · `node/src/admin/roles.ts:5`
- [ ] `auth-ropc-password-grant` **[H/M]** ROPC(password) 그랜트가 SDK에 없어 9개 하네스 앱이 전부 raw HTTP로 손수 만든다 · `harness/apps/node/server.js:62`
- [ ] `auth-surface-parity-unguarded` **[M/M]** auth·oidc 공개 표면에 가드가 없어 3곳이 이미 갈렸다 — PHP만 logoutUrl, Kotlin만 userinfo, Ruby만 access_token · `php/src/AuthClient.php:161`
- [ ] `admin-family-scope-undeclared` **[M/S]** 파사드가 안 덮는 admin 리소스 패밀리 13종에 대한 '지원 범위' 선언이 어디에도 없다 · `docs/reference/admin-capability.md:12`
- [ ] `tenth-language-registration-registry` **[M/M]** 10번째 언어를 넣으려면 38개 파일의 언어 목록을 손으로 고쳐야 한다 — 등록 지점 레지스트리가 없다 · `scripts/check-admin-capability.mjs:23`
- [ ] `cross-cutting-http-capabilities` **[L/M]** User-Agent·프록시·재시도·로깅 훅이 9개 언어 전부 없다 — 횡단 HTTP 능력이 축에서 빠졌다 · `node/src/config.ts:7`

### CI·릴리스 미결 — 7

- [x] `go-consumer-floor-1-26-decision` **[M/S · 신규 2026-09-11 · 판정 2026-09-21]** `golang.org/x/oauth2 v0.37.0` 과 `golang.org/x/sync v0.23.0` 이 둘 다 `go 1.26.0` 을 선언해, 그 둘을 받으면 **소비자 하한이 1.25 → 1.26 으로 올라간다**(`go get` 이 스스로 `go.mod` 의 `go` 지시자를 올린다 — 실측). #453 이 그래서 실패했고 닫았고, #511 로 같은 것이 다시 왔다. ⚠️ **dependabot 잘못이 아니다** — 상류가 하한을 올린 것이고, dependabot 은 「하한을 안 올리는 선에서만」을 표현할 수 없다. **판정: 1.26 으로 올린다**(#511) — Go 지원창이 이미 1.25 를 제외한다(안정 1.27.x, 실측 `curl -s 'https://go.dev/dl/?mode=json'`). 하한과 함께 옮긴 자리: CI 매트릭스(1.27 레그는 staticcheck v0.7.0 이 막아 **한 레그**가 됐다) · `getting-started.md` 앵커(`published=1.25.0` — 게시된 `go/v1.0.0` 은 그대로 1.25 이고 상향은 다음 태그부터 닿는다) · 루트 README 미러 둘 · `go/README.md` · `.claude/rules/go.md` · 하네스 golang 이미지·go.mod 여섯 자리. 재현: `cd go && go get golang.org/x/oauth2@v0.37.0 && grep '^go ' go.mod`
- [ ] `dependabot-updater-failure-blind` **[M/M]** dependabot updater 잡의 실패가 어떤 CI 에도 안 보인다 — 실측 실패 2건 전부 무성 · `.github/dependabot.yml:123`
- [ ] `security-invariant-not-required` **[M/S · 절반 닫힘 2026-09-09]** Jackson 보안 불변식 잡이 required 밖이다 — **0건 스윕을 삼키던 절반은 #443 이 닫았다**(`-lt 47` 하한) · `.github/workflows/repo-hygiene.yml:277`
  - ⚠️ 인용 줄번호가 `:219` → `:277` 로 드리프트했다(재판정 2026-09-09). required 컨텍스트는 여전히 정확히 둘이다.
  - ⚠️ **required 이름을 늘리는 것이 답이 아니다** — `bypass_actors: []` 에서 생성되지 않는 체크 하나가 `main` 을 잠근다. 이 잡을 **`doc-facts` 안으로 접는** 쪽이 PR 크기다.
- [ ] `post-publish-version-verify` **[M/M]** 게시 후 「이 버전이 라이브인가」를 답하는 도구가 없다 — readiness 는 좌표 단위이고 태그가 있으면 즉시 return 한다 · `DEPLOY.md:428`
- [ ] `ci-lane-trigger-branch-filter` **[L/S]** 언어 CI 6개가 `branches:` 없이 push 트리거 — 태그·아카이브 ref·PR 브랜치에서 중복으로 돈다 · `.github/workflows/dotnet-ci.yml:3`
- [ ] `orphan-active-workflows` **[L/S]** 파일이 없는 워크플로 2개가 Actions 에 `active` 로 남아 있다 — 라이브 26 vs 커밋 24 · `.github/workflows/repo-hygiene.yml:207`
- [ ] `repo-settings-ssot-gap` **[L/S]** 브랜치 자동삭제 등 저장소 설정이 SSOT 밖 — 원격이 깨끗한 이유가 어디에도 안 적혀 있다 · `.github/security-config.json:2`

### 테스트 실행 갭 — 6

- [ ] `integration-coverage-never-measured` **[H/L]** 9개 언어가 "경계는 통합으로 검증"이라 적고 omit했지만, 통합 실행에서 커버리지를 재는 언어가 0개다 · `.github/workflows/ci.yml:42`
- [ ] `integration-admin-surface-uneven` **[H/M · 계수 정정 2026-09-09]** 9개 통합 스위트가 덮는 admin 표면이 제각각이다 — **clients.update 는 2/9**, realms.create/delete 는 4/9, PHP 는 roles·groups·realms 를 하나도 안 부른다
  - ⚠️ **1/9 이 아니라 2/9**(php·rust). 두 자리 다 등록부 작성보다 앞선다(`59c7916` #190 · `dc9efd7` #240) — 즉 **처음부터 틀린 계수**였다. 함께 잰 것: `users.update` 7/9(java·python 빠짐) · `clients.create` 6/9 · `roles.update`·`groups.update` 각 7/9(php·ruby 빠짐).
  - ⚠️ **PR 크기가 아니다** — php 가 roles/groups/realms 를 **0/3 계열** 부르는 것을 「구현할지 건너뛸지」가 9×capability 결정이고, 그 위에 Docker E2E 가 붙는다. · `java/keycloak-sdk/src/test/java/io/github/xzawed/keycloak/AdminOpsIT.java:48`
- [ ] `coverage-omit-overreach` **[M/M]** omit의 근거("단위테스트 불가한 네트워크 경계")가 실측으로 거짓이다 — Node는 이미 96.93%, Python은 98%인 코드를 게이트 밖에 두고 있다 · `node/vitest.config.ts:14`
- [ ] `coverage-threshold-parity` **[M/M]** 커버리지 임계값이 9언어에서 갈리고(브랜치 게이트가 아예 없는 곳 셋), 문서↔설정 대조 가드는 3개 언어만 본다 · `scripts/check-docs.mjs:552`
- [ ] `coverage-omit-no-ssot` **[M/M]** omit 목록이 열 곳에 손으로 중복 기재돼 있고 대조 가드가 0건 — Rust 제외 정규식은 앵커도 없다 · `java/pom.xml:151`
- [ ] `readme-quickstarts-ungated` **[M/M]** README가 정본이라 부르는 quickstart 예제가 어떤 게이트에도 안 걸린다 — 하네스가 실제로 돌리는 것은 별도 사본이다 · `node/examples/quickstart.ts:1`

### 1.0 이후 운영 — 9

- [ ] `audit-2026-09-22-doc-code` **[H/L · 신규 2026-09-22]** 전체 코드·문서 감사(17 독립 레그 + 3렌즈 반증) 결과 **91 건 중 57 건이 과반 반증을 견뎠고**, 그중 **13 건이 닫혔다(high 는 6/6 전부)** — 나머지 44 건(medium 31 · low 12 · 계수 1)이 열려 있다 · `docs/superpowers/plans/remaining-work.md:1`
  - **방법과 계수**: 발견 레그 17(횡단 8 + 언어별 9) → 91 건. 렌즈 3(증거 재도출 · 기지사실 · 오탐)이 각 건을 독립 판정 → **생존 57**(high 14 · medium 31 · low 12), **기각 34**. high 14 는 5 렌즈 심층 반증 또는 사람의 직접 확인을 거쳤다. 범주 분포와 레그별 산출은 이 항목을 만든 PR 이 소유한다.
  - **닫힌 13 건 — high 는 6/6**: #520(빈 JWKS 키셋) · #521(소비자 문서의 거짓 보안 문장 6 자리) · #523(rust 재노출 위반 둘 + 컴파일 집행 · node 커버리지 목록 · java jackson 산문) · #524(루트 README 영↔한 **구조** 미러 가드) · #527(예산 커버리지를 **부류 규칙**으로 — 숫자 하한은 마커를 지우는 PR 이 같은 diff 에서 내리면 그만이라 쓰지 않았다) · #528(CHANGELOG 착지 게이트 + `[Unreleased]` 28 건 복원). ⚠️ 무엇이 어떻게 닫혔는지는 **그 PR 의 커밋 메시지가 소유한다** — 여기 옮겨 적지 않는다(이 파일이 246 KB 까지 자란 원인이 그것이다).
  - **열린 medium 31 · low 12**: 언어별 drift 가 다수이고 **아홉 전부에서 최소 1 건**이 나왔다(범위 1–6). 대표: getting-started 의 「coverage gate」 주장이 go·rust·dotnet 세 곳에서 거짓(그 명령은 커버리지를 재지도 게이트하지도 않는다) · `php/composer.json:41` 의 `cs`/`cs:fix` 가 `--allow-risky=yes` 누락으로 **항상 실패** · `.claude/rules/{dotnet,ruby,php,rust}.md` 의 전사된 실측값이 낡아 다음 세션을 틀린 판단으로 이끈다 · PHP·Ruby 의 기본 `readTimeout` 이 10 초로 나머지 일곱(30 초)과 갈린다.
  - ✅ 위 계수가 **하한**이었던 이유는 아래 `critic-2026-09-22-round2` 가 소유한다(완전성 비평 6 각도, 2026-09-22).
- [ ] `critic-2026-09-22-round2` **[H/L · 신규 2026-09-22]** 1 라운드가 **무엇을 못 봤는가**를 6 각도로 찾고 3 렌즈로 반증(24 에이전트) → **32 건 중 24 건 생존**. **21 건을 닫고 2 건을 반증했으며 1 건이 열려 있다** · `docs/superpowers/plans/remaining-work.md:1`
  - **1 라운드가 못 본 부류가 실재했다** — 17 레그는 「문서 ↔ 코드」를 훑었고, 2 라운드는 **가드가 스스로 거짓말하는 자리**(미러 룰셋이 이름표만 · doctor 오진 둘 · `tableAt` 이 산문 버전을 버림 · `kind=dep` 단방향)와 **소비자가 문서대로 따라 하면 막히는 자리**(퀵스타트 403 · rust 설치로 컴파일 불가 · Kotlin 좌표 그림자)를 찾았다. 닫은 21 건은 #529·#530·#531·#532·#533·#535·#536·#537·#538 이 소유한다.
  - ⚠️ **반증 2 건은 더티 워킹트리를 읽은 결과였다.** 에이전트는 주 작업트리를 읽는데 거기엔 미커밋 WIP(Java 17→25)가 있었다 — 「세 문서가 다른 `--release`」는 그 `25` 대 커밋된 `17`(`git show origin/main:java/pom.xml`), 「6/3 vs 5/4」는 `5/4` 를 말하는 살아있는 문서가 없다. **다음 감사는 발견을 `git show origin/main:<path>` 로 되재고 시작한다.**
  - ⚠️ **측정기부터 대조군으로 검증할 것** — 이 환경의 plain `grep -P` 는 유니코드 범위를 못 써 한글 탐지에 **거짓 0** 을 냈다(`git grep -P` 로 재야 CONTRACT.md 18 줄이 나온다).
  - **열린 1 건**은 아래 `korean-api-docs-in-published-packages` 로 분리했다. 재개: `resumeFromRunId:'wf_6e357bb5-d55'`.
- [ ] `korean-api-docs-in-published-packages` **[M/H · 신규 2026-09-22 · 사람 판정 「등록만, 별건으로」]** 게시된 SDK 안의 **소비자에게 렌더링되는 문서 주석**이 한글이다 — docs.rs 가 그리고, IDE 호버에 뜨고, PyPI·RubyGems 페이지가 싣는 텍스트다 · `rust/src` 외 6
  - **실측**(2026-09-22, `git grep -P '[\x{AC00}-\x{D7A3}]'` · 문서 주석 문법만): rust 231 · python 298 · node 186 · ruby 158 · php 149 · go 122 · kotlin 70 = **7 언어 1,214 줄**. **java·dotnet 은 이미 0.** ⚠️ 구현 주석까지 세면 2,296 줄이지만 소비자에게 안 보이므로 대상이 아니다.
  - **왜 별건인가**: 게시 소스 7 개를 건드려 언어별 테스트와 착지 게이트를 전부 통과해야 하고, 공개 표면이라 되돌리기 어렵다. 번역 품질은 기계로 못 재므로 **언어당 PR 하나**가 리뷰 가능한 최소 단위다.
  - **착수 순서**: 노출이 가장 직접적인 rust(docs.rs)·node(`.d.ts` 호버) = 417 줄 먼저, 그다음 python·php·ruby·go·kotlin. **기각이 아니라 결정 대기다** — 다른 선택지는 「규칙에 게시 주석 한글 예외를 명시」였다.
- [ ] `remaining-work-split-to-archive-tag` **[H/M · 신규 2026-09-22 · 설계 완료]** 이 파일이 246 KB — 전체 문서 바이트의 **31 %**, 2 위의 3 배 — 이고 그중 41~59 %가 **이미 닫힌 70 건의 사후 서사**다. 예산 앵커도 없다 · `docs/superpowers/plans/remaining-work.md:1`. **설계는 끝났고(독립 레그 판정) 실행만 남았다:**
  - **어디로**: 닫힌 항목 본문은 **아카이브 git 태그**로 간다 — 이 저장소가 이미 완료 WBS·검증로그에 쓰는 장치다(`archive/docs-history-2026-08{,b,c}`). ⚠️ **`docs/` 아래 형제 문서(`remaining-work-closed.md`)로 빼면 안 된다** — 검사 9 가 그것을 `docs/README.md` 지도에 올리라고 강제하므로 세션이 여전히 적재하고 파일은 다시 자란다. CHANGELOG 도 아니다(그것은 릴리스 로그이지 검증 기록이 아니다). 삭제도 아니다 — 규약이 「이관, 삭제 아님」이다.
  - **무엇을 어디로**(한 부분을 두 집에 복사하지 않는다): **되살릴 조건**만 살아 남아 `docs/governance/rejected.md` 로 가되 **돌아가는 명령**으로만(산문 "reopen if X" 는 되살릴 조건이 아니다 — 명령으로 못 쓰면 본문과 함께 태그로 간다) · **닫힘을 정당화한 실측**은 항목과 함께 태그로 · **사후 서사**(PR 번호·경위)도 태그로. 살아 있는 등록부에는 태그를 가리키는 **포인터 한 줄**만.
  - **계수 앵커는 총계를 다시 맞추지 말 것** — 118 은 오늘의 열린 작업이라 매번 움직인다. 분할 후 단언할 것은 **`닫힘 = 0`** 이다. 그것은 이 파일의 **규칙**이므로 올리는 것이 재보정이 아니라 규칙 변경이 된다. (지도의 `진행` 규칙이 이미 「미체크가 하나는 남아야 한다」를 강제하므로 두 번째 수를 더 넣지 않는다.)
  - **재성장 방지**: 분할 커밋이 `doc-budget: max-bytes` 를 **이동 후 크기**로 박는다(246 KB 가 아니라). 이후 `main` 대비로 검사하고 **조일 수는 있어도 올릴 수는 없게** 한다 — 옵트인이라 이 파일이 한 번도 안 덮였던 것이 원인이므로, 이 경로만은 선택 사항이 아니다.
  - ⚠️ **`CHANGELOG.md` 의 빈 `[Unreleased]` 를 이 작업으로 채우지 말 것** — 다른 실패다(아래 항목). 70 건 본문이나 150 커밋에서 역으로 만들어 넣으면 그때 기록되지 않았던 이력을 **지어내는** 것이 된다.
- [ ] `changelog-unreleased-never-written` **[M/S · 신규 2026-09-22]** `## [Unreleased]` 가 빈 채 `v1.0.0` 이후 **150 커밋**이 main 에 들어왔다(실측 `git rev-list --count v1.0.0..origin/main`) · `CHANGELOG.md:8`. CLAUDE.md 가 완료 서사의 목적지로 지목한 자리가 아무것도 받지 않아 그 서사가 246 KB 등록부에 쌓인다. ⚠️ **150 건을 역채우지 않는다**(독립 레그 판정) — 그 절은 「착지할 때 적는 소비자 가시 변경」이지 커밋 제목 모음이 아니다. 이미 들어간 150 은 git 에 두고, 격차를 인정해야 한다면 `v1.0.0..HEAD` 를 가리키는 **헤딩 한 줄**만 두되 **재구성한 항목은 넣지 않는다**. 진짜 고칠 것은 「착지할 때 쓰게 만드는 장치」가 없다는 쪽이다.
- [ ] `jwks-empty-keyset-node` **[M/M · 신규 2026-09-22]** node 만 빈 JWKS 키셋 거부가 없다 — fetch·캐시를 jose 가 소유하기 때문이다 · `node/src/jwt.ts:55`. jose v6 의 reload 는 `local = createLocalJWKSet(json)` 를 무조건 실행하고 `isJwkSet()` 은 `{"keys":[]}` 를 받는다(실측: 좋은 토큰 검증 → 빈 200 → 같은 토큰 거부). ⚠️ **독립 레그 판정 — 래핑도 프리플라이트도 보장을 못 준다**: 반환된 `JWTVerifyGetKey` 를 감싸면 이미 덮인 **뒤에** 보게 되고(빈 집합과 「그 kid 가 없는 정상 집합」이 같은 오류로 나와 구분 불가), 우리가 따로 프리플라이트하면 **덮는 응답과 다른 응답**을 검사하게 된다. 같은 보장을 얻는 길은 `createRemoteJWKSet` 대신 `createLocalJWKSet` 위에 원격 집합을 **우리가 드는 것**뿐이고, 그러면 쿨다운·캐시수명·kid-miss 재조회를 우리가 소유한다(jose 의 원격 수정도 더는 상속하지 않는다). 구조 변경이라 #520 에서 분리했다. 되살릴 조건: 이 교환을 받아들일지 사람이 판정.
- [ ] `jwks-empty-keyset-jvm-dotnet-undetermined` **[M/S · 신규 2026-09-22]** java·kotlin(Nimbus `JWKSourceBuilder`)·dotnet(`ConfigurationManager`)이 빈 200 에 오염되는지 **판정되지 않았다** · `kotlin/src/main/kotlin/io/github/xzawed/keycloak/jwt.kt:29`. 캐시가 라이브러리 내부라 코드 읽기로는 결정할 수 없다. 실험(독립 레그 설계): **프로덕션 빌더를 그대로 태우고**(테스트용 캐시로 바꾸지 말 것) 리트리버 호출을 세며, 좋은 문서 → kid 해석 → 빈 200 → 카운터 증가 확인 → 같은 kid 재해석. ⚠️ **판정 행렬** — 두 번째 요청이 아예 없었으면 「면역」이 아니라 **판정 불가**다. dotnet 은 `BackoffConfigurationManager` 를 거치고 `RefreshInterval = 0` 으로 두 번째 호출이 삼켜지지 않게 한다. python 은 실측으로 면역이다(joserfc 가 대입 전에 `MissingKeyError`).
- [x] `nightly-failure-reaches-nobody` **[H/M · 신규 2026-09-16 · 닫힘 2026-09-21 #518]** 야간이 여드레 빨간 동안 아무 조치가 없었다 — 저장소 안에 **실패가 사람에게 가는 경로가 0건**이다 · `.github/workflows/harness.yml:8`
- [ ] `codeql-kotlin-extractor-lags-kgp` **[M/M · 신규 2026-09-21]** CodeQL 의 Kotlin 추출기가 KGP 를 못 따라와 **JVM 두 언어의 코드 스캐닝이 통째로 멈춘다** — KGP 2.4.20 에서 `KotlinVersionTooRecentError: Kotlin version 2.4.20 is too recent. CodeQL currently supports versions below 2.4.20` 로 autobuild 의 `:compileKotlin` 이 죽고, `java-kotlin` 은 Java 와 Kotlin 이 **한 데이터베이스**라 Java 분석까지 함께 사라진다 · PR #515 가 이것으로 막혀 있다(doc-facts 는 초록, CodeQL 만 빨강 — main 과 다른 PR 은 초록이라 원인이 KGP 범프임이 대조로 확정됐다). ⚠️ **CodeQL 은 required 가 아니라 병합은 된다** — 병합하면 main 이 조용히 빨개지고 아무도 스캔하지 않는 상태가 남는다(배포 시크릿 미설정을 스킵으로 끝내던 것과 같은 모양). ⚠️ 이 저장소의 CodeQL 은 `.github/workflows/` 에 파일이 없는 **default setup** 이라 번들을 핀하거나 앞당길 수 없다(실패 번들: CodeQL CLI 2.27.0). 되살릴 조건(명령): `gh run list --workflow=340524379 --limit 20 --json headBranch,conclusion --jq '.[]|select(.headBranch=="refs/pull/515/head")|.conclusion'` 가 `success` 를 낼 때 — 그때 #515 를 그대로 병합한다(문서 작업은 `e7f18f6` 에 이미 올라가 있다).
- [ ] `push-lane-failures-still-silent` **[M/S · 신규 2026-09-21]** `nightly-alert` 은 **`schedule` 만** 본다 — `sonarcloud` 처럼 push 로만 도는 레인의 빨강은 여전히 아무에게도 안 간다(실측: 09-16~09-21 닷새 무성, 그 창은 `nightly-failure-reaches-nobody` 의 야간 창과 **겹치지 않는다**) · `.github/workflows/nightly-alert.yml:38`. ⚠️ 그리고 `nightly-alert` **자기 실패는 못 잡는다**(`workflow_run` 은 자기를 감시 못 한다). schedule 로 넓힌 판정은 소음을 피하려던 것이라, 넓히려면 「민 사람이 이미 보는 실패」와 「main 에서 조용히 빨간 실패」를 가르는 기준이 먼저 필요하다.
- [ ] `registry-truth-check` **[H/M]** 게시 SSOT가 문서하고만 대조되고 실제 레지스트리와는 한 번도 대조되지 않는다 · `scripts/lib/deploy-facts.sh:138`
- [x] `stale-release-comments` **[H/S · 닫힘 2026-09-09 #447]** 릴리스 경로의 주석 **여섯**이 낡았고, 그중 하나는 다음 릴리스를 정반대로 오도했다 · `.github/workflows/install-smoke.yml:57`
- [x] `post-1-0-registry-missing` **[M/S]** 1.0 이후 잔여작업 등록부가 저장소 어디에도 없다 — 안 닫힌 항목은 복원 불가능하다 · `docs/README.md:49`
- [ ] `public-registry-install-smoke` **[M/L]** 게시된 1.0.0 을 공개 레지스트리에서 받아 설치·컴파일해 보는 정기 검증이 없다 · `harness/install/install-verify.sh:11`
- [ ] `advisory-path-never-run` **[M/M]** 보안 권고·회수 경로가 문서에만 있고 한 번도 실행된 적 없다 · `SECURITY.md:141`
- [ ] `divergence-rehearsal-artifact` **[M/M]** 함대가 갈리는 릴리스에서 새로 써야 하는 분기 문장 8건에 초안이 없다 · `scripts/test/test-publication-claims.sh:704`
- [ ] `keycloak-server-tag-ssot` **[M/L]** Keycloak 서버 태그가 18개 파일에 복제된 채 떠 있고, 호환성 표의 「actual 26.6.4」는 재현 불가한 스냅샷 · `docs/reference/compatibility.md:20`
- [ ] `harness-consume-pin-unsupported` **[L/S]** 주간 OSV 감사가 지원 대상이 아닌 0.1.0 트리를 재고 있다 · `harness/install/consume/kotlin-app/build.gradle.kts:36`
- [ ] `npm-rc-dist-tag-residue` **[L/S]** npm `rc` dist-tag 가 지원하지 않는 0.1.0-rc.2 를 아직 서빙한다 · `DEPLOY.md:503`

### 완전성 비평 신규 — 6

- [x] `runtime-eol-support-window` **[H/M]** 선언된 소비자 런타임 하한 둘이 상류 지원 종료다 — Ruby 3.2는 이미 EOL, .NET 8은 68일 뒤 · `ruby/keycloak-sdk.gemspec:20`
- [ ] `consumer-intake-surface-absent` **[M/S]** 9개 레지스트리에 게시했는데 소비자 유입 표면이 통째로 없다 — 이슈 템플릿·PR 템플릿·CODEOWNERS·행동강령 0건 · `.github/ISSUE_TEMPLATE:0`
- [ ] `harness-base-images-unmanaged` **[M/M · 절반 닫힘 2026-09-15]** 하네스 Docker 베이스 이미지 20개가 dependabot·가드 양쪽 밖 — 무핀 태그와 갈린 alpine이 섞여 있다 · `.github/dependabot.yml:134`
  - ✅ **절반 닫힘 2026-09-15 — 일관성 가드는 섰고 dependabot 은 열어 둔다.** ⚠️ **먼저 세었더니 수가 달랐다**: 「20개」는 **파일 수**이고 실제는 **20 파일 · 26 `FROM` · 13종**이다(픽스처 3개를 빼야 한다 — 처음 집계에 섞여 23/30/13 이 나왔다). 「무핀 태그」는 **`latest` 가 아니라 digest 미핀**을 뜻한다(모두 태그는 있다).
  - **주장 둘 다 실측으로 확인됐다**: dependabot 10 생태계에 **docker 없음**(0건) · 갈림을 잡는 가드 **0건**(프로브: 한 파일의 `alpine:3.20` → `3.22` 가 `check-versions.mjs`·`check-docs.mjs` **둘 다 SILENT**).
  - ⚠️ **다만 「가드 밖」은 절반만 참이다** — `check-versions.mjs` 는 `FROM` 을 읽는다. 단 **`rust:` 만**(`/^FROM\s+(?:--\S+\s+)*rust:(\d+(?:\.\d+)*)/`) 이고 `Cargo.toml` 의 `rust-version` 과 대조한다. 그래서 **rust 태그를 한 파일만 올리면 잡힌다**(MSRV 불일치로). 독립 레그가 그 정규식을 짚었고 실측이 일치했다. 가족 내 태그 통일·digest 핀은 어디에도 없다(`sha256` 검색 0건).
  - **실물 결함 하나를 고쳤다**: `alpine` 이 **3.20 둘(go·rust 앱) · 3.21 하나(php consume)** 로 갈려 있었다. 올려서 통일했다 — go·rust 의 alpine 단계는 `ca-certificates`+`adduser`+정적 바이너리 복사뿐이라 위험이 낮고, php 쪽은 `php83` 패키지 집합이 걸려 내리면 위험하다. ⚠️ **Docker 빌드는 여기서 돌리지 않았다**(하네스는 별도 게이트다).
  - **가드**: `scripts/test/test-base-images.sh`(repo-hygiene 배선, 5 단언) — 같은 저장소는 한 태그 · 떠다니는 태그 금지 · 공허 하한(`BI_MIN`) · 면제표(이유 강제 + 낡으면 실패). 변이 **3/3 CAUGHT**(갈림·떠다님·파싱 무력화, 각각 **격리해서**). ⚠️ `eclipse-temurin` 은 **jdk/jre 가 정당하게 갈려** 면제표에 이유와 함께 있다.
  - ⚠️ **하한을 짐작으로 15 를 박았다가 가드가 자기 자신을 빨갛게 했다**(실측 12). 등록부가 이미 경고한 부류다 — **세어서 박는다**. 그리고 상수를 검사와 문구 **두 곳**에 적어 갈렸다(조건 10 · 문구 15) — `BI_MIN` 변수 하나로 묶었다.
  - ⏸ **열어 두는 절반 — dependabot 의 `docker` 생태계.** 이 저장소는 전부 `directory:` 단수를 쓰고 Dockerfile 이 20개 디렉터리에 흩어져 있다. 추가하면 **주간 봇 PR 양**이 바뀌고, 이 리포는 이미 dependabot 잡이 빨개지는 소음을 겪었다(ruby `parallel` 사례). **봇 설정은 사람 판단이 붙는 자리**라 측정만 남기고 연다.
- [ ] `release-artifact-verification-undocumented` **[M/M]** 소비자가 게시물의 무결성을 확인할 방법이 문서에 0건 — 증명 수단이 레인마다 다른데 아무도 그 표를 쓰지 않았다 · `SECURITY.md:96`
- [ ] `dependency-license-claims-unverified` **[L/M]** CLAUDE.md가 아홉 스택 전부의 라이선스 호환을 단언하는데 CI에 라이선스 검사가 0건 · `CLAUDE.md:150`
- [ ] `repo-topics-omit-four-languages` **[L/S]** 저장소 topics가 아홉 언어 중 다섯만 담고 20개 한도를 소진했다 — 그리고 topics는 SSOT 밖이다 · `.github/security-config.json:2`

---

## 닫는 조건

전 항목이 체크되면 `doc-status` 를 `complete` 로 내리고(가드가 강제한다), 아카이브 태그로 내린 뒤 [지도](../../README.md) §3 에서 지운다. 기각으로 닫는 항목은 미체크로 남기고 [기각 레지스트리](../../governance/rejected.md)에 **되살릴 조건과 함께** 옮긴다 — 미체크가 0 이 아니어도 `complete` 로 내릴 수 있는 이유가 그것이다.
