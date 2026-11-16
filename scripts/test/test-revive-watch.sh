#!/usr/bin/env sh
# revive-watch.mjs 자가테스트 — 기각 레지스트리의 행마다 탐침 또는 수동 사유가 있는가(분할), 그리고 탐침마다 그 되살릴 조건이
# 오면 그 행의 이름으로 exit 1 인가(등록부 revive-conditions-unmeasured).
#
# 트리 탐침은 임시 git 저장소 픽스처에서 하나씩 뒤집는다(열 번째 언어는 df_tree_langs 가 git 추적 매니페스트를 보므로 저장소여야
# 한다). gh 탐침은 net-stub 의 STUB_GH 로 가짜 gh 를 대고(네트워크 없음 · CI 와 같은 argv), mypy 탐침은 --mypy-output 으로 잰다.
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
. "$DIR/net-stub.sh"
ROOT="$(cd "$DIR/../.." && pwd)"
RW="$ROOT/scripts/revive-watch.mjs"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# 가짜 gh 가 바깥 저장소 이름에 기대지 않게 — CI 는 GITHUB_REPOSITORY 를 준다(그때 -R 이 붙어도 가짜는 무시한다).
unset GITHUB_REPOSITORY 2>/dev/null || true

# ── 진짜 트리 ─────────────────────────────────────────────────────────────────────────────────────
_rc=0
_o="$(node "$RW" --partition "$ROOT" 2>&1)" || _rc=$?
assert_eq "0" "$_rc" "[되살림] 진짜 레지스트리의 분할이 어긋났다: $_o"
_n="$(printf '%s\n' "$_o" | sed -n 's/^기각 행 \([0-9]*\) .*/\1/p')"
# 공허 하한 — 표 파서가 깨져 행이 줄면 분할이 「대상이 없어서」 통과한다. ⚠️ 세어서 박는다: 실측 25(2026-11-16).
assert_eq "ok" "$(ok_if "$([ "${_n:-0}" -ge 25 ] && echo 0 || echo 1)" "${_n:-0}")" "[되살림] 기각 행이 25 미만이다(${_n:-?}) — 표 파서가 깨졌나?"
_rc=0
_o="$(node "$RW" --tree "$ROOT" 2>&1)" || _rc=$?
assert_eq "0" "$_rc" "[되살림] 진짜 트리에서 트리 탐침이 되살릴 조건을 말한다 — 그 행을 재판정하라: $_o"

# ── 픽스처 저장소 ─────────────────────────────────────────────────────────────────────────────────
F="$TMP/f"
fresh() {
  rm -rf "$F"
  mkdir -p "$F"
  for p in docs/governance/rejected.md .github/rulesets/main.json sonar-project.properties java/pom.xml dotnet/Directory.Build.props; do
    mkdir -p "$F/$(dirname "$p")"
    cp "$ROOT/$p" "$F/$p"
  done
  # 아홉 언어의 매니페스트 자리(빈 파일) — 진짜 트리가 df_tree_langs 에 주는 그 경로들.
  . "$ROOT/scripts/lib/deploy-facts.sh"
  ( cd "$ROOT" && git ls-files ) | grep -E "^[^/]+/$DF_MANIFEST" | while IFS= read -r m; do
    mkdir -p "$F/$(dirname "$m")"
    [ -f "$F/$m" ] || : > "$F/$m"
  done
  git -C "$F" init -q
  git -C "$F" add -A
}
flip() { # name expected-row-substring
  _frc=0
  _fo="$(node "$RW" --tree "$F" 2>&1)" || _frc=$?
  assert_eq "1" "$_frc" "[되살림·트리] $1 — 되살릴 조건이 왔는데 exit 1 이 아니다: $_fo"
  assert_contains "$_fo" "되살릴 조건이 왔다 — $2" "[되살림·트리] $1 — 그 행의 이름으로 말하지 않는다"
}
fresh
_rc=0
_o="$(node "$RW" --tree "$F" 2>&1)" || _rc=$?
assert_eq "0" "$_rc" "[되살림] 손대지 않은 픽스처가 되살릴 조건을 말한다 — 아래 뒤집기가 공허하다: $_o"

