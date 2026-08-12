#!/usr/bin/env sh
# 출처 게이트 **런타임 행동** 테스트 — 계획서 Task B0.
#
# 왜 이것이 필요한가: 자매 가드 `test-harness-registries.sh`는 consume 스크립트의 셸 **텍스트를
# 정적으로 분석**한다. 그 방식으로 두 라운드에 걸쳐 7종 우회를 닫았지만 적대적 재리뷰가 곧바로
# 4종을 더 찾았고, 계획서는 이렇게 결론지었다 — **"정적으로 임의 POSIX 셸의 의미를 증명하려는
# 시도라 수렴하지 않는다."**
#
# 그래서 이 테스트는 게이트를 **실행한다**. 각 스크립트의 게이트 블록을 센티널 주석
# (`# >>> provenance-gate` … `# <<< provenance-gate`) 사이에서 뽑아, 합성 `provenance.txt`와
# 스텁 환경을 주고 dash로 돌려 `PROVENANCE_OK`가 무엇이 되는지 본다. 문법 회피(따옴표·`||`·
# 주석)에 면역이다 — 값이 무엇이 되는지만 보기 때문이다.
#
# ⚠️ **센티널은 판정 계산 구간만 감싼다.** 뒤따르는 `installed.ok` 쓰기 블록에는 `sleep 3600`이
# 있어 함께 추출하면 기대 0인 행마다 한 시간을 잔다.
#
# ⚠️ **정적 가드는 남긴다 — 둘은 다른 것을 지킨다.** 정적은 "게이트가 존재하고 판정에 배선됐다",
# 런타임은 "게이트가 실제로 옳게 판정한다". 런타임은 센티널 **밖**의 조작을 못 보고, 정적은
# 블록 **안**의 의미를 못 본다.
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
ROOT="$DIR/../.."
CONSUME="$ROOT/harness/install/consume"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/st"

# 게이트 블록을 센티널 사이에서 뽑는다.
pg_extract() { awk '/# >>> provenance-gate/{f=1;next} /# <<< provenance-gate/{f=0} f' "$CONSUME/$1-run.sh"; }

# $1=언어 $2=스텁 선언(셸 코드) / stdin=provenance.txt 내용 → PROVENANCE_OK 출력
pg_run() {
  cat > "$TMP/st/provenance.txt"
  {
    echo 'set -u'
    printf 'STATUS=%s\n' "$TMP/st"
    printf '%s\n' "$2"
    echo 'PROVENANCE_OK=x'
    pg_extract "$1"
    # ⚠️ 값은 **파일로** 회수한다 — 게이트가 실패 경로에서 진단을 stdout에 찍으므로(go는
    # `cat /tmp/prov.log`까지 한다) 표준출력을 값으로 읽으면 그 진단이 섞여 들어온다.
    printf 'printf "%%s" "$PROVENANCE_OK" > %s/ok\n' "$TMP"
  } > "$TMP/run.sh"
  : > "$TMP/ok"
  dash "$TMP/run.sh" >/dev/null 2>&1 || true
  cat "$TMP/ok"
}

# $1=언어 $2=스텁 $3=기대 $4=설명 / stdin=provenance
pg_case() {
  _got="$(pg_run "$1" "$2")"
  assert_eq "$3" "$_got" "[$1] $4"
}

# 대조군 — 추출이 실제로 무언가를 뽑았는가. 센티널이 사라지거나 이름이 바뀌면 블록이 빈 문자열이
# 되고, 그러면 `PROVENANCE_OK`가 `x`로 남아 모든 행이 실패한다(조용한 통과가 아니라 시끄러운 실패).
pg_blocks=0
for L in go java kotlin node php python ruby rust; do
  _n="$(pg_extract "$L" | grep -c . || true)"
  assert_ok test "$_n" -ge 3
  [ "$_n" -ge 3 ] && pg_blocks=$((pg_blocks + 1))
done
assert_eq "8" "$pg_blocks" "센티널로 게이트 블록을 뽑은 언어 수가 8이 아니다 — 센티널이 지워졌나?"

