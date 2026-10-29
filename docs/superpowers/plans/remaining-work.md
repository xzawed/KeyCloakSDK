<!-- doc-status: active -->
<!-- doc-budget: max-bytes=174781 max-raw-bytes=199954 -->
<!-- 193526 → 174781 (2026-10-28). 끝난 이력 다섯 — 2026-09-11 회고 · 2026-09-13 재발 원인 분석 · 2026-09-03 닫힌 표 ·
     착수 순서 · 예산 인상 기록 — 을 `git show 7a4763a:docs/superpowers/plans/remaining-work.md` 로 보냈다. 살아 있는
     규칙 중 다른 집이 없던 것만 진입점 함정 (a)–(f) · (ii)–(ll) 와 「읽는 법」으로 옮겼다 — 나머지는 이미 CLAUDE.md ·
     process.md · ci.md · kotlin.md · 각 항목과 시험 주석이 소유한다(손실 점검 레그 둘, 심은 대조군 4/4). 검사 8e 가 이 인하를 강제했다.
     max-raw-bytes 는 사람 판정이다(2026-10-28, 「등록부에만 건다」) — 분할(2026-09-22) 뒤 36 일 동안 적재는 거의
     그대로인데 블록 주석이 633 → 60,409B 로 늘었다. 이제 주석도 센다(검사 8f). 열린 항목의 긴 착수 메모와 경위는
     PR 본문으로 보내고 포인터만 남긴다. -->
# 잔여작업 등록부 — 2026-09-03 전수 감사 후속

**이 문서가 답하는 것 하나** — 「감사가 남긴 것 중 무엇이 아직 열려 있고, 각각을 **어떤 명령으로** 닫았다고 말할 수 있는가」.

