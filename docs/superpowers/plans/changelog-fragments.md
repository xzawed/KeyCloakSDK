<!-- doc-status: active -->
<!-- doc-budget: max-bytes=47045 -->
# CHANGELOG 조각 파일 — 미출시 변경을 상한 걸린 한 절에서 꺼낸다 (설계)

**이 문서가 답하는 것** — 미출시 변경 노트를 어디에 어떤 꼴로 두고, 릴리스가 그것을 어떻게 날짜 절로 옮기며, 무엇이 그 전환을 지키는가.

## 1. 왜

검사 8d(`scripts/check-docs.mjs` — #868)는 `CHANGELOG.md` 의 **머리말 + `[Unreleased]` 를 64 KiB 안에** 묶는다. 날짜 절은 월별 보관본으로 회전되지만 `[Unreleased]` 는 회전되지 않고, 비우는 길은 릴리스뿐이다.

실측(`git show <sha>:CHANGELOG.md` 를 원장 파서로 — 2026-11-23):

- 11-03 물결 뒤 2.4 KB → 18 일 뒤 65.5 KB. **하루 약 3.5 KB · 항목 5 개.** 지금 97 항목(평균 약 665 B), 그중 27 은 여러 언어(13 은 8 언어 이상), 언어마다 21–36.
- 아홉 언어는 따로 릴리스하고, 사용자는 릴리스를 드물게 원한다(2026-11-10). → **릴리스를 아낄수록 막힌다.** 64 KiB 는 마지막 물결 뒤 약 18 일에 찬다.
- 같은 구조의 부작용 둘: 여러 언어 항목을 릴리스 때 손으로 언어 절마다 옮긴다(DEPLOY.md 릴리스 1 단계 — 10-31 물결부터 같은 항목이 언어 절마다 복사됐다) · 병렬 PR 이 `### Fixed` 머리에서 매번 충돌한다.

## 2. 목표 · 비목표 · 반목표

- **목표** — 미출시 노트가 상한 걸린 한 절에 쌓이지 않는다 · 릴리스가 물결 하나의 노트를 명령 하나로 날짜 절로 옮긴다 · PR 끼리 노트 자리에서 충돌하지 않는다 · 「게시 소스를 고치면 노트가 있다」를 지금보다 **강하게**(언어까지) 지킨다.
- **비목표** — 릴리스 주기를 바꾸지 않는다 · **이미 나간** 날짜 절 · 월별 보관본 · 회전은 그대로다(새 물결의 꼴만 §5.3 으로 바뀐다) · 노트의 문체(한글 · 항목 1,024 B) · GitHub Release 본문 생성(릴리스 워크플로는 CHANGELOG 를 읽지 않는다).
- **반목표** — 노트가 조용히 빠지거나 다른 언어 절에 들어가는 것 · 미출시 변경을 사람이 못 보게 되는 것 · 릴리스의 손일이 늘어나는 것 · 노트의 소재지가 둘이 되는 것.

## 3. 제약

- required 체크는 `doc-facts` · `shell-exec-bits` 뿐이다 — 새 판정은 `doc-facts` 안에서 돌아야 필수가 된다(지금의 착지 게이트가 그 자리다).
- `check-docs.mjs` 는 저장소의 **모든 `.md`** 를 훑고 각각에 `doc-budget` 앵커를 요구한다(예외: 원장 · 언어 README) · 8d 는 `changelog/` 에 월별 보관본 말고는 두지 못하게 한다.
- 8d 는 `## ` 제목으로 `[Unreleased]` 와 `[<무엇>] - <YYYY-MM-DD> …` 만 받고, 루트와 보관본을 통틀어 같은 제목을 두 번 받지 않는다. 대괄호 안을 판 번호로 읽는 소비자는 없다(2026-11-24 검색 — 원장 파서 · 8d · 회전기 · 자가시험뿐).
- 8d 의 보존 규칙(기준의 날짜 절은 사라지지 않고, 보관본은 고치지 않는다)과 새 절의 항목 상한(1,024 B — 머리말 문단 포함)은 그대로 산다.
- 검사 8c 는 `CHANGELOG.md` 와 보관본마다 **256 KiB** 를 넘지 못하게 한다(`DOC_TRIPWIRE_BYTES`) · 루트 64 KiB 는 날짜가 하나뿐이면 풀린다(회전은 날짜를 쪼개지 않는다).
- `scripts/` 의 판정기는 `repo-hygiene.yml` 이 돌리는 자가시험이 있어야 하고(마지막 줄 `assert_report`), 판정의 거부는 변이 레코드가 지킨다.
- Windows 작업 트리는 CRLF 다 — 파서는 줄 끝을 LF 로 맞춰 읽는다.

## 4. 접근 — 검토한 셋

| 안 | 내용 | 대가 | 판정 |
|---|---|---|---|
| **A 조각 파일** | 변경마다 파일 하나, 릴리스가 물결로 모은다 | 도구 · 게이트 개편 · 97 항목 이관 · 미출시 노트가 흩어져 보임 | **채택** |
| B 언어별 CHANGELOG | 언어마다 `[Unreleased]` 와 상한 | 다언어 항목을 최대 9 번 복사(사본 금지 위반) · 언어마다 같은 문제가 작게 되풀이 | 기각 |
| C 규칙 조정 | 항목 400 B · 상한 128 KiB | 약 5 주마다 다시 막힌다 · 충돌 · 손 분할 그대로 | 기각 |

임계치 자동 릴리스는 「릴리스는 드물게」와 맞지 않아 후보에서 뺐다. A 는 사용자 수용(2026-11-23)이고, Grok 독립 레그(계약 · 사실 인라인 · 선택지 순서 섞음)도 A 를 골랐다 — 최대 위험으로 「조각이 잘못 분류돼 노트가 빠져도 릴리스 전까지 모른다」를 짚었고, 그 대책이 §5.5 다.

**물결 크기**(빌더 검토, 2026-11-24) — 언어 절마다 복사하는 지금 관행이면 지금 대기분(고유 64,468 B)이 판 번호가 모두 다른 아홉 언어 물결에서 163,038 B(2.53 배)다 → 약 30 일 대기로 8c 에 닿아 그 물결의 버전 범프 PR 이 막힌다(지금은 64 KiB 상한이 간접적으로 막는다). 사용자 결정(2026-11-24): **물결 공통 절**(§5.3). 기각: 지금 꼴 + 경고(약 30 일이라는 숨은 주기 제약) · 원장만 경보선 512 KiB(가드 완화).

## 5. 설계 — 정한 것

### 5.1 조각 파일

- 자리: 저장소 루트 `changelog.d/` · 이름 `<YYYY-MM-DD>-<slug>.txt`(만든 날 · 등록부 id 나 짧은 kebab). **`.md` 가 아니다** — 문서 가드(§3)의 대상이 아닌 데이터다.
- 꼴: 머리 줄들 · `---` · 본문.
  ```
  langs: python ruby
  section: Fixed
  ---
  ⚠️ 본문 — 지금 항목의 「**(태그)**」 뒤 글과 같다(한 문단).
  ```
- `langs` 는 `scripts/lib/deploy-facts.sh` 의 `DEPLOY_LANGS` 토큰(새 언어 목록을 만들지 않는다), `section` 은 Keep a Changelog 의 여섯(Added · Changed · Deprecated · Removed · Fixed · Security). **릴리스는 내보낸 언어를 `langs` 에서 뺀다** — 남은 `langs` 가 곧 미출시다.
- 한 줄로 컴파일하면 `- **(<표시명들>)** <본문>` — 표시명(토큰 → `.NET` 등, 대응표는 공통 파서가 갖는다)과 순서는 `DEPLOY_LANGS` 에서 파생. 태그는 **그 자리에서 내보내는 언어**다(미리보기는 `langs` 전부, 날짜 절은 그 물결이 내보내는 언어 — 날짜 절은 그 판이 담은 것의 기록이다). 상한 1,024 B 는 `langs` 전부로 컴파일한 줄(가장 긴 꼴)에 건다.

### 5.2 루트의 `[Unreleased]`

제목은 남기고 내용은 **고정된 한 문단**(조각의 자리와 미리보기 명령을 가리킨다)뿐이다. 항목을 다시 적으면 검사가 거부한다.

### 5.3 릴리스 — 물결 하나를 명령 하나로

`node scripts/changelog.mjs release [--date YYYY-MM-DD] <lang>=<version> …` 가 물결 하나(지금처럼 버전 범프 커밋 하나)를 `[Unreleased]` 바로 아래에 만든다:

1. 판 번호가 같은 언어는 한 절로 묶는다 — `## [1.0.7] - 2026-10-31 (Python · .NET · Node)`(지금 관행).
2. 절이 둘 이상이면 맨 위에 **공통 절** `## [물결] - <날짜> (<표시명> <판> · …)` 을 둔다. 물결 머리말과, 내보내는 언어가 두 절 이상에 걸친 조각이 거기 **한 번만** 산다. 언어 절은 그 절의 언어로만 나가는 조각을 담고, 첫 줄이 공통 절을 가리킨다(지금 손으로 쓰는 「같은 물결의 나머지는 위 … 절의 머리말」). 제목의 판 번호는 같은 날 두 물결에도 제목이 겹치지 않게 한다(§3).
3. 절 안은 `### <section>` 여섯의 정해진 순서, 항목은 조각 이름순.
4. 각 조각의 `langs` 에서 그 물결의 언어를 빼고, 비면 파일을 지운다.

물결 머리말과 언어 절의 손글(판 종류 · 공개 API 변경 수 · 같은 번호 경고)은 지금처럼 그 커밋에서 사람이 쓴다. DEPLOY.md 릴리스 1 단계의 「손으로 옮긴다」를 이 명령으로 바꾼다.

크기: 물결 하나 ≈ 대기 노트의 고유 바이트 → 8c 까지 약 75 일(256 KiB ÷ 하루 3.5 KB). 그 너머는 8c 의 기존 길(같은 PR 에서 상한을 올리는 사람 판정)이고, §5.5 가 미리 알린다.

### 5.4 미리보기

`node scripts/changelog.mjs preview [<lang>]` — 모든 언어(지금의 `[Unreleased]` 와 같은 꼴) 또는 한 언어의 다음 릴리스 절을 찍는다. `--stats` 는 언어마다 대기 수 · 바이트와 아홉 언어 물결의 예상 크기(8c 대비)를 찍는다(정보).

### 5.5 검사(`doc-facts` 안)

`node scripts/changelog.mjs check` —

- 조각마다: 머리 키 · `langs`(비지 않고 겹치지 않고 아홉 안) · `section` · 비지 않은 본문 · 1,024 B · 이름 꼴.
- **시험 컴파일** — 아홉 언어 물결(판 번호 모두 다름)과 한 언어씩의 물결 아홉에서, 각 조각이 자기 `langs` 를 내보내는 물결마다 정확히 한 번, 그 밖에는 0 번(Grok 레그가 낸 회귀 방지 검사).
- 루트 `[Unreleased]` 가 §5.2 의 고정 문단 그대로.
- 대기 노트가 8c 의 75 % 를 넘으면 **경고**(실패 아님 — 약 19 일 앞서 알린다). 경보선 수는 check-docs 의 것을 읽는다(사본 금지).

### 5.6 착지 게이트

`scripts/test/test-changelog-landing.sh` 의 실제 트리 판정을 바꾼다: 범위(기준 merge-base)에서 **게시 소스가 바뀐 언어마다**, 그 범위가 **더한 조각 중 그 언어를 `langs` 에 가진 것이 하나 이상**. `[no-changelog: <이유>]` 면제는 그대로. 「줄이 늘었는가」보다 강하다 — 다른 언어의 조각으로는 통과하지 못한다.

### 5.7 검사 8d

`[Unreleased]` 의 항목 상한이 조각의 상한(§5.1)으로 옮겨가고, `[Unreleased]` 는 §5.2 꼴만 받는다. 공통 절은 지금의 날짜 절로 읽혀 회전 · 보존 · 새 절 항목 상한이 그대로 걸린다. 루트 64 KiB · 보관본 · 보존 규칙은 그대로다.

### 5.8 이관

전환 PR 에서 지금 `[Unreleased]` 항목(97 — 그때 다시 센다)을 조각으로 바꾼다: 굵은 태그 → `langs`(`(전 언어)` 는 아홉), 감싼 `###` → `section`, 나머지 → 본문. **검증**: 이관 뒤 전체 미리보기의 항목 다중집합(`section` · 언어 집합 · 본문)이 이관 전 `[Unreleased]` 와 같다 — 허용되는 차이는 태그 순서뿐(§5.1). 실측(2026-11-24): 태그 23 가지가 전부 아홉 이름으로 읽히고, 정규 순서로 바꿔도 가장 긴 항목은 1,001 B 그대로다.

### 5.9 문서

`CLAUDE.md` 문서 규칙 표의 CHANGELOG 행 · `DEPLOY.md` 릴리스 1 단계 · `CONTRIBUTING.md`(영문 — 지금 노트 안내가 아예 없다)에 조각 쓰는 법 · 등록부 진입점의 8d 메모.

## 6. 빌더에게 남긴 것

- 머리 줄의 세부 문법(주석 · 공백) · CLI 인자 꼴 · 오류 문구 · 공통 파서의 자리(`scripts/lib/`) · 8c 경보선 상수를 함께 읽는 길.
- 공통 절을 가리키는 줄의 문구 · 도구가 언어 절의 손글 자리를 어떻게 비워 두는지.
- 이관한 조각의 날짜 · 순서(가능하면 각 항목이 들어온 커밋의 날짜, 못 정하면 이관일 + 지금 순서).
- 기존 조각에 언어를 더한 변경이 §5.6 을 채우는지 · 노트 없는 릴리스(의존성만 올린 판)의 처리.
- PR 나누기(도구 → 전환) — 전환(이관 · 게이트 · 8d · 문서)은 한 PR 이어야 사이에 깨진 상태가 없다.

## 7. 진행

- [x] 설계 승인(사용자, 2026-11-24)
- [ ] 계획(WBS) — §8, 사용자 확인
- [ ] PR 1 도구 — 과제 1–7
- [ ] PR 2 전환 — 과제 8–11
- [ ] PR 3 마감 — 과제 12

## 8. 구현 계획

> **에이전트 작업자에게:** 필수 하위 스킬은 superpowers:subagent-driven-development(권장) 또는 superpowers:executing-plans 다. 과제마다 단계 체크박스로 추적한다.

**목표** — `changelog.d/` 조각과 `scripts/changelog.mjs`(check · preview · release · migrate · covered)로 미출시 노트를 상한 걸린 `[Unreleased]` 에서 꺼내고, 8d 와 착지 게이트를 그 꼴로 바꾼다.

**구조** — 문법은 `scripts/lib/` 의 셋이 소유한다: 원장(`changelog-ledger.mjs` — 루트 꼴) · 조각(`changelog-fragments.mjs` — 파일 문법 · 언어 표) · 물결(`changelog-wave.mjs` — 컴파일 · 독립 대조 · 트리 검사). CLI · check-docs 8d · 착지 게이트는 부르기만 한다. PR 1 = 도구 + 자가시험(실제 트리의 판정은 그대로), PR 2 = 이관 · 8d · 게이트 · 문서를 한 PR 로, PR 3 = 마감.

**기술** — Node 22 ESM(새 의존 없음) · POSIX sh 자가시험(`scripts/test/assert.sh`) · git CLI. **스펙** — 이 문서 §1–§6.

### 8.1 전역 제약

- 조각 `changelog.d/<YYYY-MM-DD>-<slug>.txt` = 머리 `langs:`(`DEPLOY_LANGS` 토큰) · `section:`(Added · Changed · Deprecated · Removed · Fixed · Security) · `---` · 본문 한 줄.
- 컴파일한 줄 `- **(<표시명 · …>)** <본문>` — 표시명 · 순서는 `DEPLOY_LANGS`, 태그는 그 자리에서 내보내는 언어. 상한 1,024 B(`BULLET_MAX_BYTES`)는 `langs` 전부로 컴파일한 줄 + 줄 끝 `\n` 에 건다 — 8d 가 날짜 절 항목을 재는 단위와 같다.
- 물결: 판이 같은 언어는 한 절, 절이 둘 이상이면 맨 앞에 `## [물결] - <날짜> (<표시명> <판> · …)`.
- 8c 상한은 `DOC_TRIPWIRE_BYTES` 를 import 해 읽는다(사본 금지). 경고선 75 % — 실패가 아니다.
- 새 판정은 `doc-facts` 안에서 돈다. 모든 `test-*.sh` 는 마지막 명령 `assert_report` · `repo-hygiene.yml` 배선 · 인덱스 100755.
- 읽을 때 줄 끝을 LF 로 맞추고, 쓰는 것은 LF 다.
- CLI 종료 코드: 0 성공 · 1 거부(트리 상태 · 검사 실패 — 아무것도 안 쓴다) · 2 사용법(모르는 하위명령 · 인자 · 빈/겹친 `--root=`).
- 문서 예산은 8b(+300 B) · 8e(줄면 내림)를 따른다. 올리면 앵커 주석에 `옛값 → 새값` 과 판정을 적는다.
- 실질 과제마다 Grok 독립 레그(plan 모드 · 읽기 전용 · 사실 인라인 · 닫힌 질문 · 심은 거짓 주장 · 600 초). 커밋이 변이보다 앞이다(`scripts/probe.sh` 가 강제).

### 8.2 검토 초점

시험이 짚지 않으면 사람이 먼저 밟을 다섯이다. 각 줄의 시험은 소유 과제에 있다.

1. 윈도 편집기가 저장한 조각(BOM · CRLF · 끝의 빈 줄)은 받아들인다 — 과제 1 F2.
2. 같은 물결을 다시 돌리거나 이미 있는 판으로 돌린 release 는 쓰기 전에 거부하고, 원장 · 조각을 한 바이트도 바꾸지 않는다 — 과제 4 R3.
3. 대기 노트가 없는 언어의 release(의존성만 올린 판)는 실패가 아니다. 제목과 손글 자리만 있는 절을 만들고 알린다 — 과제 4 R4.
4. 한 조각이 두 물결에 걸쳐 나가면, 둘째 물결에 남은 언어 태그로 정확히 한 번 나오고 그 뒤 파일이 지워진다 — 과제 4 R2.
5. 원장의 최신 날짜보다 이른 `--date` 는 최신순을 깨므로 거부한다 — 과제 4 R5.

### 8.3 기각 체크리스트(③)

1. 전제 거짓? 아니다 — 머리말 1,054 B + `[Unreleased]` 64,437 B = 65,491 B, 상한까지 45 B(2026-11-24, 원장 파서로 잰 스크래치 `items-shape.mjs`).
2. 이미 덮는가? 아니다 — 회전은 날짜 절만 옮긴다(`changelog-rotate.mjs` 머리).
3. 더 강한 것? 착지 판정이 「줄이 늘었는가」에서 「바뀐 언어마다 그 언어의 조각」으로 강해진다.
4. 불변식 선언? 사용자 결정(2026-11-23 조각 · 2026-11-24 공통 절) · §5.
5. 수렴? 조각 문법은 기계 판정이고 문맥에 기대지 않는다.
6. 실패 표면? 느는 것은 조각 문법 오류(파일 이름을 대고 실패)와 손글 자리표시다. 주는 것은 `[Unreleased]` 충돌 · 손 분할 · 64 KiB 막힘 · 등록부 함정 (ff) 의 원인이다.
7. 격리가 단언을 대신? 아니다 — 출력 재파싱 대조(`verifyWave`)와 이관 다중집합 대조가 단언이다.
8. 소비자 하한? 바꾸지 않는다(게시 소스 불변).

### 8.4 WBS

```
[상태] ID  항목                                  담당          끝나는 조건
 [x]   0   계획 검토 레그                        Grok          판정 보고 · PM 재검증
 [ ]   1   조각 문법 · 언어 표 · check(문법)     구현          자가시험 F 절 green
 [ ]   2   물결 컴파일 · 독립 대조 · preview      구현          W 절 green(골든)
 [ ]   3   migrate(픽스처 생성기 겸)             구현          M 절 green
 [ ]   4   release                               구현          R 절 green
 [ ]   5   check 시험 컴파일 · 75 % · --stats     구현          K 절 green · test-check-docs.sh green
 [ ]   6   covered                               구현          V 절 green
 [ ]   7   PR 1 — 변이 레코드 · 적대 레그 · 병합  PM · Grok     sweep --only changelog CAUGHT · CI green
 [ ]   8   이관(PR 2 시작)                       구현 · PM · Grok  이관 대조 차이 0 · 저장소 check-docs green
 [ ]   9   8d 전환                               구현          test-changelog-ledger.sh green
 [ ]  10   착지 게이트(언어 단위)                구현          test-changelog-landing.sh green
 [ ]  11   문서 · PR 2                           구현 · PM · Grok  doc-facts green · 병합
 [ ]  12   마감(PR 3)                            PM            지도 행 · 이 문서 내림 · 등록부
```

순서는 위에서 아래다(1→6 은 인터페이스가 이어지고, PR 2 는 이관이 먼저라 커밋마다 초록이다). 게이트는 7 과 11 의 CI 다. 비가역 행위는 없다(릴리스 · 태그는 이 계획 밖). 11 의 병합이 착지 규칙을 바꾸므로 열린 PR 이 있으면 병합 전에 알린다.

### 8.5 과제

자가시험은 하나다 — `scripts/test/test-changelog-fragments.sh`(절 F · W · R · K · M · V). 픽스처 뿌리마다 `scripts/lib/deploy-facts.sh` 에 `DEPLOY_LANGS="python dotnet ruby node rust java kotlin go php"` 한 줄을 쓴다. 거부 사례는 바늘과 **종료 코드** 둘 다 단언한다(`run` 이 `__rc=N` 을 붙인다 — `test-changelog-ledger.sh` 와 같은 꼴). 쓰기를 거부하는 사례는 원장 · `changelog.d/` 의 cksum 이 그대로인지도 본다.

#### 과제 1 — 조각 문법 · 언어 표 · `check`(문법)

**파일** — 만든다: `scripts/lib/changelog-fragments.mjs` · `scripts/changelog.mjs`(100755, 셔뱅) · `scripts/test/test-changelog-fragments.sh`(100755). 고친다: `.github/workflows/repo-hygiene.yml` — doc-facts 의 「CHANGELOG 원장 자가테스트」 스텝 바로 아래에 `sh scripts/test/test-changelog-fragments.sh` 스텝.

**만드는 인터페이스**

```
FRAGMENT_DIR = 'changelog.d'
FRAGMENT_NAME_RE = /^\d{4}-\d{2}-\d{2}-[a-z0-9]+(?:-[a-z0-9]+)*\.txt$/
SECTIONS = ['Added', 'Changed', 'Deprecated', 'Removed', 'Fixed', 'Security']
DISPLAY = { python: 'Python', dotnet: '.NET', ruby: 'Ruby', node: 'Node', rust: 'Rust',
            java: 'Java', kotlin: 'Kotlin', go: 'Go', php: 'PHP' }
readDeployLangs(repoRoot) → string[]        // 던진다: 못 읽음 · DISPLAY 키와 집합이 다름
parseFragment(name, text, order) → { fragment: { name, langs, section, body } | null, errors: string[] }
renderFragment({ langs, section, body }, order) → 'langs: <순서대로>\nsection: <S>\n---\n<body>\n'
tagOf(langs, order) → 'Python · Go'
compileItem(langs, body, order) → '- **(Python · Go)** <body>'
readFragmentDir(repoRoot, order) → { fragments: 이름순, errors: string[] }   // 디렉터리가 없으면 둘 다 빈다
```

**문법**(오류는 `changelog.d/<이름>: ` 로 시작) — 이름이 `FRAGMENT_NAME_RE` 인 파일 · 맨 앞 BOM 은 떼고 CRLF 는 LF 로, 끝의 빈 줄은 무시 · 첫 `---` 줄 앞은 줄마다 `<키>: <값>` 이고 키는 `langs` · `section` 하나씩(모르는 키 · 겹친 키 · 빈 줄 · `---` 없음은 오류) · `langs` 는 공백 구분, 비지 않고 겹치지 않고 `DEPLOY_LANGS` 안 · `section` 은 `SECTIONS` 그대로 · 본문은 정확히 한 줄, 비지 않고 앞뒤 공백 없음 · `bytes(compileItem(langs, body, order) + '\n') ≤ BULLET_MAX_BYTES`.

- [ ] **1.1 실패하는 시험(F 절)** — F1 `2026-11-25-a.txt`(`langs: python go` · `section: Fixed` · 본문 `A 고침`) → `check` rc 0 · `ok`. F2 같은 조각을 BOM + CRLF + 끝 빈 줄 둘로 → rc 0. F3 rc 1 과 파일 이름 바늘 — 모르는 키 `kind:` · `section` 없음 · `langs:` 비었음 · `swift` · `python python` · `section: Fix` · `---` 없음 · 빈 본문 · 두 줄 본문 · 이름 `notes.txt` · 디렉터리 `changelog.d/sub/`. F4 경계(`langs: go`, 접두 `- **(Go)** ` 11 B) — 본문 1,012 B → rc 0, 1,013 B → rc 1 · `1025B > 1024B`. F5 `changelog.d/` 없음 → rc 0 · `대기 중인 조각이 없다`. F6 stub 의 `DEPLOY_LANGS` 에 `swift` 를 더하면 rc 1 · `표시명`. F7 `chek` · `--rot=x` → rc 2 · 아무것도 안 씀.
- [ ] **1.2** `sh scripts/test/test-changelog-fragments.sh` → FAIL(스크립트 없음).
- [ ] **1.3** 라이브러리와 CLI 뼈대(`check` 만)를 쓴다. CLI 의 인자 규칙은 `changelog-rotate.mjs` 를 따른다(`--root=` 만, 모르는 인자는 실패).
- [ ] **1.4** 다시 돌려 PASS. `sh scripts/test/test-selftest-hygiene.sh` 도 green(규칙 1 · 2 · 4).
- [ ] **1.5** 커밋(`git update-index --chmod=+x` 로 두 파일의 비트).

#### 과제 2 — 물결 컴파일 · 독립 대조 · `preview`

**파일** — 만든다: `scripts/lib/changelog-wave.mjs` · `scripts/test/changelog-wave-probe.mjs`(시험 도우미: `<root> <날짜> <lang=ver,…> <글 파일>` → `verifyWave` 오류를 찍고 있으면 rc 1, 없으면 0, 인자 오류 2). 고친다: `scripts/lib/changelog-ledger.mjs` · `scripts/changelog.mjs`(`preview [<lang>] [--date=]`).

**만드는 인터페이스**

```
// changelog-ledger.mjs
UNRELEASED_POINTER = (아래 문구)
HAND_MARK = 'TODO(release-notes)'
isUnreleasedPointer(blockText) → blockText.replace(/\s+$/, '') === `## [Unreleased]\n\n${UNRELEASED_POINTER}`
// changelog-wave.mjs — wave = { date: 'YYYY-MM-DD', versions: { <lang>: '<ver>' } }
compileWave(fragments, wave, order) → { text, updates: [{ name, langs }] }   // langs 가 비면 지울 조각
verifyWave(fragments, wave, text, order) → string[]
renderPreview(fragments, order) → '## [Unreleased]\n\n' + `### ` 절들
```

문구(그대로 쓴다 — 고정 문단에는 링크를 두지 않는다: 검사 5 가 링크 대상을 재는데 대기 조각이 없으면 `changelog.d/` 가 없다):

- `UNRELEASED_POINTER` = ``미출시 변경은 변경마다 `changelog.d/` 의 조각 파일 하나로 둡니다(쓰는 법은 CONTRIBUTING.md) — 모아 보기: `node scripts/changelog.mjs preview`. 릴리스 때 `node scripts/changelog.mjs release` 가 이 절 아래 날짜 절로 옮깁니다.``
- 물결 머리말 자리: `TODO(release-notes) 물결 머리말 — 이 물결이 내보내는 언어 · 판과 그 근거를 쓴다.`
- 언어 절 손글 자리: `TODO(release-notes) 이 절의 판 종류 · 공개 API 변경 수 · 같은 번호 경고를 쓴다.`
- 공통 절이 있을 때 언어 절 첫 문단: ``같은 물결의 머리말과 여러 절에 걸친 항목은 위 `[물결] - <날짜>` 절에 있습니다.``

**컴파일** — 판이 같은 언어끼리 한 절(절 순서 = 그 절 첫 언어의 `DEPLOY_LANGS` 순서) · 제목 `## [<판>] - <날짜> (<표시명 · …>)` · 절이 둘 이상이면 맨 앞에 공통 절 · 조각마다 S = `langs` ∩ 물결 언어, 비면 건너뛰고, S 의 판이 하나면 그 언어 절, 둘 이상이면 공통 절에 `compileItem(S, body)` · 블록 안은 문단들 → `### <section>`(`SECTIONS` 순, 빈 절 생략, 항목은 조각 이름순) · 블록은 빈 줄 하나로 끝난다 · 공통 절과 단일 블록 물결은 물결 머리말 자리를, 공통 절 아래 언어 절은 첫 문단 + 손글 자리를 갖는다.

**`verifyWave` 는 독립 대조다 — `compileWave` 의 묶기 식을 부르지 않는다**(같은 식을 부르면 그 버그를 함께 놓친다). text 를 `parseLedgerFile` 로 읽어 모두 본다:

1. 머리말이 비고 모든 블록이 릴리스 절이다.
2. 블록의 항목(`itemsOf`)은 넷뿐이다 — 블록 제목 · `### <SECTIONS 중 하나>` · 생성 문단(물결 머리말 자리 · 손글 자리 · 공통 절을 가리키는 첫 문단) · `### ` 아래의 `- **(태그)** 본문`. 그 밖(`###` 앞의 목록 항목 · 꼴이 다른 목록 항목 · 모르는 문단)은 오류다.
3. 항목마다 `bytes(item) ≤ BULLET_MAX_BYTES` — 8d 와 같은 잼이라 제목 줄도 잰다(긴 판 문자열의 제목이 8d 에서 처음 걸리지 않게).
4. 공통 절이 아닌 블록마다 괄호 안 표시명을 토큰으로 되돌리면 그 언어들은 물결에서 대괄호 판과 같은 판이고 그 판의 언어 전부다. 그 블록들의 언어를 모으면 물결 언어 전부이고 겹치지 않는다(항목이 없는 언어 절이 빠져도 잡힌다).
5. 판이 둘 이상이면 첫 블록만 공통 절이고 그 괄호 안이 물결 언어 전부의 `<표시명> <판>` 이다. 판이 하나면 공통 절이 없다.
6. 기대 다중집합(조각마다 S 가 비지 않으면 `<판 또는 물결> | <section> | <S> | <본문>` 하나)과 text 에서 읽은 항목의 다중집합이 같다.

**W 픽스처**(과제 4 의 R 절도 쓴다) — 조각 넷:

```
2026-11-25-a.txt  langs: python go      section: Fixed     A 고침
2026-11-25-b.txt  langs: dotnet         section: Added     B 추가
2026-11-26-c.txt  langs: python dotnet  section: Fixed     C 고침
2026-11-26-d.txt  langs: ruby python    section: Security  D 보안
```

**W1 골든** — 물결 `{ date: 2026-12-01, python: 1.0.8, dotnet: 1.0.8, go: 1.2.6 }` 의 글은 바이트까지 아래와 같다(마지막 줄 뒤에 빈 줄 하나):

```
## [물결] - 2026-12-01 (Python 1.0.8 · .NET 1.0.8 · Go 1.2.6)

TODO(release-notes) 물결 머리말 — 이 물결이 내보내는 언어 · 판과 그 근거를 쓴다.

### Fixed
- **(Python · Go)** A 고침

## [1.0.8] - 2026-12-01 (Python · .NET)

같은 물결의 머리말과 여러 절에 걸친 항목은 위 `[물결] - 2026-12-01` 절에 있습니다.

TODO(release-notes) 이 절의 판 종류 · 공개 API 변경 수 · 같은 번호 경고를 쓴다.

### Added
- **(.NET)** B 추가

### Fixed
- **(Python · .NET)** C 고침

### Security
- **(Python)** D 보안

## [1.2.6] - 2026-12-01 (Go)

같은 물결의 머리말과 여러 절에 걸친 항목은 위 `[물결] - 2026-12-01` 절에 있습니다.

TODO(release-notes) 이 절의 판 종류 · 공개 API 변경 수 · 같은 번호 경고를 쓴다.
```

- [ ] **2.1 실패하는 시험(W 절)** — W1 위 골든. W2 `preview` = `## [Unreleased]` · 빈 줄 · `### Added` / `- **(.NET)** B 추가` · 빈 줄 · `### Fixed` / `- **(Python · Go)** A 고침` / `- **(Python · .NET)** C 고침` · 빈 줄 · `### Security` / `- **(Python · Ruby)** D 보안` · 빈 줄. W3 `preview go --date=2026-12-01` = `## [?] - 2026-12-01 (Go)` · 물결 머리말 자리 · `### Fixed` / `- **(Go)** A 고침`(태그는 내보내는 언어뿐). W4 도우미로 `verifyWave` — W1 글은 rc 0(대조군), 다음 변형은 각각 rc 1: 항목 하나 지움 · 하나 겹침 · 같은 항목을 `###` 앞에 한 번 더 · `A 고침` 을 `### Added` 아래로 · `A 고침` 을 `[1.2.6]` 절로 · `[1.2.6] (Go)` 절을 통째로 뺌 · 공통 절 제목에서 `· Go 1.2.6` 을 뺌 · 모르는 문단 하나 · 1,025 B 제목 줄 · 판 하나짜리 물결에 공통 절 덧붙임.
- [ ] **2.2** FAIL 확인 → **2.3** 구현 → **2.4** PASS → **2.5** 커밋.

#### 과제 3 — `migrate`(픽스처 생성기 겸)

**파일** — 고친다: `scripts/changelog.mjs`. `node scripts/changelog.mjs migrate [--root=<dir>] [--date=YYYY-MM-DD]`:

- 루트 `[Unreleased]` 가 이미 포인터면 `이미 전환됐다` · rc 0 · 안 쓴다. `changelog.d/` 에 파일이 있으면 rc 1(섞지 않는다).
- 받는 항목은 블록 안 `### <S>`(S ∈ `SECTIONS`) 아래의 한 줄 `- **(<태그>)** <본문>` 뿐이다. 태그는 `·` 로 나눈 표시명(앞뒤 공백 제거)이고 `전 언어` 는 아홉이다. 그 밖(태그 없음 · 모르는 이름 · 절 밖 · 문단 · 여러 줄 · 모르는 `###`)은 모아서 rc 1.
- `DEPLOY_LANGS` 는 항목이 있을 때만 읽는다 — 빈 `[Unreleased]` 를 포인터로 바꾸는 것이 픽스처 생성기다(과제 4 · 9). 시험이 포인터 문구를 다시 쓰지 않게 하려는 것이다(생성 규칙의 두 번째 구현 금지 — `test-changelog-ledger.sh` 머리와 같은 원칙).
- 이름 `<날짜>-unreleased-<NNN>.txt`(NNN = 블록 안 순서, 001 부터) — 이름순이 지금 순서다.
- 쓰기 전 대조 셋, 어긋나면 rc 1 · 안 쓴다: (a) 렌더한 조각을 `parseFragment` 로 다시 읽어 같은 값 (b) 원래 항목과 조각의 (section · 언어 집합 · 본문) 다중집합이 같다 (c) `renderPreview` 의 항목을 다시 읽은 다중집합도 같다.
- 쓰기 — 조각들과 `[Unreleased]` 블록 = `## [Unreleased]\n\n<포인터>\n\n`. 출력 `ok   migrate: 항목 <n>개 → 조각 <n>개`.

- [ ] **3.1 실패하는 시험(M 절)** — M1 옛 꼴 항목 셋(`### Fixed` 아래 `- **(Java · Kotlin)** J 고침` · `- **(Go · Python)** G 고침`, `### Security` 아래 `- **(전 언어)** S 보안`) → 조각 셋의 머리가 정확히 `langs: java kotlin` / `langs: python go` / `langs: python dotnet ruby node rust java kotlin go php` · 루트 `[Unreleased]` 가 포인터 · `preview` 의 항목 줄은 원래 줄과 태그만 다르다(`(Python · Go)`, `(전 언어)` → 아홉 표시명). M2 태그 없음 · `(Swift)` · `###` 밖 항목 · 문단 · `### Notes` 각각 rc 1 · cksum 그대로. M3 두 번째 실행 → `이미 전환됐다` · rc 0 · cksum 그대로. M4 `changelog.d/` 에 파일 하나 → rc 1. M5 `deploy-facts.sh` 없는 뿌리의 빈 `[Unreleased]` → rc 0 · 포인터.
- [ ] **3.2** FAIL → **3.3** 구현 → **3.4** PASS → **3.5** 커밋.

#### 과제 4 — `release`

**파일** — 고친다: `scripts/changelog.mjs`. **소비**: 과제 1–3 의 전부.

`node scripts/changelog.mjs release [--root=<dir>] [--date=YYYY-MM-DD] <lang>=<ver> …` — 판은 `^\d+\.\d+\.\d+(?:-[0-9A-Za-z][0-9A-Za-z.-]*)?$`, 날짜 기본은 오늘. 아래 차례로 확인하고, 하나라도 걸리면 아무것도 쓰지 않는다:

1. 인자 — 언어는 `DEPLOY_LANGS` 안 · 겹침 없음 · 하나 이상, 판 · 날짜 꼴(rc 2)
2. 루트 `[Unreleased]` 가 `isUnreleasedPointer` — 아니면 rc 1 · `먼저 migrate`
3. 조각 문법 오류가 없다
4. 날짜 ≥ 루트의 최신 날짜 절
5. 새 제목이 루트 · 보관본 어디에도 없다
6. `compileWave` → `verifyWave` 오류 0 → 새 루트를 `parseLedgerFile` 로 다시 읽어 모르는 제목 0
7. 쓰기 — 루트 = 머리말 + `## [Unreleased]\n\n<포인터>\n\n` + 물결 + 기존 날짜 절들, 조각은 `updates` 대로(남은 `langs` 는 `renderFragment`, 비면 지운다)
8. 출력 `ok   release <날짜>: 절 <n>개 · 항목 <m>개 · 조각 갱신 <k> · 삭제 <d>` + 노트가 없는 언어마다 `⚠️  <lang>: 대기 노트가 없다 — 절에는 손글 자리만 있다`

픽스처 루트는 옛 꼴(빈 `[Unreleased]` + `## [1.0.7] - 2026-11-03 (Python)` 절 하나)로 쓴 뒤 `migrate` 로 포인터 꼴로 바꾼다(과제 3).

- [ ] **4.1 실패하는 시험(R 절)** — R1 W 픽스처 → `release --date=2026-12-01 python=1.0.8 dotnet=1.0.8 go=1.2.6` rc 0 · 루트 = 릴리스 전 루트의 `[Unreleased]` 블록 바로 뒤에 W1 골든을 끼운 것(바이트) · a · b · c 삭제 · d = `renderFragment` 꼴의 `langs: ruby`. R2(검토 초점 4) 이어서 `release --date=2026-12-02 ruby=1.4.2` → `- **(Ruby)** D 보안` 한 번, d 삭제. R3(검토 초점 2) 새 픽스처에서 R1 직후 같은 인자로 다시 → rc 1 · `이미 있는 제목` · cksum 그대로. R4(검토 초점 3) 조각에 없는 `php=1.5.3` → rc 0 · `## [1.5.3] - … (PHP)` 절에 손글 자리만 · `대기 노트가 없다`. R5(검토 초점 5) `--date=2026-11-01` → rc 1 · cksum 그대로. R6 `[Unreleased]` 에 항목이 있는 옛 꼴 루트 → rc 1 · `먼저 migrate`. R7 문법이 깨진 조각이 있으면 rc 1. R8 R1 결과의 `TODO(release-notes)` 줄을 손글로 바꾸면 `node scripts/check-docs.mjs "$TMP"` 출력에 `검사 8d` 가 없다. R9 판 문자열이 긴 `go=1.2.6-<x 1,100 개>`(판 꼴은 맞다) → rc 1 · `1024B` 바늘 · cksum 그대로(제목 줄이 상한을 넘는다 — `verifyWave` 3).
- [ ] **4.2** FAIL → **4.3** 구현 → **4.4** PASS → **4.5** 커밋.

#### 과제 5 — `check` 시험 컴파일 · 75 % 경고 · `--stats`

**파일** — 만든다: `scripts/lib/doc-tripwire.mjs`(`export const DOC_TRIPWIRE_BYTES = 256 * 1024` — `scripts/check-docs.mjs:2078-2085` 의 정의와 주석을 옮긴다). 고친다: `scripts/check-docs.mjs`(그 자리는 import 한 줄) · `scripts/lib/changelog-wave.mjs` · `scripts/changelog.mjs`.

**만드는 인터페이스** — `checkFragmentTree(repoRoot) → { errors, warnings, stats: { perLang: { <lang>: { count, bytes } }, projected, tripwire } }`. `changelog.d/` 가 없으면 빈 결과다.

- 문법 오류(과제 1) + 시험 물결 열(아홉 언어 하나 — 판 `0.0.1`…`0.0.9` 를 `DEPLOY_LANGS` 순으로, 한 언어씩 아홉 — 판 `0.0.1`, 날짜 `2000-01-01`)의 `verifyWave` 오류 → errors.
- `projected = bytes(루트 머리말 + 포인터 블록 + 아홉 언어 시험 물결)` · `projected * 4 >= DOC_TRIPWIRE_BYTES * 3` 이면 warnings 에 `대기 노트를 아홉 언어 물결로 내면 루트가 <N>B — 전역 상한 <T>B 의 <P>%`.
- CLI `check` — 위에 더해, 루트 `CHANGELOG.md` 가 있으면 `[Unreleased]` 가 `isUnreleasedPointer` 인지 본다(§5.5 — 8d 도 같은 함수를 부른다, 과제 9). errors 면 rc 1, warnings 는 `⚠️  ` 로 찍고 rc 0. `preview --stats` — 언어마다 `<lang> 대기 <n>개 · <b>B`(b = 그 언어 한 언어 물결의 바이트)와 `아홉 언어 물결 예상 <N>B / 8c 상한 <T>B (<P>%)`.

- [ ] **5.1 실패하는 시험(K 절)** — K1 세 절에 걸친 조각이 섞인 픽스처 → rc 0. K2 `langs: go` · 본문 1,000 B 조각 210 개 → rc 0 · `대기 노트를 아홉 언어 물결로 내면`(약 82 %). 같은 꼴 100 개(약 40 %) → 그 바늘 없음(대조군). K3 `preview --stats` 에 `아홉 언어 물결 예상`. K4 `[Unreleased]` 에 항목이 있는 옛 꼴 루트 → rc 1 · `고정 문단`.
- [ ] **5.2** FAIL → **5.3** 구현 → **5.4** PASS + `sh scripts/test/test-check-docs.sh` · 저장소 check-docs(§3 의 명령) green — 상수를 옮겨도 8c 가 그대로다 → **5.5** 커밋.

#### 과제 6 — `covered`

**파일** — 고친다: `scripts/changelog.mjs`. `node scripts/changelog.mjs covered [--root=<dir>] --base=<rev>` → 한 줄: 범위가 조각으로 **얻은** 언어 토큰(`DEPLOY_LANGS` 순, 공백 구분).

- 작업 트리의 조각(문법 오류면 rc 1)과 기준의 조각(`git ls-tree -r --name-only <base> -- changelog.d` + `git show`, 못 읽으면 rc 1).
- 조각마다 기준 `langs` = 같은 경로의 기준 조각 → 없으면 같은 본문의 기준 조각들(합집합 — 이름만 바꾼 조각은 새 노트가 아니다) → 없으면 ∅. 얻은 언어 = `langs` − 기준 `langs`, 그 합집합을 찍는다.

- [ ] **6.1 실패하는 시험(V 절)** — 픽스처 git 저장소: 기준 = a(`python`) · b(`go`), 작업 = c(`ruby`) 추가 · a 를 `python node` 로 · b 를 같은 내용으로 이름만 바꿈 → `ruby node` · rc 0. V2 변화 없음 → 빈 줄 · rc 0. V3 `--base=nope` → rc 1. V4 작업 트리에 문법이 깨진 조각 → rc 1.
- [ ] **6.2** FAIL → **6.3** 구현 → **6.4** PASS → **6.5** 커밋.

#### 과제 7 — PR 1: 변이 레코드 · 적대 레그 · 병합

- [ ] **7.1** `scripts/test/mutation-records.txt` 에 줄 변이 여섯(OLD 는 구현된 줄을 그대로 옮긴다): CF1 조각 크기 비교(F4 가 잡는다) · CF2 `verifyWave` 의 다중집합 비교를 늘 같게(W4) · CF3 75 % 비교(K2) · CF4 `covered` 의 같은 본문 기준(V1) · CF5 release 의 제목 겹침 거부(R3) · CF6 `verifyWave` 의 항목 상한(R9). 제외 하나: `test-changelog-fragments.sh` × `check-docs.mjs` — R8 대조군이고 check-docs 의 거부는 `test-changelog-ledger.sh` 가 단언한다.
- [ ] **7.2** `node scripts/mutation-sweep.mjs --list` 의 새 쌍이 계획한 둘(`test-changelog-fragments.sh` × `changelog.mjs` · × `check-docs.mjs` 제외)뿐인지 본다 — 쌍 파생은 주석 속 경로도 읽고, 실행 줄에는 파일 이름만 있으면 된다(`pairsOf`). 커밋 뒤 `node scripts/mutation-sweep.mjs --only changelog` → M1 쌍과 CF1–CF6 전부 CAUGHT. `sh scripts/test/test-mutation-sweep.sh` green.
- [ ] **7.3** Grok 적대 레그 — PR 1 diff 와 §5 를 인라인, 닫힌 질문(조각이 빠지거나 다른 언어 절로 가는 입력이 있는가 · `verifyWave` 가 잘못된 컴파일을 통과시키는 입력이 있는가 · release 가 쓰다 멈춰 반쯤 쓴 상태가 남는가), 심은 거짓 주장 둘. PM 이 주장마다 재현해 판정한다.
- [ ] **7.4** 로컬 doc-facts — `sh scripts/test/test-check-docs.sh` · `test-changelog-ledger.sh` · `test-changelog-fragments.sh` · `test-selftest-hygiene.sh` · `test-mutation-sweep.sh` · §3 의 check-docs 명령, 전부 rc 0.
- [ ] **7.5** §7 의 「계획」 · 「PR 1」 체크 → 브랜치 `feat/changelog-fragments-tooling` push → PR → CI green → 병합.

#### 과제 8 — 이관(PR 2 시작)

이관을 맨 앞에 둔다. 옛 8d 는 포인터 문단을 받고(1,024 B 아래 문단 하나) 조각 파일은 아직 어느 검사도 보지 않으므로 PR 2 의 모든 커밋이 저장소 check-docs 에서 초록이다 — 8d 를 먼저 바꾸면 이관 전 커밋이 빨갛다(Grok 레그 지적).

- [ ] **8.1** 이관 전 항목 수 N 을 잰다(지금 97 — 원장 파서를 쓰는 스크래치 `items-shape.mjs`). `node scripts/changelog.mjs migrate --date=<그날>` → `항목 N개 → 조각 N개`. 이어서 `check` rc 0 · `preview --stats`.
- [ ] **8.2 독립 대조** — PM: `git show origin/main:CHANGELOG.md` 의 `[Unreleased]` 줄들과 `preview` 줄들을 태그 정규화 뒤 비교하면 차이 0(원장 파서를 쓰는 스크래치 스크립트). Grok 손실 점검 레그: 원본과 조각 세트에 심은 대조군 둘(조각 하나 지움 · 본문 한 글자 바꿈)을 함께 준다 — 둘 다 잡고 진짜 차이는 0 이어야 받는다.
- [ ] **8.3** `.gitattributes` 에 `changelog.d/** text eol=lf`(주석 한 줄 — 도구가 다시 쓰는 데이터라 기계마다 바이트가 같아야 한다). 저장소 check-docs(§3 의 명령) rc 0 → 커밋.

#### 과제 9 — 8d 전환

**파일** — 고친다: `scripts/check-docs.mjs` `checkLedger`(지금 2144–2329) · `scripts/test/test-changelog-ledger.sh` · `scripts/test/mutation-records.txt`.

- `[Unreleased]` 블록이 `isUnreleasedPointer` 가 아니면 실패(`[Unreleased] 에는 고정 문단만 둔다 — 미출시 노트는 changelog.d/ 의 조각으로`). 기준(git) 없이도 돈다 — 지금 `capBullets(b, baseUnrel)` 의 자리다.
- `baseUnrel` 과 `capBullets` 의 면제 인자를 지운다. 새 날짜 절의 항목은 전부 상한을 받는다 — release 가 쓰기 전에 같은 잼을 하므로(`verifyWave` 3) 도구가 만든 절이 여기서 처음 걸리지 않는다.
- 루트에 `HAND_MARK` 가 있으면 실패(`손글 자리표시가 남았다`).
- `checkFragmentTree(ROOT)` — errors 는 `검사 8d: ` 로, warnings 는 `warnings` 로(`::warning::` · 실패 아님).
- 머리 주석(2144–2156)을 새 규칙으로 고친다.

- [ ] **9.1 시험부터** — `root_file` 은 옛 꼴로 쓴 뒤 `node "$CL" migrate --root="$TMP"` 로 포인터 꼴로 바꾼다. `add_section <절 글>` 도우미(루트의 첫 날짜 절 앞, 없으면 끝에 넣는다)를 두고, `replace('## [Unreleased]\n\n', …)` 꼴의 node 치환은 전부 그것으로 바꾼다(그대로 두면 포인터 문단이 새 절 안으로 밀린다). A6 · A7 → 포인터 + 항목 하나 · 포인터 한 글자 변경 · 빈 `[Unreleased]` 를 각각 거부하고, 세 우회 모양(`* ` · 게으른 이어짐 · 표지 없는 문단)은 기준에 없던 새 날짜 절에서 거부한다(`commit_main` 뒤 `add_section`). G4 · H6 은 지운다 — 기준 `[Unreleased]` 면제가 없어졌다(이유는 커밋 메시지에). H4 → 70 KB 머리말로 「회전으로 줄일 수 없다」. H5 의 `[Unreleased]` 소제목 반쪽은 지우고 새 절 제목 줄 반쪽은 둔다. H7 은 새 날짜 절에서. 새 A8 — `TODO(release-notes)` 가 남은 루트 rc 1 · 문법이 깨진 조각 rc 1 + `changelog.d/` 바늘 · 75 % 픽스처는 `::warning::` 과 rc 0.
- [ ] **9.2** FAIL 확인 → **9.3** check-docs 를 고친다 → **9.4** PASS + `sh scripts/test/test-check-docs.sh` · 저장소 check-docs rc 0.
- [ ] **9.5** 레코드 — 제외 `test-changelog-ledger.sh` × `changelog.mjs`(픽스처 생성기로만 부른다 — 그 거부는 `test-changelog-fragments.sh` 가 종료 코드로 단언한다). 커밋.

#### 과제 10 — 착지 게이트(언어 단위)

**파일** — 고친다: `scripts/test/test-changelog-landing.sh` · `.github/workflows/repo-hygiene.yml:380-387`(주석 · 스텝 이름 `착지 시점 CHANGELOG 게이트(게시 소스 언어 ↔ changelog.d 조각)`) · `scripts/test/mutation-records.txt`.

- 판정기 `_unreleased_lines` · `_grew` 를 지우고 둘을 둔다 — `_langs`(stdin 의 게시 경로 → 첫 경로 조각, 정렬 · 중복 제거. 그 조각이 곧 `DEPLOY_LANGS` 토큰이다) · `_missing <바뀐 언어(줄마다)> <덮인 언어(공백 구분)>` → 덮이지 않은 언어(줄마다, 낱말 단위 비교).
- 살아 있는 검사 — `_covered="$(node "$DIR/../changelog.mjs" covered --root="$ROOT" --base="$_base")"` 가 실패하면 단언으로 실패한다(조용히 통과시키지 않는다). `_missing` 이 비어야 통과하고, 메시지는 빠진 언어와 조각 쓰는 법(CONTRIBUTING.md)과 면제 꼴을 댄다. 면제 · 기준점 처리는 그대로다. 머리 주석은 새 질문(「바뀐 언어마다 그 언어의 조각이 생겼는가」)으로 고친다.
- `_shipped` 의 확장자 제외(`.json` · `.xml` · `.toml` …)는 그대로 둔다. 게시 디렉터리 안의 데이터 파일 변경이 대상 밖으로 빠지는 기존 틈이다(Grok 레그 지적 — 지금 트리에서 그 규칙이 거르는 것은 의도한 `.csproj` 하나와 `.gitkeep` 둘뿐, 2026-11-24). 이 계획 밖이고 과제 12 가 등록부에 남긴다.

- [ ] **10.1 시험** — `_langs` 에 지금의 `_FIX_PATHS` 를 `_shipped` 로 거른 것 → `go` / `ruby` / `rust`. `_missing` 대조 넷 — (`go`+`ruby`, `ruby`) → `go` · (`go`, `go`) → 빈 값 · (`go`, 빈 값) → `go` · (`go`, `gox`) → `go`.
- [ ] **10.2** FAIL → **10.3** 구현 → **10.4** PASS.
- [ ] **10.5** 레코드 — CL4(`_grew`)를 지우고 CL5(`_missing` 의 비교를 늘 덮인 것으로 → 대조가 잡는다)를 더한다. 제외 `test-changelog-landing.sh` × `changelog.mjs`(`covered` 의 출력만 읽는다). 커밋 뒤 `node scripts/mutation-sweep.mjs --only CL` · `--only changelog` 전부 CAUGHT.

#### 과제 11 — 문서 · PR 2

- [ ] **11.1 문서**(바꿀 글을 그대로):
  - `CLAUDE.md` 문서 규칙 표 — `(항목은 짧게 — 상한은 검사 8d)` → ``(미출시 노트는 `changelog.d/` 조각 한 줄 — 상한은 검사 8d)``.
  - `DEPLOY.md` §4 step 1 의 마지막 문장 → ``The same commit runs `node scripts/changelog.mjs release <lang>=<ver> …` once for the whole wave: it writes the wave's dated sections right under `[Unreleased]` (a common wave section first when the versions differ) and removes the shipped languages from the `changelog.d/` fragments. Then replace each `TODO(release-notes)` paragraph with the wave intro and the per-language lines — `check-docs` fails while one remains.``
  - `CONTRIBUTING.md` §3 PR checklist 에 한 항목 → ``- [ ] Published library source changed → one note per change in `changelog.d/<YYYY-MM-DD>-<slug>.txt` (`langs:` tokens from `DEPLOY_LANGS` · `section:` Added/Changed/Deprecated/Removed/Fixed/Security · `---` · one line). `node scripts/changelog.mjs check` validates it; `doc-facts` fails when a changed language has no note (exempt: `[no-changelog: <reason>]` in a commit message)``.
  - 등록부 106 행 ``[Unreleased]` 는 아홉 언어 몫`` → ``미출시 노트는 `changelog.d/` 조각(`node scripts/changelog.mjs preview`)`` · 112 행의 「⚠️ CHANGELOG 의 묶는 상한은 … 릴리스뿐이다).」 → 「⚠️ 미출시 노트는 조각이라 릴리스를 미뤄도 막히지 않는다 — 대기분이 아홉 언어 물결로 8c 의 75 % 를 넘으면 `doc-facts` 가 경고한다.」 · (bb) → 「`[no-changelog: …]` 표지 하나가 범위 전체의 언어별 조각 검사를 끈다(`scripts/test/test-changelog-landing.sh`) — 조각을 더하는 브랜치에는 달지 않는다.」
  - `repo-hygiene.yml:380-385` 주석을 새 판정으로.
- [ ] **11.2 예산** — check-docs 가 찍는 값대로 맞춘다. 커지는 문서(DEPLOY · CONTRIBUTING)는 +300 B 안에서 앵커 주석에 `옛값 → 새값 (날짜): 사용자 결정(2026-11-24)으로 이 문서가 조각 안내를 맡는다`, 넘치면 교환으로 줄인다. 등록부는 8f(raw)도.
- [ ] **11.3 부류 재스캔** — `git grep -n "Unreleased\|_unreleased_lines\|test-changelog-landing"` 의 남은 언급이 전부 참인지(남는 것: 원장 파서 · 8d · 회전기 · 자가시험 · 이력).
- [ ] **11.4** 로컬 doc-facts 전부(과제 7.4 의 목록) rc 0 · `mutation-sweep.mjs --list` 의 새 쌍이 넷(PR 1 의 둘 + 과제 9 · 10 의 제외 둘)뿐 → Grok 적대 레그(PR 2 diff — 이관 · 8d · 게이트) → PM 재현 판정 → §7 「PR 2」 체크 → push → PR → CI green → 병합.

#### 과제 12 — 마감(PR 3)

- [ ] **12.1** 이 문서를 지운다(`git rm`). 지도 §3 의 행을 지우고 `docs/README.md` 예산을 8b/8e 가 찍는 값으로 내린다(이 행 전 7873 근처).
- [ ] **12.2** 등록부 — 진입점에 ``CHANGELOG 조각 전환 — 설계 · 계획은 `git show <PR 2 병합 SHA>:docs/superpowers/plans/changelog-fragments.md` `` 한 줄, 열린 항목 하나(착지 게이트의 확장자 제외가 게시 디렉터리 안의 데이터 파일까지 뺀다 — 과제 10). 예산 8e/8f.
- [ ] **12.3** 메모리 `doc-size-ledger` 를 새 구조로 고친다. PR → CI green → 병합.
