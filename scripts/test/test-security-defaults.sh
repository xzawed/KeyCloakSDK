#!/usr/bin/env sh
# 보안 파라미터 기본값의 단일 진실 — 아홉 언어의 코드와 그것을 말하는 모든 소비자 문서가 같아야 한다.
#
# 왜 이 가드가 필요한가: JWKS 최소 재조회 간격은 **DoS 증폭 상한**이다. 위조 kid를 담은 토큰이
# 쏟아질 때 SDK가 IdP를 얼마나 자주 때리는지를 이 값 하나가 정한다. 2026-07-31에 아홉 언어를
# 30초로 정렬했는데(그 전에는 10·30·60 세 갈래였고, 같은 공격에 Ruby가 Python보다 IdP를 6배
# 자주 때렸다), **그 사실을 말하는 문서는 아무도 검사하지 않았다.**
#
# 실제로 그래서 깨져 있었다(2026-08-12 문서 감사): `ruby/README.ko.md`가 소비자에게 기본값을
# `10.0`이라고 알려주고 있었다 — 영문 미러는 30초라고 적는 그 자리에서. 3배 차이이고 하필
# 보안 파라미터다. 리포 전체에 이 불변식을 겨누는 가드는 0건이었다
# (`grep -rn "efetch" scripts/ .github/workflows/` → 0).
#
# ⚠️ 이 가드는 **두 축을 함께** 본다. 한쪽만 보면 조용히 공허해진다:
#   (1) 코드 축 — 아홉 언어의 config 기본값이 서로 같은가. 하나가 드리프트하면 문서가 전부
#       맞아도 언어 간 동작이 갈린다.
#   (2) 문서 축 — 그 값을 말하는 소비자 문서가 코드값과 같은가. 코드가 전부 같아도 문서가
#       틀리면 소비자는 틀린 값을 전제로 자기 rate-limit을 설계한다.
#
# ⚠️ **거버넌스·계획 문서는 스코프 밖이다.** `docs/governance/`·`docs/superpowers/`는 과거 시점을
# 기록하는 append-only 문서라, 옛 값을 적고 있는 것이 드리프트가 아니라 기록이다(문서 감사의
# 적대적 검증층이 이 부류를 오탐으로 걸러냈다). 소비자가 복사해 가는 문서만 겨눈다.
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
ROOT="$DIR/../.."

# ⚠️ `assert_ok`는 **명령만** 받는다(메시지 인자를 주면 그것까지 명령으로 해석해 실패한다).
# 메시지를 남기려면 "ok" 여부를 문자열로 만들어 `assert_eq`에 넘긴다.
ok_if() { if [ "$1" = 0 ]; then printf 'ok'; else printf '%s' "${2:-NOT-OK}"; fi; }

