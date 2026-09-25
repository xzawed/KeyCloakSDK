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
# ⚠️ **언어 목록을 손으로 적지 않는다.** 예전에는 아홉을 나열하고 `pg_blocks == 9` 를 단언했다 —
# 그러면 **열 번째 언어는 이 축을 조용히 건너뛴다**(루프가 그 이름을 모르니 게이트가 없어도
# `9 == 9` 로 통과한다). 목록을 `consume/*-run.sh` 에서 파생하고, 그 파생이 실제 레인 집합과
# 같은지는 **독립 원천**(`deploy-facts.sh` 의 `DEPLOY_LANGS`)으로 대조한다 — 파생 하나만 쓰면
# 스크립트를 지우는 것이 곧 축을 줄이는 길이 된다(자기충족).
_pg_langs="$(ls "$ROOT"/harness/install/consume/*-run.sh 2>/dev/null | sed 's#.*/##; s#-run\.sh$##' | sort | tr '\n' ' ')"
# shellcheck source=/dev/null
. "$ROOT/scripts/lib/deploy-facts.sh"
_pg_lanes="$(printf '%s\n' $DEPLOY_LANGS | sort | tr '\n' ' ')"
# 공허 방지 — 파생이 0 건이면 아래 루프가 아무것도 안 돌고 통과한다.
assert_eq "ok" "$(ok_if "$([ -n "$_pg_langs" ] && echo 0 || echo 1)" EMPTY)" \
  "[출처게이트] consume/*-run.sh 에서 언어를 하나도 파생하지 못했다 — 이 축이 통째로 공허해진다"
assert_eq "$_pg_lanes" "$_pg_langs" \
  "[출처게이트] consume 스크립트의 언어 집합이 배포 레인(DEPLOY_LANGS)과 다르다 — 레인이 생겼는데 게이트가 없거나, 그 반대다"

pg_blocks=0
_pg_n=0
for L in $_pg_langs; do
  _pg_n=$((_pg_n + 1))
  _n="$(pg_extract "$L" | grep -c . || true)"
  assert_ok test "$_n" -ge 3
  [ "$_n" -ge 3 ] && pg_blocks=$((pg_blocks + 1))