> ⚠️ **닫힌 항목의 사후 서사와 끝난 회고는 여기 없다 — git 이 소유한다.**
> 2026-09-22 이관분(닫힌 70 건의 하위 서사)은 `git show archive/docs-history-2026-09:docs/superpowers/plans/remaining-work.md`,
> 2026-10-28 이관분(회고 2026-09-11 · 재발 원인 분석 2026-09-13 · 2026-09-03 닫힌 표 · 착수 순서 · 예산 인상 기록)은
> `git show 7a4763a:docs/superpowers/plans/remaining-work.md` 에 있다. 슬러그 하나의 서사는
> `git log -1 -S '<!-- <슬러그>' -- docs/superpowers/plans/remaining-work.md` 가 찾는 이관 커밋의 부모에 있다.
>
> **표제줄은 남긴다** — 열린 항목이 닫힌 슬러그를 선례로 인용한다. **닫은 항목에 하위 서사를 다시 붙이지 말 것** —
> `scripts/test/test-remaining-work-shape.sh` 가 「닫힌 항목이 소유한 줄 수 == 닫힌 항목 수」를 단언한다(들여쓴 줄도,
> 바로 뒤의 블록 주석도 센다). 열린 항목의 블록 주석(착수 정보)은 그 항목이 닫힐 때 함께 나간다. 이관은 git 으로만 한다 —
> 형제 문서(`remaining-work-closed.md` 따위)로 빼면 검사 9 가 지도에 올리게 해 다시 적재되고, CHANGELOG 는 릴리스 로그다.

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
⚠️ **이 표를 판정에 쓰지 말 것 — 세 줄이 서로 맞지 않는다.** 체크박스 전수는 `284`(2026-10-29 기준 열림 131 · 닫힘 153)인데 심각도·작업량 행의 합은 **153**이다. 어긋난 채로 커밋돼 있었고(2026-09-06 확인), 어느 쪽이 옳은지는 원장을 다시 세야 정해진다. ⚠️ **그리고 그 문장이 「위 두 명령을 돌린다」로 끝나 있었는데 위에는 명령이 없었다** — 세는 법을 지운 채 「세라」만 남은 자리였다(2026-09-16 정정). 세는 명령은 이것이다:

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
node scripts/check-docs.mjs . --strict --min-facts=78 --min-anchors=26 --min-anchor-links=24 --min-blob-refs=5 --min-count-anchors=4
git branch --show-current               # ⚠️ 아래 함정 (e)
```

⚠️ **`main` 이 아닌 브랜치에서 시작했다면 먼저 `main` 으로 간다** — 함정 (e)가 그것이다. ⚠️ **에이전트의 세션 메모리는 PC를 넘어가지 않는다.** 넘어가야 하는 것은 전부 이 문서와 `.claude/rules/*.md`·`docs/guides/development-setup.md` 에 있어야 하고, 새로 배운 것도 거기 적는다.

### 다음 세션 진입점 (2026-10-29 · #834–#880 반영)

**지금 상태** — 물결 6(2026-10-27/28): 아홉 전부 **LIVE**, 게시 바이트 = 태그 · 기준선 = 게시판(#863·#865). 월간 상한 경고(6/7)는 7·8 번째 게시를 막지 않았다(`ci.md`). 태그 위임은 물결마다 다시 묻는다. 열린 PR 은 Dependabot 뿐이어야 한다. 래퍼 9.8 의 되살릴 조건은 #682·#788.

열린 항목 수는 위 「규모」의 명령으로 센다. 게시 번호는 루트 `CLAUDE.md` 현재 상태 표가 소유한다. 릴리스 물결의 경위는 `CHANGELOG.md` 와 `git log --oneline d7439f5..HEAD` 가 소유한다.

**다음 순서** — ①초록이 거짓 → ②게시본 소비자 → ③잠복 → ④완결성 축 그대로.

1. 2026-10-29 판정의 수행(`grep -n '판정 2026-10-29'` 과 아래 「항목 없는 셋」) · 그다음 `response-framing-unbounded` 의 node·python · `wave4-hardening-php` 의 남은 칸.
2. `guard-detection-surface-hand-narrowed` [H/M](손 표 축 — 되살릴 조건) · `integration-coverage-never-measured` [H/L](go·python 파일럿 #774 의 CI 관측 셋 → 나머지 일곱).
3. ⚠️ **손대기 전에 전제를 잰다** — 이번에도 뒤집혔다: jwks 후보(「신선한 캐시가 없으면 센다」)는 600 초 경계에서 규칙 (4) 를 깼고, 「낡은 캐시 + 장애」는 node 하나가 아니라 node·.NET 이었고, probe.sh 초안 정규식은 지어낸 줄로 골라 실제 출력 셋을 못 맞췄다.

**판정 2026-10-29(사람 위임 「권장안」)** — 대기 판정이 모두 났다 — 항목 표제줄의 「판정 2026-10-29」와 그 주석이 소유한다(PM·Grok 대조는 #881 본문). 항목 없는 셋 — php 하한 `guzzle ^7.15.2`·`psr7 ^2.12.3`(composer.json 반영) · rust·node `raw()` 오류 본문 상한은 두지 않는다 · Dependabot PR 스캔 안 함(`rejected.md`). 2026-10-23 판정 둘 — commons-codec 은 1.15 유지(이유·이동 조건은 `.github/dependabot.yml` 의 ignore 주석) · sonarcloud 는 잡 분리(규칙 12 — 닫힘).

**함정** — 전부 그대로 유효하다. (a)–(i) 는 한 줄 요약이다(원문: (a)–(f) 는 2026-10-28 이관분의 「세션 회고」 절 끝(2026-09-05·06), (g)–(i) 와 더한 날은 git log).

- (a) **「사본이면 지운다」 전에 그것이 인접 판정의 입력인지 본다** — 앞뒤 문장의 유도 관계와 `git blame -L n-1,n+1` 로 같은 커밋인지(`18/20` 을 지우면 다음 줄의 「two branches」가 `20−18` 을 잃었다).
- (b) **「N 개가 전부」 전에 전수를 세고 계측기를 알려진 정답으로 먼저 잰다** — 줄단위 정규식은 인라인 플로우 맵(`matrix: { java: [...] }`)을, `git log -S'<속성이름>'` 은 값만 바뀐 커밋을 놓친다.
- (c) **가드 초록은 삭제·안전의 근거가 아니다** — 그 값을 읽는 스크립트가 0 건이면 「안전」이 아니라 「문서가 유일한 소재지」다.
- (d) **워크플로 뒤에는 `git rev-parse --show-toplevel` 부터** — 서브에이전트가 `.git/config` 에 `core.worktree` 를 써서 `git status` 가 거짓 clean 을 냈다.
- (e) **브랜치를 파기 전에 `git branch --show-current` + `gh pr list --head "$(git branch --show-current)" --state open`** — 열린 PR 의 브랜치 위에서 파서 그 diff 가 다음 PR 에 실려 나갔다. 스쿼시 저장소라 `git merge-base --is-ancestor` 로는 못 가린다 — PR 머지 상태와 `git log -S'<고유 문자열>' origin/main` 이 답한다.
- (f) **Grok 레그는 읽을 파일을 1–2 개로 묶거나 사실을 인라인으로 주고 「읽지 말라」 하며, 답 길이를 단어 수로 못박는다** — 비용은 도구가 아니라 탐색량이다. 타임아웃이면 `"PONG"` 한 번으로 연결과 추론량을 먼저 가른다.
- (g) 변이 미착지 — `probe.sh --site '<의도한 자리>'` 로 잡·함수 이름까지 좁혀 겨눈다(파일의 첫 매치가 다른 잡의 것이라 셋이 거짓 SILENT 였다) · (h) gradle 데몬 락 · (i) 컴파일 안 되는 변이는 INVALID.

- (j) **`scripts/probe.sh` 는 node·php·python 을 못 잰다**(워크트리에 의존성이 없다). 그 언어는 커밋한 뒤 의존성이 깔린 워크트리에서 파일 하나를 변이 → 테스트 → `git checkout -- <파일>` → `git status` 빈 것 확인.
- (k) **변이 대상은 줄 번호가 아니라 내용으로 고른다** — `| Java |` 가 툴체인 표에 먼저 나와 엉뚱한 줄을 겨눴다(probe 가 INVALID 로 막았다).
- (l) **커밋을 다른 브랜치로 옮기거나 `main` 을 합친 뒤에는 깨끗한 워크트리에서 `check-docs` 를 다시 돈다.** 옮기기 전 기준에서의 통과가 거짓이었고(#552 예산 초과가 그렇게 CI 로 샜다), 주 트리의 추적 안 되는 산출물(`.pytest_cache`·`harness/report`·`.github/modernize`)은 거짓 오류를 낸다: `git worktree add --detach <tmp> HEAD` 에서 돌린다.
- (m) **브랜치 전환에 `git stash`/`pop` 을 짝지어 쓰지 않는다** — 넣을 것이 없으면(추적 안 되는 파일뿐) `pop` 이 **옛 stash 를 푼다**. 실제로 위 JDK 실험 diff 가 풀려 다시 보관했다.
- (n) **`target/` 에 major 69 클래스가 남아 있으면 surefire 가 `UnsupportedClassVersionError`** — 위 실험의 잔재다. `mvn clean` 부터.
- (o) **YAML·문서를 grep 하는 가드는 주석을 먼저 벗기고, 값은 셀 경계까지 대조한다** — 맨 부분 문자열은 형제 값(`v*` ⊂ `kotlin-v*`, `…:keycloak-sdk` ⊂ `…-core`)과 주석 속 사본에 흡수된다(#552·#558). 문서 주석은 `check-docs.mjs` 의 `withoutHtmlComments`(CommonMark 블록 규칙 + 같은 줄 주석)로 벗긴다 — 문서 전체에 `/<!--[\s\S]*?-->/` 를 걸면 코드 스팬 `` `<!--` `` 에서 다음 줄까지 삼켜 주장이 사라지고 검사가 **조용히 건너뛴다**(#587).
- (p) **독립 레그(Grok)의 「면역·안전」 판정은 대조군으로 다시 잰다** — dotnet 빈 JWKS 를 「면역」이라 했으나 LKG 폴백이 가린 오염이었다(#551). 반대로 설계 비판·변이 목록 실행은 신뢰도가 높았다(주장 표본 전부 재현).
- (q) **레그의 우회 목록은 정적으로 재현한 뒤 런타임에서 한 번 더 거른다** — 6/6 이 정적으로 재현됐지만 둘(빈 기본값 · `unset`)은 빈 근거 거부와 `set -u` 로 fail-closed 라 약화가 아니었다(#571). 받을 것은 「통과하면서 약해지는 것」뿐이다.
- (r) **게이트를 `| tail` 로 보면 종료코드가 사라진다** — `check-docs … | tail -2; … && git commit && git push` 가 예산 초과를 push 했다(#574). `${PIPESTATUS[0]}` 로 받아 그 값으로 분기한다.
- (s) **dependabot 은 JVM 짝의 같은 좌표를 두 생태계로 따로 올린다** — doc-facts 가 문서 간 좌표를 한 버전으로 강제해 둘 다 빨갛다. 한 PR 로 합치고(#562) 남은 쪽은 `@dependabot rebase` 가 다시 만든다(#569 → #572). KGP 가 움직이면 `kgp-gradle-band` 도 kotlinlang.org 표로 다시 확인한다(가드가 요구한다).
- (t) **「앞 글자가 식별자·`.` 면 세지 않는다」 경계는 카나리아(테스트 선언)용이다** — 구조 표지에 걸면 멤버 접근(`url.searchParams.set('nonce'`)이 0 이 되어 required 체크가 정당한 코드를 막는다(#580 이 계수를 둘로 나눴다).
- (u) **변이 SILENT 가 곧 구멍은 아니다 — 관찰 가능한 행동이 남는지 먼저 따진다.** node 백오프 성공 리셋은 콜드 캐시만 셀 때 지워도 드러날 행동이 없었다(#743 뒤 낡은 캐시 축에서는 아니다 — 카나리아가 섰다), go 의 id_token 누락 검사는 지워도 `Validate("")` 가 같은 오류 타입으로 거부한다 — 그때 둘 다 동치 변이로 판정했다. **판정은 축이 늘면 다시 한다.** 반대로 **컴파일이 깨지는 변이는 INVALID** 다(go `vt` 미사용 — (i), 이제 `probe.sh` 가 막는다 #738).
- (v) **「부류를 닫았다」는 적대적 레그가 반증하지 못한 뒤에만 쓴다** — #585 첫 커밋의 재스캔은 Nimbus **값 타입 생성자**만 봤다. 계약과 코드만 받은(내 결론은 안 받은) Grok 레그가 **빌더 `build()` 의 redirect_uri 검사**가 남긴 누출을 인쇄로 증명했다.
- (w) **JVM 변이를 `probe.sh` 로 잴 때는 검사 명령을 래퍼로 감싸 실패한 테스트 이름과 컴파일 오류를 출력 끝에 모은다** — 근거로 보이는 것은 꼬리 12 줄이고 mvn·gradle 의 꼬리는 상투구라, 래퍼 없이는 CAUGHT 이 단언인지 컴파일 실패((i))인지 안 보인다.
- (x) **열린 PR 의 초록은 그 PR 기준점에서의 초록이다** — 기준점 뒤에 병합된 가드와 의미 충돌한다. #666 은 python 적대 행렬(#655)보다 앞선 기준점에서 초록이었고, `origin/main` 을 합치자 행렬이 7 FAIL 을 냈다(기전·변이·반증 판정은 #666 의 PR 코멘트). 병합 전 `origin/main` 을 합쳐 **언어 CI 를 다시 보고**, 같은 언어의 PR 둘(#658 행렬 · #663)은 하나를 병합한 뒤 나머지를 다시 잰다. CHANGELOG 만 바뀐 재푸시는 required 둘로 충분하다 — 언어 코드가 초록 실행과 같음을 `git diff --stat <초록 SHA> HEAD -- <lang>/` 가 빈 출력으로 보인다.
- (y) **Git Bash 는 `origin/main:<path>` 인자를 경로로 바꿔 `git show` 를 깨뜨린다** — `2>/dev/null` 이면 빈 출력이 「없다」로 읽힌다(아홉 언어 CI 의 `paths:` 가 전부 비어 보였다). `MSYS_NO_PATHCONV=1` 로 돌리고(그때 경로는 `/d/…` 가 아니라 `D:/…`), 알려진 파일 하나로 양성 대조를 먼저 찍는다.
- (z) **`git -C <워크트리> config <키>` 는 공용 `.git/config` 에 쓴다** — 워크트리 하나만 LF 로 받으려다 저장소 전체의 `core.autocrlf` 를 덮었다(2026-10-01, 되돌림). 명령 단위로 준다: `git -c core.autocrlf=false worktree add …`.
- (aa) **Edit·Write 툴은 백슬래시-u 이스케이프를 글자로 풀어 쓴다** — .NET 시험의 U+2028 이 컴파일을 깼고 python 소스에 U+2028·U+FEFF 가 박혔다(ruff RUF001). 그런 줄을 옮길 때는 `git merge-file --union`, 새로 쓸 때는 `chr(0x…)` 꼴.
- (bb) **`[no-changelog: …]` 표지 하나가 범위 전체의 착지 성장 검사를 끈다**(`scripts/test/test-changelog-landing.sh:150`) — `[Unreleased]` 를 키우는 브랜치에는 달지 않는다.
- (cc) **PHP `vendor/` 를 정션으로 걸면 Composer 오토로더가 원 트리의 `src` 를 읽는다** — 파스 오류를 넣은 워크트리가 「OK (21 tests)」를 냈다(2026-10-09). 변이·프로브 워크트리에는 `vendor/` 를 복사한다. node_modules 정션은 의존성만 풀어 안전하다(실측).
- (dd) **워크트리끼리(probe.sh 포함) `CARGO_TARGET_DIR` 을 같이 쓰면 소스가 더 오래된 쪽이 남이 지은 라이브러리를 돈다**(#768 · #844). 돌리기 전에 `.rs` 를 touch 하고 `-v` 에 `--crate-name keycloak_sdk` 의 lib 호출이 있는지 본다 — 「Compiling」 줄은 증거가 아니다.
- (ee) **스쿼시는 `git merge-base HEAD origin/main` 위에서** — `origin/main` 위에서 하면 그 사이 main 의 변경을 되돌린다(#774, 307 줄 삭제로 발견).
- (ff) **CHANGELOG 절을 옮긴 main 위로 rebase 하면 새 글머리가 충돌 없이 이웃 절로 들어간다** — #813 의 Ruby 항목이 Go `[1.2.3]` 안에 착지했다. rebase 뒤 새 글머리의 소속 절을 다시 본다.
- (gg) **Git Bash 의 UTF-8 로캘에서 `grep '🚀'` 는 0 줄이다** — `test-publication-claims.sh` 의 매트릭스 10 건이 거짓 실패한다. `LANG= LC_ALL= dash scripts/test/test-publication-claims.sh` 는 241/0.
- (hh) **에이전트는 주 작업트리를 읽는다** — 미커밋 WIP(Java 17→25)가 감사 발견 둘을 거짓 반증으로 만들었다(2026-09-22). 발견은 `git show origin/main:<path>` 로 되재고 시작한다(Git Bash 는 (y)).
- (ii) **게이트 결과는 마지막 편집 뒤의 것이어야 한다** — 「초록을 봤다」와 「지금 초록이다」는 다르다. 규칙 파일을 고친 뒤 `check-docs` 를, ruby 생성자를 더한 뒤 rubocop 을 안 돌려 CI 가 빨개졌고, 미커밋 압축 위에서 변이를 돌려 수정을 잃었다.
- (jj) **아홉 언어 공동 축의 보안 항목은 하나라도 「미측정」이면 닫지 않는다** — 먼저 아홉을 다 재고 이음매별로 항목을 쪼갠 뒤 착수한다(「우리 소스에 선언이 없다」로 잘라냈던 언어를 다시 재니 2/2 가 실제 구멍이었다).
- (kk) **규칙을 새로 쓰기 전에 도구가 거부하게 할 수 없는지 본다** — 존재를 요구하는 규칙(빠진 것이 빈 칸으로 보이는 것)은 구속하고 정확성을 요구하는 규칙은 구속하지 않았다(2026-09-13: 회고가 「어긴 것」으로 적은 다섯 중 넷이 바로 재발했다). 이미 있는데 어긴 규칙을 또 쓰지 않는다. 도구가 닫은 것은 변이 미착지(`probe.sh --site`) 하나이고, 동어반복 초록 · 싼 첫 명령 · 인터프리터 왕복은 규칙으로만 남아 있다.
- (ll) **소비자가 틀릴 수 있는데 HEAD 는 맞다면, 오라클은 트리가 아니라 태그·레지스트리다**(#415 · `check-docs.mjs` 의 `kind=runtime` 두 번째 오라클 주석) — 다른 주장에도 건다. 그때 적은 후보: 게시된 공개 API 표면 · 게시 매니페스트의 의존성 하한 · 릴리스 바이너리에 컴파일된 기능 · 배포 아티팩트의 라이선스 · 「vX 에 포함됨」류 CHANGELOG 결속.

## 읽는 법

각 항목은 근본원인 하나에 대응한다 — 같은 결함이 여러 줄·여러 언어에 걸친 것은 한 줄로 접혀 있다. `[H/M/L]` 은 심각도, `[S/M/L]` 은 작업량. **가드 없는 수정은 완료가 아니다** — 항목을 닫을 때 「다시 깨지면 CI 가 어떻게 잡는가」를 함께 남긴다([작업 프로세스](../../governance/process.md) ⑤⑥).

전체 근거·수정안·동반 가드·검증 명령은 기계용 원장에 있다: `ledger-dedup.json`(원장 209건) · 인벤토리 산출물(패키지 150건). 이 문서는 **무엇이 열려 있는가**만 소유한다.

⚠️ **기각된 제안은 이 등록부에 없다 — 의도적이다.** 게시 잡의 `environment:` 부재 · `workflow_dispatch` 우회 · admin-capability D열 무보호는 문서화된 설계이거나 되살릴 조건이 적힌 기각이다. 착수 전 [기각 레지스트리](../../governance/rejected.md)를 먼저 읽는다. ⚠️ **닫을 때마다 그 항목의 범위와 지목 줄을 먼저 다시 잰다** — 2026-09-04 재검증에서 손댄 7 항목이 전부 범위를 틀렸고 방향은 양쪽이었다(축소 1 → 7 언어 · 과장 「영영 안 닫힌다」). ⚠️ **되살리면 안 되는 것 둘** — `harness-consume-pin-unsupported` 의 `scripts/check-versions.mjs` 확장분과 `public-registry-install-smoke` 의 `harness/install/install-verify.sh:44` 는 각각 기각된 자리다. `rust-rustdoc-jwks-refetch-says-60` 은 **주석 문자열만** 고친다 — 두 줄 아래 `with_jwks_min_refetch_secs` 에 0 강제를 넣으면 또 다른 기각을 되살린다.

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

## B. 재검증 대상 — 52건 (열림 13)

3렌즈 통과, 원장은 개별 재실행을 하지 않았다. 이번 인벤토리에서 전량 파일 확인 — 기각 권고 0건.

### 재검증 · 언어 소스 — 38

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
- [x] `jvm-17-floor-never-shipped` **[H/M · 신규 2026-09-06 · 닫힘 2026-09-24]** 1.0.1 게시(Portal Publish 후 repo1 첫 404 → 약 10 분 뒤 200)로 닫았다 — 게시 바이트 **전부 major ≤ 61**(`node scripts/check-published-jvm-floor.mjs`; metadata 가 늦은 `-core` 는 jar 직접 16/16). API 기저선 1.0.0 → 1.0.1 은 같은 PR(DEPLOY §4 step 9)
- [x] `jvm-api-surface-pin-unguarded` **[H/S · 신규·닫힘 2026-09-23]** `-Xjdk-release`·`options.release` 를 읽는 가드가 0 개였다(부르는 다섯 자리가 **전부 주석**) — 지우면 major 는 61 그대로라 바이트코드 가드도 초록인데 JDK 17 소비자만 런타임에 죽는다 · `scripts/check-jvm-api-surface-pins.mjs`(변이 7/7 CAUGHT + OFF 짝 · 그중 둘은 독립 레그가 낸 구멍)
- [x] `write-token-persists-into-build` **[H/S · 신규·닫힘 2026-09-23]** 규칙 1b 가 `contents: write` 에만 걸려 `attestations: write` 잡의 자격증명 잔류를 못 봤고, ⚠️ **그 규칙은 자가테스트가 전혀 안 덮고 있었다** · `check-ci-permissions.mjs`(변이 4/4 · PR #550)
- [x] `published-jar-bytes-never-read` **[H/M · 신규·닫힘 2026-09-23]** 게시된 jar 를 받아 바이트를 읽는 호출 지점이 **0 개**였다 — 사슬이 태그에서 끊겨, 릴리스가 다른 JDK 로 빌드했거나 업로드가 부분 실패해도 저장소는 전부 초록이었다 · `scripts/check-published-jvm-floor.mjs` + `published-floor.yml`(예약·required 밖 · 변이 15/15 CAUGHT + OFF 짝 · 그중 하나는 **실제 repo1 바이트**로 CAUGHT · 실측 274 클래스, 1.0.0 부분만 세면 91 로 손측정과 일치 · ⚠️ 독립 리뷰 **BLOCK** 뒤 다섯 구멍 수정)
- [ ] `published-bytes-have-no-oracle` **[M/M · 신규 2026-09-06 · 범위 축소 2026-09-23]** 남은 것은 **다이제스트 동일성** — 게시 바이트를 읽는 것은 위 항목이 닫았고 「우리가 올린 그 바이트인가」는 못 닫았다
  - ⚠️ **봉인은 PR #550 이 놓았다(attest) — 검증은 아직이고, 첫 증명은 다음 릴리스에 생긴다.** 검증 설계는 아래 블록 주석 (f).

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

     (f) **봉인(PR #550, 2026-09-23 밤) — 놓인 것과 남은 것.**
         놓인 것: 두 JVM 릴리스 잡이 `actions/attest-build-provenance` 로 **배포한 그 바이트**를
         증명한다. ⚠️ **게시 뒤에 건다** — 앞이면 Maven 이 라이프사이클을 다시 돌아 서명한
         바이트와 올라간 바이트가 갈린다(두 빌드 다 재현 가능하지 않다). 실패해도 Portal 은
         스테이징일 뿐이고 공개는 사람이 누르므로 이 순서가 fail-closed 다.
         권한: `id-token: write` + `attestations: write`. 같은 목적을 Release 자산으로 하면
         `contents: write` 가 필요해 **더 큰 권한**이 된다 — 그래서 이 둘이 최소다.
         ⚠️ **기존 6 버전에는 소급되지 않는다. 첫 증명은 다음 릴리스에 생긴다.**

         남은 것(검증): 오라클이 Central 에서 받은 바이트의 다이제스트로 `gh attestation verify`.
         ⚠️ **반드시 `--signer-workflow` 로 서명자를 고정한다.** 안 하면 `attestations: write` 를
         가진 **아무 잡이나** Central 에서 내려받은 바이트를 재서명할 수 있고, 그러면 검사가
         「릴리스 빌드가 이것을 만들었다」에서 「누군가 Central 에 이미 있던 것을 재서명했다」로
         조용히 바뀐다(독립 레그 지목).
         ⚠️ 증명이 없는 옛 버전은 **건너뜀도 경고도 아니라 얼린 허용목록**이다 — 주간 경고는
         묵음되고, 건너뜀은 attest 단계를 지워도 초록이다. 허용목록은 스스로 자라지 못한다.
         ⚠️ **미검증 전제**: 「Portal 이 jar 바이트를 재포장하지 않는다」는 독립 레그의 주장이고
         **우리가 잰 적이 없다**(봉인 이전 버전으로는 잴 방법이 없다). 첫 증명이 생긴 릴리스에서
         그 전제가 처음으로 시험된다 — 틀렸다면 검증이 실패하므로 방향은 안전하다.

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
- [x] `public-client-confidential-grants-not-refused` **[M/M · 신규 2026-09-07 · 닫힘 2026-09-24]** 착수 조건대로 쟀더니(KC 26.6) **결함은 java·kotlin 쪽이었다** — 공개 클라이언트의 refresh 200 · logout 204(세션 실제 종료)인데 둘이 로컬에서 거부했다. 서버가 거부하는 client_credentials(401)·introspect(403)만 로컬 거부를 남겼다(진단 개선, 일곱은 흔들지 않는다) · 실서버 `AuthFlowIT`·`FullFlowIT` · 변이 java·kotlin CAUGHT
- [x] `go-tokenprovider-injection-missing` **[M/M · 닫힘 2026-09-09 #449]** Go의 TokenProvider 주입점이 문서에만 있고 실제로는 존재하지 않았다 · `go/tokenprovider.go:11`
- [x] `python-sync-admin-close-noop` **[M/S · 닫힘 2026-09-11]** sync `close()` 가 `return None` 이라 `requests.Session` 둘이 GC 까지 살아 있었다(aio 미러는 같은 자리에서 닫는다). ⚠️ **`test_close_is_noop` 이 그 결함을 「의도」로 고정**하고 있었으므로 테스트를 먼저 뒤집었다. 매니저 둘(`connection._s` · `connection.keycloak_openid.connection._s`)을 `finally` 계약으로 닫는다. ⚠️ **`async_s` 는 닫지 못한다** — sync 경로에서 `await` 가 불가하므로 과대광고하지 않는다. 변이 3/3 `CAUGHT`. ⚠️ 「중첩 매니저 부재」는 **도달 불가**라 테스트하지 않는다 — `harden_admin` 이 생성자에서 지연 프로퍼티를 실체화하며 fail-closed 한다(그 예제를 써 보니 `AdminClient(...)` 생성 자체가 거부됐다).
- [x] `python-sync-authorization-url-unencoded` **[M/S · 닫힘 2026-09-07 #442]** Python 동기 authorization_url이 퍼센트 인코딩 없이 URL을 조립했다 — async 미러는 `urlencode`를 쓴다 · `python/src/keycloak_sdk/auth.py:151`
- [x] `php-sensitiveparameter-methods-missing` **[M/S · 닫힘 2026-09-11 · 계수 정정]** PHP `#[\SensitiveParameter]` 가 생성자에만 붙어 있었다. ⚠️ **「여섯 메서드」가 아니라 아홉 파라미터였다** — 손 목록 대신 반사 가드를 세우자 `TokenSet::__construct($idToken)` 이 드러났다(생성자인데도 빠져 있었다). 가드 `tests/Unit/SensitiveParameterTest.php` 는 `php/src` 를 반사해 **문자열 타입 + 비밀 이름** 파라미터를 스스로 찾으므로 새 자리가 생겨도 목록을 고칠 필요가 없다. 변이 5/5 `CAUGHT`(공허 대조군 포함). 실측: 속성 없는 인자는 스택트레이스에 원문(`refresh('SUPER-SECRET-RE...')`), 있으면 `Object(SensitiveParameterValue)`.
- [x] `authorization-request-verifier-unmasked` **[M/M]** AuthorizationRequest.codeVerifier가 마스킹 없이 평문 출력된다 (Go·Node) — 같은 파일의 TokenSet은 마스킹한다 · `go/tokens.go:86`
- [ ] `coverage-exclusion-hides-untested-branches` **[M/M]** 네트워크 경계 커버리지 제외가 손으로 쓴 실패 분기와 미호출 공개 메서드를 숨긴다 (Kotlin·PHP) · `kotlin/src/main/kotlin/io/github/xzawed/keycloak/admin/Users.kt:47`
- [x] `redirect-uri-signature-parity` **[L/M · 닫힘 2026-09-12 · 중복이었다]** ⚠️ **이 항목은 `authz-redirect-uri-not-per-call` 과 같은 것을 다른 이름으로 적은 것이다** — 등록부에 한 부류가 두 행으로 있었고(이름·심각도·지목줄이 달라 서로를 못 알아봤다: 여기는 `rust/src/auth.rs:96` · 저기는 `:106`), 그래서 **한쪽만 보면 범위를 절반으로 읽는다**. 실제로 그렇게 됐다 — 「다음 대상」에 오른 쪽은 인가요청만 적었고 `exchangeCode` 비대칭은 이 행에만 있었다. 같은 PR 이 둘을 닫는다. ⚠️ **교훈**: 새 항목을 적기 전에 **부류로** 검색할 것(이름으로만 찾으면 중복이 남는다).
- [x] `python-config-comment-says-60` **[L/S]** python config 주석이 JWKS 재조회 기본값을 60초라고 적었다 — 두 줄 아래 실제 값은 30.0 · `python/src/keycloak_sdk/config.py:23`

### 재검증 · 가드/CI/문서 — 14

- [x] `selftest-enforcer-cannot-guard-itself` **[H/M]** 자가테스트 종료코드 규약의 집행자가 자기 자신과 '실패 삼킴'을 못 본다 · `scripts/test/test-selftest-hygiene.sh:19`
- [ ] `guard-detection-surface-hand-narrowed` **[H/M · 계수 정정 2026-09-07 · 손 목록 셋 닫힘 2026-09-23]** 가드의 탐지 표면이 손으로 좁혀져 있어 새 자리·새 문법이 조용히 통과한다 · `scripts/test/test-security-defaults.sh:311`
  - ⏳ **새 교환 경로 축 — 설계 확정, Go 파일럿 완료(2026-09-27).**
    - **모양.** 언어마다 `HostilePathMatrix` 단위 테스트를 둔다. 덤프 걷기가 닿는 타입의 공개 메서드 전부와 소스에 선언된 공개 메서드의 합집합을 기록하는 가짜 IdP 위에서 부른다. 그리고 실제로 보낸 요청으로 가른다: `CODE_EXCHANGE`·`TOKEN_GRANT`·`JWKS_FETCH`·`OTHER`·`NONE`. 요청 없이 실패하면 `UNDETERMINED` 이고, 이유 없는 면제는 실패다.
    - **계급별 적대 변형(W3).** 붙이는 곳은 손 목록이 아니라 계급이다.
      - 토큰 부여·코드 교환 행: 형식이 깨진 토큰 응답을 받으면 SDK 오류로 끝나야 한다. 카나리아가 새면 안 되고, 토큰 뒤로 나아가도 안 되며, 정상 응답 대조보다 토큰 요청이 많아서도 안 된다.
      - nonce 파라미터가 있는 교환 행: 대상은 go/parser 로 서명에서 파생한다. nonce 가 다름 · 다른 키(같은 kid·다른 kid) · id_token 없음 · nonce 클레임 없음을 모두 거부해야 한다. nonce 이름이 아닌 교환 행은 이유 있는 면제가 있어야만 빠진다.
      - JWKS 조회 행: 콜드 캐시에서 503 을 5 번 받는 동안 `/certs` 요청이 `1 ≤ hits ≤ 4` 여야 한다.
    - **손 목록 포함(W1).** 파생 집합은 기존 손 테스트와 보안 기본값 가드의 Go 앵커를 전부 담아야 한다. 알려진 틈(`hpKnownGaps`)은 0 이고, 낡은 항목은 실패한다.
    - **여덟 언어 이식 완료(2026-09-27).** #654–#661 이고, java #658 만 병합 대기다. 언어마다 Grok 레그를 거쳤고 필수 변이 여섯은 전부 CAUGHT 였다.
      - KNOWN_GAPS 가 SDK 결함 셋을 드러냈다(#685–#688 이 닫음): `php-admin-token-error-unsanitized` · `jvm-admin-token-response-type-unchecked` · `python-admin-grant-accepts-empty-access-token`.
      - dotnet 의 로컬 고부하 일시 실패는 CI 로 가렸다(8 회 연속 초록).
    - ✅ **attest(판정 2026-10-29 · 측정은 PR 본문).** 행렬이 모든 단언 뒤에만 `<lang>.json` 을 쓰고 레인이 같은 nonce 로 `scripts/check-hp-attest.mjs` 를 돌린다(비-required) — 필터로 빠지면 1.
<!-- known-gaps 대조(#773): scripts/check-known-gaps.mjs · 실제 트리는 비-required known-gaps-join 잡, 픽스처 자가테스트는 doc-facts. 정적 대조의 남은 틈 둘(리터럴 접두가 아닌 id · 넘겨받은 함수가 채운 목록)은 attest 의 knownGaps(런타임 값)가 닫는다. 남은 것: 레인 paths: 에 W1 이 읽는 test-security-defaults.sh·등록부가 없다 · 레인에서 attest 단계를 지워도 아무것도 울지 않는다(배선 대조 없음). 맵 키 꼴 id 는 node :271 'content-type': 오탐 때문에 기각(PHP 밖 언어가 id 키 묶음을 쓰면 선언문 안으로 좁혀 되살린다). -->
    - **Go 재는 명령.** `go -C go test -run TestHostilePathMatrix -v ./...` — 판정표와 요약이 찍힌다. 변이는 모두 `CAUGHT` 였다: nonce 비교 삭제 · 백오프 우회 · 빈 access_token 검사 삭제 · 캐시 선가열 · 적대 응답을 정상으로 교체 · 검사 없는 새 grant 메서드 · 서명 검증 생략 · 원인 스크럽 우회 · nonce 클레임 누락 허용.
    - ⚠️ **잴 때 함정 둘.**
      - 문자열 인자는 가짜 IdP 키로 **서명한 JWS** 여야 한다. 평문이면 `Validate` 가 요청 전에 실패해 `JWKS_FETCH` 가 빈다.
      - 토큰 응답의 `expires_in` 은 skew(30s)보다 짧아야 한다. 300 이면 캐시가 부여 경로를 가려 `TOKEN_GRANT` 29→3 이 된다.
    - **한계.** 요청도 오류도 없이 끝나는 경로는 `NONE` 으로 읽힌다(Grok 레그 실측). 목록은 파일 머리 주석이 소유한다.
  - ✅ **대조 없는 손 목록 셋을 닫았다(#542).** `scripts/` 의 9 언어 손 목록을 전수로 재니 파생과 대조되는 것은 `SD_LANGS` 하나뿐이었다. 나머지 셋(`SD_TOKEN_TYPE_LANGS` · `_GS_ORDER` · 출처 게이트 루프)은 **아무와도 대조되지 않아 열 번째 언어가 그 축을 조용히 건너뛴다**. 각각 `SD_LANGS`·`DEPLOY_LANGS`·(consume 파생 ↔ `DEPLOY_LANGS`)와 대조하게 했다. ⚠️ 출처 게이트를 **파생 하나로만** 두지 않았다 — 그러면 스크립트를 지우는 것이 곧 축을 줄이는 길이 된다. 변이 3/3 CAUGHT.
  - ⚠️ **파생으로 바꾼 첫 축 — 「언어 집합」(2026-09-12).** 되살릴 조건이 요구한 오탐 실측을 **nightly 한 창이 아니라 `main` 이력 전수로** 답했다: 커밋 475 중 `SD_LANGS` 가 존재한 **281 건에서 불일치 0**(kotlin 이 아홉째로 들어온 구간 포함). 재현 `sh scripts/measure-lang-universe-fp.sh`(자가테스트 양성·음성·공허 8/8, repo-hygiene 배선). ⚠️ **대조군이 `9 == 9` 라 구조적으로 공허했다** — `assert_eq "9" "$_seen"` 의 `_seen` 은 `SD_LANGS` 자신을 센 수다. 실측 프로브: 최상위에 빌드파일을 가진 디렉터리를 하나 주입해도 `244 passed, 0 failed`(열 번째 언어는 보안 기본값 커버리지 0 으로 들어온다). ⚠️ **파생 원천 선택이 이 항목의 핵심이고, 내 첫 직관이 틀렸다** — 독립 레그가 `.claude/rules/*.md` 를 기각했다(이미 비언어 둘을 얻었다: `ci.md` 2026-08-06 · `security.md` 2026-08-17 · 삭제 이력 0 — 다음 횡단 규칙 파일 하나가 **모든 PR 을 막는다**). `harness/apps/*/` 는 플레이북 Stage 5 라 구조적으로 늦고(아홉 전부 SDK 디렉터리가 먼저 · kotlin 하루·java 사흘), `check-versions.mjs --list` 는 설계상 **7** 이라 오늘 main 을 빨갛게 한다. 채택은 **최상위 디렉터리 중 자기 루트에 빌드 매니페스트를 가진 것**(오늘 정확히 아홉). 잔여 오탐 하나(`website/package.json` 류 — 같은 커밋에서 목록을 늘리면 된다)와 잔여 거짓음성(매니페스트가 목록에 없는 Swift·Elixir)은 축 주석이 적는다.
  - ⚠️ **재도전 결과(2026-09-13) — 다섯 주장 모두 실재하나, 내가 기록한 증거는 위치 편향이었다.** 감사가 「구조적으로 볼 수 없다」고 한 모드를 표본으로 쳤다. `assert.sh` 는 fail-fast 가 아니라 **누적**하고 `probe.sh` 는 꼬리만 찍었으므로, 한 변이가 여러 축을 넘어뜨릴 때 **물리적으로 마지막** 단언이 범인으로 기록됐다. 실측: `SD_LANGS` 에서 java 를 빼면 **7건**이 함께 실패하는데(새 단언은 132행, 마스킹 축은 563행) 꼬리는 마스킹만 보여 **과소** 평가했고, `DEPLOY_LANGS` 에서 php 를 빼면 **10건**이 실패하는데 새 단언이 280행(마지막)이라 9행이 잡은 것을 새 단언의 공으로 **과대** 평가했다. **양방향 편향이다.** ⚠️ 그래서 중간에 「다른 단언이 잡았다」고 낸 내 결론도 **같은 깨진 계측기로 낸 과잉 정정**이었다. 고친 뒤 격리 변이로 다시 재니 **6/7 이 실패 단언 정확히 1건**이고 그것이 의도한 단언이었다(⑦ ruby 는 `assert.sh` 형식이 아니라 계수 없음 — probe 가 그것을 명시한다). **다섯 축은 전부 실재한다.**
  - ✅ **(A) 부류의 마지막 손 목록도 닫았다 — 소스 주석 축의 글롭 아홉(2026-09-12).** ⚠️ **독립 레그가 지목했고 실측이 맞다고 했다** — `SD_LANGS` 를 파생으로 바꿔도 `SD_SRC` 는 `git ls-files 'java/*.java' … 'kotlin/*.kt'` 로 **경로 글롭 아홉을 손으로** 적고 있어 열 번째 언어의 소스는 이 축에 못 들어왔다. **더 나쁜 것은 기존 언어도 조용히 빠졌다는 것**이다: `scripts/probe.sh` 로 kotlin 글롭 하나를 지우니 **SILENT**(셋을 지워야 비로소 걸렸다 — 총 히트 하한이 `-ge 8` 인데 아홉이 기여하므로 하나가 빠져도 8 이 남는다). 처방은 하한을 올리는 것이 **아니다**(정당한 삭제에 오탐이 난다) — 스캔 집합을 `SD_LANGS` 에서 파생하고 **언어별 기여(파일 ≥ 1)** 를 따로 단언한다. 총 히트 하한 8 은 **그대로 둔다**(다른 양을 센다: 스캔된 파일 vs 값을 말하는 주석 줄 — 레그의 지적). 변이 재측정: 확장자 필터에서 `kt` 제거 `CAUGHT` · 파생 루프가 kotlin 건너뜀 `CAUGHT`(수정 전 같은 계급은 `SILENT`). 파생은 `node/src`·`rust/src` 로만 좁혀 두었던 비대칭도 없앤다 — 확장으로 더해지는 넷(examples 둘 · vitest 설정 둘)은 축의 대상 패턴을 **한 번도 담지 않는다**(required 체크라 확인).
  - ✅ **(A) 부류 완결 — 뿌리였던 `DEPLOY_LANGS` 를 트리에 못 박았다(2026-09-12).** ⚠️ **직전 판에 내가 적은 「하네스 손목록 둘이 무보호」는 절반 틀렸다** — `test-deploy-facts.sh:264-269` 의 `check_langset` 이 **네 사본**(`harness/verify.sh` 의 `LANGS=` 와 Usage 주석 · `install-verify.sh` 의 `DEFAULT_LANGS` 와 Usage 주석)을 이미 `DEPLOY_LANGS` 와 대조하고 있었다. 진짜 구멍은 **뿌리**였다: `DEPLOY_LANGS` 자신이 트리와 대조되지 않아, 열 번째 언어가 들어와도 **다섯이 서로 정합한 채 조용하다**(실측: 추적된 `zig/` 를 심고 아무 목록도 안 고치니 `probe.sh` → `SILENT`). `scripts/lib/deploy-facts.sh` 에 `df_tree_langs` 를 두고 `test-deploy-facts.sh` 가 뿌리를 대조한다 — 사본 넷은 기존 `check_langset` 이 전파한다. ⚠️ **파생은 `git ls-files`(index 인지)여야 한다** — 처음 쓴 `git ls-tree HEAD` 는 커밋된 것만 봐서 스테이징된 새 언어를 놓쳤다(실측). 자매 가드와 같은 관용이어야 둘이 같은 순간에 말한다. ⚠️ **음성 대조군이 또 필요했다** — 파생을 정답 상수로 바꾸면 `SILENT` 였다(보안 가드에서 난 것과 **같은 구멍이 같은 방식으로** 났다). 변이 3/3 `CAUGHT`(10번째 언어 · 뿌리에서 언어 제거 · 파생 no-op).
  - ✅ **(B) 부류의 첫 자리를 닫았다 — 설정 타입의 마스킹(2026-09-12).** ⚠️ **비밀 보유 타입은 `TokenSet`·인가요청 둘이 아니었다 — 셋째가 `KeycloakConfig`(client_secret)이고 아홉 언어 전부다.** 독립 레그의 공개타입 전수가 지목했고 실측이 확인했다: config 마스킹을 원문 노출로 되돌리는 변이가 **4/4 `SILENT`**(go·kotlin·python·ruby) — 1d 가 닫은 것과 **같은 모양의 구멍**이다(1c/1d 앵커가 각자의 타입 전용이라 설정 타입은 어느 축에도 없었다). 소비자가 기동 시 설정을 로깅하는 것이 흔해 노출 경로가 넓다. ⚠️ **처방대로 「그 파일에 축을 더하지」 않았다** — 별도 가드 `scripts/test/test-config-masking.sh`(repo-hygiene 배선, 30 단언). 언어 집합은 `df_tree_langs` 로 **파생**해 손 목록을 또 만들지 않았다(열 번째 언어는 표가 비어 실패한다). ⚠️ **java 는 계약이 다르다** — 마스킹 훅이 없고 안전 근거가 「필드를 안 찍는 기본 `toString`」이라, 겨눈 것은 훅이 아니라 **「record 로 바뀌지 않았다」**(1d 가 java `AuthorizationUrlRequest` 에 쓰는 것과 같은 모양). 변이 **9/9 `CAUGHT`**(수정 전 같은 변이 4/4 `SILENT`) + 음성 대조군(앵커를 지운 사본에서 안 잡히는지).
  - ⏸ **(B) 에 남은 것 — 레그가 함께 찾은 자리들.** ~~`ClientCredentialsTokenProvider` 의 기본 덤프가 캐시된 액세스 토큰을 찍는다~~ — 닫혔다(ruby `inspect` #490 · php `__debugInfo`, 재측정 2026-09-26). 같은 부류가 **파사드**에 남아 있었다 — `go-facade-dump-leaks-secret` · `php-facade-dump-leaks-secret`. 그리고 java 의 `Pkce`(verifier 보유) · `KeycloakConfig.Builder`(char[] secret) · `InMemoryTokenStore` 가 전부 「기본 toString 이 필드를 안 찍는다」에만 기대고 있어 record 화가 조용히 통과한다. ⚠️ **그리고 덮은 타입에도 바닥 밖 경로가 남는다** — python `asdict` · php `var_dump` · go `%#v`/`json.Marshal` · .NET Serilog `{@}`. 이것들은 「축이 정한 바닥(기본 문자열/디버그 표현)」 **밖**이므로 바닥을 넓힐지부터 사람이 판정해야 한다.
  - ✅ **(B) 잔여 java 타입들은 오경보였다 — 실측이 그렇게 갈랐다(2026-09-13).** 등록부가 「java `Pkce`·`KeycloakConfig.Builder`·`InMemoryTokenStore` 가 기본 toString 에만 기대 record 화가 조용히 통과한다」고 적었는데, **record 화만으로는 새지 않는다**. JDK 21 실행 측정: `record R(char[] s)` 는 `Arrays.toString` 이 아니라 **배열 identity**(`[C@7c41…`)를 찍고, `CodeVerifier` 와 상위 `Secret` 은 **`toString` 을 선언하지 않으며**(바이트코드 확인), `TokenSet` 을 담은 타입은 중첩 마스킹이 탄다. kotlin provider 의 `cached` 는 **본문 프로퍼티**라 `data class` toString 에 애초에 안 들어간다. **원문을 찍는 것은 비밀이 `String` 인 경우뿐이고, 그 타입(`AuthorizationUrlRequest`)은 이미 1d 가 가드한다.** ⚠️ **가드를 하나 더 세울 뻔했고 그것은 required 체크의 오탐이 됐을 것이다** — 「record 가 아니다」는 대리지표라, 위 넷에 걸면 **안 새는 변경을 빨갛게** 내고 「record + 마스킹 toString」이라는 **정당한 해법까지 막는다**(독립 레그 지목, 내가 실행으로 확인).
  - ⚠️ **그 과정에서 내 가드의 거짓 전제가 드러났다** — `test-config-masking.sh` 의 java 분기가 「record 가 되면 컴파일러 toString 이 clientSecret 을 찍는다」고 적었는데 **거짓이다**(`char[]` 이라 identity 다). 단언은 남기되(진짜 위험은 **record + 비밀을 String 으로** 바꾸는 **조합**이고 모양 변화가 그 보이는 절반이다) 근거를 정정했다. 1d 의 같은 문장은 `AuthorizationUrlRequest.codeVerifier` 가 `String` 이라 **참이다**.
  - ✅ **대신 행위 검열을 언어 로컬에 세웠다** — `KeycloakConfigTest#toString_doesNotLeakClientSecret` · `#builderToString_doesNotLeakClientSecret`(java 16 → 18). 모양이 아니라 **비밀이 찍히는가**를 본다. 프로브 확인: **모양은 그대로 둔 채 손으로 쓴 누출 `toString`** 을 심으면 `CAUGHT`(모양 단언은 그것을 못 잡는다). `Builder` 는 가변이라 record 가 될 수 없어 모양 단언 자체가 무의미하고, 행위 검열만이 유일한 장치다.
  - ⚠️ **그 축의 첫 판은 `SILENT` 였다 — 파생이 no-op 여도 통과했다.** `sd_tree_langs` 를 **정답 상수**로 바꾸면 초록이다(`scripts/probe.sh` 실측). 「지금 일치한다」만 보는 단언의 고질이고, 이 파일이 `sd_default`·`sd_skew` 에 대해 이미 적어 둔 부류다. 언어 집합이 **다른** 임시 저장소에서 파생이 다른 답을 내는지 보는 음성 대조군으로 닫았다(재측정 `CAUGHT`). ⚠️ **그 SILENT 에 닿기까지 변이 둘이 `CAUGHT` 로 위장했다** — perl 이 치환문의 `$SD_LANGS` 를 **자기 변수로 보간**해 빈 문자열을 만들었고(공허 가드가 잡아 `CAUGHT` 로 보였다), `q{}` 는 **perl 문법을 셸 파일에** 그대로 써 넣었다. 셋째 변이에서야 참값이 나왔다. **변이는 착지 여부가 아니라 「무엇이 됐는지」를 봐야 한다**(함정 (i)).
  - ⏸ **남은 것은 (B) 부류다 — 「기존 언어에 새 자리가 생겼다」.** 이번에 닫은 것은 (A)「새 언어가 손 목록에 안 들어왔다」뿐이다. (B) 가 83파일 노이즈를 가진 그 부류이고, 되살릴 조건도 그쪽을 겨눈 것이다. ⚠️ **독립 레그가 (B) 의 자리를 하나 더 찾았다**: `SD_SRC`(`test-security-defaults.sh` 의 소스 주석 축)는 `git ls-files` 지만 **아홉 개 글롭이 손으로 박혀 있다** — 열 번째 언어의 주석은 `SD_LANGS` 를 고쳐도 그 축에 못 들어온다. 같은 모양이 `harness/verify.sh:5` · `harness/install/install-verify.sh:37` 에도 있다.
  - ✅ **(B) 부류의 첫 자리를 닫았다 — 2차 정의 자리를 파생으로(2026-09-16).** 축 3 은 앵커 **넷**(go·php·ruby·ruby-skew)만 봤고, 1절은 언어당 한 파일 한 줄을 `sed | head -1` 로 읽어 **둘째 줄을 구조적으로 못 본다**. 실측: `node/src/jwt.ts` 에 `probeJwksMinRefetchSeconds = 60` 을 심으면 **SILENT**. 처방은 「정의 자리는 하나」가 아니라 **「어디에 적히든 값은 같다」**다 — SDK 소스 전체에서 두 파라미터에 숫자 리터럴을 대입하는 자리를 찾아 1절이 합의시킨 값과 대조한다(정당한 2차 자리를 막지 않는다). 합의값은 숫자로 안 적는다 — 그러면 **이 축 자신이 2차 정의 자리**가 된다. **오탐 실측**: 최근 **300 커밋**(2026-08-14~09-16 = 30 합의 이후 전 구간) **0 건**. **계측기 대조군**: 전 이력 1102 커밋으로 넓히면 **664 커밋이 60 으로 걸린다**(합의 이전 시기) — 침묵이 아니라 오늘 갈림이 없는 것이다. 오늘 히트 **20**(9언어 전부 기여), 공허 하한은 **창 최저값 20**(오늘 값이 아니다 — #443 판정). 변이 4/4 `CAUGHT` + OFF 짝(main 판 가드) `SILENT`.
  - ⚠️ **같은 PR 이 손 표 하나를 지웠다 — 중복이 됐기 때문이다.** `sd_skew_secondary`(dotnet·python)는 파생이 같은 두 자리를 값으로 잡는다(손 표를 죽이고 python 을 60 으로 → `CAUGHT`). 반대로 **손 표만 죽이면 `SILENT`** 였고 그것이 중복 게이트의 정의다. 그 표의 지식(**dotnet 은 1절이 읽는 `JwtValidator.cs` 가 아니라 `KeycloakConfig.cs` 가 소비자 값**)은 주석으로 남겼다.
  - ⏸ **(B) 의 잔여** — 닫은 것은 **1절·3절이 소유한 두 파라미터**(JWKS 재조회 · clock skew)뿐이다. 나머지 축(크기상한·nonce·백오프·마스킹 둘·토큰타입)은 **여전히 손 표**라 같은 부류가 그대로 있다. 다음 자리는 그 축들에 같은 「값 동형」 파생을 적용할 수 있는지다.
  - ✅ **크기상한 축을 닫았다(2026-09-25).** 실측 `main` 에서 넷 다 SILENT: JVM 두 줄은 `grep -c 'DEFAULT_HTTP_SIZE_LIMIT'` 인데 그 토큰이 **바로 위 doc 주석에도** 있어 생성자 인자를 `0` 으로 바꿔도(#400 결함 그대로) 초록 · `sed | head -1` 은 주석 속 옛 선언을 먼저 읽음 · 다른 파일의 둘째 선언은 안 봄. → 주석 뺀 줄 · 인자 **자리** · 3절식 값 동형 파생(오탐 이력 122 커밋 0 건, 하한 6 은 창 최저값). 독립 레그가 우회 넷(`…LIMIT * 100` · 인자 안 블록 주석 · `51200 << 10` · `*=`)과 오탐 하나(꼬리 주석 속 대입)를 냈고 다섯 다 재현 → 대조군. ⚠️ 빈 키셋 축은 주석 줄만 걸렀다(꼬리 주석은 못 거른다). **남은 손 표: nonce · 백오프 · 마스킹 둘 · 토큰타입.**
  - ✅ **남은 넷도 비공허 앵커로 옮겼다(2026-09-25, #578 · #580 · #582).** 모형 하나로 수렴했다: 구조 표지는 **주석 밖 ≥ 1**, 행위 테스트 카나리아는 **주석 밖 정확히 1 회**(`파일|선언`, 경로마다 한 줄). `main` 실측 SILENT 였던 것: 카나리아가 형제에 흡수(go `assertMasked` 8 회 · node 3 회 · go 인가요청 7 회) · 주석 속 훅 사본 · `xit` 로 건너뛴 테스트 · 선언 이름 표지라 **호출 삭제**가 통과(nonce·백오프). ⚠️ 호출 삭제 자체는 이 가드가 아니라 **언어 CI 의 행위 테스트**가 잡는다 — 그 테스트가 없던 java·rust nonce(#577)·토큰타입(node #579 · go·java·kotlin #581)을 먼저 세웠다.
  - ⏸ **열린 채 남는 것** — 이 부류의 (B) 「기존 언어에 **새 자리**가 생겼다」는 값 동형이 서는 숫자 축(재조회·skew·크기상한)만 파생으로 닫혔다. 마스킹·nonce·백오프·토큰타입은 앵커가 비공허해졌을 뿐 **새 비밀 보유 타입·새 교환 경로**를 스스로 찾지 못한다. 줄 단위라 다음 줄의 skip 표지(`#[ignore]`·`@Disabled`·데코레이터)도 못 본다. 닫으려면 「새 자리」를 트리에서 파생할 술어가 필요하다(예: 공개 타입 중 비밀 필드를 가진 것 전수).
  - ✅ **첫 파생 술어 — Go, 이름 grep 이 아니라 행위로(2026-09-26 #592).** 공개 API 호출로 만든 뿌리에서 리플렉션으로 닿는 패키지 타입 전부를 fmt 다섯 동사·slog 두 핸들러로 찍어 카나리아를 찾고, 소스를 파싱한 **구조체 선언 전수**가 걷기에 걸렸는지 대조한다(새 타입은 걷기에 닿거나 이유와 함께 면제 — 면제 0). 언어 CI 안이라 required 를 잠그지 않는다. 첫 실행이 실제 누출을 냈다(`go-facade-dump-leaks-secret`). 선행 전수(9 언어 · 독자+비판자 18): 기본 표현으로 새는 파사드는 go 뿐이었다. ⚠️ **한계**: 카나리아는 뿌리 호출이 흘린 비밀뿐이다. **남은 것**: 같은 모양을 여덟 언어에(리플렉션 없는 rust 는 다른 모양) · nonce·백오프·토큰타입의 「새 교환 경로」는 이 술어 밖.
  - ✅ **둘째 — PHP(#593).** 같은 모양을 `ReflectionObject` 로 — 인스턴스 상태 없는 클래스는 규칙으로 제외, 면제 1(이유 적음). ⚠️ 예외 뿌리는 트레이스 인자에 **하네스**(PHPUnit 러너 프레임의 테스트 객체·비정적 클로저의 `$this`)가 실려 첫 RED 172 가 대부분 거짓이었다 — 하네스 상태를 정적으로, 클로저를 `static fn` 으로. 고칠 수 없는 누출은 `KNOWN_LEAKS`(낡으면 실패)로 드러낸 채 고정했다. **남은 일곱**: java·kotlin·python·node·dotnet·ruby·rust.
  - ✅ **아홉 전부 — 나머지 일곱(#596–#602).** 언어마다 워크트리 하나에서 같은 모양을 세웠다(java·kotlin·python·node·dotnet·ruby 는 리플렉션 걷기, rust 는 리플렉션이 없어 **Debug/Display 를 구현한 타입 전수를 소스에서 파생**하고 파사드가 Debug 를 갖지 않음을 단언). 언어마다 변이 4–13건 전부 CAUGHT(kotlin 하네스 규칙 하나는 지금 뿌리에 대해 등가 변이), 구현마다 Grok 독립 레그가 붙어 걷기가 놓치던 자리(JDK 프록시 핸들러·익명 클래스·부분 노출·enum 새 변형 등)를 메웠다. 걷기가 찾은 실제 누출은 node 하나 — `node-error-cause-carries-response-tokens`. **남은 것**: 이 술어는 **마스킹 축의 새 자리**를 닫는다. nonce·백오프·토큰타입의 「새 교환 경로」와 줄 단위 skip 표지는 여전히 밖이다.
  - ⚠️ **또 늘었다 — 축 9 중 손 표 7 → 축 11 중 손 표 9 → 축 12 중 파생 3 · 혼합 1 · 손 8**(재측정 2026-09-16 · 직전 판 2026-09-12 는 독립 레그와 일치했다). 그 사이 추가된 축 둘(JWKS 크기상한 · 토큰응답 타입검증)이 **둘 다 손 표**다. 파생은 여전히 `git ls-files` 둘뿐. 배너 전수: `grep -cE '^# [0-9]+[a-z0-9]*\) ' scripts/test/test-security-defaults.sh` → **11**. ⚠️ `'^# [0-9]'` 로 세면 **15** 가 나온다 — 숫자로 시작하는 산문 넉 줄(「30초로…」 등)이 섞인다. ⚠️ 그리고 **축 이름이 이미 충돌한다**(`1b` 셋 · `1c` 둘) — 「축 N」으로 지목하지 말고 줄번호로 지목할 것. ⚠️ **처방은 그대로다**(이 파일에 축을 더하지 않는다) — 이번 PR 도 새 불변식을 여기가 아니라 `check-versions.mjs` 로 냈다.
  - **축 7 중 손 표 5 → 축 9 중 손 표 7 로 늘었다**(실측 2026-09-07, 독립 레그 둘). 그 사이 추가된 축 둘 — 1b2 콜드캐시 백오프 · 1d 형제 마스킹(#437) — 이 **둘 다 손 표**다. 파생은 여전히 `git ls-files` 둘(문서 축·소스 주석 축)뿐이다.
  - ⚠️ **그런데 지금 파생으로 바꾸는 것이 옳은 수가 아니다.** 이 파일은 required 체크 `doc-facts` 안에서 `paths:` 필터 없이 돌고 룰셋은 `bypass_actors: []` 다 — 오탐 하나가 모든 PR 을 막고 소유자도 못 푼다. **되살릴 조건**: required **밖**(nightly 등)에서 먼저 돌려 오탐 0 을 실측할 것. 노이즈는 이미 쟀다 — 9언어 비테스트 소스에서 비밀 이름을 언급하는 파일이 **83개**라 그 신호를 그대로 쓸 수 없다.
  - ⚠️ **당장의 처방은 「이 파일에 축을 더 늘리지 않는 것」이다** — 두 번 늘어난 것이 그 증거다. 새 불변식은 별도 가드로 내고(예: `test-osv-audit-gate.sh`), 언어별 값은 언어 로컬 테스트로 민다.
  - ⚠️ **지목이 마스킹 축 하나를 가리키지만 체계적이다** — 가드의 **7축 중 5축**(1 코드/skew · 1b nonce · 1c 마스킹 · 3 2차자리 · 4 소유자)이 언어별 파일·앵커를 손으로 열거한다. 새 언어·새 자리가 생기면 `_seen == 9` 류의 대조군이 함께 늘지 않는 한 조용히 통과한다.
  - 참고: 2026-09-04 에 추가한 2b(소스 주석) 축은 `git ls-files` 로 전체를 훑어 이 부류를 피했다 — 같은 형태가 나머지 축의 목표다.

- [x] `jwks-response-size-unbounded-non-jvm` **[M/M · php·ruby 닫힘 2026-09-11]** JWKS 응답 크기 상한이 Go·Java·Kotlin 에만 있었다(rust 는 #440). php·ruby 에 51200 상한을 넣고, php 는 **상태 검사보다 먼저 본문을 슬러프하던 순서**도 함께 뒤집었다. 가드는 `test-security-defaults.sh` 의 「JWKS 크기상한」 축 — 변이 6/6 `CAUGHT`. ⚠️ **미측정으로 남겼던 셋을 그 다음에 쟀고, 둘이 실제 구멍이었다** — node 는 닫혔고(아래) python 은 열려 있다: `jwks-response-size-unbounded-python` 참조. **「측정되지 않았다」를 「아마 괜찮다」로 읽지 말 것 — 재 보니 2/2 가 구멍이었다.**
- [x] `node-jwks-response-size-unbounded` **[M/S · 닫힘 2026-09-11]** jose 에는 상한이 **없다**(6.2.12 실측 · `dist/webapi/jwks/remote.js:10-26`: `GET` → status 200 → `response.json()` 이 전부. `Content-Length` 검사도 최대 바이트 옵션도 없고 유일한 중단은 `AbortSignal.timeout` 5초). `createRemoteJWKSet` 의 `[customFetch]` 이음매로 우리가 상한을 건다 — **JWKS 전용**이라 토큰·introspect 경로는 그대로다. 변이 4/4 `CAUGHT`. ⚠️ **첫 판 테스트가 거짓 초록이었다** — 거대 본문을 쓰레기 바이트로 만들었더니 상한이 없어도 JSON 파싱이 실패해 「거부됐다」가 통과했다. 본문을 **유효한 JWKS + 패딩**으로 바꿔야 상한 없이는 검증이 성공하고, 그때 비로소 거부가 증거가 된다.
- [x] `jwks-response-size-unbounded-python` **[M/M · 닫힘 2026-09-12 · 부류 완결]** ⚠️ **9언어 JWKS 크기상한 부류의 마지막 이음매**였다(축 6 → **7**). 구현 `_internal/jwks_fetch.py`(sync·aio 공용) — 상류를 우회해 JWKS **요청 하나만** 스트리밍 GET 한다.
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
<!-- facade-wiring-close-contract-unasserted: #774 의 통합 미실행 목록이 go NewAdminClient(소비자 provider 배선 — 단위 omit 경계 파일 admin.go)의 소유자로 이 항목을 쓴다(PM 수용 — 제목이 파사드 provider 배선 일반이다). 이 항목을 닫으면 scripts/integration-coverage.json 의 소유자도 옮겨야 한다(check 가 닫힌 소유자를 잡는다). -->
- [x] `python-aio-security-test-asymmetry` **[M/M · 닫힘 2026-09-12 · 범위 6 → 8]** 착수 전 재판정이 **또 넓혔다** — `security.md` 가 명시한 백오프 두 성질(**성공이 카운터를 되돌린다**·**클레임 실패는 재조회가 아니다**)이 DoS 속성인데 1차 재판정에서 비보안으로 분류돼 있었다. ⚠️ **aio 프로덕션 코드는 여덟을 이미 갖고 있었다** — 이 PR 은 행동을 바꾸지 않고 **고정**한다(고정되지 않은 성질은 다음 리팩터에서 조용히 사라진다). 변이 6/6 `CAUGHT`(alg 핀에 ES256 몰래 추가 · rate-limit 게이트 삭제 · 백오프 성공리셋 제거 · 클레임실패 억제 제거 · verifier 마스킹 제거 · urlencode 무인코딩화). ⚠️ **남은 비보안 비대칭 넷은 열어 둔다**(`constructs_real_openid_when_not_injected`·`injected_openid_is_used_verbatim`·`wrap_passes_through_successful_result`·`wrap_translates_error_with_response_code_but_no_json_body`) — 보안 축이 아니고, 그 넷까지 미러링하는 것은 **동형성 항목**이지 이 항목이 아니다. 옛 서술:

## C. 품질 부채 — 132건 (열림 66)

low 강등분 + 아무 배치도 담당하지 않았던 harness 사각지대 14건.

### 9언어 소스 — 70

- [x] `authz-redirect-uri-not-per-call` **[M/M · 닫힘 2026-09-12 · 사람 판정 (a)]** php·rust 만 인가요청과 교환의 `redirect_uri` 를 호출당 받지 못했다 — §4 판정 「표기가 아니라 능력의 차이이니 API 를 맞춘다」로 둘 다 가산적으로 맞췄다. 사후 서사는 `git show 8d7316c:docs/superpowers/plans/remaining-work.md` 522행

- [x] `jwks-refetch-budget-overclaimed` **[M/M · 닫힘 2026-09-07]** JWKS 재조회 예산 문서가 실제보다 강하게 약속했다 — cold 로드가 예산을 안 쓴다 · `rust/src/jwks.rs:34-49`
- [x] `jwks-response-not-validated` **[M/M · 닫힘 2026-09-07 #440]** JWKS 응답을 검증 없이 신뢰했다 — JVM 둘의 본문 크기 무제한은 #400 이 `DEFAULT_HTTP_SIZE_LIMIT` 를 되살려 닫았고, **Rust 의 상태코드 미확인은 #440 이 닫았다**(그 전 실측: `error_for_status`·`.status()` **0건**) · `rust/src/jwks.rs:34`
- [ ] `authcode-flow-verification-defeated` **[M/L]** 인가 코드 흐름의 검증이 무력하거나 오적용된다 — azp 미검증·iss 자기주입·공유 검증기 · `java/keycloak-sdk-auth/src/main/java/io/github/xzawed/keycloak/auth/AuthClient.java:135-149`
- [x] `lenient-parsing-yields-false-success` **[M/M · 닫힘 2026-09-12 · 부류 다섯]** ⚠️ **rust 하나가 아니라 다섯이었다** — 아홉 전수 측정 뒤 rust·python·ruby·php·**dotnet** 을 함께 고쳤다(아래 표가 근거). 불변식: **`access_token` 이 비어 있지 않은 JSON 문자열이 아니면 TokenSet 을 만들지 않는다.** ⚠️ **dotnet 은 문자열 검사로 못 잡는다** — Duende 가 이미 강제변환한 뒤라 원본 JSON 의 `ValueKind` 를 봐야 한다. ⚠️ **`expires_in` 의 문자열 허용은 건드리지 않았다**(php·ruby 가 테스트로 고정한 의도된 관용). ⚠️ **팩토리만 지키면 우회된다 — 재스캔이 이음매를 셋 더 찾았다**(독립 레그가 첫 둘을 지목): **ruby·php 의 AuthClient 경로는 팩토리를 지나지 않고 생성자를 직접 부른다**(`auth_client.rb` 의 `to_token_set` · `AuthClient.php` 의 `toTokenSet`) → 검증을 **생성자로** 내렸다. 그리고 **rust `auth.rs:to_token_set` 은 타입은 안전하나 빈 문자열을 통과**시켜 `exchange_code`/`refresh` 가 쓸 수 없는 토큰으로 성공했다 → `Result` 로 바꿨다. python·dotnet 은 생성 자리가 하나뿐임을 재스캔으로 확인했다. 가드: `test-security-defaults.sh` 축 1c(9언어·공허 하한 9). 변이 7/7 `CAUGHT`. ⚠️ **축 앵커가 두 종류인 것은 의도다** — 고친 다섯은 행동 테스트, 이미 옳던 넷은 집행 기제(소스 철자를 겨누면 동작이 같은 리팩터에도 빨개진다: 실측 rust `Value::as_str` → `|v| v.as_str()`).
- [ ] `nimbus-type-on-public-surface` **[L/M]** JWSAlgorithm이 두 JVM SDK의 공개 팩토리 시그니처에 올라 있다 — §4 은닉 위반 · `java/keycloak-sdk-auth/src/main/java/io/github/xzawed/keycloak/auth/JwtValidator.java:27-28`
  - **같은 부류의 둘째 자리(2026-09-27, kotlin 코드 교환 레그).** `TokenValidationException` 의 원인 사슬에 Nimbus `BadJOSEException` 이 그대로 남는다(java 도 같다고 레그가 보고). 측정한 경우에서 토큰 조각은 찍히지 않았다 — 비밀 누출이 아니라 §4 「하위 타입은 경계에서 변환」의 문제다. #617–#624 의 원인 스크럽이 이 예외 경로도 덮는지부터 잰다. 셋째 자리(java 레그 2026-10-05): admin 토큰 400·응답 없는 전송 실패의 원인 사슬에 jakarta `ProcessingException` 이 남는다(토큰 인용 없음).
- [ ] `configured-timeout-not-propagated` **[L/M]** 설정한 타임아웃·취소 토큰이 JWKS/검증 경로에 도달하지 않는다 · `node/src/jwt.ts:47-51`
- [ ] `close-path-leaks` **[L/M]** 정리 경로가 자원을 놓친다 — 실패 시 중단·생성 중 누락·미소유 executor · `go/admin.go:66-68`
- [ ] `node-nonsdk-error-escapes` **[L/S]** Node의 두 공개 경로가 SDK 예외 계층 밖의 오류를 던진다 · `node/src/admin/call.ts:13-26`
<!-- node-nonsdk-error-escapes 2026-10-05(node 물결 4 구현 레그): admin 쓰기의 representation 을 JSON 으로 못 쓰면 raw TypeError 가 공개 API 로 나온다 — users.update·create(순환) 「Converting circular structure to JSON」, BigInt 속성 「Do not know how to serialize a BigInt」 · isSdkError false · admin 요청 0 · 토큰 인용 없음. call() 이 HTTP·전송 밖 오류를 그대로 던지는 것은 admin-call.test.ts 가 고정한 계약이다. .NET 은 #714 가 같은 부류를 KeycloakTransportException 으로 바꿨다. -->
- [ ] `rust-admin-error-cause-flattened` **[L/M]** Rust에서 admin 토큰 실패의 원인이 가짜 401로 뭉개져 사라진다 · `rust/src/admin.rs:146-151`
<!-- 2026-10-05(rust 물결 4 구현 레그): 새 토큰 응답 상한도 같은 길로 뭉개진다 — admin 레인 32 MiB → 「admin error: admin HTTP 401」, provider 를 직접 부르면 Transport("token response …"). 파사드의 `send` 가 토큰 오류를 버리고 401 로 낸다(#844 전에는 SdkTokenSupplier 가 HttpFailure{401, text} 로 싸고 map_admin 이 text 를 버렸다 — raw() 는 지금도 그렇다). 형제: rust-admin-unreachable-classified-admin. -->
- [ ] `error-message-surface-unspecified` **[L/M]** 오류 메시지 표면에 규약이 없다 — 서버 본문 원문 삽입과 한글 메시지. 토큰 제시자가 고른 `kid` 도 줄바꿈째 실린다(.NET IDX10503, 실측) · `dotnet/src/Xzawed.Keycloak.Sdk/Admin/AdminClient.cs:95-101`
<!-- 2026-10-03 #710 재스캔(.NET): JwtValidator.cs:122/127 이 ErrorCause.MessageOf(IdentityModel 예외)로 메시지를 만든다 — kid "k\nINJ-FORGED-LINE" → Message·ToString 에 INJ. kid 는 IdP 가 아니라 토큰을 내민 쪽이 고른다(로그 위조). alg·iss·aud 의 LF 는 메시지에 안 닿았다. admin 타입 경로 AdminClient.cs:66/74 (ErrorDescription 원문, LF 그대로)·raw 경로 :98-100 (본문 통째) 도 실측. 다른 여덟 언어의 kid 인용은 미측정. 2026-10-05 물결 4 레그: .NET admin 오류 본문이 KeycloakAdminException 메시지에 원문으로 실려, 받은 bearer 를 되울리는 admin 서버면 그것을 찍는다(SendRawAsync·IdFromLocationAsync 의 MapHttpError, raw·타입드 401·404 16/16 LEAK=bearer, 6f23931 도 같음 — 보낸 bearer 를 가릴지 php 처럼 본문을 버릴지 판정). go AdminError.Msg 도 apiErr.Message 를 그대로 싣는다(admin.go:178, 카나리아 1 히트 — cause.go 는 토큰·introspection 레인만 정화). · 2026-10-09 (secret-echo JVM 구현 레그): java getKeycloakError() 가 admin 리소스 오류 본문을 그대로 돌려준다 — 그 요청은 Bearer 를 실었다(되울리면 남는다). -->
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
- [x] `python-admin-grant-guard-install-time` **[L/S · 닫힘 2026-10-03 #708]** 하드닝이 생성 때만 걸렸다 — 이제 `connection` 을 읽을 때마다 살아 있는 연결에 다시 건다. 남은 틈은 `python-admin-guard-send-time`
- [x] `php-oauth-error-code-trailing-newline` **[L/S · 닫힘 2026-10-03 #705]** `$`(D 없음)가 끝 줄바꿈 앞에서도 맞았다 — `\A…\z`. 같은 부류의 .NET 은 #710
- [x] `jvm-admin-token-guard-buffers-whole-body` **[L/S · 닫힘 2026-10-03 #711 #712]** 상한 1 MiB·`readNBytes` — 후보였던 JWKS 상한 51,200 은 KC 기본이 받는 bearer(65,459B, 실측)보다 작아 기각
- [x] `token-response-size-unbounded` **[M/M · 닫힘 2026-10-05 #714–#723]** 아홉 언어가 토큰 응답을 1,048,576 B 까지만 받는다 — 가드는 #724 의 축 1e. 상한 밖에서 읽히는 바이트는 아래 신규 셋
- [x] `jwks-forced-refetch-window-burned` **[M/S · 닫힘 2026-10-05 #714 #715 #717 #719 #720 #721]** 호출자 취소는 창을 쓰지 않는다
- [x] `dotnet-unpaired-surrogate-escapes` **[M/S · 닫힘 2026-10-05 #714]** 디코드·인코딩 못 하는 값이 SDK 예외가 됐다
- [ ] `jvm-admin-token-guard-residuals` **[L/S · 신규 2026-10-03 · java·kotlin]** 0 을 돌려주는 스트림에서 회전한다(main 동일) · HttpCore 프레이밍 예외가 응답 바이트를 인용한다 · `java/keycloak-sdk-admin/src/main/java/io/github/xzawed/keycloak/admin/TokenResponseGuard.java`
<!-- jvm-admin-token-guard-residuals: (1) 은 close-drain-time-unbounded 로 옮겼다 — 서버가 16 MiB 를 다 썼다(가드 1,048,577 · close 가 나머지) — 끊기(abortConnection)는 풀 재사용을 잃는다 — #769 가 거부한 응답만 끊어 닫았다(끝까지 읽은 응답은 그대로 풀로). (2) read 가 0 을 돌려주면 readNBytes 가 200 ms 에 1.5 GB 할당(InputStream 계약 위반 스트림, 운송 경로에서 미발견). (3) MalformedChunkCodingException 「Bad chunk header: <줄>」 — 정화 트리거는 ResponseProcessingException·파서 예외뿐(WithheldCauses), 후보: RESTEasy ClientInvocation.extractResult 의 finally close(2xx·미디어 타입 없음). (4) JVM 은 Nimbus 가 문법 밖 OAuth 코드를 버려 줄바꿈이 안 실리지만 고정하는 시험이 없다(#710 재스캔). -->
- [ ] `python-admin-guard-send-time` **[L/S · 신규 2026-10-03]** 검사가 보내는 순간이 아니라 무장 때다 — 다른 스레드가 요청 도중 중첩 세션을 바꾸면 그랜트가 307 을 따라 `client_secret` 을 넘긴다(실측) · `python/src/keycloak_sdk/_internal/admin_guard.py`
<!-- python-admin-guard-send-time 실측(#708 검증 레그 두 차례): 401 재시도 중 다른 스레드의 토큰 쓰기·_keycloak_openid 교체 → 'Bearer ' · 소문자 'bearer ' · _s.headers 기본값 · _s 를 바꾼 연결 직접 호출(307 따라감) · 설치 안 된 copy.copy(conn) 직접 호출 · wrapt.ObjectProxy(admin) 는 생성 때만 무장. 같은 부류: 주입한 openid 의 연결을 바꾸면 auth 레인이 리다이렉트를 따라 client_secret 을 넘긴다(sync). 이음매 후보: _s.send / async_s 의 송신 시점 검사(병합된 헤더, 대소문자 무시). -->
- [x] `jvm-chunked-trailers-unbounded` **[H/M · 닫힘 2026-10-09 #756 #761]** JVM 둘의 운송이 응답 틀을 상한 안에서 읽는다
- [x] `close-drain-time-unbounded` **[M/M · 신규 2026-10-05 · 닫힘 2026-10-27 #756 #761 #769 #833 #848]** 끝없는 본문의 `close()`·취소 — 일곱의 닫기는 재스캔 · 취소 API 가 있는 넷은 곧 돌아온다(실측 · kotlin 은 `response-read-deadline-divergent`)
- [x] `go-cancel-identity-lost-in-body` **[M/M · 신규·닫힘 2026-10-27 #849]** 교환 도중의 기한이 그랜트·admin 에서 `errors.Is` 정체를 잃었다
- [x] `python-aio-admin-build-blocks-loop` **[M/S · 닫힘 2026-10-28]** README 를 「요청은 await · 생성(`create`·첫 `kc.admin`)은 동기」로 고쳤다 — TLS 컨텍스트 공유는 기각(requests 가 SSLContext 를 못 받고 첫 생성의 막힘이 남는다)
- [x] `admin-response-body-unbounded` **[M/M · 신규 2026-10-25 · 닫힘 2026-10-27 #846]** admin 이 오류 본문을 다 읽는다
- [ ] `go-admin-3xx-read-as-success` **[M/S · 신규 2026-10-25]** Location 없는 3xx 를 admin 파사드 24 호출(Realms.Update 뺌)이 성공으로 읽는다 · `go/admin.go:175`
<!-- go-admin-3xx-read-as-success 실측(2026-10-25 · main 0a4cfee · 루프백 · NewAdminClient + 정적 토큰): 300 · 302(Location 없음) · 399 + JSON 본문 — 파사드 25 호출(다섯 리소스의 Create·Get·목록·Update·Delete) 중 24 가 오류 없이 돌아온다: Users.Get 은 빈 *User, Search 는 0 건, Create 는 id "", Update·Delete 는 nil. Realms.Update 만 오류다(raw PUT 이 2xx 를 명시한다). 기전: gocloak checkForError 는 resty IsError()(> 399)만 오류로 보고, resty 는 2xx 만 결과로 해석한다 — 3xx 는 둘 다 아니라 영값과 nil 이다. net/http 는 Location 없는 3xx 를 따라가지 않으므로 errOnRedirect 도 닿지 않는다. #380 은 같은 구멍을 토큰 요청(LoginClient — AccessToken == "" 검사)과 Realms.Update 의 raw PUT(2xx 명시)에서 막았다 — gocloak 의 판정을 쓰는 나머지 파사드는 그대로다. 발견: admin-response-body-unbounded go 수정 중 300 행을 쓰다가. 나머지 여덟 언어는 미측정 — 다음 걸음은 부류 재스캔(같은 다섯 리소스 × 300·302 무 Location·399). python 한 칸(2026-10-26, admin-response-body python 시험의 300 행): users.get 300 → KeycloakAdminError 300 — python-keycloak 의 expected_codes 가 막는다(다른 호출 미측정). dotnet 한 칸(2026-10-26, 그 시험의 300 행): typed·raw 다섯 호출 다 KeycloakAdminException 300(다른 호출·302·399 미측정). ruby 한 칸(같은 날, 그 시험의 300 행): 네 호출 다 AdminError 300(미측정은 같다). php 한 칸(같은 날, 그 시험의 302 행): users.get 302(Location 없음) → 성공(User) — http_errors 는 400 이상만 오류로 본다. 상한보다 긴 3xx JSON 이 잘리면 KeycloakAdminError(상태 null). rust 한 칸(2026-10-27, admin-response-body rust 시험의 302 행): 다섯 호출(단건·목록·update·create·delete) 다 Admin(Other(302)) — 파사드도 crate 도 2xx 만 성공으로 본다(300·399 미측정). node 한 칸(2026-10-27, admin-response-body node 시험의 300·302·399 행): 다섯 호출(단건·목록·update·create·delete) 다 KeycloakAdminError(HTTP 3xx) — `redirect: 'manual'` 의 3xx 는 `!ok` 다. 고치기 전 admin-client 경로도 같았다(#846 의 RED 실행). · 재스캔 때 먼저 볼 셋(닫힌 admin-response-body-unbounded 의 주석에서 옮김 — go 의 첫 설계를 깬 것): Raw() 의 하위 메서드가 201·PUT 본문을 결합하는가 · 잘린 오류 본문이 분류를 바꾸는가 · 호출자가 청한 압축을 상한 위에서 누가 푸는가. 본문 크기 칸(T1·T2·A1–A3)의 정의는 #834 의 PR 본문. -->
- [ ] `response-read-deadline-divergent` **[M/S · 신규 2026-10-09 · 판정 2026-10-29 · 본문은 아홉 다 2026-10-29]** 응답 전체를 설정한 타임아웃 안에 — 남은 칸: JVM admin 의 헤더·청크 틀(읽기마다) · node JWKS 는 설정이 아니라 jose 의 5 초 · `.claude/rules/security.md`
<!-- response-read-deadline-divergent 남은 칸(2026-10-29 레그 측정 · 읽기 1 s · 마지막 10 B 를 700 ms 마다 · 수정 전 측정은 이 줄의 git 이력): python sync 는 소켓 원문 읽기마다로 닫혔다(wire.py · 7.1 → 1.0 s). 남은 python 칸: HTTPS 프록시(TLS 안의 TLS)·pyOpenSSL 은 읽기 하나가 바깥 소켓을 여러 번 돌아 기한을 넘길 수 있다(늦은 바이트는 거부 · 코드 판독 ssltransport.py:266). JVM admin — 헤더 7,527 · 청크 7,089 · 트레일러 7,102 · TLS 레코드 33,643 ms(프로브 — 수정 전에는 받았고 이제 그 뒤 실패), 소켓이 RESTEasy 풀 것이라 엔진을 다시 짓지 않으면 못 닫는다. JVM admin 의 멈춤은 TLS 1.3 닫기가 한 번 더 읽는다(2 s 설정에 평문 2,039 · TLS 4,064 ms — 기한 실패는 피한다: TLS 흘리기 2,853 ms). node JWKS — createRemoteJWKSet 에 timeoutDuration 이 없어 jose 기본 5 s 다(설정 readTimeoutMs 기본 30 s · jwt.ts remoteJwksWithRefetchWindow). python 3.10·3.11 — asyncio.wait_for 가 교환이 끝나는 순간 도착한 호출자 취소를 삼킬 수 있다(CPython 결함 — 3.12 부터 wait_for 는 asyncio.timeout 위 · 재현 시험 없음). 판정 2026-10-29 의 기각 안: 감시자가 연결을 끊는 정확한 기한 — 요청마다 타이머·풀 반환·누수 위험을 네 런타임에 들이고 버는 것이 정확성 하나. 재는 법: 각 레인의 ResponseReadDeadline 시험 · 프로브는 PR 본문. -->
- [ ] `response-framing-unbounded` **[M/M · 신규 2026-10-05 · 아홉 측정 2026-10-09 · ruby 닫힘 #760]** 헤더 줄·청크 크기 줄·트레일러는 본문 상한 밖이다 — 남은 것은 node(undici 청크 확장 — 라운드 2: 상류 보고, 사람 몫) · python 트레일러는 바이트 예산이 닫았다. go 는 #742, JVM 은 #756·#761, php 는 ext-curl 요구(2026-10-29 판정) · `node/src/`
<!-- response-framing-unbounded 실측(2026-10-09 · 아홉 언어 측정 레그 둘 · 가짜 IdP 원시 TCP · cc 그랜트 · 각 16 MiB · F1 헤더 한 줄 · F2 청크 확장 · F3a 4 KiB 트레일러 줄 4096 개 · F3b 트레일러 한 줄 · 대조군 F4·F4c 는 전 레인 수락·할당 ≤ 0.3 MB · 양성 대조 ruby F1 +66.7–67.2 MB 로 2026-10-05 값 재현): ruby — F1 수락 +67 MB · F2 수락 +50 MB · F3a 수락 +32–46 MB · F3b 수락 +50 MB(auth·admin 같다 — net-http 의 readuntil/readline 에 한도가 없다) · php curl 처리기(기본) — F1 거부(cURL 100) · F2 수락(평탄) · F3 거부 / stream 처리기(ext-curl 이 없을 때 — 2026-10-29 부터 composer.json 이 요구한다) — F1 수락 +56.6 MB · F2·F3 수락(평탄) · python sync(requests) — F1·F2·F3b 거부(LineTooLong 65536) · F3a 수락(할당 0.04 MB 지만 16.78 MB 를 끝까지 읽는다 — 트레일러 줄 수에 한도가 없다) · aio(httpx/h11) 넷 다 거부 · node(undici 6.21.2) — F1·F3a·F3b 거부(HEADERS_OVERFLOW) · F2 수락 +16.8 MB(SDK 밖 실험: 64 MiB 확장 → arrayBuffers +74 MB · RSS +104 MB, GC 뒤 0) · go — F1 은 거부하지만 10 MiB 를 읽고 73.3 MB 를 할당했다 → #742(64 KiB) · F2·F3 작게 거부 · rust(hyper 1.11) 넷 다 작게 거부 · .NET 넷 다 거부(헤더·트레일러 64 KiB) · JVM — F1 은 jdk.http.maxHeaderSize 393,216 에서, F2 는 2,050 에서 거부하고 트레일러는 위 항목. 남은 넷의 수정 후보 — ruby: SDK 전용 Net::HTTP 하위 클래스의 BufferedIO 줄 상한(net-http 판에 기댄다) · php: stream 처리기에는 헤더 크기 손잡이가 없다 → ext-curl 을 요구하거나 문서로 · node: undici 상류(SDK 밖) · python: 시간·대역뿐이라 L. 측정 하네스는 커밋 안 함(세션 스크래치패드 xmeas1·xmeas2). · 2026-10-09 #760: ruby 는 SDK 가 연 소켓에만 거는 줄 8,192 · 틀 65,536 예산으로 닫혔다(net_http 어댑터 · 할당 1 MB 아래). · 2026-10-09 #767 레그(현 main 재측정): php stream 처리기 F1 수락 +57.2 MB · F2·F3 수락 1.0 MB / curl F1·F3 거부 · F2 수락 0.9 MB. 손잡이가 없다 — PHP 8.3 http_fopen_wrapper.c:1037 이 헤더 줄을 길이 제한 없이 읽고, Guzzle progress 는 헤더 뒤에 켜진다(F3b 는 1.6 MB 에서 끊었지만 F1 은 그대로), on_headers 는 57.2 MB 를 잡은 뒤다. 선택지: (a) composer.json 이 ext-curl 을 요구 — 소비자 하한이 오른다(기각 체크리스트 8, 릴리스 또는 등록 후속), gzip×stream 할당(7–8 MB)도 없앤다 · (c) 문서. 판정 2026-10-29 「(a)」(재측정은 그 PR 본문). · node 칸을 잴 때의 프로브 함정 둘(2026-10-27 · 닫힌 admin-response-body-unbounded 의 주석에서 옮김): 메모리는 `heapUsed + external` 로 잰다 — `external` 이 `arrayBuffers`(Buffer)를 이미 담아, 더하면 두 번 센다(#846 이 그 판의 전제 수를 버리고 다시 쟀다) · 사례마다 새 포트를 쓴다 — 같은 포트를 다시 쓰면 다음 디스커버리가 실패했다(전역 undici 풀이 클라이언트를 넘어 연결을 다시 쓰는지 · 하네스가 붙든 소켓을 끊은 탓인지 미판정). -->
- [x] `ruby-framing-hook-breaks-on-net-protocol-0-4` **[H/S · 닫힘 2026-10-22 #797 · 미게시]** 훅이 `limit:` 를 원판(0.3.0+)의 뜻으로 받는다(SDK 상한이 먼저) · 핀은 두 모양과 설치된 원판과의 대조 · 레인 CI 에 `latest-runtime-deps`(런타임 그룹을 새로 푼다 — 소비자 시야) · `ruby/lib/keycloak_sdk/http.rb`
- [x] `ruby-boundary-non-faraday-exception-leak` **[H/S · 닫힘 2026-10-22 #798 · 게시본 1.3.0 포함]** introspect · logout · admin(REST 와 자기 토큰) 경계도 세 그랜트처럼 SDK 밖 예외를 감싼다(`rescue Error; raise` 뒤 `rescue StandardError` → `TransportError` + `RedactedCause`) — net-http 0.10.0 의 응답 헤더 검증 `ArgumentError` 가 raw 로, 헤더 이름을 인용한 채 샜다 · `ruby/lib/keycloak_sdk/auth_client.rb`
- [x] `ruby-admin-error-status-lost-on-bad-json` **[M/S · 신규 2026-10-22 · 닫힘 2026-10-23 #810]** admin 의 오류 상태가 JSON 이라면서 JSON 아닌 본문에서도 상태 클래스를 지킨다 — json 미들웨어의 해석 실패를 응답 상태로 되짚는다(.NET 과 같다)
- [x] `ruby-framing-proxy-connect-unbounded` **[M/M · 신규 2026-10-22 · 닫힘 2026-10-23 #813]** CONNECT 응답을 나르는 소켓(평문 프록시의 TCP · TLS 프록시면 첫 `ssl_socket_connect`)에도 줄 8,192 · 블록 65,536 — net-http `>= 0.9` 하한 · `ruby/lib/keycloak_sdk/http.rb`
- [x] `jwks-stale-cache-outage-unbounded` **[M/S · 닫힘 2026-10-09 #743 #744]** node·.NET 에 실패 백오프. 남은 판정은 `jwks-cache-lifetime-divergent`
- [x] `jwks-cache-lifetime-divergent` **[M/S · 신규 2026-10-09 · 닫힘 2026-10-29 · 판정 「300 초 · 실패면 거부」]** 아홉의 키 집합이 300 초 뒤 콜드 캐시가 된다 — 가드 1h · security.md
- [x] `python-sync-post-retried` **[M/S · 신규·닫힘 2026-10-09 #747]** sync 세션은 어떤 요청도 저절로 다시 보내지 않는다(13 종 2 → 1)
- [ ] `oauth-error-field-echo-unmasked` **[L/S · 신규 2026-10-09 · python·go·java·kotlin (+재스캔)]** IdP 가 시크릿·토큰을 `error_description` 이 아니라 OAuth `error` 에 되울리면 공개 오류 속성에 그대로 남는다 · `python/src/keycloak_sdk/_internal/lower.py`
<!-- oauth-error-field-echo-unmasked(2026-10-09 #741 구현 레그 재스캔): python KeycloakAuthError.error(lower.py:118-120)는 JSON error 값을 그대로 싣는다 — sync·aio client_credentials 에서 vars(e) == {'error': 'sec+ret%2F%2B%3D~0005%C3%A9'}, refresh 는 호출자의 refresh token. 문법 검사(NQSCHAR)로는 못 막는다 — 폼 인코딩 꼴이 문법 안이다. go 는 같은 자리(oauthError)에 #764 가 문법 검사를 걸었지만 바로 그 이유로 이 항목은 남는다. JVM 둘(secret-echo 구현 레그 재스캔)도 getError()·oauthError 가 IdP 의 error 코드를 그대로 넘긴다. 나머지 다섯(node·rust·.NET·php·ruby)은 미측정. -->
- [x] `backoff-jitter-redrawn-per-check` **[L/S · 신규 2026-10-09 · 닫힘 2026-10-29]** 일곱이 지터를 실패할 때 한 번 뽑는다 — 같이 찾은 python 지수 넘침(약 1,025 번 연속 실패 뒤 `OverflowError`)도 닫았다
- [x] `backoff-counts-caller-cancellation` **[L/S · 신규 2026-10-09 · 닫힘 2026-10-29 · 판정 「센다」]** 공개 API 로는 닿지 않는다(처리기가 `CancellationToken.None` 으로 설정을 묻는다) — 게이트·리트리버의 고정 시험 둘이 「센다」를 지킨다
- [x] `token-provider-outage-refetch-per-call` **[L/S · 신규 2026-10-09 · 닫힘 2026-10-29 · 판정 「그대로」]** 만료 뒤 장애에서 호출마다 그랜트 — 앱의 호출만 닿고 위조 입력으로 못 부풀린다
- [x] `bearer-token-grammar-divergent` **[L/S · 신규 2026-10-09 · 닫힘 2026-10-29 · 판정 「다듬고 b64token」]** 아홉이 앞뒤 SP·HTAB·CR·LF 를 떼고 `b64token` 만 보낸다 — 가드 1g · security.md
- [x] `inbound-token-cap-divergent` **[M/S · 신규 2026-10-27 · 닫힘 2026-10-27]** 아홉이 256,000 을 디코드·JWKS 전에 검사한다(사람 판정 「권장안」) — 1f 축 · security.md
- [ ] `exchange-id-token-preparsed` **[L/S · 신규 2026-10-27 · java·kotlin·node·rust]** 코드 교환의 id_token 은 OIDC 라이브러리가 토큰 응답과 함께 먼저 푼다 — Nimbus `OIDCTokenResponseParser` · openid-client `authorizationCodeGrant` · openidconnect 역직렬화. 1e(1 MiB)가 묶고 IdP 가 보낸 값이다(실측: JVM 헤더에 몰린 ≈1 MB 응답이 ≈40 MB). 고치려면 응답 파서를 갈아야 한다 · `java/keycloak-sdk-auth/src/main/java/io/github/xzawed/keycloak/auth/AuthClient.java:140`
- [x] `secret-echo-form-encoded-rescan` **[M/S · 닫힘 2026-10-09 #741 #745 #746]** 샌 곳 넷(java·kotlin auth · JVM admin · python admin)을 가렸다. 남은 것은 `oauth-error-field-echo-unmasked`
- [x] `dotnet-admin-bogus-charset-escape` **[M/S · 닫힘 2026-10-09 #740]** 풀지 못하는 charset 이 SDK 예외가 됐다. 메시지 삽입은 `error-message-surface-unspecified`
- [x] `wave4-hardening-dotnet` **[L/S · 신규 2026-10-05 · 닫힘 2026-10-29 · #765 #876 · (2) 판정 「그대로」]** 요청 본문의 짝 없는 서로게이트 → U+FFFD 는 직렬화기 동작이고 새는 것이 없다
- [x] `wave4-hardening-go` **[L/S · 신규 2026-10-05 · 닫힘 2026-10-29 · #764 #883]** 동점은 준비된 결과 · 공개 provider 는 못 쓰는 토큰을 캐시하지 않는다 · (2) 는 비공개 ctx 로만 닿아 「그대로」
- [ ] `wave4-hardening-rust` **[L/S · 신규 2026-10-05 · (1)(5) 닫힘 #768 · (2) 닫힘 #877 · (4) 전제 거짓 #877 · (3) bearer 판정으로 닫힘]** 남은 것 — reqwest 디코딩을 안 켜 「푼 바이트」 조항이 시험되지 않는다 · python README·aio CHANGELOG 의 「끝까지 간다」는 미측정 · `rust/src/`
<!-- wave4-hardening-rust(2026-10-05 rust 구현·검증 레그): (3) U+00FF 위 문자를 담은 bearer 를 admin 레인이 날 UTF-8 헤더로 보낸다(누출·이스케이프 없음, bearer-token-grammar-divergent). (4) 전제 거짓(#877 재측정) — 형식이 틀린 400/401 본문은 비 JSON·잘린 JSON·짝 없는 서로게이트·빈 본문 모두 고정 문구의 Transport 로 일관된다. 닫힌 칸의 경위는 #768 · #877((1) 의 고정 시험 포함) 본문. 남은 것: python/README.md:7 과 aio CHANGELOG 도 「끝까지 간다」고 적는다(asyncio.run 을 호출마다 쓰는 동작은 미측정) · reqwest 디코딩 기능을 안 켜 「푼 바이트」 조항은 시험되지 않는다 · rust.md 함정 후보(예산): 「oauth2 5.0 은 end() 를 부르지 않는다 — 값 뒤 검사는 CappedHttp 가 한다」. admin 토큰 실패가 401 로 뭉개지는 것은 rust-admin-error-cause-flattened. -->
- [x] `wave4-hardening-python` **[L/S · 신규 2026-10-05 · 닫힘 2026-10-29 · #770 #879 · (1)(4) 판정 「그대로」]** 생성 때만 거는 auth 상한은 비공개 속성으로만 풀리고, 짝 없는 서로게이트는 IdP 가 준 값 그대로다
- [x] `wave4-hardening-node` **[L/S · 신규 2026-10-05 · 닫힘 2026-10-29 · #768 #772]** bearer 끝 공백 다듬기를 SDK 가 맡는다(bearer 판정) · 폼 본문 U+FFFD 는 「그대로」
- [x] `wave4-hardening-ruby` **[L/S · 신규 2026-10-05 · 닫힘 2026-10-29 · #763 #874]** 전역 `Rack::OAuth2.http_config` 를 걸지 않는다(판정) — ASCII 밖 bearer 는 bearer 판정이 닫는다
- [ ] `wave4-hardening-php` **[L/S · 신규 2026-10-05 · (3)(4) 닫힘 #767 · 토큰 판독기 멈춤 닫힘 #772 · 라운드 2(2026-10-29) 다섯 칸 수락]** 남은 칸 — 비-JSON 토큰 응답이 league `TransportError` · cc provider `AuthError` · `php/src/`
<!-- wave4-hardening-php 판정 2026-10-29 라운드 2(PM 판정 먼저 · Grok 판정 레그 대조, 다섯 중 넷 일치 — 칸별 이유와 Grok 의 반대는 그 PR 본문). 받아들임: (1) curl 8.21.0(Windows)이 +307,200 B Bearer 헤더를 버린다(→ 401 · 누출 없음) — 기본 Keycloak 은 65,459 B 위를 431 로 막는다 · 되살릴 조건: 지원 플랫폼 libcurl 이 그 아래에서 버린다는 측정. (2) 주입 PSR-18 전송 무상한(메모리는 상한까지). (3) 탐색 불가 본문을 현재 위치부터 읽음(주입 미들웨어). (4) 주입 전송 읽기 오류의 일반 문구. (5) stream 처리기 gzip 7–8 MB — ext-curl 필수라 주입 때만(뒤집히면 이 칸도). 남은 칸(6): 비-JSON 토큰 응답(503 HTML 등)을 AuthClient(league)는 TransportError, ClientCredentialsTokenProvider 는 AuthError('client-credentials failed')로 부른다(OAuth 오류 JSON · access_token 없음은 둘 다 AuthError · 상한은 둘 다 TransportError · introspection 비-JSON 은 AuthError · JwksStore 는 TransportError). 다음 걸음: 아홉 언어의 같은 다섯 응답 분류표. raw() 트레이스 인자의 시크릿은 php-exception-trace-third-party-args. -->
- [x] `wave4-hardening-java` **[L/S · 신규 2026-10-05 · 닫힘 2026-10-29 · #769 #833 #875]** JVM 공통 bearer 는 판정이 닫았고 조회 스레드 생성 실패(Error)는 「그대로」 — admin 원인 사슬의 jakarta 타입은 `nimbus-type-on-public-surface` 로
- [x] `wave4-hardening-kotlin` **[L/S · 신규 2026-10-05 · 닫힘 2026-10-29 · #878]** 짧은 §5.2 꼴이 산문도 가리는 것은 받아들였고(판정) `MaskingTest` 가 고정한다 · %3F 는 「그대로」
- [x] `python-admin-error-body-strict-decode` **[M/S · 신규·닫힘 2026-10-05 #719]** UTF-8 아닌 admin 오류 본문이 raw `UnicodeDecodeError` 였고 그 `__context__` 가 본문을 실었다(§4)
- [x] `kotlin-echo-mask-misses-filtered-form` **[M/S · 신규·닫힘 2026-10-05 #718]** Nimbus 가 §5.2 밖 글자를 지운 뒤라 되울린 토큰·시크릿의 그 꼴을 못 가렸다
- [x] `kotlin-echo-mask-misses-form-encoded-secret` **[M/S · 신규·닫힘 2026-10-05 #718]** Basic 의 폼 인코딩 시크릿 되울림을 못 가렸다 — 부류는 `secret-echo-form-encoded-rescan`
- [x] `node-admin-bearer-header-escape` **[M/S · 신규·닫힘 2026-10-05 #721]** 헤더에 못 싣는 admin 토큰이 그 토큰을 인용한 raw `TypeError` 로 나왔다(§4)
- [x] `php-admin-bearer-header-quote` **[M/S · 신규·닫힘 2026-10-05 #723]** CR·LF admin 토큰을 인용한 psr7 메시지가 원인으로 실렸다(sodium 없는 PHP)
- [x] `php-admin-raw-leaks-internal-cap-error` **[L/S · 신규·닫힘 2026-10-05 #723]** 이 물결의 상한이 `raw()` 에 `@internal` 예외를 냈다 — 병합 전에 잡았다
- [x] `ruby-bearer-and-utf8-raw-escapes` **[M/S · 신규·닫힘 2026-10-05 #722]** CR·LF admin 토큰이 Bearer 를 인용한 raw `ArgumentError` 로, 잘못된 UTF-8 응답이 raw 예외로 나왔다(§4)
- [ ] `ruby-admin-resource-duplication` **[L/S · 2026-09-03 닫힌 표에서 분리 2026-10-28]** admin 리소스 셋의 중복이 남아 있다(비차단) — 모듈로 추출하는 리팩터가 required `doc-facts` 를 깨서(가드가 「리소스 하나 = 파일 하나」를 전제한다) 되돌렸다. 길 둘: (a) 리팩터 + 두 가드를 모듈 인지형으로 · (b) `sonar.cpd.exclusions`. 재는 법: `curl -s 'https://sonarcloud.io/api/measures/component_tree?component=xzawed_KeyCloakSDK:ruby/lib/keycloak_sdk/admin&metricKeys=duplicated_lines&qualifiers=FIL'` (2026-10-28: `clients.rb` 33 · `groups.rb` 32 · `users.rb` 22).

### 테스트·커버리지 — 14

- [x] `selftest-hygiene-textual-rules` **[H/M]** '존재'가 아니라 '실행'을 센다던 규칙이 주석·비활성화·`|| true`를 실행으로 센다 · `scripts/test/test-selftest-hygiene.sh:20`
- [x] `coverage-exclusions-swallow-pure-logic` **[H/L · 닫힘 2026-09-25 #573 #574 #577 #579]** '네트워크 경계' 커버리지 제외가 순수 로직까지 삼켰다 — **아홉 언어를 변이로 전수 측정**: node 3 · python 10 · dotnet 4 · java 5 · kotlin 3 · ruby 3 · go 4 CAUGHT(제외돼도 시험됨), php 2/2 SILENT → #573, rust 제외 정규식 무앵커 → #574. 측정 중 드러난 **교환 경로 nonce 무시험**(java·rust, #577)·**node 토큰 타입 무시험**(#579)은 제외와 무관한 테스트 구멍이었다. 사후 서사는 `git show ef040af:docs/superpowers/plans/remaining-work.md` 515–528행 · `php/phpunit.xml:13`
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
- [x] `probe-build-failure-reported-caught` **[M/S · 닫힘 2026-10-09 #738]** 컴파일·적재 실패 표식 14 개(실제 도구 출력 16 건에서 뽑음)면 INVALID · php-api-compat 81 행이 사유를 단언한다
- [x] `selftest-assert-counter-subshell` **[M/M · 닫힘 2026-09-23 #540]** 어서션 카운터가 서브셸에서 증발한다 — 자가테스트 프레임워크의 구조적 맹점 · `scripts/test/assert.sh:10`
- [ ] `guard-paths-never-exercised` **[M/M]** 자가테스트가 가드의 한 경로만 태워, 나머지 경로를 지워도 초록이다 · `scripts/test/test-check-coverage.sh:41`
- [ ] `selftests-with-no-negative-case` **[M/L]** 일곱 자가테스트가 라이브 상태만 단언한다 — 판정기가 나쁜 입력을 거부한다는 증거가 없다 · `scripts/test/test-deploy-md.sh:7`
- [ ] `probes-that-discard-the-result` **[M/M]** 프로브가 결과를 버린다 — 예외 타입 미단언·반환값 미단언 · `php/tests/Unit/Jwks/JwksStoreTest.php:188`
- [ ] `wall-clock-ordering-in-tests` **[M/M]** 동시성·시간창 테스트가 벽시계에 매달려 있다 — 조용한 퇴화와 거짓 실패. rust·ruby·go 는 닫았다(#701 #706 #707 #709). 남은 다섯 언어의 자리는 아래 주석 — ⚠️ 시계를 얼리면 창 크기 검출이 사라지니 결정적 창 크기 시험을 함께 둔다 · `python/tests/unit/test_auth.py:992`
<!-- wall-clock 남은 자리(2026-10-03 첫 물결 재스캔, 정적 읽기 + 표시한 것은 주입 실측): python tests/unit/test_auth.py:992 · aio/test_auth.py:734 · W3c test_hostile_path_matrix.py:1258 / php JwksStoreTest.php:333 · FailureBackoffTest.php:103 · W3c HostilePathMatrixTest.php:1481 / dotnet BackoffConfigurationManagerTests.cs:137 · W3c HostilePathMatrixTests.cs:950 / node W3c hostile-path-matrix.test.ts:1557 / ruby jwks_store_spec.rb:135(주입 0.25 s → 3/3 실패) · W3c hostile_path_matrix_spec.rb:810 / go tokenprovider_test.go:29 TestProviderSingleFlight(50 ms 비행, 주입 60 ms → 2/3 실패, 경합만으로 0/300 — 원인은 비행 안에서 캐시를 다시 안 보는 것, token-provider-cache-invariants). java·kotlin 은 30 s 창이라 실노출 없음. go 원래 지목(jwt_test.go:322)은 경합만으로 13/200 실패했다. -->
- [x] `ruby-framing-spec-server-written-flaky` **[M/S · 닫힘 2026-10-22 #797]** 원인은 리눅스가 받은 소켓의 송신 버퍼를 자동으로 키운 것 — `FramingServer` 가 SO_SNDBUF 를 64 KiB 로 고정한다(Go 의 같은 오라클과 같다) · `ruby/spec/support/framing_server.rb`
- [ ] `dotnet-allocation-test-process-wide-counter-flaky` **[L/S · 신규 2026-10-23]** 2 KiB 할당 시험이 프로세스 전체 카운터로 재서 같은 SHA 에서 갈렸다(318,336 B ≥ `Cap / 4`, 재실행 초록) · `dotnet/tests/Xzawed.Keycloak.Sdk.Tests/TokenResponseCapTests.cs:271`
<!-- dotnet-allocation-test-process-wide-counter-flaky: A_2_KiB_body_allocates_nothing_near_the_cap(chunked: False). run 39893087370 attempt 1(.NET SDK 10.0.x, #824) 빨강 · attempt 2 초록 · 같은 SHA 434fab6 의 push 실행 39893081688 초록 — 재실행 전 dotnet-ci 최근 60 회 중 실패는 이 하나. GC.GetTotalAllocatedBytes 는 프로세스 전체이고 DisableParallelization 은 동시에 도는 시험을 막을 뿐 시험 밖의 배경 작업은 막지 못한다. 원인 미측정 — 후보: 앞 시험이 남긴 가짜 IdP 의 ServeAsync · 러너 보고. 고칠 후보: k 회 측정의 최솟값(잡음은 더하기만 한다). -->
- [ ] `dotnet-rawserver-reads-once-flaky` **[L/S · 신규 2026-10-27]** `RawServer` 가 요청을 한 번만 읽고 닫는다 — g4 의 `IntrospectAsync` 가 401 대신 `ResponseEnded` 로 두 번 갈렸다(#852·#863, .NET 8). 기제 미측정 · `dotnet/tests/Xzawed.Keycloak.Sdk.Tests/MalformedTokenResponseTests.cs:353`

### 가드·CI — 20

- [x] `selftest-exit-code-contract-two-leaks` **[H/M · 닫힘 2026-09-23 #540]** 자가테스트의 「실패하면 비영 종료」 계약이 한 곳에서 샜다 — 탐지기는 #405, 계수기는 #540(파일 눈금 오라클) · `scripts/test/test-selftest-hygiene.sh:20`
- [x] `sweeps-without-vacuity-floor` **[H/M · 닫힘 2026-09-08 #443]** 스윕/스캔이 0건을 훑고 통과했다 — 이 저장소의 하한 관용이 적용되지 않았다 · `.github/workflows/repo-hygiene.yml:234`
- [x] `seven-selftests-have-no-negative-control` **[H/L · 닫힘 2026-09-25 #571]** 자가테스트가 **깨진 대상에도 참인 단언**을 가졌다 — 지목한 여섯 파일을 단언 단위로 전부 봤다(조각 1–8). 마지막 조각: `test-provenance-gate` 의 근거 정의 검사가 「문자열이 어딘가 있다」라 주석 속 사본·센티널 앞 재대입에 SILENT(3/3) → 「센티널 앞 마지막 대입」 판정 + 음성 대조군. 사후 서사는 `git show ed3ef3b:docs/superpowers/plans/remaining-work.md` 541–602행 · `scripts/test/test-provenance-gate.sh:107`
- [ ] `irreversible-publish-no-reentry` **[H/M · 착수 보류 판정 2026-09-09 · 재판정 2026-09-25: 보류 유지]** 비가역 게시 뒤 재진입 경로가 없다 — **두 레인**(dotnet·php)의 게시 뒤 `gh release create` · `.github/workflows/dotnet-release.yml:160`
  - ✅ **재판정(2026-09-25) — 보류 유지. Claude·Grok 독립 일치, 사용자 수용.** 실측: 릴리스 워크플로 10 개 53 회, 실패한 시도 4 회는 전부 게시 전·게시 단계 자체(게시 **뒤** 0) · 실패 모드는 **dotnet·php 둘뿐** — go 는 게시(태그)가 워크플로 앞이라 재실행으로 복구되고(옛 인용 `go-release.yml:156` 은 줄이 밀린 것), JVM 은 스테이징 + 사람 클릭 · 잃는 것은 Release 페이지뿐(Release 는 원래 3/9 레인, 대칭화는 기각). **09-09 에 미확인이던 신호 둘을 쟀다**: php `git subtree split` 은 결정적(로컬 `php-v1.0.0` → `7169b1c` = CI 가 미러에 올린 SHA) · dotnet nuspec `commit=` == 태그 커밋(음성 대조 0.1.1). 그래서 **출처 확인 후 계속**(409·태그 존재 시 SHA 대조)이 기술적으로 열렸다. 손 복구 절차는 DEPLOY §4 6단계(#584).
  - **뒤집을 조건**: 게시 뒤 단계가 실제로 실패해 손 복구가 무언가를 잃었거나 릴리스를 막았다 · Release 자산·노트가 설치/기계 판독 경로가 된다 · 릴리스가 자동화·고빈도가 된다 — 그때 잡 분리(+ 출처 확인). ⏸ **미측정**: NuGet 부분 게시(nupkg 성공·snupkg 실패) · Central Portal 에 같은 버전 스테이징이 둘일 때 · nuget.org 색인 지연 중의 출처 판정.
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
- [ ] `w1-shared-script-drift-weekly-only` **[L/S · 신규 2026-10-01]** 아홉 적대 행렬의 W1 은 `scripts/test/test-security-defaults.sh` 의 앵커를 언어별 손 표와 대조하는데, 그 스크립트만 바꾼 PR 은 언어 CI 를 만들지 않고(`paths:` 가 `<lang>/**` 뿐) 야간 harness 도 #674 이후 W1 을 건너뛴다 — 앵커 드리프트는 그 언어의 다음 PR 이나 월요일 정기 실행에서야 드러난다(#674 의 Grok 레그가 지목). 후보: 아홉 언어 CI `paths:` 에 그 스크립트를 더하기 · harness 스위트에 `scripts/` 읽기전용 마운트(dotnet·ruby 실측 초록). php 만 건너뜀 메시지가 없다 · `php/tests/Unit/HostilePathMatrixTest.php:1789`
- [ ] `push-trigger-branches-asymmetry` **[L/S]** 여섯 워크플로의 push 트리거에 branches가 없어 PR 브랜치에서 레인이 두 번 돈다 · `.github/workflows/dotnet-ci.yml:3`
- [x] `sonarcloud-dependabot-skip-keys-on-actor` **[M/S · 신규 2026-10-22 · 닫힘 2026-10-23 #801]** 건너뛰기가 PR 작성자도 본다 — actor 로만 거를 때 사람이 커밋을 얹은 Dependabot PR 실행 일곱(2026-10-08~21)이 미검토 범프와 `SONAR_TOKEN` 을 한 잡에서 돌렸다. 가드는 `check-ci-permissions.mjs` 규칙 11
- [x] `java-release-bundle-never-built-before-tag` **[H/S · 신규·닫힘 2026-10-23 #825]** 릴리스 번들을 태그 전에 만드는 잡이 없어 러너 Maven 3.10.0 × central-publishing 0.11.0 의 장부 번들을 v1.2.0·v1.2.1 두 번호를 태운 뒤에야 알았다 — `ci.yml` release-bundle + `scripts/check-central-bundle.mjs`
- [x] `sonarcloud-human-pr-carries-unreviewed-bump` **[M/M · 신규·닫힘 2026-10-23 · 사람 판정 「잡 분리」]** 사람이 연 PR 이 bump 를 실으면 미검토 패키지가 `SONAR_TOKEN` 과 한 잡에서 돌았다 — `sonarcloud.yml` 을 `coverage`(시크릿 없음)·`scan`(산출물만)으로 나눴고 규칙 12 가 고정한다(#832).


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

### harness 사각지대 — 13

- [x] `H1-conformance-authz-vacuous` **[M/M · 닫힘 2026-09-12 · 범위 확대]** ⚠️ **공허가 하나가 아니라 셋이었다.** 요청↔응답 미대조 외에 `/code_challenge=/` 가 **빈 값**을 통과시켰고, URL 의 `state` 와 돌려준 `state` 를 **존재만 따로** 보고 대조하지 않았다. 판정을 `harness/conformance/authz-url.mjs` 로 뽑아 **Docker 없이** 픽스처로 재게 했다(그 판정이 오래 공허했던 이유가 「시험할 수 없다」였다). 가드 `scripts/test/test-conformance-authz-url.sh`(픽스처 8종, `doc-facts` 배선). 변이 6/6 `CAUGHT` + OFF 짝 3/3. ⚠️ **프로브가 구멍 하나를 실제로 찾았다** — 모듈을 부르되 `v.ok` 를 버리면 침묵했다(같은 PR 에서 닫음). ⚠️ 파생 신규: `authz-redirect-uri-not-per-call`(php·rust).
- [x] `H3-harness-image-and-lock-pins` **[M/S · 닫힘 2026-09-12 · 범위 정정]** ⚠️ **「세 자리」가 아니라 한 파일의 두 결함이었고, 그중 하나는 거짓 초록이었다.** (1) `security-audit.yml:277` 이 `cargo audit -f harness/apps/rust/Cargo.lock` 으로 감사하는 그 락을 `harness/apps/rust/Dockerfile` 은 **COPY 하지 않았다** — 게다가 락이 `keycloak-sdk` **0.1.0** 을 고정한 채였고 매니페스트는 **1.0.0** 이다(4ed3298, 2026-08-30). 락은 2026-08-01 이후 안 움직였으므로 야간 감사는 **1.0 이전 그래프**를 6주째 감사하며 초록을 냈다. (2) `FROM rust:alpine` 은 하네스 아홉 앱 중 **유일한 무버전 태그**였다(install 경로 둘은 이미 `rust:1.88-alpine`). ⚠️ **install 경로의 락 처리는 결함이 아니다** — consume 은 registry 의존으로 재기입하고 publish 는 클로저 미러링용으로 `generate-lockfile` 하는 것이 설계다(주석이 그렇게 적는다). 부류 재스캔: `git ls-files harness/apps | grep -Ei 'lock|\.sum$'` → **1건** · `cargo audit -f` 전수 → **1건** · 무버전 `FROM` 전수(9앱) → **1건**. 형제 언어에 같은 결함 없음. ⚠️ **락 재생성에 MSRV 인지 해석이 필요했다** — cargo 가 `Locking 253 packages to latest Rust 1.88 compatible versions` 로 reqwest 0.13·matchit 0.8.6 을 눌렀다. edition 2021 은 resolver v2 라 기본이 아니고, 플래그 없이 재생성했으면 `--locked` 빌드가 1.88 에서 깨졌다(`scripts/regen-harness-rust-lock.sh` 가 소유). **Docker 실빌드로 확인**(107s, `rust:1.88-alpine` + `--locked`). 변이 6/6 `CAUGHT` + OFF 짝 6/6 `SILENT`.
- [x] `ruby-token-provider-inspect-leaks-token` **[M/S · 닫힘 2026-09-12 · 실행 재현]** ⚠️ **가드 부재가 아니라 실제 노출이었다.** `ClientCredentialsTokenProvider` 의 기본 `inspect` 가 캐시된 **액세스 토큰을 원문으로** 찍었다 — `@cached` 가 `ts.access_token`(원시 String)이라 `TokenSet#inspect` 의 마스킹이 닿지 않는다. 형제인 `Config`·`TokenSet` 은 `inspect` 재정의가 있는데 **이 타입만 없던** 불일치다. **실행으로 재현**했다(읽기 아님): `p provider` → `@cached="AT-CENSUS-TOKEN-…"`. 고친 뒤 재측정 → `cached="***"`. ⚠️ 캐시 **유무는 남긴다**(빈 캐시에 `***` 를 찍으면 「토큰이 있다」는 거짓 신호다 — 대조군 spec 이 고정). ruby 123/123 · 커버리지 99.61/96.72 · rubocop 청정 · 변이 `CAUGHT`(수정 전 상태로 되돌리는 변이). ⚠️ **아홉 전수는 실행으로 갈랐다** — node 는 안전(`#cached` 비노출 실측) · python 은 공개 캐싱 provider 없음 · java·kotlin·dotnet·rust 는 기본 표현이 필드를 안 찍음 · go 는 provider 가 미노출 타입.
- [x] `php-var-dump-bypasses-all-masking` **[M/M · 닫힘 2026-09-12 · 범위 재정의]** ⚠️ **「덤프 경로를 마스킹한다」는 아홉 언어 균일 계약으로 불가능하다** — 정밀 실측(독립 레그 census + 내 실행 검증)이 그것을 갈랐다. 그래서 **할 수 있는 것만 하고 못 하는 것은 경계로 적었다**. **훅 가능·저렴(구현함)**: php `__debugInfo`(`var_dump`·`print_r`·`debug_zval_dump`) · go `GoStringer`(`%#v` 만 — `%v`·`%+v`·`%s` 는 `String()` 그대로, 대조군이 고정) · ruby `pretty_print`(⚠️ 이것은 **바닥 안**이었다 — `pp` 는 표시 경로인데 `Data` 타입은 PP 가 멤버를 직접 찍어 `inspect` 를 건너뛴다. 일반 클래스인 `Config` 는 폴백해 안전). **훅 불가(경계로 문서화)**: python `asdict`/`astuple`/`vars`(필드를 직접 훑는다 — `__getstate__` 무시됨, 실측) · node 객체 스프레드(열거 가능 프로퍼티를 훅보다 먼저 복사) · .NET Serilog `{@}`(소비자가 정책을 등록해야 한다) · php `var_export`(private 까지 원문, 실측) · java/kotlin Jackson·Gson(게터 기반 — java core 는 **의존성 0** 이라 `jackson-annotations` 가 첫 컴파일 의존이 된다) · **아홉 전부의 공개 필드/게터 읽기**. ⚠️ **왕복 훅은 일부러 안 넣었다** — go `MarshalJSON`·rust `Serialize` 를 마스킹하면 소비자가 세션·캐시에 `***` 를 저장한다(덤프는 단방향, JSON 은 왕복이라 부류가 다르다). ⚠️ **저장소 주석 셋이 거짓이 됐다가 정정됐다** — 「`var_dump`/`print_r` 은 여전히 프로퍼티를 직접 읽는다」(php 8.3.32 에서 `print_r` 은 `__debugInfo` 를 **존중한다**, 실측). 계약은 `SECURITY.md` 가 소유한다 — **기밀 경계가 아니라 우발적 로깅에 대한 심층 방어**라고 적었다.
- [x] `harness-orphan-container-reads-as-build-failure` **[L/S · 닫힘 2026-09-16 · 부류로 넓혀서]** 중단된 하네스 런이 남긴 컨테이너가 다음 런을 막는데, 신호가 **원인을 잘못 가리킨다** · `harness/verify.sh:30`
- [ ] `H2-harness-judgment-module-no-test` **[L/M]** harness 판정 모듈에 「테스트가 있어야 한다」 규칙이 없다 — conformance.mjs 는 Docker 전체 런 없이는 시험 불가 · `harness/conformance/conformance.mjs:1`
- [x] `H4-runsh-network-divergence` **[L/S · 닫힘 2026-09-15]** verify.sh 가 배운 것을 run.sh 는 못 받았다 — compose 네트워크명을 아직 리터럴로 박는다 · `harness/run.sh:6`
- [ ] `harness-app-ports-on-all-interfaces` **[L/S · 신규 2026-10-27]** verify 하네스 앱 아홉이 호스트 포트를 모든 인터페이스에 연다(`"${HARNESS_PORT_PHP:-8095}:8090"` 꼴) — 하네스가 도는 동안 같은 LAN 에서 닿고, php 앱은 `php -S 0.0.0.0` 이다. `127.0.0.1:` 로 묶을지(PHP2Shell 검토의 Grok 독립 레그 제안) · `harness/docker-compose.yml:109`
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

## D. 원장 밖 — 88건 (열림 51)

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

### 로드맵·기능 갭 — 14

- [x] `php-admin-token-error-unsanitized` **[M/S · 닫힘 2026-10-02 #686]** admin 오류가 토큰·`client_secret`·Bearer·보낸 입력을 찍었다(행렬 208칸보다 넓었다) — `Admin\ErrorTranslation` 이 #622 의 `SanitizedCause` 를 쓰고 파사드 인자를 `#[\SensitiveParameter]` 로 가린다. KNOWN_GAPS 삭제.
- [x] `jvm-admin-token-response-type-unchecked` **[M/S · 닫힘 2026-10-02 #687·#688]** admin 이 숫자·불리언·빈 `access_token` 을 Bearer 로 실었다 — `TokenResponseGuard` 가 결합 직전 바이트를 판정해 `KeycloakTransportException` 으로 거부한다. KNOWN_GAPS 삭제.
- [x] `python-admin-grant-accepts-empty-access-token` **[L/S · 닫힘 2026-10-02 #685]** 빈 `access_token` 이 `Bearer ` 로 나갔다 — sync·aio 모두 admin 요청 없이 auth 레인과 같은 `KeycloakAuthError`. KNOWN_GAPS 삭제.

- [x] `id-token-audience-follows-access-audience` **[M/S · 신규 2026-09-27 · 닫힘 2026-10-01 #663–#671 · 아홉 언어]** `expectedAudience` 를 clientId 가 아닌 값(리소스 서버)으로 재정의하면 nonce 를 넘긴 코드 교환이 id_token `aud` 불일치로 실패했다 — 아홉 언어 전부 id_token 을 액세스 토큰과 같은 검증기로 봤다. ✅ 판정 (a)(2026-09-27, 사용자 · Grok 독립 판정 일치): id_token `aud` 는 clientId 로 따로 검증한다. OIDC Core §2·§3.1.3.7 은 client_id 를 **MUST** 담게 하고, 재정의는 RFC 9700 §2.3·§4.10.2 의 **액세스 토큰** 제한이다. 실서버(Keycloak 26.6) 실측: access-only audience 매퍼에서도 id_token `aud` 는 client_id 다. 수용 기준(아홉 동형, 각 PR 이 테스트로 고정): 재정의 아래 교환 통과 · `aud` 에 client_id 가 없으면 재정의 값만 있어도 거부 · access 검증은 재정의 유지 · JWKS 캐시·재조회 제한 공유. `azp` 는 다루지 않는다(SHOULD — 원문 확인 전 계약 아님). php(`validateIdToken`)·ruby(`audience:`)는 공개 API 가 늘어 minor 다.
- [ ] `node-auth-error-no-oauth-code` **[L/S · 신규 2026-09-27]** node `KeycloakAuthError` 에만 OAuth `error` 코드가 없다. python 은 `.error`, go 는 `OAuthError`, rust 는 `oauth_error` 로 공개한다. `scrubCause` 가 name·message·code 만 남겨, `invalid_grant` 를 공개 API 로 가를 수 없다. 코드 교환 이식 테스트는 그래서 `OAUTH_RESPONSE_BODY_ERROR` 까지만 단언한다 · `node/src/errors.ts`
- [x] `nonce-failure-leaves-session-alive` **[L/S · 신규·닫힘 2026-09-27 · 판정 (b) 기각]** 검증에 실패한 교환의 토큰을 revoke 하지 않는다 — 버리고 원래 오류를 던지는 지금 동작이 계약이다(사용자가 권장안으로 결정). 실서버 실측: 거부된 교환은 로그인 때 생긴 세션을 끝내지 않는다(idle 1800s · max 36000s). revoke 는 SDK 가 버린 refresh token 이 있어야만 가능하다. 근거: OIDC Core 는 revoke 를 요구하지 않고, RFC 7009 §2.2 는 무효 토큰에도 200 이며, 주입된 코드면 남의 grant 에 손댄다(Grok 독립 판정도 (b)). **되살릴 조건**: 검증 통과 뒤의 실패에 한정한 제품 요구 + 잔존 수명 실측 + Keycloak `/revoke` 범위 실측. ⚠️ 이 실측이 `python-traceback-locals-carry-tokens` 를 찾았다.
- [x] `python-traceback-locals-carry-tokens` **[M/S · 신규 2026-09-27 · 닫힘 2026-10-01 #666]** python 에서 거부된 교환의 토큰이 예외 traceback 의 **프레임 로컬**에 남았다 — `TracebackException(capture_locals=True)` 와 Sentry Python(기본값)이 찍고, `str`·`repr`·`format_exception` 에는 없어 누출 테스트가 못 봤다. 원인 사슬 스크럽(#617–#624)은 `__cause__` 만 보았다. 비밀을 다루는 공개 진입점을 `@scrub_frames`(`_internal/frames.py`)로 감싸, 실패하면 안쪽 프레임·사슬 traceback·인자를 떼고 **같은 예외**를 던진다(sync·aio · `authorization_url` · 생성자 포함). 다른 언어는 예외가 로컬을 들고 다니지 않는다(php 호출 인자는 `php-exception-trace-third-party-args`).

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
- [x] `post-publish-version-verify` **[M/M · 닫힘 2026-09-24]** `registry-truth-check` 와 한 도구로 닫았다 — `node scripts/check-registry-truth.mjs --lang=<lang>` 이 LIVE/PENDING 을 답한다(DEPLOY §4 step 8)
- [ ] `ci-lane-trigger-branch-filter` **[L/S]** 언어 CI 6개가 `branches:` 없이 push 트리거 — 태그·아카이브 ref·PR 브랜치에서 중복으로 돈다 · `.github/workflows/dotnet-ci.yml:3`
- [x] `orphan-active-workflows` **[L/S · 닫힘 2026-10-28]** 파일 없는 둘을 껐다 — `repo-config.mjs check` 가 워크플로 상태를 대조한다
- [ ] `repo-settings-ssot-gap` **[L/S]** 브랜치 자동삭제 등 저장소 설정이 SSOT 밖 — 원격이 깨끗한 이유가 어디에도 안 적혀 있다 · `.github/security-config.json:2`

### 테스트 실행 갭 — 9

- [ ] `realm-copies-unguarded` **[L/S · 신규 2026-09-27]** 통합 렐름 사본 아홉을 대조하는 가드가 없다. 지금은 우연히 둘로 수렴해 있다 — 일곱이 `3e76565`, java·kotlin 이 `191515a` 다. 코드 교환 이식이 클라이언트 둘을 손으로 아홉 곳에 복사했다. 다시 재는 명령: `git ls-files '*it-realm-realm.json' | xargs -n1 git hash-object`. JVM 짝이 공개 클라이언트 하나를 더 가진 것은 의도다 — 가드는 「두 집합, 그 차이만」을 고정하면 된다.

- [x] `integration-code-exchange-never-run` **[H/M · 신규·닫힘 2026-09-27 #640–#648]** 코드 교환이 이제 **9/9 통합에서 실제 Keycloak 에 대고 돈다**. 수단은 브라우저 없는 로그인이다(인가 URL GET → `kc-form-login` POST, 쿠키 직접 되싣기 → `Location` 의 code·state). 정상 흐름(교환 → refresh → introspect → logout)과 거부 넷(nonce 불일치 · nonce 없음 · 재사용 코드 · JWKS 밖 키)을 돈다. **node 에서 id_token 서명 미검증 결함이 나와 고쳤다**(#648 → node `1.0.2`). 다시 재는 명령: `grep -rliE 'exchange_?code|ExchangeCode' <각 통합 디렉터리>` → 언어마다 ≥ 1. 옮길 때의 함정(Secure 쿠키 · audience 매퍼 · 위조 RS256 은 단위 층)은 각 헬퍼 머리 주석이 소유한다.
- [ ] `integration-coverage-never-measured` **[H/L]** 9개 언어가 "경계는 통합으로 검증"이라 적고 omit했지만, 통합 실행에서 커버리지를 재는 언어가 0개다 · `.github/workflows/ci.yml:49`
  - ✅ **전제 실측(2026-09-27, 9/9, Docker).** 통합 실행에서 커버리지를 **리포트**하는 언어는 0 이다.
    - java 는 failsafe 가 `jacoco.exec` 에 적기는 하지만, 그 데이터를 읽는 리포트가 없다. IT 가 다른 모듈에서 돌고, 경계 클래스는 exclude 돼 있다.
    - 통합만의 경계 라인 %: java 59.7 · kotlin 68.8 · go 64.3(문장) · python 67.6 · node 54.4 · dotnet 61.9 · ruby 81.6 · php 34.0 · rust 80.2.
    - php 는 `Groups`·`Realms`·`Roles` 리소스가 **0%** 다(`integration-admin-surface-uneven`).
  - **판정: 두 설계를 합친다 — 퍼센트 하한만 걸면 위의 구멍을 ⌊최솟값⌋으로 동결한다.** 순서는 네 걸음이다.
    1. ✅ `integration-code-exchange-never-run` 으로 구멍부터 메운다 — 닫힘(#640–#648). 통합만의 auth 커버리지는 python 60→91 · go 43.5→88.2 · node 37→86(auth 파일, 언어별 레그 실측)으로 올랐다.
    2. omit 사본 조인 가드를 세운다(`coverage-omit-no-ssot`).
    3. 레인별 통합 전용 리포트를 **보고 모드**로 붙인다. 붙이는 세 가지:
       - include 는 단위 omit 설정에서 파생한다 — 사본을 더하지 않는다.
       - 리포트의 파일 집합을 고정한다 — 파생이 너무 적게 고르면 %가 오른다. 실측: coverlet `<Include>` 를 그대로 뒤집으면 중첩 async 타입이 빠져 211/312 가 된다.
       - 통합 미실행 함수 목록을 둔다. 항목마다 열린 등록부 id 를 소유자로 단다.
       - ⏳ go·python 파일럿 #774(보고 모드). 일곱으로 넓힐 함정·판정은 그 PR 본문.
         <!-- integration-coverage 파일럿(#774) 재측정 — 등록부 기준선 그대로 재현: go 2ab5f72^ 200/311 = 64.3% → 2ab5f72 238/311 = 76.5% → 지금 251/330 = 76.1%(경계 문장이 늘었다) · python 3fc0f1e^ 236/349 = 67.6% → 3fc0f1e 320/349 = 91.7% → 지금 367/395 = 92.9%(import 만으로 160 줄 = 40.5% — 함수 본문 207/235 = 88.1% 를 따로 낸다). 판정(파일럿 기본값): 핀은 읽을 수 있는 목록(드리프트 가드) · 소유 문제는 경고 · 하한 지표(python 줄 vs 함수 본문)와 -run TestE2E 앵커는 4 걸음째 · 규칙 문서 포인터는 go.md·python.md·ci.md 예산이 0·26·11 B 라 없음. 일곱으로 넓힐 때: 데이터가 한 번도 적재 안 된 파일도 담아야 하고, 함수 이름의 믿을 원천, 적재 시점 코드(JVM static init · Ruby/PHP require)를 「아무것도 안 돈 실행」 판정에서 빼야 한다. -->
    4. CI 관측 세 번 뒤에만 하한을 무장한다.
  - ⚠️ **리포트 구성의 함정.** java 는 `prepare-agent-integration` 으로 IT 전용 exec 를 떼야 한다 — 단위와 IT 가 같은 파일에 합쳐진다. kotlin 은 `integrationTest` 계측을 끄고 있다(`build.gradle.kts`). rust 브랜치는 stable 에서 못 잰다.
- [ ] `integration-admin-surface-uneven` **[H/M · 계수 정정 2026-09-09]** 9개 통합 스위트가 덮는 admin 표면이 제각각이다 — **clients.update 는 2/9**, realms.create/delete 는 4/9, PHP 는 roles·groups·realms 를 하나도 안 부른다
  - ⚠️ **1/9 이 아니라 2/9**(php·rust). 두 자리 다 등록부 작성보다 앞선다(`59c7916` #190 · `dc9efd7` #240) — 즉 **처음부터 틀린 계수**였다. 함께 잰 것: `users.update` 7/9(java·python 빠짐) · `clients.create` 6/9 · `roles.update`·`groups.update` 각 7/9(php·ruby 빠짐).
  - ⚠️ **PR 크기가 아니다** — php 가 roles/groups/realms 를 **0/3 계열** 부르는 것을 「구현할지 건너뛸지」가 9×capability 결정이고, 그 위에 Docker E2E 가 붙는다. · `java/keycloak-sdk/src/test/java/io/github/xzawed/keycloak/AdminOpsIT.java:48`
- [ ] `coverage-omit-overreach` **[M/M]** omit의 근거("단위테스트 불가한 네트워크 경계")가 실측으로 거짓이다 — Node는 이미 96.93%, Python은 98%인 코드를 게이트 밖에 두고 있다 · `node/vitest.config.ts:14`
  - **전 언어 실측(2026-09-27).** 단위만으로 java `AuthClient` 97.3%·`AdminClient` 100% 에 닿는다(세 모듈 exec 합산). 통합이 더하는 것은 **브랜치 1** 이다. dotnet `AuthClient` 는 단위와 합산이 같은 93.8% 다.
  - ⚠️ **「도달」은 「검증」이 아니다.** go 의 `TestHostilePathMatrix`(#636)는 단언 없이 모든 공개 메서드를 부른다. 그래서 단위 커버리지가 77.2% → 93.6% 로 오른다(`-skip TestHostilePathMatrix` 로 대조). omit 을 걷어낼 근거로 이 숫자를 쓰지 말 것.
- [ ] `coverage-threshold-parity` **[M/M]** 커버리지 임계값이 9언어에서 갈리고(브랜치 게이트가 아예 없는 곳 셋), 문서↔설정 대조 가드는 3개 언어만 본다 · `scripts/check-docs.mjs:552`
- [x] `coverage-omit-no-ssot` **[M/M · 닫힘 2026-09-27 #662]** 조인 가드가 섰다. `scripts/coverage-boundary.mjs check` 는 언어별 SSOT 아홉을 제품 소스 파일 집합으로 전개해 모든 사본과 대조한다. 첫 실행은 등록부가 잰 드리프트 셋만 냈고, 이 PR 이 셋을 고쳤다(비-required 잡 `coverage-boundary`). 잔여 SILENT 는 `coverage-boundary-guard-residuals`.
- [ ] `coverage-boundary-guard-residuals` **[L/S · 신규 2026-09-27]** 조인 가드(#662)가 계약 밖이라 못 보는 자리. 전부 독립 변이 레그와 Grok 레그의 실측이다.
  - 파일을 `sonar.exclusions` 로 옮기기
  - `.md` 코드 펜스 안의 사본 — 중간
  - go 게이트의 두 번째 omit 손잡이(`sed` · 두 번째 `grep`)
  - pom 속성 간접 참조 `${…}`, Kover `excludedSourceSets`, vitest `'!…'` 부정 패턴, SimpleCov 필터를 다른 파일로 옮기기
  - 등록되지 않은 새 사본 파일
  - 자리를 늘리거나 그 모양을 FAIL 로 · `scripts/coverage-boundary.mjs`
- [ ] `readme-quickstarts-ungated` **[M/M]** README가 정본이라 부르는 quickstart 예제가 어떤 게이트에도 안 걸린다 — 하네스가 실제로 돌리는 것은 별도 사본이다 · `node/examples/quickstart.ts:1`

### 1.0 이후 운영 — 21

- [ ] `audit-2026-09-22-doc-code` **[H/L · 신규 2026-09-22]** 전체 코드·문서 감사(17 독립 레그 + 3렌즈 반증) 결과 **91 건 중 57 건이 과반 반증을 견뎠고**, 그중 **13 건이 닫혔다(high 는 6/6 전부)** — 나머지 44 건(medium 31 · low 12 · 계수 1)이 열려 있다 · `docs/superpowers/plans/remaining-work.md:1`
  - **방법과 계수**: 발견 레그 17(횡단 8 + 언어별 9) → 91 건. 렌즈 3(증거 재도출 · 기지사실 · 오탐)이 각 건을 독립 판정 → **생존 57**(high 14 · medium 31 · low 12), **기각 34**. high 14 는 5 렌즈 심층 반증 또는 사람의 직접 확인을 거쳤다. 범주 분포와 레그별 산출은 이 항목을 만든 PR 이 소유한다.
  - **닫힌 13 건 — high 는 6/6**: #520(빈 JWKS 키셋) · #521(소비자 문서의 거짓 보안 문장 6 자리) · #523(rust 재노출 위반 둘 + 컴파일 집행 · node 커버리지 목록 · java jackson 산문) · #524(루트 README 영↔한 **구조** 미러 가드) · #527(예산 커버리지를 **부류 규칙**으로 — 숫자 하한은 마커를 지우는 PR 이 같은 diff 에서 내리면 그만이라 쓰지 않았다) · #528(CHANGELOG 착지 게이트 + `[Unreleased]` 28 건 복원). ⚠️ 무엇이 어떻게 닫혔는지는 **그 PR 의 커밋 메시지가 소유한다** — 여기 옮겨 적지 않는다(이 파일이 246 KB 까지 자란 원인이 그것이다).
  - **열린 medium 31 · low 12**: 언어별 drift 가 다수이고 **아홉 전부에서 최소 1 건**이 나왔다(범위 1–6). 대표: getting-started 의 「coverage gate」 주장이 go·rust·dotnet 세 곳에서 거짓(그 명령은 커버리지를 재지도 게이트하지도 않는다) · `php/composer.json:41` 의 `cs`/`cs:fix` 가 `--allow-risky=yes` 누락으로 **항상 실패** · `.claude/rules/{dotnet,ruby,php,rust}.md` 의 전사된 실측값이 낡아 다음 세션을 틀린 판단으로 이끈다 · PHP·Ruby 의 기본 `readTimeout` 이 10 초로 나머지 일곱(30 초)과 갈린다.
  - ✅ 위 계수가 **하한**이었던 이유는 아래 `critic-2026-09-22-round2` 가 소유한다(완전성 비평 6 각도, 2026-09-22).
- [x] `critic-2026-09-22-round2` **[H/L · 신규 2026-09-22 · 닫힘 2026-10-27]** 24 생존 중 21 닫힘(#529–#538) · 2 반증 · 남은 1 건은 `korean-api-docs-in-published-packages` 로 분리 — 열린 것이 없다
- [ ] `korean-api-docs-in-published-packages` **[M/H · 신규 2026-09-22 · 판정 2026-10-29 「번역 — 언어당 PR」]** 게시된 SDK 안의 **소비자에게 렌더링되는 문서 주석**이 한글이다 — docs.rs 가 그리고, IDE 호버에 뜨고, PyPI·RubyGems 페이지가 싣는 텍스트다 · `rust/src` 외 6
  - **판정 기준 = 산출물의 한글 0**(`git grep --no-index -P '[\x{AC00}-\x{D7A3}]'` — ⚠️ plain `grep -P` 는 거짓 0): rust `cargo doc` HTML 22 파일 → 0(#890) · node `.d.ts` 19 → 0(#891) · ruby `yard doc` HTML 26 → 0(#894) · php docblock 덤프 343 → 0(#895) · go `go doc -all` 38 → 0(#896). 대상은 그려지는 것 + README 의 quickstart 예제 · 남은 둘은 PR 마다 그 렌더러로. ⚠️ 2b 축 히트를 전후로 잴 것(줄바꿈이 「default 30」을 넘기면 빠진다).
  - ⏳ **런타임 오류 문구는 별건**(동작 — 소비자의 문자열 대조가 바뀐다): node `JWT 검증 실패: …` · ruby·php·go 0 · 나머지는 소비자에게 닿는 것부터 잰다.
  - **착수 순서**: rust·node 먼저, 그다음 python·php·ruby·go·kotlin. **판정 2026-10-29: 번역한다 — 언어당 PR**(공개 표면이고 번역 품질은 기계로 못 잰다) — 버린 선택지는 「규칙에 게시 주석 한글 예외를 명시」였다.
- [x] `remaining-work-split-to-archive-tag` **[H/M · 신규 2026-09-22 · 닫힘 2026-10-28]** #526 이 실행했다(닫힌 70 건의 서사 → 태그 · 예산 앵커 · 되살릴 조건 이관은 명령 형태가 0 건이라 no-op). 설계의 「닫힘 = 0」만은 「소유 줄 == 닫힘 수」로 바뀌었고(`test-remaining-work-shape.sh` 머리 주석), 뒤이은 이관은 머리말의 포인터가 가리킨다.
- [x] `changelog-unreleased-never-written` **[M/S · 신규 2026-09-22 · 닫힘 2026-10-27]** 착지 장치 `scripts/test/test-changelog-landing.sh` 가 섰고 `[Unreleased]` 가 착지마다 자란다 — 150 건은 역채우지 않았다
- [x] `jwks-empty-keyset-node` **[M/M · 신규 2026-09-22 · 닫힘 2026-09-24]** 「구조 변경뿐」이라는 전제가 틀렸다 — 기각된 두 길(getKey 래핑·별도 프리플라이트) 밖에 셋째가 있었다: 이미 배선된 `[customFetch]` 래퍼는 jose 가 파싱할 **바로 그 응답**을 보고, jose reload 는 fetch 가 던지면 옛 캐시를 남긴다(`jose/dist/webapi/jwks/remote.js` `.then` 안에서만 대입). jose 원격 집합을 그대로 상속한다 · `jwt-jwks.test.ts` 수정 전 RED → GREEN · 변이 CAUGHT
- [x] `jwks-empty-keyset-jvm-dotnet-undetermined` **[M/S · 신규 2026-09-22 · 닫힘 2026-09-24]** 셋 다 **오염됐다** — 판정 불가가 아니었다. ⚠️ dotnet 은 첫 판정이 「면역」이었는데 LKG 폴백이 가린 것이었다(현재 설정 키 0 · LKG 끄면 IDX10500) — 그래서 테스트가 LKG 를 끄고 단언한다(켜면 수정 없이도 초록, 대조군 실측). `RefreshInterval = 0` 은 IDX10107 로 거부된다(하한 1s) · JwksEmptyKeyset 테스트 셋(변이 3/3 CAUGHT + 대조군 SILENT)
- [x] `nightly-failure-reaches-nobody` **[H/M · 신규 2026-09-16 · 닫힘 2026-09-21 #518]** 야간이 여드레 빨간 동안 아무 조치가 없었다 — 저장소 안에 **실패가 사람에게 가는 경로가 0건**이다 · `.github/workflows/harness.yml:8`
- [ ] `codeql-kotlin-extractor-lags-kgp` **[M/M · 신규 2026-09-21]** CodeQL 의 Kotlin 추출기가 KGP 를 못 따라와 **JVM 두 언어의 코드 스캐닝이 통째로 멈춘다** — KGP 2.4.20 에서 `KotlinVersionTooRecentError: Kotlin version 2.4.20 is too recent. CodeQL currently supports versions below 2.4.20` 로 autobuild 의 `:compileKotlin` 이 죽고, `java-kotlin` 은 Java 와 Kotlin 이 **한 데이터베이스**라 Java 분석까지 함께 사라진다 · PR #515 가 이것으로 막혀 있다(doc-facts 는 초록, CodeQL 만 빨강 — main 과 다른 PR 은 초록이라 원인이 KGP 범프임이 대조로 확정됐다). ⚠️ **CodeQL 은 required 가 아니라 병합은 된다** — 병합하면 main 이 조용히 빨개지고 아무도 스캔하지 않는 상태가 남는다(배포 시크릿 미설정을 스킵으로 끝내던 것과 같은 모양). ⚠️ 이 저장소의 CodeQL 은 `.github/workflows/` 에 파일이 없는 **default setup** 이라 번들을 핀하거나 앞당길 수 없다(실패 번들: CodeQL CLI 2.27.0). 되살릴 조건(명령): `gh run list --workflow=340524379 --limit 20 --json headBranch,conclusion --jq '.[]|select(.headBranch=="refs/pull/515/head")|.conclusion'` 가 `success` 를 낼 때 — 그때 #515 를 그대로 병합한다(문서 작업은 `e7f18f6` 에 이미 올라가 있다).
- [ ] `push-lane-failures-still-silent` **[M/S · 신규 2026-09-21]** `nightly-alert` 은 **`schedule` 만** 본다 — `sonarcloud` 처럼 push 로만 도는 레인의 빨강은 여전히 아무에게도 안 간다(실측: 09-16~09-21 닷새 무성, 그 창은 `nightly-failure-reaches-nobody` 의 야간 창과 **겹치지 않는다**) · `.github/workflows/nightly-alert.yml:38`. ⚠️ 그리고 `nightly-alert` **자기 실패는 못 잡는다**(`workflow_run` 은 자기를 감시 못 한다). schedule 로 넓힌 판정은 소음을 피하려던 것이라, 넓히려면 「민 사람이 이미 보는 실패」와 「main 에서 조용히 빨간 실패」를 가르는 기준이 먼저 필요하다.
- [x] `registry-truth-check` **[H/M · 닫힘 2026-09-24]** `scripts/check-registry-truth.mjs` — 유예(Maven 72h·나머지 24h, 시계=태그 또는 SSOT 커밋)로 「첫 404 로 실패 결론」을 피하고, Maven 은 metadata 가 아니라 pom 200 으로 판정 · 주간 `published-floor.yml` · 자가테스트 47/0 · 변이 8/8 CAUGHT
- [x] `stale-release-comments` **[H/S · 닫힘 2026-09-09 #447]** 릴리스 경로의 주석 **여섯**이 낡았고, 그중 하나는 다음 릴리스를 정반대로 오도했다 · `.github/workflows/install-smoke.yml:57`
- [x] `post-1-0-registry-missing` **[M/S]** 1.0 이후 잔여작업 등록부가 저장소 어디에도 없다 — 안 닫힌 항목은 복원 불가능하다 · `docs/README.md:49`
- [ ] `public-registry-install-smoke` **[M/L]** 게시된 1.0.0 을 공개 레지스트리에서 받아 설치·컴파일해 보는 정기 검증이 없다 · `harness/install/install-verify.sh:11`
- [ ] `advisory-path-never-run` **[M/M]** 보안 권고·회수 경로가 문서에만 있고 한 번도 실행된 적 없다 · `SECURITY.md:141`
- [ ] `divergence-rehearsal-artifact` **[M/M]** 함대가 갈리는 릴리스에서 새로 써야 하는 분기 문장 8건에 초안이 없다 · `scripts/test/test-publication-claims.sh:704`
- [ ] `keycloak-server-tag-ssot` **[M/L]** Keycloak 서버 태그가 18개 파일에 복제된 채 떠 있고, 호환성 표의 「actual 26.6.4」는 재현 불가한 스냅샷 · `docs/reference/compatibility.md:20`
- [ ] `harness-consume-pin-unsupported` **[L/S]** 주간 OSV 감사가 지원 대상이 아닌 0.1.0 트리를 재고 있다 · `harness/install/consume/kotlin-app/build.gradle.kts:36`
- [ ] `npm-rc-dist-tag-residue` **[L/S]** npm `rc` dist-tag 가 지원하지 않는 0.1.0-rc.2 를 아직 서빙한다 · `DEPLOY.md:503`
- [x] `php-admin-client-0.44-upgrade` **[L/M · 닫힘 2026-10-09 #759]** 0.44 가 감싼 예외를 `ErrorTranslation` 이 벗긴다(#750 대체)
- [ ] `kotlin-pom-description-jdk-floor` **[M/S · 신규 2026-10-27]** 게시 POM `<description>` 이 「JDK 21+」다 — 하한은 1.0.1 부터 17(`JVM_17` · `-Xjdk-release=17`)인데 1.0.1–1.0.7 이 그 문구다(repo1 .pom) · `kotlin/build.gradle.kts:266`

### 완전성 비평 신규 — 25

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
- [x] `java-short-code-verifier-leaks-iae` **[M/S · 신규·닫힘 2026-09-25 #585]** 아홉을 쟀다 — 잘못된 verifier 를 로컬에서 거부하는 것은 JVM 짝(Nimbus)뿐이고 자매 일곱은 전송 → 400 → SDK 인증 오류다. 부류 재스캔이 verifier 밖으로 넓혔다: 빈 code·refresh·introspect 토큰, client_credentials 공백 scope(전례가 인가 요청만 고쳤다), kotlin 문자열 redirectUri, Nimbus `build()` 의 redirect_uri 검사(Grok 레그가 찾음), java null 셋 — 전부 SDK 타입으로, 변이 22/22 CAUGHT · `java/keycloak-sdk-auth/src/test/java/io/github/xzawed/keycloak/auth/AuthClientInputBoundaryTest.java`
- [x] `jvm-config-values-leak-lower-exceptions` **[M/M · 신규·닫힘 2026-09-25 #588]** 아홉을 쟀다 — 같은 설정값에서 SDK 밖 예외가 새는 것은 JVM 짝만이 아니었다(ruby·dotnet·node 는 아래 신규 항목). JVM 은 생성 시점 검증(serverUrl 절대 http(s)·authority·`toURL`·포트 · 타임아웃 1 ms~int ms · null 목록 · clockSkew·jwksMinRefetch ≥ 0 과 밀리초 표현) → `KeycloakConfigException`, realm 은 엔드포인트에서만 퍼센트 인코딩, openid 없는 scopes 는 자매 일곱처럼 그대로 보냄 — 「덧붙인다 vs 거부한다」 판정은 측정이 셋째 안(통과)으로 정했다. Kotlin 은 Grok 레그가 구현했고, 다른 레그의 적대적 계약 프로브(927 사례)가 남은 누출을 찾아 같은 PR 에서 닫았다(최종 위반 0) · 변이 31/31 · `java/keycloak-sdk-core/src/main/java/io/github/xzawed/keycloak/core/KeycloakConfig.java`
- [x] `config-url-values-leak-ruby-dotnet-node` **[M/M · 신규 2026-09-25 · 닫힘 2026-09-26 #589]** 셋 다 생성 시 ConfigError — ruby(URI::HTTP·host·port, realm 은 엔드포인트에서만 인코딩) · dotnet(`Uri.TryCreate` Absolute + http(s)) · node(`new URL` + http(s)). 밑줄 호스트는 셋 다 받는다(실측). ruby·dotnet 은 Grok 레그가 구현, 변이 7/7 · 음수 타임아웃 동형 문제는 아래 신규 항목 · `ruby/lib/keycloak_sdk/config.rb`
- [x] `config-timeouts-accept-negative-node-python-php` **[L/S · 신규·닫힘 2026-09-26 #590]** 셋의 0·음수를 먼저 쟀다 — 누출은 없고 쓸 수 없거나 위험한 설정이었다(php 0 = 무한 대기, node 2^31 이상 = 타이머가 1ms 로 바꿔 즉시 abort, python admin 은 즉시 실패). 셋 다 타임아웃 유한 > 0(node 는 ≤ 2147483647), skew·재조회 유한 ≥ 0 → 생성 시 ConfigError. python·php 는 Grok 레그가 구현, 변이 10/10 · `node/src/config.ts`
- [ ] `release-publish-job-holds-contents-write` **[M/S · 신규 2026-09-25]** dotnet·php 에서 레지스트리 자격증명(`NUGET_API_KEY` · `PHP_SPLIT_TOKEN`)을 쥔 잡이 `gh release create` 때문에 저장소 `contents: write` 도 쥔다 — 게시와 Release 를 잡으로 나누면 풀리지만 그것은 `irreversible-publish-no-reentry` 의 보류된 안이라, **권한만을 위한 분리**가 값을 하는지는 별도 판정이다 · `.github/workflows/dotnet-release.yml`
- [x] `go-facade-dump-leaks-secret` **[H/S · 신규·닫힘 2026-09-26 #592]** `*Client`·`*AuthClient` 가 fmt 다섯 동사 전부에서 클라이언트 시크릿을, 토큰 provider 가 캐시된 액세스 토큰을, `*AdminClient` 가 `%s`·`%q` 에서 그 토큰을 원문으로 찍었다(실측) — 비공개 필드는 fmt 가 `Config.String()` 을 못 부른다. 넷에 String·GoString + 도달 객체 걷기 테스트, 변이 8/8 · `go/facade_dump_test.go`
- [x] `php-facade-dump-leaks-secret` **[M/S · 신규·닫힘 2026-09-26 #593]** php 파사드의 `var_dump`·`print_r` 가 클라이언트 시크릿과 **살아 있는 PKCE verifier** 를 원문으로 찍었다(실측). 새는 것을 쥔 자리에만 `__debugInfo`(league 프로바이더 · AdminClient · 리소스 다섯) — 두 파사드 훅은 변이가 SILENT 라 뺐다. go 와 같은 걷기 테스트, 변이 12 · `php/tests/Unit/FacadeDumpTest.php`
- [x] `php-jwtvalidator-trace-arg` **[M/S · 신규·닫힘 2026-09-26 #593]** `JwtValidator::validate`·`decodeHeader` 에 `#[\SensitiveParameter]` — #467 의 파생 정규식이 이름 `jwt` 를 못 골라 빠졌다. 정규식에 더하자 정확히 그 둘이 RED, `$jwt` 선택을 대조군으로 고정 · `php/src/JwtValidator.php`
- [ ] `php-exception-trace-third-party-args` **[L/M · 신규 2026-09-26]** `introspect`·`logout` 이 Guzzle `request()` 옵션으로 넘긴 토큰·Basic 헤더·클라이언트 시크릿이 `previous` 예외의 **Guzzle 프레임 인자**로 `var_dump`·`print_r` 에 찍힌다(실측, `zend.exception_ignore_args=0` — 운영 php.ini 는 1). `#[\SensitiveParameter]` 는 제3자 프레임에 못 닿는다. PSR-7 요청 + `send()` 면 본문은 스트림이라 안 찍히나 introspect 의 Basic 헤더는 남는다 — `FacadeDumpTest` 의 `KNOWN_LEAKS` 넷이 고정한다(고치면 낡은 항목으로 실패) · `php/src/AuthClient.php`
<!-- 2026-10-05(php 물결 4 검증 레그): admin()->raw() 도 같다 — raw() 가 내는 Guzzle 오류(401 대조군 ClientException)를 var_dump 하면 트레이스 인자에 클라이언트 시크릿이 있다(zend.exception_ignore_args=0). 물결 전부터다. -->
- [ ] `go-nonstring-verb-bypasses-stringer` **[L/S · 신규 2026-09-26]** go 의 `%d` 류(비문자열 동사)는 `Stringer` 를 안 타 `Config`·`TokenSet`·`AuthorizationRequest`·파사드·provider 가 비밀을 찍는다(Grok 레그 818 사례 중 92, 재현). 바닥(`%v %+v %#v %s %q`) 밖이고 `go vet` printf 가 그 호출을 경고한다 — `fmt.Formatter` 로 닫을 수 있다. ⚠️ 같은 레그의 `json.Marshal`·slog JSON(컨테이너 안) 누출은 **설계 경계**다(`MarshalJSON` 은 왕복을 `***` 로 오염시킨다) · `go/config.go`
- [x] `dotnet-cached-record-tostring` **[L/S · 신규·닫힘 2026-09-26 #594]** `ClientCredentialsTokenProvider.Cached` 레코드의 컴파일러 `ToString` 이 캐시된 액세스 토큰을 찍었다(실측) — 모양은 두고 `ToString` 만 덮었다. Grok 레그가 명세대로 구현(RED → 104), 변이 CAUGHT · `dotnet/src/Xzawed.Keycloak.Sdk/ITokenProvider.cs`
- [x] `probe-new-file-mutation-dies-silent` **[M/S · 신규·닫힘 2026-09-26 #591]** 새 파일만 만드는 변이에서 `probe.sh` 가 판정 없이 1(SILENT 의 코드)로 죽었다 — diff 가 비면 자리 검사의 `grep` 파이프가 1 을 내 `set -e` 가 끝냈다(실측: 0 바이트 · exit 1). `|| true` 한 곳 + 판정 줄을 보는 자가테스트 둘(RED → 18/18) · `scripts/probe.sh`
- [x] `probe-verdict-line-glued-or-name-split` **[L/S · 신규·닫힘 2026-09-26 #595]** Grok 레그의 퍼저(193 사례, 인자 이동 버그를 고쳐 돌림)가 러너 계약 위반 둘을 냈다 — 끝 개행 없는 새 파일이면 판정 줄이 미리보기 뒤에 붙어(`+plantedCAUGHT — …`) `^CAUGHT` 로 읽는 쪽이 판정을 못 보고, 이름에 공백이 든 새 파일은 `for … in $(…)` 가 쪼개 맞는 변이를 INVALID 로 거부했다. 나머지 INVALID 는 전부 fail-closed. 자가테스트 둘 RED → 20/20, 되돌림 변이 둘 CAUGHT · `scripts/probe.sh`
- [x] `node-error-cause-carries-response-tokens` **[M/S · 신규·닫힘 2026-09-26 #603]** 형식이 틀린 토큰 응답에서 난 오류가 cause 사슬로 토큰을 찍었다 — oauth4webapi 가 응답 본문 전체나 원문 id_token 을 `cause` 에 싣고 SDK 가 그대로 달았다. 실측: id_token 이 JWT 가 아니면 `console.log(err)` 에 원문 id_token, access_token·expires_in·token_type 이 틀리면 깊은 inspect 에 access/refresh 토큰. 걷기 테스트(#599)가 첫 경우를 잡았다. `KeycloakError` 생성자 한 곳에서 cause 를 이름·메시지·code·스택 사본으로 — 원본 하위 오류도 안 샌다(§4). ⚠️ Grok 적대 레그가 그 사본에서 하나 더 찾았다: 200 에 JSON 아닌 본문이면 `SyntaxError` 가 본문을(짧으면 전부, 길면 앞 10 자) 메시지·스택에 인용한다 — 그 둘은 옮기지 않는다. 변이 6/6 · `node/src/errors.ts`
- [x] `error-cause-chain-carries-response-body-crosslang` **[M/M · 신규 2026-09-26 · 닫힘 2026-09-26 #617–#624]** 여덟 전부 샜다 — 먼저 쟀다(수정 전, 언어당 변형 17–40 · 누출 6–18): java·kotlin `Caused by:` 가 비-JSON 본문·토큰째, python 트레이스백·메시지, go `RetrieveError` 본문·`error_description`, .NET `ToString()` 내부 예외, php `getPrevious()` 원본과 트레이스 인자, rust `oauth_error` 의 `error_description`, ruby `full_message`·`Faraday::ParsingError#inspect`. 되울린 `error_description` 이 보낸 refresh·code·verifier·Basic 을 싣는 경로도 여럿. 각 경계에서 하위 원인을 타입 이름·프레임만 남긴 사본으로 · 보낸 비밀은 `***` · 코드 모양만 OAuth 오류로. 언어마다 변이 8–13 CAUGHT, Grok 레그(ruby 는 여섯째 시도) 주장 측정·채택. 워크플로 한 번(격리 워크트리 여덟)
- [ ] `error-description-foreign-token-residue` **[L/S · 신규 2026-09-26]** 위 수정이 **설계상 남긴** 자리 일곱 — `KNOWN_LEAKS` 가 고정한다(낡으면 실패): java 셋(보내지 않은 20 자 미만 값·소문자만의 긴 값이 `error_description` 에 — 산문 식별자와 가를 수 없다), kotlin 둘(남의 토큰을 되울린 `error_description`), .NET 둘(서버가 OAuth `error` **코드 자리**에 토큰을 넣음 — 코드 모양이면 그대로 둔다). 모두 IdP 가 이미 가진 값이나 적대적 IdP 가 심은 값이다 — 더 좁히려면 오류 설명을 통째로 버리는 결정이 필요하다 · `*/…MalformedTokenResponse*`
<!-- 2026-10-05(kotlin 물결 4 구현 레그, 소스 판독 — 미측정): java 는 보낸 시크릿과 10 자 창을 공유하는 런과 20 자 이상의 토큰 모양 런까지 가리고(AuthClient.java:346-420) kotlin 은 정확한 꼴(+ #718 의 되울림 꼴)만 가린다 — 잘리거나 다시 인코딩된 되울림은 kotlin 메시지에 남을 수 있다. -->
- [ ] `rust-admin-unreachable-classified-admin` **[L/S · 신규 2026-09-26]** rust 에서 도달 불가 서버로의 admin 호출이 `Transport` 가 아니라 `Admin(Other{401})` 로 나온다 — 파사드의 `send` 가 토큰 획득 실패를 전부 `Admin(Other{401})` 로 낸다(`raw()` 는 `SdkTokenSupplier` 의 `HttpFailure{401}`). 걷기 테스트가 그 분류를 지금 그대로 단언한다(`rust/tests/facade_dump.rs` 「admin get_user unreachable」) — 고치면 그 단언도 함께 · `rust/src/admin.rs`
- [ ] `java-admin-token-401-classified-transport` **[L/S · 신규 2026-09-26 · 재현 필요]** java 걷기 레그의 관측: 잘못된 realm 으로 admin 토큰 요청이 401 을 받으면 `KeycloakTransportException`("admin transport failure")으로 나온다 — RESTEasy 가 토큰 필터의 `NotAuthorizedException` 을 `ProcessingException` 으로 감싸 `AdminExceptions` 가 전송으로 매핑한다는 진단. 걷기 테스트는 기반 예외만 단언해 고정되지 않았다 · `java/keycloak-sdk-admin`
- [x] `token-type-library-behaviour-unpinned` **[M/S · 신규·닫힘 2026-09-25 #581]** go·java·kotlin 이 비문자열 `access_token` 거절을 라이브러리(x/oauth2 · Nimbus)에 맡기면서 그 행동을 고정한 테스트가 0 이었다 — go 는 전제부터 미측정(실측: 여섯 다 `*AuthError`). 셋 다 표 테스트로 고정, 파싱 실패를 삼키는 변이에 go·java CAUGHT(kotlin 미측정) · `go/auth_test.go`

---

## 닫는 조건

전 항목이 체크되면 `doc-status` 를 `complete` 로 내리고(가드가 강제한다), 아카이브 태그로 내린 뒤 [지도](../../README.md) §3 에서 지운다. 기각으로 닫는 항목은 미체크로 남기고 [기각 레지스트리](../../governance/rejected.md)에 **되살릴 조건과 함께** 옮긴다 — 미체크가 0 이 아니어도 `complete` 로 내릴 수 있는 이유가 그것이다.
