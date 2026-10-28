#!/usr/bin/env sh
# 잔여작업 등록부가 **다시 이력 저장소가 되지 않게** 한다.
#
# ⚠️ 왜: 이 파일은 예산 없이 256,624 B 까지 자랐고 그중 **닫힌 70 건의 하위 서사가 65,347 B**
# 였다. 2026-09-22 에 그 서사를 `archive/docs-history-2026-09` 태그로 이관했다. 다시 붙는 것을
# 막는 장치가 없으면 같은 자리로 돌아간다(옵트인 예산이 한 번도 이 파일을 안 덮은 것이 원인이다).
#
# ⚠️ **단언할 수 있는 규칙은 하나뿐이다 — 「닫힌 항목이 소유한 줄 수 == 닫힌 항목 수」.**
# 정상적인 닫기는 표제 한 줄만 소유하므로 항목이 하나 닫힐 때 **양변이 함께 1 씩** 움직인다.
# 하위 서사가 돌아오면 **좌변만** 움직여 빨개진다. 기대 상수를 영원히 고칠 일이 없다 —
# `닫힘 == 70` 도 `닫힘 <= N` 도 바이트 상한도 전부 변경 때마다 다시 맞추는 수라 공허하다.
# (독립 레그 판정. `닫힘 == 0` 은 이 저장소의 계수 앵커 프레임워크가 추출값 0 을 「추출 실패」로
#  읽어 쓸 수 없고, 애초에 표제를 남기는 이 설계에서는 성립하지도 않는다.)
#
# ⚠️ `> 0` 절이 **이중 추출 실패**(`0 == 0`)를 막는다 — 정규식이 깨지면 양변이 함께 0 이 되어
# 조용히 통과한다. 그 부류가 이 저장소에서 이미 여러 번 나왔다.
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
ROOT="${RW_ROOT:-$DIR/../..}"
F="$ROOT/docs/superpowers/plans/remaining-work.md"

assert_eq "yes" "$([ -f "$F" ] && echo yes || echo no)" "[등록부] 파일이 없다: $F"

# 항목이 "소유"하는 줄 = 표제줄 + 뒤따르는 **들여쓴** 줄 + 바로 뒤에 붙은 **블록 주석**(다음 항목/헤딩/
# 다른 본문 전까지). 끝의 빈 줄은 항목 사이 간격이므로 소유에서 뺀다.
# ⚠️ 블록 주석도 센다(2026-10-27) — 들여쓴 줄만 세던 동안 닫힌 13 건이 열 0 블록 주석으로 서사 9,362 B 를
# 다시 달고 있었고 이 단언은 초록이었다(주입 예산은 주석을 세지 않으니 그 길로 옮겨 붙었다). 기계 앵커
# (`<!-- doc-guard:` · `doc-budget:` · `doc-status:`)는 서사가 아니라 다음 본문의 표지라 **세지도 끊지도
# 않는다** — 끊으면 앵커 뒤에 놓인 서사 주석을 놓친다(사례 anchor-then-narrative). ⚠️ 단 **한 줄이고
# `-->` 로 끝날 때만** 앵커다(들여쓰기는 상관없다). 여러 줄이거나 뒤에 글이 붙은 「앵커」는 서사로 센다 —
# 중립으로 두면 그 안에 숨긴 글과, 닫히지 않은 앵커가 삼킨 뒤 항목까지 놓친다(Grok 레그가 지목한 셋).
_shape_of() {
  awk '
  function flush(){ if (cur=="x") { owned += (n - trail) } ; cur=""; n=0; trail=0 }
  incomment { n++; trail=0; if ($0 ~ /-->/) incomment=0; next }
  /^- \[[ x]\] / { flush(); cur = (substr($0,4,1)=="x") ? "x" : "o"; if (cur=="x") closed++; n=1; trail=0; next }
  /^#{1,6} / { flush(); next }
  {
    if (cur != "") {
      if ($0 ~ /^[[:space:]]*<!--[[:space:]]*doc-(guard|budget|status):.*-->[[:space:]]*$/) next
      if ($0 ~ /^[[:space:]]*$/) { n++; trail++; next }
      if ($0 ~ /^[[:space:]]/)   { n++; trail=0; next }
      if ($0 ~ /^<!--/) { n++; trail=0; if ($0 !~ /-->/) incomment=1; next }
      flush(); next
    }
  }
  END { flush(); printf "%d %d", owned, closed }
  ' "$1"
}
_shape="$(_shape_of "$F")"
_owned="${_shape%% *}"
_closed="${_shape##* }"