# ---------------------------------------------------------------------------
# 근거 변수의 **정의 자리** — 두 가드 사이의 이음매
# ---------------------------------------------------------------------------
#
# ⚠️ 이 검사가 없으면 실측으로 확인된 구멍이 열린 채로 남는다. 근거 변수는 센티널 **밖**에서
# 정의되므로 (a) 런타임 테스트는 그 자리를 스텁으로 덮어써서 못 보고 (b) 정적 가드는 조건절에
# 변수 **이름**이 있는지만 보므로 값이 무엇이든 통과한다. 실측: `REG="${REGISTRY_URL:-…}"`를
# `REG="."`로 바꾸면 런타임 47/0·정적 59/0 — **둘 다 초록**인데 `grep -v -F "."`가 거의 모든
# URL을 "로컬"로 보아 공개 레지스트리에서 받아도 통과한다.
# 그래서 정의가 **주입 가능한 출처에서 파생되는지**를 여기서 문자로 확인한다. 값 자체가 아니라
# 정의의 모양을 보는 것이라 오케스트레이터가 URL을 바꿔도 흔들리지 않는다.
pg_defn() { # $1=언어 $2=기대하는 정의 문자열
  _line="$(grep -m1 -F "$2" "$CONSUME/$1-run.sh" || true)"
  _got="$( [ -n "$_line" ] && echo ok || echo MISSING )"
  assert_eq "ok" "$_got" "[$1] 근거 변수 정의가 기대 형태가 아니다 — 약한 값으로 바뀌었나? (기대: $2)"
}
pg_defn python 'REG="${REGISTRY_URL:-'
pg_defn node   'REG="${REGISTRY_URL:-'
pg_defn php    'REG="${REGISTRY_URL:-'
pg_defn ruby   'REG="${REGISTRY_URL:-'
pg_defn rust   'LOCAL_REG="/opt/local-registry"'
# kotlin·java는 리터럴이 아니라 빌드파일/settings.xml에서 **파생**한다 — 그 파생 자체가 근거이므로
# 정의 문자열이 아니라 파생 명령이 남아 있는지 본다.
pg_defn kotlin '_kreg_candidates="$(sed -n '
pg_defn java   '_local_url="$_exc_url"'

# ---------------------------------------------------------------------------
# URL/경로 축 7언어
# ---------------------------------------------------------------------------
PY='REG="http://pypiserver:8080"'
pg_case python "$PY" 1 "정상: 로컬 휠" <<'X'
http://pypiserver:8080/packages/keycloak_sdk-0.1.0rc1-py3-none-any.whl
X
pg_case python "$PY" 0 "혼재: 공개 PyPI 한 줄" <<'X'
http://pypiserver:8080/packages/keycloak_sdk-0.1.0rc1-py3-none-any.whl
https://files.pythonhosted.org/packages/keycloak_sdk-0.1.0rc1-py3-none-any.whl
X
pg_case python "$PY" 0 "빈 provenance" < /dev/null
pg_case python "$PY" 0 "메타만: 인덱스 URL, 휠 없음" <<'X'
http://pypiserver:8080/simple/keycloak-sdk/
X
pg_case python "$PY" 0 "중간 임베드: 로컬 URL이 쿼리에 박힌 외부 주소" <<'X'
https://evil.example/redir?u=http://pypiserver:8080/x.whl
X
pg_case python "$PY" 0 "호스트 경계: pypiserver:8080.evil.com" <<'X'
http://pypiserver:8080.evil.com/x.whl
X
pg_case python 'REG=""' 0 "빈 근거 그림자" <<'X'
https://files.pythonhosted.org/packages/x.whl
X
pg_case python 'REG="."' 0 "약한 근거 그림자(REG=.)" <<'X'
https://files.pythonhosted.org/packages/x.whl
X

ND='REG="http://verdaccio:4873"'
pg_case node "$ND" 1 "정상: 로컬 tarball" <<'X'
http://verdaccio:4873/@xzawed/keycloak-sdk/-/keycloak-sdk-0.1.0-rc.2.tgz
X
pg_case node "$ND" 0 "혼재: 공개 npm 한 줄" <<'X'
http://verdaccio:4873/@xzawed/keycloak-sdk/-/keycloak-sdk-0.1.0-rc.2.tgz
https://registry.npmjs.org/@xzawed/keycloak-sdk/-/keycloak-sdk-0.1.0-rc.2.tgz
X
pg_case node "$ND" 0 "빈 provenance" < /dev/null
pg_case node "$ND" 0 "메타만: packument URL, tarball 없음" <<'X'
http://verdaccio:4873/@xzawed/keycloak-sdk
X
pg_case node 'REG="."' 0 "약한 근거 그림자(REG=.)" <<'X'
https://registry.npmjs.org/@xzawed/keycloak-sdk/-/x.tgz
X

PH='REG="http://satis-web"'
pg_case php "$PH" 1 "정상: 로컬 dist zip" <<'X'
http://satis-web/dist/xzawed/keycloak-sdk-0.1.0-rc.1.zip
X
pg_case php "$PH" 0 "혼재: Packagist 한 줄" <<'X'
http://satis-web/dist/xzawed/keycloak-sdk-0.1.0-rc.1.zip
https://api.github.com/repos/xzawed/keycloak-sdk-php/zipball/abc123
X
pg_case php "$PH" 0 "빈 provenance" < /dev/null
pg_case php "$PH" 0 "기록 실패 리터럴" <<'X'
<no dist url>
X
pg_case php 'REG="."' 0 "약한 근거 그림자(REG=.)" <<'X'
https://api.github.com/repos/x/zipball/abc.zip
X

