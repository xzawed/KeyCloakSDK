#!/usr/bin/env sh
# 게시되는 라이브러리 소스를 건드린 변경은 `CHANGELOG.md` 의 `[Unreleased]` 절을 **자라게**
# 해야 한다.
#
# ⚠️ 왜 기제가 필요한가: 아홉 패키지가 `1.0.0` 으로 게시된 뒤 `main` 에 157 커밋이 쌓였고
# 그중 **31 건이 게시 소스**를 고쳤다(PKCE verifier·토큰 누출, JWKS 바이트 상한, 백채널 SSRF,
# 마스킹 계약 — 대부분 보안 수정이다). 그동안 `[Unreleased]` 는 **0 줄**이었다. 산문 규칙은
# 이미 있었고 지켜지지 않았다 — 착지 시점에 거는 기제가 아니면 다음 릴리스에서 또 이력을
# 복원해야 하고, 그 복원은 커밋 제목을 베껴 쓰는 일이라 반드시 틀린다.
#
# ⚠️ **「CHANGELOG.md 를 건드렸는가」로 묻지 않는다.** 그렇게 물으면 공백 한 줄이나 옛
# `[1.0.0]` 절 수정으로 통과하고, `[Unreleased]` 는 읽히지 않는 소음이 된다. 묻는 것은 하나다 —
# **`[Unreleased]` 절의 내용 줄이 늘었는가.**
#
# ⚠️ 면제는 커밋 메시지의 `[no-changelog: <이유>]` 다. **이유가 비면 면제되지 않는다.** 주석
# 수정·테스트 지원처럼 소비자 행동이 안 바뀌는 소스 변경을 위한 자리이고, 그 판정이 git
# 이력에 남아 다음 릴리스에서 되읽힌다.
#
# ⚠️ 매니페스트(`pom.xml`·`package.json`·`Cargo.toml`…)는 **일부러 조준 밖**이다. dependabot 이
# 그 PR 을 여는데 그것은 CHANGELOG 를 쓸 수 없어, 넣으면 이 게이트가 꺼지는 쪽으로 끝난다.
# 의존성의 SSOT 는 매니페스트이고 문서와의 드리프트는 `check-docs.mjs` 가 이미 본다.
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
ROOT="${CL_ROOT:-$DIR/../..}"

# ── 판정기 둘 (아래 음성 대조가 이 둘을 직접 먹인다) ────────────────────────────────

# 변경 경로 목록(stdin) → **게시되는 라이브러리 소스**만. 테스트·문서·CI·매니페스트는 뺀다.
# go 만 평면 배치라 따로 본다(`admin` 을 서브패키지로 두면 import 순환 — CLAUDE.md §아키텍처).
#
# ⚠️ **매니페스트는 게시 디렉터리 안에 있어도 뺀다.** 실측으로 드러난 자리가 하나 있다 —
# `dotnet/src/Xzawed.Keycloak.Sdk/Xzawed.Keycloak.Sdk.csproj`. dependabot 의 #457 이 정확히
# 그것만 고쳤고, 경로 규칙만 봤다면 이 게이트가 **dependabot PR 마다** 울렸을 것이다(그리고
# dependabot 은 CHANGELOG 를 쓸 수 없으므로 게이트가 꺼지는 쪽으로 끝난다).
# `.gitkeep` 같은 마커도 뺀다. `py.typed` 는 **안 뺀다** — 그것이 사라지면 소비자의 타입 검사가
# 꺼진다(행동 변화다).
_shipped() {
  awk '
    /\.(csproj|props|targets|toml|gemspec|xml|json|kts)$/ { next }
    /(^|\/)(go\.mod|go\.sum|\.gitkeep)$/                  { next }
    /^java\/[^/]+\/src\/main\//    { print; next }
    /^python\/src\/keycloak_sdk\// { print; next }
    /^node\/src\//                 { print; next }
    /^dotnet\/src\//               { print; next }
    /^php\/src\//                  { print; next }
    /^rust\/src\//                 { print; next }
    /^ruby\/lib\//                 { print; next }
    /^kotlin\/src\/main\//         { print; next }
    /^go\/[^/]*\.go$/ && !/_test\.go$/ { print }
  '
}