fresh; sed 's/"bypass_actors": *\[\]/"bypass_actors": [{"actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "always"}]/' "$ROOT/.github/rulesets/main.json" > "$F/.github/rulesets/main.json"
flip bypass '`repo-config`를 required 체크로'
fresh; grep -v '^sonar\.java\.binaries=' "$ROOT/sonar-project.properties" > "$F/sonar-project.properties"
flip java-binaries 'java 린트·정적분석 게이트'
# examples 뒤에 모듈 하나 — examples 가 더는 마지막이 아니다.
fresh; awk '/<\/modules>/ && !done { print "    <module>keycloak-sdk-extra</module>"; done = 1 } { print }' "$ROOT/java/pom.xml" > "$F/java/pom.xml"
flip modules-order 'examples 모듈에 `<skipPublishing>`'
fresh; sed 's#<TargetFrameworks>[^<]*</TargetFrameworks>#<TargetFrameworks>net8.0;net10.0;net11.0</TargetFrameworks>#' "$ROOT/dotnet/Directory.Build.props" > "$F/dotnet/Directory.Build.props"
flip target-frameworks '`global.json`으로 .NET SDK 밴드 고정'
fresh; mkdir -p "$F/zig"; : > "$F/zig/package.json"; git -C "$F" add zig/package.json
flip tenth-language 'capability matrix **L열** 가드'
flip tenth-language-deploy '`DEPLOY.md` 3분할'
# 같은 사실의 다른 표기는 조건이 아니다 — 공백 있는 속성 · 순서와 공백만 다른 대상 집합(Grok 레그).
same() { # name
  _src=0
  _so="$(node "$RW" --tree "$F" 2>&1)" || _src=$?
  assert_eq "0" "$_src" "[되살림·트리] $1 — 같은 사실의 다른 표기를 되살릴 조건으로 센다: $_so"
}
fresh; sed 's/^sonar\.java\.binaries=/sonar.java.binaries = /' "$ROOT/sonar-project.properties" > "$F/sonar-project.properties"
same binaries-spaced
fresh; sed 's#<TargetFrameworks>[^<]*</TargetFrameworks>#<TargetFrameworks> net10.0; net8.0 </TargetFrameworks>#' "$ROOT/dotnet/Directory.Build.props" > "$F/dotnet/Directory.Build.props"
same frameworks-reordered
# 배열이 아니면 못 잰다 — 조용히 「안 옴」이 되지 않는다(--require-all 이면 exit 2).
fresh; sed 's/"bypass_actors": *\[\]/"bypass_actors": {}/' "$ROOT/.github/rulesets/main.json" > "$F/.github/rulesets/main.json"
_rc=0
_o="$(node "$RW" --tree --require-all "$F" 2>&1)" || _rc=$?
assert_eq "2" "$_rc" "[되살림·트리] bypass_actors 가 배열이 아닌데 조용히 통과한다"
assert_contains "$_o" "bypass_actors 가 배열이 아니다" "[되살림·트리] 못 잰 이유를 말하지 않는다"

# ── 분할 ─────────────────────────────────────────────────────────────────────────────────────────
part() { # name expected-message
  _prc=0
  _po="$(node "$RW" --partition "$F" 2>&1)" || _prc=$?
  assert_eq "2" "$_prc" "[되살림·분할] $1 — 어긋난 분류가 통과한다"
  assert_contains "$_po" "$2" "[되살림·분할] $1 — 어긋남을 그 이름으로 말하지 않는다"
}
fresh; printf '%s\n' '| 새 기각 | 한 줄 | 조건 |' >> "$F/docs/governance/rejected.md"
part new-row "분류 없는 행: 새 기각"
fresh; grep -v '^| KGP 2.4.20 |' "$ROOT/docs/governance/rejected.md" > "$F/docs/governance/rejected.md"
part removed-row "표에 없는 분류(유령): KGP 2.4.20"
fresh; grep -v '^| ' "$ROOT/docs/governance/rejected.md" > "$F/docs/governance/rejected.md"
part zero-rows "기각 행을 0 개 읽었다"