# ---------------------------------------------------------------------------
# 1) 코드 축 — 아홉 언어의 config 기본값
# ---------------------------------------------------------------------------
#
# ✅ **좁혔던 스코프는 Task D1에서 해소됐다(2026-08-13).** 예전에는 go `jwt.go`(60)·php
# `JwksStore`(60)·ruby `jwks_store.rb`(10.0)에 **2차 리터럴**이 남아 있었고, 이 가드는 그 셋을
# 스코프 밖에 두었다(함께 검사하면 미해결 결함 때문에 영구 RED가 되어 아무도 켜두지 않게 되므로).
# 지금은 셋 다 config의 상수를 참조하므로 리터럴이 하나뿐이고, **2차 리터럴이 다시 생기는 것을
# 아래 3-절이 막는다.**
#
# ⚠️ php·ruby의 2차 자리는 cosmetic이 아니었다 — 두 클래스 다 public 생성자라 소비자가 파사드를
# 거치지 않고 직접 생성할 수 있었고, ruby는 그 경로에서 10초를 받아 문서가 말하는 30초보다
# **IdP를 3배 자주** 때렸다(한글 README도 그 10.0을 옮겨 적고 있었다). go만 비수출이라 도달 불가였다.
sd_default() { # $1=언어 → 기본값(정규화 전)
  case "$1" in
    java)   sed -n 's/.*jwksMinRefetch *= *Duration\.ofSeconds(\([0-9][0-9.]*\)).*/\1/p' \
              "$ROOT/java/keycloak-sdk-core/src/main/java/io/github/xzawed/keycloak/core/KeycloakConfig.java" | head -1 ;;
    python) sed -n 's/.*jwks_min_refetch_seconds: *float *= *\([0-9][0-9.]*\).*/\1/p' \
              "$ROOT/python/src/keycloak_sdk/config.py" | head -1 ;;
    node)   sed -n 's/.*jwksMinRefetchSeconds: *input\.jwksMinRefetchSeconds *?? *\([0-9][0-9.]*\).*/\1/p' \
              "$ROOT/node/src/config.ts" | head -1 ;;
    go)     sed -n 's/.*DefaultJwksMinRefetchSecs *int64 *= *\([0-9][0-9.]*\).*/\1/p' "$ROOT/go/config.go" | head -1 ;;
    dotnet) sed -n 's/.*RefreshIntervalSeconds *{ *get; *init; *} *= *\([0-9][0-9.]*\).*/\1/p' \
              "$ROOT/dotnet/src/Xzawed.Keycloak.Sdk/JwtValidator.cs" | head -1 ;;
    php)    sed -n 's/.*DEFAULT_JWKS_MIN_REFETCH_SECONDS *= *\([0-9][0-9.]*\).*/\1/p' "$ROOT/php/src/KeycloakConfig.php" | head -1 ;;
    rust)   sed -n 's/.*jwks_min_refetch_secs: *\([0-9][0-9.]*\).*/\1/p' "$ROOT/rust/src/config.rs" | head -1 ;;
    ruby)   sed -n 's/.*DEFAULT_JWKS_MIN_REFETCH *= *\([0-9][0-9.]*\).*/\1/p' "$ROOT/ruby/lib/keycloak_sdk/config.rb" | head -1 ;;
    kotlin) sed -n 's/.*jwksMinRefetch: *Duration *= *Duration\.ofSeconds(\([0-9][0-9.]*\)).*/\1/p' \
              "$ROOT/kotlin/src/main/kotlin/io/github/xzawed/keycloak/config.kt" | head -1 ;;
  esac
}
# `30.0`·`30` 은 같은 값이다 — 언어마다 float/int 관용이 달라 표기만 갈린다.
sd_norm() { printf '%s' "$1" | sed 's/\.0*$//'; }

SD_LANGS='java python node go dotnet php rust ruby kotlin'

sd_expect=''
sd_seen=0
for L in $SD_LANGS; do
  _raw="$(sd_default "$L" || true)"
  # ⚠️ 추출 실패를 통과로 읽지 않는다 — 파일이 옮겨지거나 선언 표기가 바뀌면 sed가 빈 문자열을
  # 내는데, 그걸 넘기면 이 가드는 **아홉 언어를 하나도 안 보면서 초록**이 된다(이 저장소가
  # 반복해서 겪은 부류).
  _has=1; [ -n "$_raw" ] && _has=0
  assert_eq "ok" "$(ok_if "$_has" MISSING)" \
    "$L 의 JWKS 기본값을 소스에서 추출하지 못했다 — 선언 표기가 바뀌었나?"
  [ -n "$_raw" ] || continue
  _v="$(sd_norm "$_raw")"
  sd_seen=$((sd_seen + 1))
  if [ -z "$sd_expect" ]; then
    sd_expect="$_v"
  else
    assert_eq "$sd_expect" "$_v" \
      "$L 의 JWKS 최소 재조회 기본값이 다른 언어와 다르다 — 아홉이 함께 움직여야 하는 값이다"
  fi
done

# 대조군 — 위 루프가 실제로 아홉 언어를 돌았는지. `SD_LANGS`가 비거나 경로 규칙이 바뀌면
# 어서션이 0건 실행되고 이 테스트는 조용히 통과한다.
assert_eq "9" "$sd_seen" "JWKS 기본값을 읽은 언어 수가 9가 아니다 — 추출 표가 낡았나?"

# ---------------------------------------------------------------------------
# 2) 문서 축 — 그 값을 말하는 소비자 문서
# ---------------------------------------------------------------------------
#
# ⚠️ **"파라미터명이 나오는 줄"이 아니라 "값을 말하는 줄"만 본다.** 전자로 잡으면
# `.claude/rules/java.md`의 "Nimbus 캐시 TTL(기본 5분)보다 작아야 한다" 같은 줄이 걸려
# 5 ≠ 30 으로 오탐이 난다. 그래서 파라미터명과 값-서술 신호를 **함께** 요구한다.
#
# ⚠️ 아홉 언어 README가 전부 자기 파라미터 이름을 적는다 — dotnet만 "30-second minimum
# interval"로 이름 없이 적고 있어서 탐지에서 빠졌고, 그래서 이름을 적도록 문서를 고쳤다
# (가드가 볼 수 없는 표현은 가드가 지켜주지 못한다).
SD_DOCS="$(cd "$ROOT" && git ls-files '*/README.md' '*/README.ko.md' 'README.md' 'README.ko.md' \
  'docs/guides/*.md' 'SECURITY.md' 2>/dev/null || true)"
