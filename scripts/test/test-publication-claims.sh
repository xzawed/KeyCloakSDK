#!/usr/bin/env sh
# 각 `<lang>/README.md`의 프리릴리스 배너가 실제 게시 현황(DF_PUBLISHED)과 맞는가.
#
# 왜 이 가드가 필요한가: 이 README들은 **레지스트리 랜딩 페이지**가 된다. 패키지 안에 담겨
# 올라가고, 레지스트리는 README를 **버전마다 고정**한다 — 게시 후에 고치려면 새 버전을 태워야
# 한다(DEPLOY.md §4 step 1의 경고). 그래서 "게시했는데 배너가 아직 미게시라고 말하는" 실수는
# 되돌리는 데 좌표 하나가 든다. 9개 언어를 손으로 맞춰 왔고 지금은 전부 맞지만, 남은 5개를
# 게시하는 동안 다섯 번 더 틀릴 기회가 있다.
#
# ⚠️ 이 어서션은 **양방향이라야 의미가 있다**. "미게시면 '아직'이라고 적혀 있어야 한다"만
# 검사하면 게시 후 배너를 안 고쳐도 통과하고, 그 반대만 검사하면 새 언어가 추가될 때 빈
# 배너를 통과시킨다. `DF_PUBLISHED` 한 줄을 옮기는 순간 **양쪽이 동시에** 요구된다.
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
. "$DIR/../lib/deploy-facts.sh"
ROOT="$DIR/../.."

for L in $DEPLOY_LANGS; do
  f="$ROOT/$L/README.md"
  assert_ok test -f "$f"

  # 배너는 첫머리에 있어야 한다 — 소비자가 레지스트리 페이지에서 처음 보는 줄이다.
  banner="$(sed -n '1,12p' "$f" | grep -m1 '^> \*\*Pre-release\*\*' || true)"
  assert_ok test -n "$banner"
  [ -n "$banner" ] || continue

  if df_is_published "$L"; then
    # 게시됨: "아직"이라고 말하면 안 되고, **어디에 있는지**를 말해야 한다. 부정형만 지우고
    # 아무것도 안 적는 절반짜리 수정을 막으려고 긍정 어서션을 함께 둔다.
    assert_not_contains "$banner" "not yet" \
      "$L 은 게시됐는데 README 배너가 아직 미게시라고 말한다 — 이 README는 레지스트리 랜딩 페이지다"
    assert_contains "$banner" "is on " \
      "$L 배너가 어느 레지스트리에 올라가 있는지 말하지 않는다"
  else
    assert_contains "$banner" "not yet" \
      "$L 은 미게시인데 README 배너가 그렇게 말하지 않는다"
    assert_not_contains "$banner" "is on " \
      "$L 은 미게시인데 배너가 레지스트리에 올라가 있다고 말한다"
  fi

  # ---- 설치 스니펫에 **핀된 버전** ----
  #
  # ⚠️ 배너만 검사하면 **설치 스니펫이 낡은 채로 통과한다.** `java/README.md`가 실제로 그랬다 —
  # 배너는 게시형으로 고쳐졌는데 설치 예제 두 곳은 `0.1.0`이었고, 게시된 것은 `0.1.0-RC1`뿐이라
  # 소비자에게 **존재하지 않는 좌표**를 권하고 있었다(가드는 초록, 사람이 손으로 발견).
  # 레지스트리는 README를 버전마다 고정하므로 이 실수를 고치려면 좌표 하나를 더 태워야 한다.
  #
  # ⚠️ **파일 전체 containment로는 못 잡는다 — 실제로 시도했다가 변이가 통과했다.** 배너 산문에
  # 게시 버전이 들어 있으면(`the first release candidate (\`0.1.0-RC1\`) is on …`) 스니펫이 옛 값
  # 이어도 "파일 어딘가에 있다"가 성립한다. 그래서 **코드펜스 안**만 본다.
  #
  # ⚠️ "펜스 안에 게시 버전이 있어야 한다"도 틀렸다 — python·rust·dotnet·php는 설치 명령에 버전을
  # 쓰지 않는 것이 **옳다**(`pip install keycloak-sdk`처럼 리졸버가 고르게 둔다). 그래서 규칙은
  # "있어야 한다"가 아니라 **"핀했다면 그 값이어야 한다"** 이다. 미게시 언어의 기대값은 아직 태우지
  # 않은 라인 버전 `0.1.0`이라, 그 언어가 게시되는 순간 기대값이 RC로 바뀌며 갱신을 강제한다.
  _want="$(df_published_version "$L")"
  [ -n "$_want" ] || _want="0.1.0"
  _bad="$(awk '/^```/ { f = !f; next } f' "$f" \
    | grep -oE '0\.1\.0[A-Za-z0-9.-]*' | sort -u | grep -Fxv "$_want" || true)"
  assert_eq "" "$_bad" \
    "$L/README.md 코드펜스에 핀된 버전이 기대값($_want)과 다르다 — 소비자에게 없는 좌표를 권하게 된다"
