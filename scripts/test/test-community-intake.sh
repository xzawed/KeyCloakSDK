#!/usr/bin/env sh
# 소비자 유입 표면의 자가테스트 — 이슈 양식 · PR 템플릿 · CODEOWNERS · 행동강령(등록부 consumer-intake-surface-absent).
#
# 겨누는 것: 아홉 레지스트리에 게시했는데 유입 표면이 통째로 없었다(GitHub community profile 실측 2026-11-15:
# health 71 · code_of_conduct · issue_template · pull_request_template 셋 다 null). 파일이 있어도 썩는 자리는 하나다 —
# **이슈 양식의 SDK 언어 목록**은 손 목록이라, 열 번째 언어가 들어오면 그 언어로는 버그를 낼 수 없다. 그래서 그 목록을
# 트리에서 파생한 언어 집합과 대조한다(열 번째 언어가 오면 여기가 먼저 빨개진다).
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
. "$DIR/../lib/deploy-facts.sh"
ROOT="$(cd "$DIR/../.." && pwd)"
FORMS="$ROOT/.github/ISSUE_TEMPLATE"

# ── 판정 — 라이브 단언과 아래 음성 대조가 **같은 함수**를 부른다 ─────────────────────────────────
# 양식 하나 → 그 `id: sdk` 드롭다운의 선택지(줄마다 하나). 다른 요소의 선택지는 섞지 않는다.
ci_options() { # $1=양식 파일
  awk '
    /^[[:space:]]*- type:/ { in_sdk = 0; in_opts = 0 }
    /^[[:space:]]*id:[[:space:]]*sdk[[:space:]]*$/ { in_sdk = 1 }
    in_sdk && /^[[:space:]]*options:[[:space:]]*$/ { in_opts = 1; match($0, /^[[:space:]]*/); ind = RLENGTH; next }
    in_opts {
      match($0, /^[[:space:]]*/)
      if (RLENGTH <= ind || $0 !~ /^[[:space:]]*- /) { in_opts = 0; next }
      s = $0; sub(/^[[:space:]]*- /, "", s); sub(/[[:space:]]+$/, "", s); print s
    }' "$1" 2>/dev/null || true
  # ⚠️ `|| true` 를 빼지 말 것 — 파일을 못 열면 awk 가 2 로 끝나고 `set -e` 가 명령 치환을 빈 값으로 끊어, 아래 판정이
  # 「차이 없음」 으로 통과했다(실측 2026-11-15: 양식이 없는데 언어 대조가 초록). 빈 선택지는 NO-OPTIONS 로 운다.
}
# 선택지 라벨 → 언어 디렉터리. 모르는 라벨은 그대로 `?라벨` — 집합 대조가 그것을 짚는다.
ci_label_dir() {
  case "$1" in
    Java) echo java ;; Kotlin) echo kotlin ;; Python) echo python ;; 'Node.js / TypeScript') echo node ;;
    Go) echo go ;; 'C# / .NET') echo dotnet ;; PHP) echo php ;; Rust) echo rust ;; Ruby) echo ruby ;;
    *) echo "?$1" ;;
  esac
}
# 양식의 언어 집합 판정 — 트리 집합과 같으면 빈 출력, 다르면 「빠진 · 남는 · 겹친」 을 말한다. $1=양식 $2=트리 집합(공백)
ci_lang_gap() {
  _opts="$(ci_options "$1")"
  [ -n "$_opts" ] || { printf 'NO-OPTIONS'; return 0; }
  _dirs="$(printf '%s\n' "$_opts" | while IFS= read -r _o; do ci_label_dir "$_o"; done)"
  _dup="$(printf '%s\n' "$_dirs" | sort | uniq -d | tr '\n' ' ')"
  _have="$(printf '%s\n' "$_dirs" | sort -u | tr '\n' ' ')"
  _want="$(printf '%s\n' $2 | sort -u | tr '\n' ' ')"
  _miss=''; for _w in $_want; do case " $_have " in *" $_w "*) ;; *) _miss="$_miss $_w" ;; esac; done
  _extra=''; for _h in $_have; do case " $_want " in *" $_h "*) ;; *) _extra="$_extra $_h" ;; esac; done
  [ -z "$_miss$_extra$_dup" ] || printf 'missing:%s extra:%s dup: %s' "$_miss" "$_extra" "$_dup"
}
# 설정 판정 — 빈 이슈를 막고, 취약점은 공개 이슈가 아니라 비공개 신고로 보낸다.
ci_config_gap() { # $1=config.yml
  _g=''
  grep -qE '^blank_issues_enabled:[[:space:]]*false[[:space:]]*$' "$1" 2>/dev/null || _g="$_g blank-issues"
  grep -qE '^[[:space:]]*url:[[:space:]]*https://github\.com/[^/]+/[^/]+/security/advisories/new[[:space:]]*$' "$1" 2>/dev/null \
    || _g="$_g no-private-report-link"
  printf '%s' "$_g"
}
# 버그 양식의 비밀 확인란 — 「토큰 · 클라이언트 시크릿 · 비밀번호를 지웠다」 를 **필수** 확인란으로 받는가.
ci_secret_ack() { # $1=양식 → ok · MISSING
  awk '
    /^[[:space:]]*- type:/ { box = ($0 ~ /checkboxes/) }
    box && /secrets/ { seen = 1 }
    box && seen && /required:[[:space:]]*true/ { ok = 1 }
    END { print (ok ? "ok" : "MISSING") }' "$1" 2>/dev/null
}
# CODEOWNERS 의 기본 소유자 — `*` 줄에 소유자가 하나 이상.
ci_default_owner() { grep -qE '^\*[[:space:]]+@[A-Za-z0-9][A-Za-z0-9-]*' "$1" 2>/dev/null && echo ok || echo MISSING; }