done
assert_eq "$_pg_n" "$pg_blocks" "센티널로 게이트 블록을 뽑지 못한 언어가 있다 — 센티널이 지워졌나?"

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
#
# ⚠️ **「그 문자열이 파일 어딘가에 있다」로 보지 않는다 — 그 판이 세 번 SILENT 였다**(probe.sh 실측):
# 정의를 `REG="."` 로 바꾸고 옛 줄을 **주석으로 남기면** 통과했고, 정의는 그대로 둔 채 센티널
# 바로 위에 `REG="."`(python) · `_kreg="."`(kotlin)를 **한 줄 더** 넣어도 통과했다 — 게이트가
# 읽는 것은 등장한 문자열이 아니라 **마지막으로 대입된 값**이다. 그래서 센티널 **앞** 구간에서
# 주석을 벗긴 뒤, 그 변수에 대한 **마지막** 대입의 우변이 기대 형태인지 본다. 센티널 **안**의
# 재대입(`REG="${REG%/}/"` 정규화)은 런타임 행이 스텁으로 실행해 보므로 여기서 세지 않는다.
# 독립 레그(Grok)가 이 판에 우회 여섯을 냈고 여섯 다 정적으로 재현됐다 — 둘을 받아 닫았다:
# 기대 형태가 읽는 **원천**(`REGISTRY_URL=.` 을 정의 앞에) · 따옴표 **안**의 ` #` 를 주석으로 오인해
# 뒤의 `; REG=.` 를 버리는 것. 빈 기본값(`:-}`)·`unset REG` 는 약화가 아니다 — 빈 값은 런타임 행
# 「빈 근거 그림자」가 0 으로 잡고, 미설정은 일곱 스크립트 전부의 `set -u` 가 죽인다(fail-closed).
# ⚠️ 잔여 — 이것도 셸 의미의 정적 근사다: 실행되지 않는 분기 안의 대입·`eval`·`read` 는 못 본다.
pg_last_assign() { # $1=파일 $2=변수 → 센티널 앞, 주석 제외, 마지막 대입의 `VAR=` 부터 끝까지
  awk -v v="$2" '
    # 셸 주석을 벗긴다 — 따옴표 밖, 단어 시작의 `#` 부터. 따옴표 안의 ` #` 는 값이다.
    function nocomment(line,   i, n, c, q, out, prev, sq) {
      sq = "\047"; q = ""; out = ""; prev = " "; n = length(line)
      for (i = 1; i <= n; i++) {
        c = substr(line, i, 1)
        if (q == "") {
          if (c == "#" && (prev == " " || prev == "\t")) break
          if (c == sq || c == "\"") q = c
        } else if (c == q) {
          q = ""
        } else if (q == "\"" && c == "\\" && i < n) {
          out = out c; i++; c = substr(line, i, 1)
        }
        out = out c; prev = c
      }
      return out
    }
    /# >>> provenance-gate/ { exit }
    {
      s = " " nocomment($0)
      re = "[ \t;)&|](export[ \t]+|readonly[ \t]+|local[ \t]+)?" v "="
      while (match(s, re)) {
        t = substr(s, RSTART + 1)
        sub(/^(export|readonly|local)[ \t]+/, "", t)
        last = t
        s = substr(s, RSTART + RLENGTH)
      }
    }
    END { print last }' "$1"
}
pg_defn_file() { # $1=파일 $2=기대 정의(「VAR=…」 접두) → ok | MISSING
  _last="$(pg_last_assign "$1" "${2%%=*}")"
  case "$_last" in "$2"*) ;; *) echo MISSING; return ;; esac
  # 기대 형태가 `${SRC:-…}` 로 원천을 읽으면, 그 원천도 센티널 앞에서 대입돼선 안 된다(주입 전용).
  _src="$(printf '%s' "$2" | sed -n 's/.*\${\([A-Za-z_][A-Za-z0-9_]*\):-.*/\1/p')"
  if [ -n "$_src" ] && [ -n "$(pg_last_assign "$1" "$_src")" ]; then echo MISSING; return; fi
  echo ok
}
pg_defn() { # $1=언어 $2=기대하는 정의 문자열
  assert_eq "ok" "$(pg_defn_file "$CONSUME/$1-run.sh" "$2")" \
    "[$1] 근거 변수의 마지막 대입이 기대 형태가 아니다 — 약한 값으로 바뀌었거나 뒤에서 덮였나? (기대: $2)"
}

