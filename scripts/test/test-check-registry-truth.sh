#!/usr/bin/env sh
# `check-registry-truth.mjs` 자가테스트 — 게시 SSOT ↔ 살아 있는 레지스트리.
#
# ⚠️ **네트워크를 쓰지 않는다.** 가드의 `--fixtures` 가 URL 을 `<host>/<path>` 파일로 읽으므로
# 아홉 레지스트리의 응답을 트리로 흉내 낸다. 네트워크 자체는 `published-floor.yml` 이 지나간다.
#
# ⚠️ 무게는 「통과한다」가 아니라 판정 행렬의 **각 칸이 제 종료코드를 내는가**에 있다 — 특히
# (1) SSOT 가 레지스트리를 정당하게 앞서는 유예 구간이 빨갛지 않은가, (2) 판정 불가가 0 이
# 아닌가, (3) Maven metadata 가 늦어도 pom 으로 LIVE 를 내는가(2026-09-24 실측 그 모양).
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
GUARD="$DIR/../check-registry-truth.mjs"
FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT
NOW=2000000000
H=3600

# mkrepo <dir> <lang> <ver> <ssot-커밋 나이(h)> [<태그 나이(h)>]
# 좌표·태그 포맷은 실제 SSOT 와 같은 모양으로 적는다 — 어댑터가 받는 입력이 같아야 한다.
mkrepo() {
  d="$1"; l="$2"; v="$3"; sa="$4"; ta="${5:-}"
  mkdir -p "$d/scripts/lib"
  cat > "$d/scripts/lib/deploy-facts.sh" <<EOF
DEPLOY_LANGS='$l'
df_published_version() { case "\$1" in $l) echo "$v" ;; *) echo "" ;; esac; }
df_coordinate() { case "\$1" in
  python) echo "keycloak-sdk" ;; node) echo "@xzawed/keycloak-sdk" ;; dotnet) echo "Xzawed.Keycloak.Sdk" ;;
  rust) echo "keycloak-sdk" ;; ruby) echo "keycloak-sdk" ;; php) echo "xzawed/keycloak-sdk" ;;
  go) echo "github.com/xzawed/KeyCloakSDK/go" ;; java) echo "io.github.xzawed:keycloak-sdk" ;;
  kotlin) echo "io.github.xzawed:keycloak-sdk-kotlin" ;; esac; }
df_tag() { case "\$1" in
  python) echo "py-v%s" ;; java) echo "v%s" ;; go) echo "go/v%s" ;; *) echo "\$1-v%s" ;; esac; }
EOF
  git -C "$d" init -q 2>/dev/null
  git -C "$d" add -A
  GIT_COMMITTER_DATE="@$((NOW - sa * H)) +0000" GIT_AUTHOR_DATE="@$((NOW - sa * H)) +0000" \
    git -C "$d" -c user.email=t@t -c user.name=t commit -qm f
  if [ -n "$ta" ]; then
    _t="$(sh -c ". '$d/scripts/lib/deploy-facts.sh'; df_tag $l" | sed "s/%s/$v/")"
    GIT_COMMITTER_DATE="@$((NOW - ta * H)) +0000" \
      git -C "$d" -c user.email=t@t -c user.name=t tag -a -m t "$_t"
  fi
}
put() { mkdir -p "$(dirname "$1")"; printf '%s' "$2" > "$1"; }

# run <이름> <lang> <ver> <ssot나이> <태그나이|''> <픽스처 채우기 함수> → OUT·CODE
run() {
  _n="$1"; _l="$2"; _v="$3"; _sa="$4"; _ta="$5"; _fill="$6"
  _r="$FIX/$_n/repo"; _f="$FIX/$_n/fix"
  mkrepo "$_r" "$_l" "$_v" "$_sa" "$_ta"
  mkdir -p "$_f"; "$_fill" "$_f"
  set +e
  OUT="$(node "$GUARD" --root="$_r" --fixtures="$_f" --now="$NOW" 2>&1)"
  CODE=$?
  set -e
}
expect() { # expect <이름> <종료코드> <판정어>
  assert_eq "$2" "$CODE" "[$1] 종료코드 — 출력: $OUT"
  assert_contains "$OUT" "$3" "[$1] 판정어 $3"
}

PYPI=pypi.org/pypi/keycloak-sdk/json
py_live()    { put "$1/$PYPI" '{"releases":{"0.1.0rc1":[{"yanked":false}],"1.0.0":[{"yanked":false}]}}'; }
py_ahead()   { put "$1/$PYPI" '{"releases":{"1.0.0":[{"yanked":false}],"1.1.0":[{"yanked":false}]}}'; }
py_rc_only() { put "$1/$PYPI" '{"releases":{"1.0.0":[{"yanked":false}],"1.1.0rc1":[{"yanked":false}]}}'; }
py_absent()  { put "$1/$PYPI" '{"releases":{"0.2.1":[{"yanked":false}]}}'; }
py_yanked()  { put "$1/$PYPI" '{"releases":{"1.0.0":[{"yanked":true}]}}'; }
py_503()     { put "$1/$PYPI.status" '503'; }
py_badjson() { put "$1/$PYPI" '<html>maintenance</html>'; }

