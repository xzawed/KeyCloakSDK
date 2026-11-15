#!/usr/bin/env sh
# 언어 집합 — 「아홉 언어」를 말하는 가드의 언어 목록이 **트리의 언어 집합을 나누는가**(등록부 symmetry-guards-cover-a-subset).
#
# 왜 필요한가: 그런 가드 다섯이 언어를 손 목록으로 들고 트리와 대조하지 않았다. 실측(2026-11-16): `main` 259540eb 에
# 추적된 `zig/package.json` 하나를 심고 repo-hygiene 의 실제 트리 가드 76 을 전부 돌렸더니 10 이 열 번째 언어를 지목했다.
# 아래 다섯은 「아홉 언어」를 말하면서 초록이었다 — 그 언어는 통합 장부 · 커버리지 경계 · 버전 대조 · admin 표 · doctor 를
# 조용히 건너뛴다.
#
# 원천은 트리다(`df_tree_langs` — 자기 루트에 빌드 매니페스트를 가진 최상위 디렉터리). 가드 쪽은 **가드가 내보낸 값**이다 —
# 소스 글자를 정규식으로 읽지 않는다. 각 가드는 `covered <언어>` · `exempt <언어> <근거>` 줄을 낸다(면제와 그 근거는 그 가드가
# 소유한다). 판정은 분할이다: covered ∪ exempt = 트리, 겹침 0, 유령(트리 밖 이름) 0.
#
# ⚠️ 여기 없는 것은 이미 묶여 있다 — 트리에서 파생하거나(`df_tree_langs` · `deriveLangs`), 자기 손 목록을 그 파생과 스스로
# 대조하거나(`test-security-defaults.sh` 0절 · `test-deploy-facts.sh` 의 DEPLOY_LANGS), DEPLOY_LANGS 를 돈다(그 뿌리가 트리와
# 대조된다). 새 가드가 언어를 손으로 들면 여기 한 줄(`lu_guard`)을 더한다.
# ⚠️ 트리 파생의 거짓음성은 그대로다 — 매니페스트가 목록에 없는 언어(`build.zig.zon`)와 매니페스트를 한 단계 더 깊이 둔 언어
# (`zig/sdk/package.json`)는 트리에 없다. 근거 · 오탐 측정은 `test-security-defaults.sh` 의 「언어 집합 축」 주석이 소유한다.
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
ROOT="$(cd "$DIR/../.." && pwd)"
. "$ROOT/scripts/lib/deploy-facts.sh"

# lu_gap <트리 집합> <가드 출력> → 어긋남(" zig(빠짐)" · " go(둘 다)" · " xx(유령)" · " (모양: …)") — 비면 분할이다.
lu_gap() {
  _cov="$(printf '%s\n' "$2" | awk '$1 == "covered" && NF == 2 { print $2 }')"
  _exe="$(printf '%s\n' "$2" | awk '$1 == "exempt" && NF >= 3 { print $2 }')"
  _bad="$(printf '%s\n' "$2" | awk 'NF && !(($1 == "covered" && NF == 2) || ($1 == "exempt" && NF >= 3)) { print; exit }')"
  _o=''
  [ -z "$_bad" ] || _o=" (모양: $_bad)"
  for _l in $(printf '%s\n' $_cov $_exe | sort -u); do
    case " $1 " in *" $_l "*) ;; *) _o="$_o $_l(유령)" ;; esac
  done
  for _l in $1; do
    _c=0; _e=0
    printf '%s\n' $_cov | grep -qxF -- "$_l" && _c=1
    printf '%s\n' $_exe | grep -qxF -- "$_l" && _e=1
    case "$_c$_e" in 00) _o="$_o $_l(빠짐)" ;; 11) _o="$_o $_l(둘 다)" ;; esac
  done
  printf '%s' "$_o"
}

# lu_exempt_bad <규칙> <가드 출력> → 규칙을 어긴 면제(" zig" …) — 면제는 **그 사실의 소유자**가 말하는 언어만이다(Grok 적대
# 레그: 근거 칸에 아무 말이나 적은 `exempt zig …` 가 분할을 통과했다). 규칙: none(면제를 받지 않는다) · tag-ssot(deploy-facts 의
# df_versionbump 가 「none …」 — 태그가 버전 SSOT — 라고 말하는 언어만).
lu_exempt_bad() {
  _o=''
  for _l in $(printf '%s\n' "$2" | awk '$1 == "exempt" { print $2 }'); do
    case "$1" in
      none) _o="$_o $_l" ;;
      tag-ssot) case "$(df_versionbump "$_l")" in none*) ;; *) _o="$_o $_l" ;; esac ;;
      *) _o="$_o $_l(규칙 $1 ?)" ;;
    esac
  done
  printf '%s' "$_o"
}