# 대조군 — 위 판정이 **알려진 나쁜 입력을 거부하는가**. 라이브 파일만 보면 판정을 `grep -F` 로
# 되돌려도 초록이다(그것이 바로 이 절이 고친 판이다). 각 행은 **그 모양 하나만** 다르다.
_pgd="$TMP/defn.sh"
_pgd_case() { # $1=기대(ok|MISSING) $2=설명 / stdin=픽스처
  cat > "$_pgd"
  assert_eq "$1" "$(pg_defn_file "$_pgd" 'REG="${REGISTRY_URL:-')" "[정의 대조군] $2"
}
_pgd_case ok "양성: 정의 한 줄" <<'X'
REG="${REGISTRY_URL:-http://x:1}"
X
_pgd_case ok "양성: 센티널 안의 재대입은 세지 않는다" <<'X'
REG="${REGISTRY_URL:-http://x:1}"
  # >>> provenance-gate
  REG="."
X
_pgd_case ok "양성: 줄 중간 대입(java 의 case 가지 모양)" <<'X'
  http://*) _a="1"; REG="${REGISTRY_URL:-http://x:1}" ;;
X
_pgd_case MISSING "음성: 약한 정의 + 옛 줄은 주석으로" <<'X'
# REG="${REGISTRY_URL:-http://x:1}"
REG="."
X
_pgd_case MISSING "음성: 약한 정의 + 옛 줄은 꼬리 주석으로" <<'X'
REG="." # REG="${REGISTRY_URL:-http://x:1}"
X
_pgd_case MISSING "음성: 정의 뒤, 센티널 앞의 재대입" <<'X'
REG="${REGISTRY_URL:-http://x:1}"
REG="."
  # >>> provenance-gate
X
_pgd_case MISSING "음성: export 로 덮기" <<'X'
REG="${REGISTRY_URL:-http://x:1}"
export REG="."
X
_pgd_case MISSING "음성: 대입이 아예 없다" <<'X'
echo 'REG="${REGISTRY_URL:-http://x:1}"'
X
_pgd_case ok "양성: 진짜 꼬리 주석 속 대입은 세지 않는다" <<'X'
REG="${REGISTRY_URL:-http://x:1}"  # 여기서 REG="." 로 바꾸지 말 것
X
_pgd_case MISSING "음성: 따옴표 안의 ' #' 뒤에 숨긴 재대입(Grok)" <<'X'
REG="${REGISTRY_URL:-http://x:1} #"; REG=.
X
_pgd_case MISSING "음성: 정의가 읽는 원천을 앞에서 덮기(Grok)" <<'X'
REGISTRY_URL=.
REG="${REGISTRY_URL:-http://x:1}"
X
pg_defn python 'REG="${REGISTRY_URL:-'
pg_defn node   'REG="${REGISTRY_URL:-'
pg_defn php    'REG="${REGISTRY_URL:-'
pg_defn ruby   'REG="${REGISTRY_URL:-'
pg_defn rust   'LOCAL_REG="/opt/local-registry"'
# kotlin·java는 리터럴이 아니라 빌드파일/settings.xml에서 **파생**한다 — 그 파생 자체가 근거이므로
# 정의 문자열이 아니라 파생 명령이 남아 있는지 본다.
pg_defn kotlin '_kreg_candidates="$(sed -n '
# ⚠️ kotlin 게이트가 읽는 것은 후보가 아니라 `_kreg` 다 — 후보만 보면 그 사이의 `_kreg="."` 가 샌다(실측 SILENT).
pg_defn kotlin '_kreg="$(printf '"'"'%s\n'"'"' "$_kreg_candidates"'
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

# dotnet — `$REG`가 origin이 아니라 인덱스 URL 전체이고 `.nupkg.metadata`의 `source`도 그 문자열
# 그대로다. 그래서 접두가 아니라 **정확일치**를 시험한다.
DN='REG="http://bagetter:8080/v3/index.json"'
pg_case dotnet "$DN" 1 "정상: 로컬 BaGetter 인덱스" <<'X'
http://bagetter:8080/v3/index.json
X
pg_case dotnet "$DN" 0 "공개 nuget.org에서 해석" <<'X'
https://api.nuget.org/v3/index.json
X
pg_case dotnet "$DN" 0 "혼재" <<'X'
http://bagetter:8080/v3/index.json
https://api.nuget.org/v3/index.json
X
pg_case dotnet "$DN" 0 "빈 provenance" < /dev/null
pg_case dotnet "$DN" 0 "기록 실패 리터럴" <<'X'
<.nupkg.metadata에서 source를 찾지 못했다: /root/.nuget/packages/xzawed.keycloak.sdk/0.1.0/.nupkg.metadata>
X
pg_case dotnet "$DN" 0 "접두만 같은 다른 피드(정확일치라 거부)" <<'X'
http://bagetter:8080/v3/index.json.evil/v3/index.json
X
pg_case dotnet 'REG=""' 0 "빈 근거 그림자" <<'X'
https://api.nuget.org/v3/index.json
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