# 공허 방지 — 추출이 깨지면 둘 다 0 이 되어 `0 == 0` 으로 통과한다.
_pos=1; [ "$_closed" -gt 0 ] && _pos=0
assert_eq "ok" "$(ok_if "$_pos" "$_closed")" \
  "[등록부] 닫힌 항목을 하나도 못 찾았다($_closed) — 추출이 깨졌나? (0 == 0 으로 통과시키지 않는다)"

assert_eq "$_closed" "$_owned" \
  "[등록부] 닫힌 항목이 소유한 줄 수($_owned)가 닫힌 항목 수($_closed)와 다르다 — 닫은 항목에 하위 서사(들여쓴 줄이나 바로 뒤의 블록 주석)가 다시 붙었다. 사후 서사는 PR·커밋 메시지나 아카이브 태그로 보낼 것(문서 상단 안내 참조)"

# 위 해석은 주석 안의 줄을 항목으로 보지 않는다 — 다른 계수기(절 헤더 · 문서 가드의 work-packages)는 열 0 체크박스를
# 어디서든 센다. 둘이 갈리면 주석 안에 체크박스 줄이 있는 것이고, 그러면 그 계수기들의 수가 거짓이 된다.
assert_eq "$(grep -c '^- \[x\] ' "$F")" "$_closed" \
  "[등록부] 모양 해석의 닫힘 수가 grep 과 다르다 — 블록 주석 안에 열 0 체크박스 줄이 있나?"

# 소유 규칙 자신의 고정 사례 — 위 단언은 실제 등록부만 보므로, 규칙이 무엇을 세는지는 여기서 잰다.
# 사례마다 「소유 − 닫힘」을 본다(0 이면 붙은 서사 없음).
_fx="$(mktemp -d)"
printf '%s\n' '- [x] `a` 닫힘' '- [ ] `b` 열림' > "$_fx/plain.md"
printf '%s\n' '- [x] `a` 닫힘' '<!-- a 닫힘 상세 -->' '- [ ] `b`' > "$_fx/comment.md"
# 둘째 줄은 열 0 이다 — 들여 쓰면 주석을 안 따라가도 들여쓴 줄 규칙이 대신 세어, 그 변이를 못 잡는다.
printf '%s\n' '- [x] `a` 닫힘' '' '<!-- 여러 줄' '서사 -->' '' '## 절' > "$_fx/multiline.md"
printf '%s\n' '- [x] `a` 닫힘' '  들여쓴 서사' > "$_fx/indented.md"
printf '%s\n' '- [x] `a` 닫힘' '<!-- doc-guard: kind=count source=x -->' '본문' > "$_fx/anchor.md"
printf '%s\n' '- [x] `a` 닫힘' '<!-- doc-guard: kind=count source=x -->' '<!-- 앵커 뒤의 서사 -->' '본문' > "$_fx/anchor-then-narrative.md"
printf '%s\n' '- [x] `a` 닫힘' '  <!-- doc-guard: kind=count source=x -->' '본문' > "$_fx/anchor-indented.md"
printf '%s\n' '- [x] `a` 닫힘' '<!-- doc-status: x' '숨긴 글' '-->' > "$_fx/anchor-multiline.md"
printf '%s\n' '- [x] `a` 닫힘' '<!-- doc-guard: 닫히지 않음' '- [x] `b` 삼켜진 항목' '  서사' > "$_fx/anchor-unterminated.md"
printf '%s\n' '- [x] `a` 닫힘' '<!-- doc-guard: kind=count source=x --> 뒤에 붙은 서사' > "$_fx/anchor-trailing-text.md"
printf '%s\n' '- [ ] `a` 열림' '<!-- a 착수 정보 -->' '- [x] `b` 닫힘' > "$_fx/open-comment.md"
for _case in plain:0 comment:1 multiline:3 indented:1 anchor:0 anchor-then-narrative:1 anchor-indented:0 \
  anchor-multiline:3 anchor-unterminated:3 anchor-trailing-text:1 open-comment:0; do
  _name="${_case%%:*}"; _want="${_case##*:}"
  _s="$(_shape_of "$_fx/$_name.md")"
  assert_eq "$_want" "$(( ${_s%% *} - ${_s##* } ))" "[소유 규칙] 사례 $_name: 소유 − 닫힘"