_hasdocs=1; [ -n "$SD_DOCS" ] && _hasdocs=0
assert_eq "ok" "$(ok_if "$_hasdocs" EMPTY)" "소비자 문서 목록이 비었다 — git ls-files 패턴이 바뀌었나?"

sd_hits=0
for f in $SD_DOCS; do
  # ⚠️ **설정표 행(`^N:|`)을 신호에 반드시 포함할 것.** 이 가드를 만든 바로 그 결함
  # (`ruby/README.ko.md:72`의 `10.0`)은 한글 표 행이라 "default"도 "기본값"도 없다 —
  # 산문 신호만 요구했더니 **변이검증에서 그 줄이 그대로 통과했다**(MC2: 29 passed, 0 failed).
  # 가드가 겨눈 실물을 변이로 재현해 보지 않았으면 공허한 채로 커밋될 뻔했다.
  _lines="$(grep -inE 'jwks[_ ]?min[_ ]?refetch|RefreshIntervalSeconds' "$ROOT/$f" 2>/dev/null \
    | grep -iE 'default|기본값|minimum interval|throttled|cooldown|^[0-9]+:\|' || true)"
  [ -n "$_lines" ] || continue
  # 코드값을 담지 않은 줄이 곧 드리프트다(고정문자열 대조 — 값에 `.`이 들어가도 안전하다).
  _bad="$(printf '%s\n' "$_lines" | grep -v -F "$sd_expect" || true)"
  assert_eq "" "$_bad" "$f 가 JWKS 최소 재조회 기본값을 코드값($sd_expect)과 다르게 말한다"
  sd_hits=$((sd_hits + $(printf '%s\n' "$_lines" | grep -c . || true)))
done

# 대조군 — 문서 축이 실제로 무언가를 봤는가. 아홉 언어 README가 전부 이 값을 말하고
# `ruby/README.ko.md`의 설정표 행이 하나 더 있어 실측 10건이다. 이 하한이 없으면 탐지
# 정규식이 깨졌을 때 "볼 것이 없어서" 초록이 된다.
_enough=1; [ "$sd_hits" -ge 10 ] && _enough=0
assert_eq "ok" "$(ok_if "$_enough" "$sd_hits")" \
  "기본값을 말하는 문서 줄을 10건 미만 찾았다 — 탐지 패턴이 낡았나?"

# ---------------------------------------------------------------------------
# 3) 2차 정의 자리 금지 — 같은 값을 두 번 적지 않는다
# ---------------------------------------------------------------------------
#
# ⚠️ 1절은 "config 기본값 아홉이 서로 같은가"만 본다. 그런데 이 값이 **한 언어 안에서 두 번**
# 적히면 그 둘이 갈라지는 것을 1절이 못 본다 — 실제로 그랬다(go 30/60 · php 30/60 · ruby 30.0/10.0).
# 그래서 2차 자리가 상수를 **참조**하는지(리터럴이 아닌지) 문자로 확인한다.
sd_no_literal() { # $1=라벨 $2=파일 $3=파라미터가 등장하는 줄의 앵커
  _l="$(grep -m1 -F "$3" "$ROOT/$2" || true)"
  _found=1; [ -n "$_l" ] && _found=0
  assert_eq "ok" "$(ok_if "$_found" MISSING)" "[$1] 2차 정의 자리를 찾지 못했다($3) — 표기가 바뀌었나?"
  [ -n "$_l" ] || return 0
  # 그 줄에 숫자 리터럴이 있으면 2차 정의다(상수를 참조하면 숫자가 없다).
  case "$_l" in
    *[0-9]*) assert_eq "" "$_l" "[$1] 2차 정의 자리에 숫자 리터럴이 있다 — config 상수를 참조할 것(정의 자리는 언어당 하나)" ;;
    *) assert_eq "ok" "ok" ;;
  esac
}
# ⚠️ go 앵커의 **뒤 공백이 하중을 받는다** — `opts.minRefetch =`(공백 없음)로 잡으면 바로 위의
# `if opts.minRefetch == 0 {`이 먼저 걸려 그 `0`을 2차 리터럴로 오인한다(실측 오탐).
sd_no_literal go   go/jwt.go                        'opts.minRefetch = '
sd_no_literal php  php/src/Jwks/JwksStore.php       'private readonly int $minRefetchIntervalSeconds ='
sd_no_literal ruby ruby/lib/keycloak_sdk/jwks_store.rb 'def initialize(jwks_url:, http:, min_refetch:'

assert_report