done

# ⚠️ 대조군 — 위 루프가 실제로 언어를 돌았는지 확인한다. `DEPLOY_LANGS`가 비거나 파일 경로
# 규칙이 바뀌면 어서션이 0건 실행되고 이 테스트는 조용히 통과한다(그게 이 저장소가 반복해서
# 겪은 실패다). 개수를 SSOT에서 파생해 맞춘다.
n=0
for L in $DEPLOY_LANGS; do n=$((n + 1)); done
assert_ok test "$n" -ge 9

# ---- 루트 문서의 게시 현황 주장 ----
#
# `deploy-facts.sh`의 주석이 스스로 열거하듯 rust RC 한 번이 최소 6곳을 동시에 낡게 만들었다.
# 그중 기계 대조가 붙은 것은 DEPLOY.md(test-deploy-md.sh)와 위의 패키지 README뿐이었고,
# **랜딩 문서 셋(README·README.ko·SECURITY)과 getting-started는 손으로만 맞춰져 있었다.**
pub_n=0;  for L in $DF_PUBLISHED; do pub_n=$((pub_n + 1)); done
unpub_n=$((n - pub_n))
en() { case "$1" in
  1) echo one ;; 2) echo two ;; 3) echo three ;; 4) echo four ;; 5) echo five ;;
  6) echo six ;; 7) echo seven ;; 8) echo eight ;; 9) echo nine ;; *) echo "" ;; esac; }
ko() { case "$1" in
  1) echo 하나 ;; 2) echo 둘 ;; 3) echo 셋 ;; 4) echo 넷 ;; 5) echo 다섯 ;;
  6) echo 여섯 ;; 7) echo 일곱 ;; 8) echo 여덟 ;; 9) echo 아홉 ;; *) echo "" ;; esac; }
pub_en="$(en "$pub_n")"; unpub_en="$(en "$unpub_n")"
pub_ko="$(ko "$pub_n")"; unpub_ko="$(ko "$unpub_n")"
assert_ok test -n "$pub_en" -a -n "$unpub_en" -a -n "$pub_ko" -a -n "$unpub_ko"