# CHANGELOG 본문(stdin) → `[Unreleased]` 절의 **내용 줄 수**. 헤딩 자신과 빈 줄은 안 센다.
# 다음 `## ` 에서 멈추므로 옛 릴리스 절을 고쳐도 이 수는 안 움직인다.
_unreleased_lines() {
  awk '/^## \[Unreleased\]/ { f = 1; next } f && /^## / { exit } f && NF { n++ } END { print n + 0 }'
}

# ── 음성 대조 — 판정기가 실제로 가르는가 ──────────────────────────────────────────
# ⚠️ 살아 있는 상태만 단언하면 판정기를 지워도 초록이 된다(등록부 `selftests-with-no-negative-case`).

_FIX_PATHS="$(printf '%s\n' \
  'rust/src/jwks.rs' 'go/jwt.go' 'ruby/lib/keycloak_sdk/client.rb' \
  'go/jwt_test.go' 'node/test/auth.test.ts' 'java/keycloak-sdk-core/src/test/java/A.java' \
  'docs/README.md' 'php/composer.json' '.github/workflows/ci.yml' 'harness/verify.sh')"

assert_eq "rust/src/jwks.rs
go/jwt.go
ruby/lib/keycloak_sdk/client.rb" "$(printf '%s\n' "$_FIX_PATHS" | _shipped)" \
  "[착지게이트] 게시 소스 셋만 골라야 한다 — 테스트·문서·매니페스트·CI 는 조준 밖이다"

assert_eq "0" "$(printf '%s\n' 'go/jwt_test.go' | _shipped | grep -c . || true)" \
  "[착지게이트] go 테스트 파일이 게시 소스로 잡히면 PR 마다 헛경보가 난다"

# ⚠️ 실측 픽스처 — dependabot 의 #457 이 고친 **유일한** 파일이다. 게시 디렉터리 **안**에 있는
# 매니페스트라 경로 규칙만으로는 잡힌다. 여기서 안 빼면 dependabot PR 마다 게이트가 운다.
assert_eq "0" "$(printf '%s\n' 'dotnet/src/Xzawed.Keycloak.Sdk/Xzawed.Keycloak.Sdk.csproj' | _shipped | grep -c . || true)" \
  "[착지게이트] 게시 디렉터리 안의 매니페스트(.csproj)가 잡히면 dependabot PR 이 전부 빨개진다"

assert_eq "0" "$(printf '%s\n' '## [Unreleased]

## [1.0.0] - 2026-08-30
- 뭔가 고침
' | _unreleased_lines)" \
  "[착지게이트] 빈 절은 0 이어야 한다 — 다음 릴리스 절의 줄을 세면 영원히 통과한다"

assert_eq "2" "$(printf '%s\n' '## [Unreleased]

### Security
- 토큰 누출을 막았다

## [1.0.0] - 2026-08-30
- 옛 줄
- 옛 줄
' | _unreleased_lines)" \
  "[착지게이트] 내용 줄 둘을 세야 한다(헤딩 자신과 빈 줄은 빼고)"

assert_eq "0" "$(printf '%s\n' '## [Unreleased]



## [1.0.0] - 2026-08-30
' | _unreleased_lines)" \
  "[착지게이트] 공백만 있는 절은 0 이어야 한다 — 빈 줄 하나로 통과되면 소음이 된다"

