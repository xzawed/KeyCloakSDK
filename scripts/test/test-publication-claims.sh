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
claim_at README.md "the other $unpub_en languages are not on a registry yet" "상단 배너"
claim_at README.md "the remaining $unpub_en (" "하단 서술"
claim_at SECURITY.md "The other $unpub_en" "미게시 열거"
claim_at docs/guides/getting-started.md "The other $unpub_en (" "상단 배너"

# 한글 미러 — 영문과 같은 사실을 한글 수사로 말한다(README.md와 동일 구조의 미러라는 규칙).
ko_t="$(cat "$ROOT/README.ko.md")"
assert_contains "$ko_t" "아홉 중 $pub_ko" "README.ko.md 의 게시 개수가 DF_PUBLISHED 파생값($pub_n)과 다르다"
assert_contains "$ko_t" "나머지 $unpub_ko 언어" "README.ko.md 의 미게시 개수가 DF_PUBLISHED 파생값($unpub_n)과 다르다"

# ⚠️ getting-started는 산문이 아니라 **구조**로 대조한다 — 언어마다 설치 절이 두 형태 중
# 하나이고, 그 개수가 곧 게시 현황이다. 산문 수사와 달리 표현을 바꿔도 흔들리지 않는다.
gs="$ROOT/docs/guides/getting-started.md"
assert_eq "$unpub_n" "$(grep -c '^### 3) Installation after release (future)$' "$gs")" \
  "getting-started의 '미게시' 설치 절 수 ≠ DF_PUBLISHED 파생 미게시 수"
assert_eq "$pub_n" "$(grep -c '^### 3) Installation from ' "$gs")" \
  "getting-started의 '게시됨' 설치 절 수 ≠ DF_PUBLISHED 파생 게시 수"

assert_report