# 영문 랜딩 문서 — 대소문자 두 형태를 모두 허용한다(문장 첫머리면 "Four", 아니면 "four").
#
# ⚠️ **`getting-started.md`가 여기 들어 있는 이유.** 이 파일은 아래에서 설치 절 **개수**로도
# 대조되지만, 그것만으로는 상단의 산문 배너("Five of the nine are on a public registry …")를
# 보지 못한다. 실제로 Ruby를 게시하는 PR에서 설치 절은 뒤집혔는데 그 배너만 "Four … The other
# five (…, Ruby, …)"로 남았고, 구조 검사가 초록이라 아무도 몰랐다 — 이 저장소에서 가장 많이
# 읽히는 문서에 거짓이 남은 것이다. 구조와 산문은 서로를 대신하지 못하므로 둘 다 본다.
#
# ⚠️ **파일 전체가 아니라 그 주장을 담은 줄만 본다.** 처음에는 `case "$(cat "$f")" in *five*`
# 처럼 파일 전체를 뒤졌는데, `getting-started.md`는 700줄이라 "five"가 어디선가 우연히 등장해
# **배너를 낡은 값으로 되돌려도 통과했다**(실측). 세 문서 모두 이 주장을 한 문장에만 쓰므로
# 그 문장을 앵커로 뽑는다 — 앵커를 못 찾으면 그것도 실패다(문구를 바꾸면 조용히 넘어가는 대신
# 시끄럽게 실패해야 한다).
for f in README.md SECURITY.md docs/guides/getting-started.md; do
  # 앵커 줄 + 뒤 2줄. SECURITY.md는 그 문장이 하드랩돼 있어 한 줄로는 수사를 놓친다.
  claim="$(grep -m1 -A2 -E 'on a public registry|shipped a first|shipped their first' "$ROOT/$f" || true)"
  assert_ok test -n "$claim"
  [ -n "$claim" ] || continue
  up="$(printf '%s' "$pub_en" | sed 's/^./\U&/')"
  case "$claim" in
    *"$pub_en"*|*"$up"*) : ;;
    *) assert_ok false "$f 의 게시 현황 문장이 개수($pub_n=$pub_en)를 말하지 않는다" ;;
  esac
done

# 미게시 수사는 **자리를 명시해서** 대조한다. 산문을 일반 파싱하려던 두 시도가 모두 실패했다:
#   (1) 파일 전체에서 `other <수사>` 찾기 → 게시와 무관한 "the other eight languages"(보여준
#       언어 말고 나머지 여덟)까지 걸려 오탐.
#   (2) registry/published를 언급하는 **줄**로 좁히기 → `SECURITY.md`는 그 문장이 하드랩돼
#       "(`0.1.0.rc1`, RubyGems). The other four" 줄에 그 키워드가 없어 **0건**이 됐다.
# 그래서 어디에 무엇이 적혀 있어야 하는지를 그냥 적는다. 문구를 바꾸면 시끄럽게 실패하고,
# 그때 이 목록을 함께 고치는 것이 맞다 — DEPLOY.md 가드가 쓰는 것과 같은 관용이다.
# ⚠️ README.md는 **두 곳**이다(상단 배너 + 하단 서술). 하나만 검사하면 다른 쪽이 낡어도 통과한다.
claim_at() { # $1=파일 $2=기대 문자열 $3=자리 이름
  assert_contains "$(cat "$ROOT/$1")" "$2" "$1 의 $3 가 DF_PUBLISHED 파생 미게시 수($unpub_n=$unpub_en)와 다르다"
}
# ⚠️ **수·복수를 가려야 한다 — 안 그러면 가드가 비문을 강제한다.** 미게시가 1개가 되는 순간
# `the other one languages are …`를 요구하게 되고, 문서를 옳은 영어로 쓰면 CI가 빨개진다(가드가
# 문서를 틀리게 만드는 상태 — `test-deploy-md.sh` 상단이 기록한 "zero tags" 실패와 같은 부류다).
# 한글도 마찬가지로 `나머지 하나 언어`는 비문이다.
if [ "$unpub_n" -eq 1 ]; then
  _en_banner="the other language is not on a registry yet"
  _en_other="The other one"
  _ko_other="나머지 한 언어"
else
  _en_banner="the other $unpub_en languages are not on a registry yet"
  _en_other="The other $unpub_en"
  _ko_other="나머지 $unpub_ko 언어"
