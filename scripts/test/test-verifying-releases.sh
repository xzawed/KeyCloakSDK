#!/usr/bin/env sh
# docs/guides/verifying-releases.md 의 자가테스트 — 소비자용 검증 안내가 저장소의 사실과 어긋나지 않는가
# (등록부 release-artifact-verification-undocumented).
#
# 안내서의 명령은 2026-11-15 에 아홉 레지스트리의 최신 게시본으로 실제로 돌려 본 것이다(PR 본문). 썩는 자리는 셋이다 —
# 이름을 대는 **서명 워크플로**(`--signer-workflow`)가 바뀌거나, **태그 접두**가 SSOT(`df_tag`)와 갈리거나, 열 번째
# 언어가 들어와 표에서 빠지는 것. 셋 다 소비자에게는 「검증이 실패한다」 가 아니라 **엉뚱한 것을 검증한다** 로 보인다.
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
. "$DIR/../lib/deploy-facts.sh"
ROOT="$(cd "$DIR/../.." && pwd)"
GUIDE="$ROOT/docs/guides/verifying-releases.md"

# ── 판정 — 라이브 단언과 아래 음성 대조가 **같은 함수**를 부른다 ─────────────────────────────────
# 안내서가 말하는 워크플로 중 저장소에 없는 것. $1=본문 파일 $2=루트
vr_missing_workflows() {
  _m=''
  for _w in $(grep -oE '\.github/workflows/[A-Za-z0-9_.-]+\.yml' "$1" 2>/dev/null | sort -u || true); do
    [ -f "$2/$_w" ] || _m="$_m $_w"
  done
  printf '%s' "$_m"
}
# 안내서의 태그 토큰(`<접두>v<version>` · `refs/tags/<접두><version>`) 중 SSOT 의 태그 접두가 아닌 것. $1=본문 파일
vr_bad_tags() {
  _ok=" "; for _l in $DEPLOY_LANGS; do _ok="$_ok$(df_tag "$_l" | sed 's/%s/<version>/') "; done
  _b=''
  for _t in $(grep -oE '[A-Za-z0-9/_.-]*-?v<version>' "$1" 2>/dev/null | sed 's|^refs/tags/||; s|^.*@||' | sort -u || true); do
    case "$_ok" in *" $_t "*) ;; *) _b="$_b $_t" ;; esac
  done
  printf '%s' "$_b"
}
# 「At a glance」 표 첫 열의 라벨 → 언어 디렉터리 집합(정렬). 모르는 라벨은 `?라벨`.
vr_table_langs() { # $1=본문 파일
  awk '/^## At a glance/{t=1; next} t && /^## /{t=0} t && /^\| / && !/^\| SDK \|/ && !/^\|---/' "$1" 2>/dev/null \
    | cut -d'|' -f2 | sed 's/^ *//; s/ *$//' | tr '·' '\n' | sed 's/^ *//; s/ *$//' | grep . \
    | while IFS= read -r _l; do
        case "$_l" in
          Java) echo java ;; Kotlin) echo kotlin ;; Python) echo python ;; Node.js) echo node ;; Go) echo go ;;
          .NET) echo dotnet ;; PHP) echo php ;; Rust) echo rust ;; Ruby) echo ruby ;; *) echo "?$_l" ;;
        esac
      done | sort -u | tr '\n' ' ' | sed 's/ *$//'
}

# ── 라이브 ───────────────────────────────────────────────────────────────────────────────
assert_ok test -f "$GUIDE"
assert_eq "" "$(vr_missing_workflows "$GUIDE" "$ROOT")" "[검증 안내] 안내서가 대는 워크플로가 저장소에 없다 — 서명자 고정(--signer-workflow)이 엉뚱한 것을 가리킨다"
assert_eq "" "$(vr_bad_tags "$GUIDE")" "[검증 안내] 안내서의 태그 토큰이 df_tag 의 접두와 다르다 — --source-ref 가 없는 태그를 가리킨다"
_tree="$(df_tree_langs "$ROOT" | tr ' ' '\n' | grep . | sort -u | tr '\n' ' ' | sed 's/ *$//')"
assert_ok test -n "$_tree"
assert_eq "$_tree" "$(vr_table_langs "$GUIDE")" "[검증 안내] 「At a glance」 표의 SDK 가 트리의 언어와 다르다 — 열 번째 언어를 넣었으면 표와 절을 함께 넣는다"
# 하한 — 안내서가 서명 워크플로를 하나도 안 대면 위 대조가 공허하다(실측: 넷을 댄다).
_nw="$(grep -oE '\.github/workflows/[A-Za-z0-9_.-]+\.yml' "$GUIDE" | sort -u | grep -c . || true)"
assert_ok test "$_nw" -ge 3

# ── 음성 대조 — 위 판정 그대로를 결함 있는 사본에 태운다 ─────────────────────────────────────
FX="$(mktemp -d)"
trap 'rm -rf "$FX"' EXIT
printf 'use `.github/workflows/release.yml` and `.github/workflows/no-such-release.yml`\n' > "$FX/wf.md"
assert_eq " .github/workflows/no-such-release.yml" "$(vr_missing_workflows "$FX/wf.md" "$ROOT")" '[대조] 없는 워크플로를 짚는다(있는 것은 짚지 않는다)'
printf 'refs/tags/kotlin-v<version> and refs/tags/java-v<version> and rust-v<version>\n' > "$FX/tags.md"
assert_eq " java-v<version>" "$(vr_bad_tags "$FX/tags.md")" '[대조] SSOT 에 없는 태그 접두를 짚는다(있는 접두는 짚지 않는다)'
printf '## At a glance\n\n| SDK | x |\n|---|---|\n| Java · Kotlin | a |\n| Zig | b |\n\n## Next\n\n| Ruby | c |\n' > "$FX/table.md"
assert_eq "?Zig java kotlin" "$(vr_table_langs "$FX/table.md")" '[대조] 표 밖의 행은 세지 않고 모르는 라벨은 짚는다'
assert_eq "" "$(vr_table_langs "$FX/absent.md")" '[대조] 파일이 없으면 빈 집합 — 위 라이브 대조에서 트리 집합과 갈려 운다'

assert_report