run live      python 1.0.0 100 90 py_live;    expect live 0 LIVE
run ahead     python 1.0.0 100 90 py_ahead;   expect ahead 1 REGISTRY_AHEAD
# 프리릴리스는 「더 새 정식」이 아니다 — 0.1.0rc1·1.1.0rc1 표기가 정식으로 승격되면 거짓 빨강이다.
run rc        python 1.0.0 100 90 py_rc_only; expect rc 0 LIVE
# 유예: SSOT 는 태그보다 먼저 올라간다(런북 §4 1 단계) — 그 구간이 빨가면 매 릴리스가 거짓 경보다.
run pending   python 1.1.0 100 2  py_live;    expect pending 0 PENDING
run missing   python 1.1.0 100 30 py_live;    expect missing 1 MISSING
run pre-tag   python 1.1.0 2   '' py_live;    expect pre-tag 0 PENDING
run untagged  python 1.1.0 48  '' py_live;    expect untagged 1 UNTAGGED
run yanked    python 1.0.0 100 90 py_yanked;  expect yanked 1 MISSING
# 판정 불가는 통과가 아니다.
# 좌표 자체가 404 면 「없다」는 답이다(판정 불가 아님) — 유예를 넘었으면 MISSING.
py_nocoord() { :; }
run nocoord   python 1.0.0 100 90 py_nocoord; expect nocoord 1 MISSING
run e503      python 1.0.0 100 90 py_503;     expect e503 2 INCONCLUSIVE
run badjson   python 1.0.0 100 90 py_badjson; expect badjson 2 INCONCLUSIVE

# Maven — 있음은 pom 200 으로만 판정한다. metadata 는 늦는다(2026-09-24 실측: jar 200 · latest=1.0.0).
M=repo1.maven.org/maven2/io/github/xzawed/keycloak-sdk
mv_lagging_meta() { put "$1/$M/maven-metadata.xml" '<versions><version>1.0.0</version></versions>'; put "$1/$M/1.0.1/keycloak-sdk-1.0.1.pom" '<project/>'; }
mv_absent()       { put "$1/$M/maven-metadata.xml" '<versions><version>1.0.0</version></versions>'; }
mv_meta_lies()    { put "$1/$M/maven-metadata.xml" '<versions><version>1.0.1</version><version>1.1.0</version></versions>'; put "$1/$M/1.0.1/keycloak-sdk-1.0.1.pom" '<project/>'; }
mv_ahead()        { mv_meta_lies "$1"; put "$1/$M/1.1.0/keycloak-sdk-1.1.0.pom" '<project/>'; }
run mv-lag   java 1.0.1 100 90 mv_lagging_meta; expect mv-lag 0 LIVE
# Maven 유예는 72h — 사람이 Portal 을 눌러야 게시된다(실측: 태그 뒤 하루 넘어 클릭).
run mv-30h   java 1.0.1 100 30 mv_absent;       expect mv-30h 0 PENDING
run mv-80h   java 1.0.1 100 80 mv_absent;       expect mv-80h 1 MISSING
run mv-lies  java 1.0.1 100 90 mv_meta_lies;    expect mv-lies 2 INCONCLUSIVE
run mv-ahead java 1.0.1 100 90 mv_ahead;        expect mv-ahead 1 REGISTRY_AHEAD
# 그리고 같은 30h 가 Maven 밖에서는 MISSING 이다 — 유예가 언어별로 갈린다는 대조.
run py-30h   python 1.1.0 100 30 py_live;       expect py-30h 1 MISSING

# 나머지 어댑터 — 각자 LIVE 하나씩. 어댑터의 URL 문법이 틀리면 404 → 여기서 MISSING/INCONCLUSIVE 가 된다.
# 가드는 요청 URL 을 `%2f` 로 인코딩하고 픽스처 경로는 디코딩해 읽는다(실제 npm 레지스트리 문법).
node_live()   { put "$1/registry.npmjs.org/@xzawed/keycloak-sdk" '{"versions":{"1.0.0":{}}}'; }
dotnet_live() { put "$1/api.nuget.org/v3-flatcontainer/xzawed.keycloak.sdk/index.json" '{"versions":["0.1.0-rc.1","1.0.0"]}'; }
rust_live()   { put "$1/crates.io/api/v1/crates/keycloak-sdk" '{"versions":[{"num":"1.0.0","yanked":false}]}'; }
ruby_live()   { put "$1/rubygems.org/api/v1/versions/keycloak-sdk.json" '[{"number":"1.0.0"},{"number":"0.1.0.rc1"}]'; }
php_live()    { put "$1/repo.packagist.org/p2/xzawed/keycloak-sdk.json" '{"packages":{"xzawed/keycloak-sdk":[{"version":"v1.0.0"}]}}'; }
# Go proxy 는 대문자를 `!소문자` 로 인코딩한다 — 안 하면 404.
go_live()     { put "$1/proxy.golang.org/github.com/xzawed/!key!cloak!s!d!k/go/@v/list" 'v0.1.0
v1.0.0
'; }
for L in node dotnet rust ruby php go; do
  run "a-$L" "$L" 1.0.0 100 90 "${L}_live"; expect "a-$L" 0 LIVE
done

# 공허 방지 — 언어 목록이 비면 0 개를 훑고 통과하지 않는다.
mkdir -p "$FIX/empty/scripts/lib"
printf '%s\n' "DEPLOY_LANGS=''" > "$FIX/empty/scripts/lib/deploy-facts.sh"
set +e; OUT="$(node "$GUARD" --root="$FIX/empty" --fixtures="$FIX/empty" --now="$NOW" 2>&1)"; CODE=$?; set -e
assert_eq "1" "$CODE" "[empty] 언어 0 개가 통과했다 — 출력: $OUT"

assert_report