# ── mypy 탐침 — SDK 이름을 가리키는 call-arg · attr-defined 만 센다 ─────────────────────────────────
printf '%s\n' 'tests/unit/test_wire.py:453: error: "BaseAdapter" has no attribute "proxy_manager_for"  [attr-defined]' \
  'tests/unit/test_x.py:9: error: Unsupported target for indexed assignment  [index]' > "$TMP/mypy-noise.txt"
printf '%s\n' 'tests/unit/test_auth.py:12: error: "AuthClient" has no attribute "validate_token"  [attr-defined]' > "$TMP/mypy-sdk.txt"
printf '%s\n' 'tests/unit/test_cfg.py:3: error: Unexpected keyword argument "realm_name" for "KeycloakConfig"  [call-arg]' > "$TMP/mypy-callarg.txt"
# gh 는 가짜로 — 빈 목록을 답한다(gh 탐침은 아래에서 따로 잰다).
cat > "$TMP/gh.mjs" <<'EOF'
const a = process.argv.slice(2)
const env = (k) => process.env[k] ?? ''
const has = (s) => a.includes(s)
const wf = a[a.indexOf('--workflow') + 1]
if (a[0] === 'run' && a[1] === 'list') {
  const key = { 'sonarcloud.yml': 'FAKE_SONAR', 'rust-ci.yml': 'FAKE_RUST', 'dispatch-release.yml': 'FAKE_DISPATCH' }[wf]
  process.stdout.write(env(key) || '[]')
} else if (a[0] === 'api') {
  process.stdout.write(JSON.stringify({ login: /\/commits\/bot/.test(a[1]) ? 'dependabot[bot]' : 'someone' }))
} else if (a[0] === 'run' && a[1] === 'view' && has('--log-failed')) {
  process.stdout.write(a[2] === '9001' ? 'ERROR Not authorized or project not found\n' : 'ERROR CE Task finished abnormally\n')
} else if (a[0] === 'run' && a[1] === 'view' && ['7', '8'].includes(a[2])) {
  // dispatch-release — 7 은 대기 중 취소(스텝 없음), 8 은 도는 중 사람이 취소(스텝 있음)
  process.stdout.write(JSON.stringify({ jobs: [{ name: 'dispatch', conclusion: 'cancelled', steps: a[2] === '8' ? [{ name: 'Set up job' }] : [] }] }))
} else if (a[0] === 'run' && a[1] === 'view') {
  const only = env('FAKE_STABLE_ONLY').split(',').includes(a[2])
  process.stdout.write(JSON.stringify({ jobs: [
    { name: 'Build + fmt + clippy + test (Rust stable)', conclusion: 'failure' },
    { name: 'Build + fmt + clippy + test (Rust 1.88)', conclusion: only ? 'success' : 'failure' },
  ] }))
} else {
  process.stderr.write(`fake gh: unexpected ${a.join(' ')}\n`)
  process.exit(1)
}
EOF
rw() { NODE_OPTIONS="$NET_STUB_IMPORT" STUB_GH="$TMP/gh.mjs" node "$RW" "$@" "$ROOT"; }
_rc=0; _o="$(rw --mypy-output "$TMP/mypy-noise.txt" 2>&1)" || _rc=$?
assert_eq "0" "$_rc" "[되살림·mypy] 서드파티 좁힘(BaseAdapter)과 다른 코드를 SDK 드리프트로 센다: $_o"
_rc=0; _o="$(rw --mypy-output "$TMP/mypy-sdk.txt" 2>&1)" || _rc=$?
assert_eq "1" "$_rc" "[되살림·mypy] SDK 클래스의 attr-defined 를 못 본다"
assert_contains "$_o" "되살릴 조건이 왔다 — mypy를 \`python/tests\`로 확장" "[되살림·mypy] 그 행의 이름으로 말하지 않는다"
_rc=0; _o="$(rw --mypy-output "$TMP/mypy-callarg.txt" 2>&1)" || _rc=$?
assert_eq "1" "$_rc" "[되살림·mypy] SDK 클래스의 call-arg 를 못 본다"
# REVIVE_PY 없이 mypy 를 못 재면 --require-all 은 exit 2 — 조용히 건너뛰지 않는다. 없으면 「못 잼」만 적고 0 이다.
_rc=0; _o="$(REVIVE_PY='' rw --require-all 2>&1)" || _rc=$?
assert_eq "2" "$_rc" "[되살림] --require-all 인데 못 잰 탐침을 통과시킨다"
assert_contains "$_o" "못 잼  [mypy]" "[되살림] 못 잰 탐침을 이름으로 말하지 않는다"
_rc=0; _o="$(REVIVE_PY='' rw 2>&1)" || _rc=$?
assert_eq "0" "$_rc" "[되살림] --require-all 없이 못 잰 탐침이 실패가 됐다"