done
rm -rf "$_fx"

# ── 절 헤더가 스스로 세는 수와 맞는가 ────────────────────────────────────────
# ⚠️ 실측 2026-09-22: `## A–D` 네 헤더의 「N건 (열림 M)」이 **넷 다 틀렸다**
# (A 12/2→실제 12/1 · B 27/20→49/15 · C 67/66→74/56 · D 46/44→55/48). 항목을 닫거나 더할
# 때마다 사람이 헤더를 같이 고쳐야 하는 수이고, 그런 수는 반드시 썩는다.
# ⚠️ 기대 상수를 두지 않는다 — 단언하는 것은 **헤더가 자기 절을 정확히 센다**는 규칙이다.
# 항목이 하나 닫히면 양변이 함께 움직이므로 이 단언은 다시 보정되지 않는다.
_hdr="$(awk '
  function flush(){ if (cur != "") { if (sn != n || so != o) bad = bad sprintf("%s: 적힘 %d건(열림 %d) vs 실제 %d건(열림 %d)\n", cur, sn, so, n, o); secs++ } }
  /^## / {
    flush()
    if ($0 ~ /^## [A-D]\./) {
      cur = substr($0, 4, 2); n = 0; o = 0; sn = 0; so = 0
      if (match($0, /— *[0-9]+ *건/))   { t = substr($0, RSTART, RLENGTH); gsub(/[^0-9]/, "", t); sn = t + 0 }
      if (match($0, /열림 *[0-9]+/))     { t = substr($0, RSTART, RLENGTH); gsub(/[^0-9]/, "", t); so = t + 0 }
    } else cur = ""
    next
  }
  cur != "" && /^- \[ \] / { n++; o++ }
  cur != "" && /^- \[x\] / { n++ }
  END { flush(); printf "%d\n%s", secs, bad }
' "$F")"
_secs="$(printf '%s' "$_hdr" | head -1)"
_bad="$(printf '%s' "$_hdr" | tail -n +2)"

# 공허 방지 — 절 이름 규칙이 바뀌어 0 개를 세면 아래 단언은 언제나 통과한다.
assert_eq "4" "$_secs" \
  "[등록부] \`## A–D\` 절을 ${_secs}개 찾았다 — 절 제목 규칙이 바뀌었나? (0 개를 세고 통과시키지 않는다)"

assert_eq "" "$_bad" \
  "[등록부] 절 헤더의 수가 그 절의 실제 체크박스와 다르다 — 헤더를 고치거나, 헤더에서 수를 빼라"