# ── 판정 함수의 대조군 — 늘 비거나 늘 우는 판정과 가른다 ──────────────────────────────────────
assert_eq " x" "$(lu_exempt_bad none 'exempt x 이유')" "[언어집합·음성대조] 면제를 받지 않는 가드의 면제를 못 본다"
assert_eq " rust" "$(lu_exempt_bad tag-ssot 'exempt rust 이유')" "[언어집합·음성대조] 태그가 버전 SSOT 가 아닌 언어의 면제를 못 본다"
assert_eq "" "$(lu_exempt_bad tag-ssot "$(printf 'exempt go 이유\nexempt php 이유')")" "[언어집합·양성대조] 태그가 버전 SSOT 인 언어의 면제를 거부했다"
assert_eq "" "$(lu_gap 'a b c' "$(printf 'covered a\ncovered b\nexempt c 이유가 있다')")" "[언어집합·양성대조] 정확한 분할에서 어긋남을 냈다"
assert_eq " c(빠짐)" "$(lu_gap 'a b c' "$(printf 'covered a\ncovered b')")" "[언어집합·음성대조] 빠진 언어를 못 본다"
assert_eq " c(둘 다)" "$(lu_gap 'a b c' "$(printf 'covered a\ncovered b\ncovered c\nexempt c 이유')")" "[언어집합·음성대조] 겹침을 못 본다"
assert_eq " d(유령)" "$(lu_gap 'a b c' "$(printf 'covered a\ncovered b\ncovered c\ncovered d')")" "[언어집합·음성대조] 트리 밖 이름을 못 본다"
assert_eq " (모양: exempt c) c(빠짐)" "$(lu_gap 'a b c' "$(printf 'covered a\ncovered b\nexempt c')")" \
  "[언어집합·음성대조] 근거 없는 면제를 면제로 받았다"

# ── 트리 ───────────────────────────────────────────────────────────────────────────────────
TREE="$(df_tree_langs "$ROOT")"
# 공허 방어 — 파생이 0 이면 「어긋남 없음」이 통과처럼 보인다(git 이 없는 트리 · 규칙 파손).
assert_ok test -n "$TREE"

# lu_guard <이름> <면제 규칙> <명령…> — 그 가드가 내보낸 언어 집합이 트리를 나누는가 · 면제가 규칙을 지키는가 · 열 번째 언어를
# 더한 트리에서는 우는가.
lu_guard() {
  _name="$1"
  _rule="$2"
  shift 2
  _got="$("$@" 2>&1)" && _rc=0 || _rc=$?
  assert_eq "0" "$_rc" "[언어집합] $_name 이 언어 집합을 내보내지 못했다 — 출력: $_got"
  assert_ok test -n "$_got"
  assert_eq "" "$(lu_gap "$TREE" "$_got")" \
    "[언어집합] $_name 의 언어 목록이 트리를 나누지 않는다 — (빠짐)은 그 가드가 조용히 건너뛰는 언어 · (둘 다)는 겹침 · (유령)은 트리 밖 이름"
  assert_eq "" "$(lu_exempt_bad "$_rule" "$_got")" \
    "[언어집합] $_name 의 면제가 규칙($_rule)을 어긴다 — 면제는 그 사실의 소유자가 말하는 언어만이다"
  # 음성 대조 — 트리에 언어 하나를 더하면 그 가드가 그것을 (빠짐)으로 지목해야 한다(내보낸 값이 트리와 무관한 상수인 판정과 가른다).
  assert_contains "$(lu_gap "$TREE zz10" "$_got")" " zz10(빠짐)" "[언어집합·음성대조] $_name 에 없는 열 번째 언어를 판정이 못 본다"
}
lu_guard integration-coverage.mjs none node "$ROOT/scripts/integration-coverage.mjs" langs
lu_guard coverage-boundary.mjs none node "$ROOT/scripts/coverage-boundary.mjs" langs
lu_guard check-versions.mjs tag-ssot node "$ROOT/scripts/check-versions.mjs" --langs
lu_guard check-admin-capability.mjs none node "$ROOT/scripts/check-admin-capability.mjs" --langs
lu_guard doctor.mjs none node "$ROOT/scripts/doctor.mjs" --langs

# ── 파생 규칙의 사본 둘 ────────────────────────────────────────────────────────────────────
# `test-security-defaults.sh` 의 `SD_MANIFEST`(그 파일의 0절 · `measure-lang-universe-fp.sh` 가 읽는다)와 `deploy-facts.sh` 의
# `DF_MANIFEST`(나머지 전부)가 다른 매니페스트를 보면, 한쪽에만 더한 매니페스트의 언어를 다른 쪽 가드가 조용히 건너뛴다.
# 표기만 다르다(`\.` · `[.]` · 감싼 괄호와 `$`) — 그것을 걷고 대안 집합으로 비교한다.
lu_manifests() { printf '%s' "$1" | sed 's/^(//; s/)\$$//; s/\[\.\]/./g; s/\\\././g' | tr '|' '\n' | sort | tr '\n' ' '; }
_sd="$(sed -n "s/^SD_MANIFEST='\(.*\)'\$/\1/p" "$ROOT/scripts/test/test-security-defaults.sh" | head -1)"
assert_ok test -n "$_sd"
assert_ok test -n "$DF_MANIFEST"
assert_eq "$(lu_manifests "$DF_MANIFEST")" "$(lu_manifests "$_sd")" \
  "[언어집합] 트리 파생 규칙의 사본 둘이 다른 매니페스트를 본다 — test-security-defaults.sh 의 SD_MANIFEST ↔ scripts/lib/deploy-facts.sh 의 DF_MANIFEST"
# 대조군 — 한쪽에만 매니페스트를 더하면 운다(정규화가 차이를 지우지 않는다).
assert_ok test "$(lu_manifests "$_sd|mix\.exs")" != "$(lu_manifests "$DF_MANIFEST")"

assert_report