RB='REG="http://gemserver:8808"'
pg_case ruby "$RB" 1 "정상: 로컬 본문 gem + 스펙" <<'X'
http://gemserver:8808/gems/keycloak-sdk-0.1.0.rc1.gem
http://gemserver:8808/quick/Marshal.4.8/keycloak-sdk-0.1.0.rc1.gemspec.rz
X
pg_case ruby "$RB" 0 "본문은 공개, 스펙만 로컬" <<'X'
http://gemserver:8808/quick/Marshal.4.8/keycloak-sdk-0.1.0.rc1.gemspec.rz
https://rubygems.org/gems/keycloak-sdk-0.1.0.rc1.gem
X
pg_case ruby "$RB" 0 "스펙만 로컬(본문 줄 없음)" <<'X'
http://gemserver:8808/quick/Marshal.4.8/keycloak-sdk-0.1.0.rc1.gemspec.rz
X
pg_case ruby "$RB" 0 "빈 provenance" < /dev/null
pg_case ruby 'REG="http://gemserver"' 0 "호스트 경계: gemserver.evil.example" <<'X'
http://gemserver.evil.example/gems/keycloak-sdk-0.1.0.rc1.gem
X

KT='_kreg="http://mvn-repo-kotlin/"'
pg_case kotlin "$KT" 1 "정상: 로컬 jar + pom" <<'X'
http://mvn-repo-kotlin/io/x/keycloak-sdk-kotlin-0.1.0-RC1.jar
http://mvn-repo-kotlin/io/x/keycloak-sdk-kotlin-0.1.0-RC1.pom
X
pg_case kotlin "$KT" 0 "혼재: Central jar" <<'X'
http://mvn-repo-kotlin/io/x/keycloak-sdk-kotlin-0.1.0-RC1.pom
https://repo1.maven.org/maven2/io/x/keycloak-sdk-kotlin-0.1.0-RC1.jar
X
pg_case kotlin "$KT" 0 "pom만 로컬(부분 출처)" <<'X'
http://mvn-repo-kotlin/io/x/keycloak-sdk-kotlin-0.1.0-RC1.pom
X
pg_case kotlin "$KT" 0 "빈 provenance" < /dev/null
pg_case kotlin '_kreg="http://repo"' 0 "호스트 경계: repo.maven.apache.org" <<'X'
http://repo.maven.apache.org/maven2/io/x/keycloak-sdk-kotlin-0.1.0-RC1.jar
X

JV='_repo_ids="mvn-repo central"; _local_url="http://mvn-repo/"; _lookup_url() { case "$1" in mvn-repo) echo "http://mvn-repo/" ;; *) echo "https://repo.maven.apache.org/maven2" ;; esac; }'
pg_case java "$JV" 1 "정상: jar+pom 전부 로컬 id" <<'X'
keycloak-sdk-0.1.0-RC1.jar>mvn-repo=
keycloak-sdk-0.1.0-RC1.pom>mvn-repo=
X
pg_case java "$JV" 0 "부분 출처: pom만 로컬, jar는 central" <<'X'
keycloak-sdk-0.1.0-RC1.pom>mvn-repo=
keycloak-sdk-0.1.0-RC1.jar>central=
X
pg_case java "$JV" 0 "전부 central" <<'X'
keycloak-sdk-0.1.0-RC1.jar>central=
keycloak-sdk-0.1.0-RC1.pom>central=
X
pg_case java "$JV" 0 "빈 provenance" < /dev/null

RS='LOCAL_REG="/opt/local-registry"'
pg_case rust "$RS" 1 "정상: 로컬 레지스트리에서 Unpacking" <<'X'
     Unpacking keycloak-sdk v0.1.0-rc.1 (/opt/local-registry/keycloak-sdk-0.1.0-rc.1.crate)
X
pg_case rust "$RS" 0 "혼재: crates.io 한 줄" <<'X'
     Unpacking keycloak-sdk v0.1.0-rc.1 (/opt/local-registry/keycloak-sdk-0.1.0-rc.1.crate)
     Unpacking keycloak-sdk v0.1.0-rc.1 (registry `crates-io`)
X
pg_case rust "$RS" 0 "빈 provenance" < /dev/null
pg_case rust 'LOCAL_REG=""' 0 "빈 근거 그림자" <<'X'
     Unpacking keycloak-sdk v0.1.0-rc.1 (registry `crates-io`)
X

# ---------------------------------------------------------------------------
# go — 축이 다르다: provenance.txt를 읽지 않고 `go mod download` 성공 여부로 판정한다.
# 그래서 합성 URL이 아니라 **스텁 `go`** 를 먹인다.
# ---------------------------------------------------------------------------
mkdir -p "$TMP/bin"
go_stub() { # $1=file 프록시 단독일 때의 종료코드
  cat > "$TMP/bin/go" <<EOF
#!/bin/sh
# GOPROXY가 정확히 file:///proxy 일 때만 $1 로 끝난다(체인이면 0 — 공개 폴스루 성공을 흉내).
case "\$GOPROXY" in
  "file:///proxy") exit $1 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$TMP/bin/go"
}
go_env='PKG_VER=0.1.0; PATH="'"$TMP"'/bin:$PATH"'

go_stub 0
pg_case go "$go_env" 1 "file 프록시 단독으로 모듈 전체 수신" < /dev/null
go_stub 1
pg_case go "$go_env" 0 "file 프록시 단독 실패(체인이면 공개로 폴스루했을 상황)" < /dev/null

assert_report
