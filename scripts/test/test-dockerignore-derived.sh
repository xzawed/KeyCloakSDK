#!/usr/bin/env sh
# `.dockerignore` 가 **손 목록으로 썩지 않게** 한다.
#
# ⚠️ **이 가드가 있는 이유는 실측이다**(2026-09-15). 아홉째 언어(kotlin)가 들어오면서 Gradle
# 산출물(`build/`·`.gradle/`)과 mypy 캐시가 `.dockerignore` 에 한 번도 반영되지 않아,
# 하네스 Docker 컨텍스트 **70.8MB 중 34MB(48%)가 빌드·캐시 산출물**이었다. 고친 뒤 **5.2MB**.
#
# **오라클은 파생이다**: 추적된 모든 `.gitignore` 가 「이건 산출물이다」라고 이미 말한다.
# 그 디렉터리 패턴을 전부 뽑아, `.dockerignore` 가 덮거나 **아래 면제표에 이유와 함께** 있어야
# 한다. 열 번째 언어가 `.gitignore` 를 들고 오면 여기서 먼저 빨개진다.
#
# ⚠️ **트리에 실재하는 디렉터리로 파생하지 않는다** — CI 는 새 체크아웃이라 그것들이 없고,
# 그러면 이 가드가 **CI 에서만 조용히 공허해진다**(이 저장소가 반복해 겪은 부류다).
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
ROOT="${DI_ROOT:-$DIR/../..}"
DOCKERIGNORE="${DI_FILE:-$ROOT/.dockerignore}"

# ── 면제표 ───────────────────────────────────────────────────────────────────
# 각 줄은 `패턴<TAB>이유`. **이유 없이 줄을 늘리지 말 것** — 면제는 판정이고, 판정에는 근거가 있다.
EXEMPT="$(cat <<'EOF'
.settings/	IDE(Eclipse) 메타 — 컨텍스트에 들어와도 바이트가 무시할 만하고, 이름이 흔해 넓게 막으면 오탐이 난다
.scamanager/	에이전트 도구 스크래치 — 이 리포의 빌드와 무관하고 존재하지 않는 기계가 많다
.playwright-mcp/	같은 부류(에이전트 도구 스크래치)
.vite/	node 개발 서버 캐시 — 이 리포는 vite 를 안 쓴다(다른 `.gitignore` 에서 상속된 줄)
.bundle/	`**/vendor/` 가 ruby 의존 트리를 이미 덮고, `.bundle/` 은 설정 몇 줄이라 바이트가 없다
vendor/bundle/	`**/vendor/` 가 상위에서 이미 덮는다
out/	`harness/install/publish/out/` 로 **경로 고정** 제외했다 — 이름만으로 넓게 막으면 정당한 `out/` 을 지울 수 있다
status/	하네스 **런타임 마운트** 경로다(컨테이너가 쓰는 곳) — 빌드 컨텍스트에서 지우는 것과 무관하고, 넓게 막으면 의도가 흐려진다
signals/	같은 부류(하네스 런타임)
ruby-repo/	하네스 런타임 레지스트리 경로 — 위와 같다
dist-base/	하네스 런타임 산출 경로 — 위와 같다
temp/	이름이 너무 흔하다 — 넓게 막으면 정당한 자리를 지울 수 있고, 실측 바이트가 0 이다
aeout/	오타로 보이는 유산 항목 — 실재하지 않는다(지우는 것은 이 가드의 일이 아니다)
EOF
)"

# ── 파생 ─────────────────────────────────────────────────────────────────────
# 추적된 모든 `.gitignore` 에서 **디렉터리 패턴**(끝이 `/`)만 뽑는다. 부정(`!`)·주석은 뺀다.
PATTERNS="$(cd "$ROOT" && for f in $(git ls-files '.gitignore' '*/.gitignore'); do
  sed -n 's/[[:space:]]*$//; /^[^#!].*\/$/p' "$f"
done | sed 's|^[*][*]/||; s|^/||' | sort -u)"

_n="$(printf '%s\n' "$PATTERNS" | grep -c . || true)"
# 공허 하한 — 파생이 깨지면 「덮을 것이 없어서」 초록이 된다. 실측 43(2026-09-15).
_enough=1; [ "$_n" -ge 30 ] && _enough=0
assert_eq "ok" "$(ok_if "$_enough" "$_n")" \
  "[.dockerignore 파생] .gitignore 에서 디렉터리 패턴을 30개 미만 뽑았다($_n) — 파생이 깨졌나?"