fi
# ⚠️ 미게시가 0이 되면(= 아홉 전부 게시) 이 문장들은 **존재해선 안 된다** — "나머지 N개는
# 미게시"가 아니라 "전부 게시됐다"로 바뀌어야 한다. 그건 수사 치환이 아니라 문장 교체라
# 자동으로 만들 수 없으므로, 그 순간 시끄럽게 실패시켜 사람이 다시 쓰게 한다.
assert_ok test "$unpub_n" -ge 1

claim_at README.md "$_en_banner" "상단 배너"
claim_at README.md "the remaining $unpub_en (" "하단 서술"
claim_at SECURITY.md "$_en_other" "미게시 열거"
claim_at docs/guides/getting-started.md "The other $unpub_en (" "상단 배너"

# ---- 가드 스코프 밖에 있던 네 자리(2026-08-10에 드리프트가 실제로 발견된 곳) ----
#
# ⚠️ 위 목록은 **랜딩 문서만** 겨눴다. Ruby·Node가 게시된 뒤 그 넷은 손으로 갱신됐지만, 같은
# 사실을 말하는 다른 네 문서는 `4개 / 나머지 5개`에 그대로 멈춰 있었고 자가테스트 15종이 전부
# 초록이었다 — 가드가 있다는 사실이 오히려 안심시킨 부류다. 특히 `CLAUDE.md`는 세션마다
# 자동 로드되는 문서라 낡은 값이 **다음 작업의 전제**가 된다.
#
# ⚠️ 처음 보고한 드리프트는 2곳(CLAUDE.md·DEPLOY.md)이었고, 리포 전수 재스캔에서 2곳
# (CHANGELOG.md·roadmap)이 더 나왔다. "지적받은 집합은 불완전하다"의 실례라 넷 다 넣는다.
Pub_en="$(printf '%s' "$pub_en" | sed 's/^./\U&/')"

claim_at CLAUDE.md "${pub_n}개는 첫 RC가 공개 레지스트리에 게시됐다" "현재 상태(게시 수)"
claim_at CLAUDE.md "나머지 ${unpub_n}개("                            "현재 상태(미게시 수)"
claim_at CLAUDE.md "9개 중 ${pub_n}개만 첫 RC 게시"                  "문서 언어 규칙 절"

claim_at DEPLOY.md "**$pub_en of nine languages are published"       "릴리스 워크플로 상태(게시 수)"
# 여기도 수·복수 — 1개면 `and one is not.`
if [ "$unpub_n" -eq 1 ]; then _dep_unpub="and $unpub_en is not.**"; else _dep_unpub="and $unpub_en are not.**"; fi
claim_at DEPLOY.md "$_dep_unpub"                                     "릴리스 워크플로 상태(미게시 수)"

claim_at CHANGELOG.md "지금까지 ${pub_ko} 언어가"                     "폴리글랏 안내(게시 수)"
claim_at CHANGELOG.md "나머지 ${unpub_ko}("                           "폴리글랏 안내(미게시 수)"

claim_at docs/roadmap/language-support.md "**$Pub_en are now live as release candidates**" "step-0(게시 수)"
claim_at docs/roadmap/language-support.md "the remaining $unpub_en ("                      "step-0(미게시 수)"

# 한글 미러 — 영문과 같은 사실을 한글 수사로 말한다(README.md와 동일 구조의 미러라는 규칙).
ko_t="$(cat "$ROOT/README.ko.md")"
assert_contains "$ko_t" "아홉 중 $pub_ko" "README.ko.md 의 게시 개수가 DF_PUBLISHED 파생값($pub_n)과 다르다"
assert_contains "$ko_t" "$_ko_other" "README.ko.md 의 미게시 개수가 DF_PUBLISHED 파생값($unpub_n)과 다르다"

# ⚠️ getting-started는 산문이 아니라 **구조**로 대조한다 — 언어마다 설치 절이 두 형태 중
# 하나이고, 그 개수가 곧 게시 현황이다. 산문 수사와 달리 표현을 바꿔도 흔들리지 않는다.
gs="$ROOT/docs/guides/getting-started.md"
assert_eq "$unpub_n" "$(grep -c '^### 3) Installation after release (future)$' "$gs")" \
  "getting-started의 '미게시' 설치 절 수 ≠ DF_PUBLISHED 파생 미게시 수"
