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
for f in README.md SECURITY.md; do
  t="$(cat "$ROOT/$f")"
  up="$(printf '%s' "$pub_en" | sed 's/^./\U&/')"
  case "$t" in
    *"$pub_en"*|*"$up"*) : ;;
    *) assert_ok false "$f 가 게시 개수($pub_n=$pub_en)를 말하지 않는다" ;;
  esac
  assert_contains "$t" "other $unpub_en" "$f 의 '나머지 N개 미게시' 수가 DF_PUBLISHED 파생값($unpub_n)과 다르다"
done

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