# ── 1. 파일이 있다 — GitHub 가 그 경로에서 읽는다 ─────────────────────────────────────────────
for _f in .github/ISSUE_TEMPLATE/bug_report.yml .github/ISSUE_TEMPLATE/feature_request.yml .github/ISSUE_TEMPLATE/config.yml \
  .github/PULL_REQUEST_TEMPLATE.md .github/CODEOWNERS CODE_OF_CONDUCT.md; do
  assert_ok test -f "$ROOT/$_f"
done

# ── 2. 양식의 언어 목록 = 트리의 언어 ──────────────────────────────────────────────────────────
_tree="$(df_tree_langs "$ROOT")"
assert_ok test -n "$_tree"
for _form in bug_report.yml feature_request.yml; do
  assert_eq "" "$(ci_lang_gap "$FORMS/$_form" "$_tree")" \
    "[유입] $_form 의 SDK 언어 선택지가 트리의 언어와 다르다 — 열 번째 언어를 넣었으면 양식에도 넣는다"
done

# ── 3. 설정 · 비밀 확인란 · 기본 소유자 ────────────────────────────────────────────────────────
assert_eq "" "$(ci_config_gap "$FORMS/config.yml")" "[유입] config.yml 이 빈 이슈를 막지 않거나 비공개 취약점 신고로 보내지 않는다"
assert_eq "ok" "$(ci_secret_ack "$FORMS/bug_report.yml")" "[유입] 버그 양식에 토큰 · 시크릿 · 비밀번호를 지웠다는 필수 확인란이 없다"
assert_eq "ok" "$(ci_default_owner "$ROOT/.github/CODEOWNERS")" "[유입] CODEOWNERS 에 기본(*) 소유자가 없다"

# ── 4. 음성 대조 — 위 판정 그대로를 결함 있는 픽스처에 태운다 ───────────────────────────────────
FX="$(mktemp -d)"
trap 'rm -rf "$FX"' EXIT
form() { # $1=파일 · 나머지=선택지
  _f="$1"; shift
  { printf 'body:\n  - type: dropdown\n    id: sdk\n    attributes:\n      label: SDK\n      options:\n'
    for _o in "$@"; do printf '        - %s\n' "$_o"; done
    printf '  - type: dropdown\n    id: other\n    attributes:\n      label: Other\n      options:\n        - Java\n'; } > "$_f"
}
form "$FX/ok.yml" Java Python
assert_eq "" "$(ci_lang_gap "$FX/ok.yml" 'java python')" '[대조] 같은 집합이면 빈 출력'
form "$FX/missing.yml" Java
assert_contains "$(ci_lang_gap "$FX/missing.yml" 'java python')" 'missing: python' '[대조] 빠진 언어를 짚는다'
form "$FX/extra.yml" Java Python Zig
assert_contains "$(ci_lang_gap "$FX/extra.yml" 'java python')" 'extra: ?Zig' '[대조] 모르는 선택지를 짚는다'
form "$FX/dup.yml" Java Java Python
assert_contains "$(ci_lang_gap "$FX/dup.yml" 'java python')" 'dup: java' '[대조] 겹친 선택지를 짚는다'
printf 'body:\n  - type: input\n    id: sdk\n' > "$FX/none.yml"
assert_eq 'NO-OPTIONS' "$(ci_lang_gap "$FX/none.yml" 'java')" '[대조] 선택지가 없으면 NO-OPTIONS — 다른 요소의 선택지를 빌려 오지 않는다'
assert_eq 'NO-OPTIONS' "$(ci_lang_gap "$FX/absent.yml" 'java')" '[대조] 양식 파일이 없으면 NO-OPTIONS — 읽기 실패를 「차이 없음」 으로 넘기지 않는다'
printf 'blank_issues_enabled: true\ncontact_links:\n  - name: x\n    url: https://example.com/\n' > "$FX/config.yml"
assert_contains "$(ci_config_gap "$FX/config.yml")" 'blank-issues' '[대조] 빈 이슈를 허용하면 짚는다'
assert_contains "$(ci_config_gap "$FX/config.yml")" 'no-private-report-link' '[대조] 비공개 신고 링크가 없으면 짚는다'
printf 'body:\n  - type: checkboxes\n    attributes:\n      options:\n        - label: I removed tokens, client secrets and passwords\n          required: false\n' > "$FX/ack.yml"
assert_eq 'MISSING' "$(ci_secret_ack "$FX/ack.yml")" '[대조] 확인란이 필수가 아니면 MISSING'
printf 'body:\n  - type: textarea\n    attributes:\n      label: secrets\n    validations:\n      required: true\n' > "$FX/ack2.yml"
assert_eq 'MISSING' "$(ci_secret_ack "$FX/ack2.yml")" '[대조] 확인란이 아닌 요소의 required 는 세지 않는다'
printf 'docs/ @someone\n' > "$FX/CODEOWNERS"
assert_eq 'MISSING' "$(ci_default_owner "$FX/CODEOWNERS")" '[대조] 기본(*) 소유자가 없으면 MISSING'

assert_report