# ── 판정 셋 — 라이브 단언과 아래 음성 대조가 **같은 함수**를 부른다. ────────────────────────
di_covers() { # $1=패턴이름(끝에 /) $2=.dockerignore → 덮으면 0
  _c_name="$1"
  grep -qxF -- "**/$_c_name" "$2" && return 0
  grep -qxF -- "$_c_name" "$2" && return 0
  return 1
}
di_exempt() { # $1=패턴이름 $2=면제표 → 면제표에 있으면 0
  printf '%s\n' "$2" | cut -f1 | grep -qxF -- "$1"
}
di_missing() { # $1=패턴 $2=.dockerignore $3=면제표 → 덮이지도 면제되지도 않은 패턴
  _dm=''
  for p in $1; do
    # 대소문자 변형(`[Bb]in/`)은 소문자 형태가 덮으면 같이 덮인다.
    case "$p" in '['*) continue ;; esac
    di_covers "$p" "$2" && continue
    di_exempt "$p" "$3" && continue
    _dm="$_dm $p"
  done
  printf '%s' "$_dm"
}
# ⚠️ **면제표가 썩지 않게** — 면제는 파생 집합 안에 있어야 한다(없어진 패턴을 면제한 채 두면
# 표가 거짓말이 된다). $1=패턴 $2=면제표 → 파생 집합에 없는 면제
di_stale() {
  printf '%s\n' "$2" | cut -f1 | while IFS= read -r e; do
    [ -n "$e" ] || continue
    printf '%s\n' "$1" | grep -qxF -- "$e" || printf '%s\n' "$e"
  done | tr '\n' ' ' | sed 's/[[:space:]]*$//'
}
# ⚠️ **면제에는 이유가 있어야 한다** — 탭 뒤가 비면 그것은 판정이 아니라 침묵이다. $1=면제표
di_noreason() { printf '%s\n' "$1" | awk -F'\t' 'NF<2 || $2=="" {print $1}' | tr '\n' ' ' | sed 's/[[:space:]]*$//'; }

_missing="$(di_missing "$PATTERNS" "$DOCKERIGNORE" "$EXEMPT")"
assert_eq "" "$_missing" \
  "[.dockerignore 파생] .gitignore 가 산출물이라 말하는데 .dockerignore 가 안 덮고 면제도 아니다 —$_missing"

_stale="$(di_stale "$PATTERNS" "$EXEMPT")"
assert_eq "" "$_stale" \
  "[.dockerignore 파생] 면제표에 **파생 집합에 없는** 패턴이 있다 — 표가 낡았다: $_stale"

_noreason="$(di_noreason "$EXEMPT")"
assert_eq "" "$_noreason" "[.dockerignore 파생] 이유 없는 면제가 있다: $_noreason"

# ── 음성 대조 — 위 판정 그대로를 결함 있는 입력에 태운다. ─────────────────────────────────────
# 라이브는 늘 「없다」라 판정이 깨져도 초록이었다(실측 2026-11-14 SILENT 셋).
# ⚠️ 임시파일은 반드시 리포 **밖**에 쓴다 — 루트에 쓰면 그 파일이 커밋될 수 있다
# (이번 세션에 `sh.exe.stackdump` 로 실제로 겪었다).
_di_fx="$(mktemp -d)"
trap 'rm -rf "$_di_fx"' EXIT
printf '%s\n' '**/build/' 'dist/' > "$_di_fx/dockerignore"
_fx_pat="$(printf '%s\n' build/ cache/ dist/ temp/)"
assert_eq " cache/" "$(di_missing "$_fx_pat" "$_di_fx/dockerignore" "$(printf 'temp/\t이름이 흔하다')")" \
  "[.dockerignore 파생·음성대조] .dockerignore 가 안 덮는 패턴을 못 잡거나, 덮은 것(**/ · 그대로) · 면제를 빠뜨렸다고 한다"
assert_eq "gone/" "$(di_stale "$_fx_pat" "$(printf 'temp/\t이유\ngone/\t이유')")" \
  "[.dockerignore 파생·음성대조] 파생 집합에 없는 면제를 낡았다고 못 한다"
assert_eq "cache/ temp/" "$(di_noreason "$(printf 'cache/\ntemp/\t\ndist/\t이유')")" \
  "[.dockerignore 파생·음성대조] 이유 없는 면제(탭 없음 · 빈 이유)를 못 잡는다"

assert_report