# ── gh 탐침 ───────────────────────────────────────────────────────────────────────────────────────
ghflip() { # name expected-row
  _grc=0
  _go="$(rw --mypy-output "$TMP/mypy-noise.txt" 2>&1)" || _grc=$?
  assert_eq "1" "$_grc" "[되살림·gh] $1 — 되살릴 조건이 왔는데 exit 1 이 아니다: $_go"
  assert_contains "$_go" "되살릴 조건이 왔다 — $2" "[되살림·gh] $1 — 그 행의 이름으로 말하지 않는다"
}
ghok() { # name
  _grc=0
  _go="$(rw --mypy-output "$TMP/mypy-noise.txt" 2>&1)" || _grc=$?
  assert_eq "0" "$_grc" "[되살림·gh] $1 — 그 부류가 아닌 것을 되살릴 조건으로 센다: $_go"
}
FAKE_DISPATCH='[{"databaseId":7,"createdAt":"2026-12-01T00:00:00Z"}]' ghflip cancelled-dispatch '릴리스 순차머지 가드'
FAKE_DISPATCH='[{"databaseId":7,"createdAt":"2026-08-01T00:00:00Z"}]' ghok cancelled-before-judgment
FAKE_DISPATCH='[{"databaseId":8,"createdAt":"2026-12-01T00:00:00Z"}]' ghok cancelled-by-a-human
FAKE_RUST='[{"databaseId":1,"createdAt":"2026-12-01T00:00:00Z","headBranch":"a"},{"databaseId":2,"createdAt":"2026-12-02T00:00:00Z","headBranch":"b"}]' \
  FAKE_STABLE_ONLY='1,2' ghflip stable-only-two-branches 'Rust `stable` 레그의 clippy 고정'
FAKE_RUST='[{"databaseId":1,"createdAt":"2026-12-01T00:00:00Z","headBranch":"a"},{"databaseId":2,"createdAt":"2026-12-02T00:00:00Z","headBranch":"a"}]' \
  FAKE_STABLE_ONLY='1,2' ghok stable-only-one-branch
FAKE_SONAR='[{"databaseId":9001,"headSha":"bot1","createdAt":"2026-12-01T00:00:00Z"}]' ghflip sonar-no-token '`SONAR_TOKEN` 을 Dependabot 시크릿에 복제'
FAKE_SONAR='[{"databaseId":9002,"headSha":"bot2","createdAt":"2026-12-01T00:00:00Z"},{"databaseId":9001,"headSha":"man1","createdAt":"2026-12-01T00:00:00Z"}]' \
  ghok sonar-other-failure

assert_report