# ── 공허 방지 — 글롭이 **언어마다** 실제로 무언가를 잡는가 ──────────────────────────
# ⚠️ 숫자 하한(「N 개 이상」)을 두지 않는다. 파일이 정당하게 줄면 그 수를 다시 맞춰야 하고,
# 그렇게 재보정되는 수는 결국 아무도 안 본다. **언어마다 ≥1** 은 재보정되지 않는 규칙이고,
# 한 언어의 배치가 바뀌어 글롭이 조용히 빗나가는 것(=이 게이트가 그 언어에서 꺼지는 것)을
# 정확히 그 언어에서 잡는다.
_glob_count() { # $1 = pathspec
  ( cd "$ROOT" && git ls-files -- "$1" ) | _shipped | grep -c . || true
}
for _spec in 'java/*/src/main/*' 'python/src/keycloak_sdk/*' 'node/src/*' 'dotnet/src/*' \
             'php/src/*' 'rust/src/*' 'ruby/lib/*' 'kotlin/src/main/*' 'go/*.go'; do
  _n="$(_glob_count "$_spec")"
  assert_eq "yes" "$([ "$_n" -ge 1 ] && echo yes || echo no)" \
    "[착지게이트] '$_spec' 가 게시 소스를 0 개 잡는다 — 그 언어에서 게이트가 꺼져 있다"
done

# ── 살아 있는 검사 — 이 브랜치가 게시 소스를 고쳤다면 [Unreleased] 가 자랐는가 ────────
_head="$(cd "$ROOT" && git rev-parse HEAD)"
_base=''
if [ -n "${GITHUB_BASE_REF:-}" ]; then
  _base="$(cd "$ROOT" && git merge-base "origin/$GITHUB_BASE_REF" HEAD 2>/dev/null || true)"
else
  _base="$(cd "$ROOT" && git merge-base origin/main HEAD 2>/dev/null || true)"
fi

# ⚠️ **CI 에서 기준점을 못 잡으면 실패다**(스킵이 아니다). 얕은 클론이나 못 가져온 ref 로
# 비교 대상이 사라지면 이 게이트는 아무것도 안 보면서 초록을 낸다 — 게이트가 없는 것과
# 구분되지 않는다. 로컬에서는 origin 이 없을 수 있으므로 안내만 하고 넘어간다.
if [ -z "$_base" ]; then
  if [ "${GITHUB_ACTIONS:-}" = 'true' ]; then
    assert_eq "base-resolved" "base-missing" \
      "[착지게이트] CI 인데 비교 기준(merge-base)을 못 잡았다 — fetch-depth 와 origin ref 를 확인하라(조용히 통과시키지 않는다)"
  else
    printf '[착지게이트] origin 기준점이 없어 살아있는 검사는 건너뛴다(판정기 음성대조는 위에서 돌았다)\n'
  fi
elif [ "$_base" = "$_head" ]; then
  printf '[착지게이트] 기준점과 HEAD 가 같다 — 이 범위에 변경이 없다\n'
else
  _changed="$(cd "$ROOT" && git diff --name-only "$_base" "$_head")"
  _ship="$(printf '%s\n' "$_changed" | _shipped)"
  if [ -z "$_ship" ]; then
    printf '[착지게이트] 이 범위는 게시 라이브러리 소스를 건드리지 않았다 — 대상 아님\n'
  else
    # 면제: `[no-changelog: <이유>]` 에서 **이유가 비어 있지 않은 것**만 센다.
    _exempt="$(cd "$ROOT" && git log --format='%B' "$_base..$_head" \
      | sed -n 's/.*\[no-changelog:[[:space:]]*\([^]]*\)\].*/\1/p' \
      | grep -c '[^[:space:]]' || true)"
    _before="$(cd "$ROOT" && git show "$_base:CHANGELOG.md" | _unreleased_lines)"
    _after="$(_unreleased_lines < "$ROOT/CHANGELOG.md")"
    if [ "$_exempt" -gt 0 ]; then
      printf '[착지게이트] `[no-changelog: …]` 면제 %s 건 — 게시 소스 %s 개 변경을 통과시킨다\n' \
        "$_exempt" "$(printf '%s\n' "$_ship" | grep -c .)"
    else
      assert_eq "grew" "$([ "$_after" -gt "$_before" ] && echo grew || echo flat)" \
        "[착지게이트] 게시 소스를 고쳤는데 [Unreleased] 가 안 자랐다($_before → $_after 줄). 소비자에게 무엇이 바뀌는지 한 줄 적거나, 안 바뀐다면 커밋에 '[no-changelog: 이유]' 를 남겨라. 대상: $(printf '%s\n' "$_ship" | tr '\n' ' ')"
    fi
  fi
fi

assert_report