assert_eq "$pub_n" "$(grep -c '^### 3) Installation from ' "$gs")" \
  "getting-started의 '게시됨' 설치 절 수 ≠ DF_PUBLISHED 파생 게시 수"

# ---- 호환성 표의 **버전 문자열** ↔ df_published_version ----
#
# ⚠️ 위 어서션들은 전부 "몇 개가 게시됐나"만 본다. **어떤 버전이 게시됐나는 아무도 안 봤다** —
# 그래서 이 표는 아홉 행 중 일곱이 `0.1.0`에 멈춘 채 여섯 번의 게시를 그대로 통과했다(2026-08-10
# 발견). 개수와 버전은 같은 사실의 다른 축이고, 소비자가 실제로 복사해 가는 쪽은 버전이다.
#
# 미게시 언어는 `0.1.0`(아직 태우지 않은 라인 버전)이라야 한다 — 이렇게 두면 그 언어가 게시되는
# 순간 `df_published_version`이 채워지면서 기대값이 RC로 바뀌고, 표를 안 고치면 시끄럽게 깨진다.
gs_label() { case "$1" in
  java) echo Java ;; python) echo Python ;; node) echo Node ;; go) echo Go ;;
  dotnet) echo 'C#/.NET' ;; php) echo PHP ;; rust) echo Rust ;; ruby) echo Ruby ;;
  kotlin) echo Kotlin ;; esac; }