# ── 소절(`###`) 헤더도 같은 규칙이다 ─────────────────────────────────────────
# ⚠️ 실측 2026-10-28: 끝에 수를 적은 소절 열다섯 중 셋이 틀렸다(15 → 실제 38 · 10 → 14 · 6 → 25) — 위 단언이
# `## A–D` 만 봐서 아무도 안 셌다. 같은 규칙(헤더가 자기 소절을 센다 · 기대 상수 없음)을 건다. 끝이 「— N」인
# `###` 만 본다 — 수를 적지 않은 소절은 주장이 없으니 볼 것도 없다. 소절은 다음 헤딩(어느 깊이든)에서 끝난다.
_sub_of() {
  awk '
  { sub(/\r$/, "") }
  function flush(){ if (cur != "") { if (sn != n) bad = bad sprintf("%s: 적힘 %d vs 실제 %d\n", cur, sn, n); secs++ }; cur = "" }
  /^#{1,6} / {
    flush()
    if ($0 ~ /^### / && match($0, /— *[0-9]+ *$/)) { t = substr($0, RSTART, RLENGTH); gsub(/[^0-9]/, "", t); sn = t + 0; n = 0; cur = $0 }
    next
  }
  cur != "" && /^- \[[ x]\] / { n++ }
  END { flush(); printf "%d\n%s", secs, bad }
  ' "$1"
}
# 규칙 자신의 고정 사례 — 「찾은 소절 수:틀린 소절 수」.
_fx="$(mktemp -d)"
printf '%s\n' '### 가 — 2' '- [ ] `a`' '- [x] `b`' > "$_fx/ok.md"
printf '%s\n' '### 가 — 3' '- [ ] `a`' '- [x] `b`' > "$_fx/wrong.md"
printf '%s\n' '### 가' '- [ ] `a`' > "$_fx/nonum.md"
printf '%s\n' '### 가 — 1' '- [ ] `a`' '## 나' '- [ ] `b`' > "$_fx/ends-at-h2.md"
printf '%s\n' '### 가 — 1' '- [ ] `a`' '### 나 — 2' '- [ ] `b`' '- [x] `c`' > "$_fx/two-subs.md"
printf '### 가 — 1\r\n- [ ] `a`\r\n' > "$_fx/crlf.md"
for _case in ok:1:0 wrong:1:1 nonum:0:0 ends-at-h2:1:0 two-subs:2:0 crlf:1:0; do
  _name="${_case%%:*}"; _rest="${_case#*:}"
  _s="$(_sub_of "$_fx/$_name.md")"
  _n="$(printf '%s' "$_s" | head -1)"; _b="$(printf '%s' "$_s" | tail -n +2 | grep -c . || true)"
  assert_eq "$_rest" "$_n:$_b" "[소절 규칙] 사례 $_name: 찾은 소절:틀린 소절"
done
rm -rf "$_fx"

_sub="$(_sub_of "$F")"
_subsecs="$(printf '%s' "$_sub" | head -1)"
_subbad="$(printf '%s' "$_sub" | tail -n +2)"
assert_eq "ok" "$(ok_if "$([ "$_subsecs" -gt 0 ] && printf 0 || printf 1)" "$_subsecs")" \
  "[등록부] 끝에 수를 적은 \`###\` 소절을 하나도 못 찾았다 — 소절 제목 규칙이 바뀌었나? (0 개를 세고 통과시키지 않는다)"
assert_eq "" "$_subbad" \
  "[등록부] 소절 헤더의 수가 그 소절의 실제 체크박스와 다르다 — 헤더를 고치거나, 헤더에서 수를 빼라"

# 아카이브 안내가 살아 있는가 — 이관한 곳을 가리키는 줄이 지워지면 다음 세션이 서사를 못 찾는다.
_ptr="$(grep -c 'archive/docs-history-2026-09' "$F" || true)"
assert_eq "ok" "$(ok_if "$([ "$_ptr" -ge 1 ] && printf 0 || printf 1)" MISSING)" \
  "[등록부] 이관 대상 태그(archive/docs-history-2026-09)를 가리키는 줄이 사라졌다"
# 2026-10-28 이관분은 태그가 아니라 `main` 커밋을 가리킨다(`docs/README.md` 규칙: main 이력에 있으면 태그를 새로
# 만들지 않는다). 그 sha 가 해석되는지는 check-docs 검사 10c 가 본다 — 여기는 포인터가 있는지만 본다.
# ⚠️ **머리말 안내(H1 ~ 첫 `##`) 안에서만 찾는다** — 본문의 항목들이 같은 꼴의 포인터를 이미 셋 갖고 있어
# 파일 전체를 grep 하면 안내 줄을 지워도 통과했다(실측 2026-10-28: 이 단언의 첫 판이 main 에서 초록이었다).
_ptr2="$(awk '/^# /{p=1; next} p && /^## /{exit} p' "$F" | grep -cE 'git show [0-9a-f]{7,40}:docs/superpowers/plans/remaining-work\.md' || true)"
assert_eq "ok" "$(ok_if "$([ "$_ptr2" -ge 1 ] && printf 0 || printf 1)" MISSING)" \
  "[등록부] 머리말 안내에 2026-10-28 이관분을 가리키는 \`git show <sha>:docs/superpowers/plans/remaining-work.md\` 줄이 없다"

assert_report