rows_seen=0
for L in $DEPLOY_LANGS; do
  _lbl="$(gs_label "$L")"
  # `| <Label> `<version>` |` 의 백틱 안을 뽑는다.
  _row="$(grep -m1 -F "| $_lbl \`" "$gs" || true)"
  [ -n "$_row" ] && rows_seen=$((rows_seen + 1))
  _got="$(printf '%s' "$_row" | sed -n 's/^| [^`]*`\([^`]*\)`.*/\1/p')"
  _want="$(df_published_version "$L")"
  [ -n "$_want" ] || _want="0.1.0"
  assert_eq "$_want" "$_got" "호환성 표의 $_lbl 버전이 SSOT와 다르다"
done
# ⚠️ 대조군 — 라벨 표기가 바뀌면 위 루프가 전부 "빈 값 == 빈 값"으로 조용히 통과할 수 있다.
# ⚠️ 메시지 인자를 빠뜨리지 말 것: `assert_eq`는 실패 경로에서 `$3`을 읽는데 이 파일은 `set -u`라
# **실패하는 순간 unbound variable로 죽는다** — 어서션 실패 메시지 대신 셸 오류가 나오고
# `assert_report`에 도달하지 못해 남은 어서션도 안 돈다(변이검증 M4에서 실제로 그렇게 죽었다).
assert_eq "9" "$rows_seen" "호환성 표에서 읽은 언어 행 수가 9가 아니다 — 라벨 표기가 바뀌었나"

# ---- DEPLOY.md `- Install:` 좌표의 **버전 문자열** ↔ df_published_version ----
#
# 같은 축(버전 문자열)인데 위 검사는 getting-started의 호환성 표만 봤다. DEPLOY.md의 설치 좌표
# 아홉 줄 중 버전을 품는 것은 Maven 좌표 둘(java·kotlin)뿐이고, **그 둘 다 게시 후에도 `0.1.0`에
# 멈춰 있었다**(2026-08-11 발견 — java는 08-10, kotlin은 08-11에 각각 `0.1.0-RC1`로 게시됐다).
# 나머지 일곱 줄은 버전 없는 설치 명령(`pip install keycloak-sdk` 등)이라 드리프트할 값이 없다.
# ⚠️ **좌표를 여기서 다시 적지 않는다 — `df_install` 템플릿에서 파생한다.** 처음에는 손으로 옮겨
# 적었는데 go에서 `go get ` 접두를 빠뜨려 **그 어서션이 영원히 성립할 수 없었다**(DEPLOY.md가
# 옳아도 매치가 빈 값이라 실패). 게다가 java 좌표가 kotlin 좌표의 접두라 `grep -m1`이 문서 순서에
# 의존했다. 템플릿의 `%s` 앞부분을 앵커로 쓰면 둘 다 사라진다(java 앵커는 `:`로 끝난다).
_bt='`'      # 백틱 리터럴. 아래 패턴은 전부 완전인용이라야 글롭으로 해석되지 않는다.
_pct='%s'    # printf 자리표시자 리터럴 — 붙여쓰면 셸마다 파싱이 미묘하다(dash 확인).
coords_seen=0
coords_want=0
for L in $DEPLOY_LANGS; do
  _tpl="$(df_install "$L")"
  case "$_tpl" in *"$_pct"*) : ;; *) continue ;; esac   # 버전을 품지 않는 설치 명령은 대조할 값이 없다
  _prefix="${_tpl%%"$_pct"*}"
  _want="$(df_published_version "$L")"
  [ -n "$_want" ] || continue   # 미게시 언어는 대조 대상이 아니다(게시되면 자동으로 편입된다)
  coords_want=$((coords_want + 1))
  # ⚠️ `--` 필수 — 패턴이 `-`로 시작해 grep이 옵션으로 파싱한다(빠뜨리면 매치가 **빈 값**이 되고
  # 아래 대조군이 없으면 "빈 값 == 빈 값"으로 조용히 통과한다).
  _line="$(grep -m1 -F -- "- Install: $_bt$_prefix" "$ROOT/DEPLOY.md" || true)"
  [ -n "$_line" ] && coords_seen=$((coords_seen + 1))
  # sed 대신 파라미터 확장 — 접두에 `/`·`.`·`@`가 섞여 있어 정규식으로 넘기면 이스케이프가 필요하고,
  # 그 이스케이프를 빠뜨리는 것이 바로 위 사고와 같은 부류다.
  _rest="${_line#"- Install: $_bt$_prefix"}"
  _got="${_rest%%"$_bt"*}"
  assert_eq "$_want" "$_got" \
    "DEPLOY.md 의 $L 설치 좌표 버전이 게시 SSOT와 다르다(기대 줄: - Install: $_bt$(printf "$_tpl" "$_want")$_bt)"
done
# ⚠️ 대조군 — 좌표 표기가 바뀌면 위 루프가 "빈 값 == 빈 값"이 아니라 아예 돌지 않아 조용히 통과한다.
# ⚠️ **기대 개수를 하드코딩하지 않는다.** 이전 판은 `2`(java·kotlin)를 박아 두었는데, go가 게시되면
# 실제 기대값은 3인데도 go 줄을 **못 찾은 채** `coords_seen`이 2에 머물러 이 대조군이 통과했다 —
# 대조군이 눈을 감은 채 초록이었다. 그래서 기대값도 SSOT에서 파생한다.
# ⚠️ 다만 파생값끼리의 비교는 **둘 다 0이면 공허하게 통과**한다(루프가 아예 안 돌아도 0==0).
# 하드코딩된 `2`가 우연히 갖고 있던 유일한 미덕이 그 비공허성이었으므로 바닥값으로 분리해 남긴다 —
# java·kotlin은 이미 게시됐고 이 수는 줄어들 수 없다.
assert_ok test "$coords_want" -ge 2
assert_eq "$coords_want" "$coords_seen" \
  "DEPLOY.md 에서 읽은 버전-보유 설치 좌표 수($coords_seen)가 SSOT 파생 기대값($coords_want)과 다르다 — 좌표 표기가 바뀌었나"

assert_report
