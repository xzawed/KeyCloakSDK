#!/usr/bin/env sh
# **설정 타입의 마스킹** 축 — 아홉 언어의 `KeycloakConfig` 가 클라이언트 시크릿을 기본
# 문자열/디버그 표현에서 가리는가.
#
# 왜 별도 가드인가: 이 불변식은 `test-security-defaults.sh` 의 1c(`TokenSet`)·1d(인가요청)와
# 같은 부류지만, 등록부 항목 `guard-detection-surface-hand-narrowed` 의 처방이
# **「그 파일에 축을 더 늘리지 말 것 — 새 불변식은 별도 가드로 내라」** 다. 그 파일은 축이
# 두 번 늘어난 이력이 있고, 늘어난 축이 전부 손 표였다.
#
# 왜 필요한가(실측 2026-09-12, `scripts/probe.sh`): config 마스킹을 **원문 노출로 되돌리는**
# 변이를 넣었더니 **4/4 가 `SILENT`** 였다(go·kotlin·python·ruby). 1d 가 닫은 것과 **같은
# 모양의 구멍**이다 — 1c/1d 의 앵커는 `TokenSet`·인가요청 전용이라 설정 타입은 어느 축에도
# 없었다. 시크릿은 소비자가 기동 시 만들어 **routine 하게 로깅하는** 값이라 노출 경로가 넓다.
#
# ⚠️ **앵커는 마스킹 자체를 포함해야 한다**(1d 가 값을 치르고 배운 규칙). `toString` 같은 훅
# 이름은 실격이다 — 훅이 남은 채 본문이 원문을 찍어도 통과한다. 아래 앵커는 전부 `mask` 호출
# 이거나 `***` 리터럴이고, 각각 프로브로 `SILENT → CAUGHT` 를 확인했다.
#
# ⚠️ **java 는 계약이 다르다** — 마스킹 훅이 **없고**, 안전 근거가 「필드를 안 찍는 기본
# `toString`」이다(`final class` + `private char[]`). 그래서 겨눌 것은 훅이 아니라
# **「record 로 바뀌지 않았다」** 이다(1d 가 java `AuthorizationUrlRequest` 에 쓰는 것과 같은 모양).
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
. "$DIR/../lib/deploy-facts.sh"
ROOT="${CM_ROOT:-$DIR/../..}"


# 설정 타입의 소스 자리.
cm_src() {
  case "$1" in
    java)   printf '%s' 'java/keycloak-sdk-core/src/main/java/io/github/xzawed/keycloak/core/KeycloakConfig.java' ;;
    kotlin) printf '%s' 'kotlin/src/main/kotlin/io/github/xzawed/keycloak/config.kt' ;;
    python) printf '%s' 'python/src/keycloak_sdk/config.py' ;;
    node)   printf '%s' 'node/src/config.ts' ;;
    go)     printf '%s' 'go/config.go' ;;
    dotnet) printf '%s' 'dotnet/src/Xzawed.Keycloak.Sdk/KeycloakConfig.cs' ;;
    php)    printf '%s' 'php/src/KeycloakConfig.php' ;;
    rust)   printf '%s' 'rust/src/config.rs' ;;
    ruby)   printf '%s' 'ruby/lib/keycloak_sdk/config.rb' ;;
  esac
}

# ⚠️ 마스킹 **행위**를 담은 앵커다(훅 이름이 아니라). java 는 훅이 없어 빈 문자열이고 아래에서
# 모양으로 판정한다.
cm_anchor() {
  case "$1" in
    kotlin) printf '%s' 'clientSecret=${mask(secret)}' ;;
    python) printf '%s' 'client_secret={mask(self.client_secret)!r}' ;;
    node)   printf '%s' 'clientSecret: config.clientSecret === undefined ? undefined : mask(config.clientSecret)' ;;
    go)     printf '%s' 'mask(c.ClientSecret)' ;;
    dotnet) printf '%s' 'Masking.Mask(ClientSecret)' ;;
    php)    printf '%s' 'Masking::mask($this->clientSecret)' ;;
    rust)   printf '%s' 'self.client_secret.as_ref().map(|_| "***")' ;;
    ruby)   printf '%s' 'Masking.mask(@client_secret)' ;;
    *)      printf '%s' '' ;;
  esac
}

# ── 판정 둘 — 라이브 루프와 아래 대조군이 **같은 함수**를 부른다(대조군에 grep 을 다시 적으면 판정 줄이 깨져도
# 대조군은 초록이다 — 실측 2026-11-14 SILENT). ────────────────────────────────────────────────────
# $1=루트 $2=언어 → 0 = 그 언어 설정 소스에 마스킹 앵커가 있다.
cm_masks() {
  _cma="$(cm_anchor "$2")"
  [ -n "$_cma" ] || return 1
  _cmh=1; grep -qF -- "$_cma" "$1/$(cm_src "$2")" && _cmh=0
  return "$_cmh"
}
# $1=파일 → 0 = java KeycloakConfig 가 record 로 선언돼 있다.
cm_java_record() { grep -qE 'record[[:space:]]+KeycloakConfig' "$1"; }

# ⚠️ 언어 집합을 **트리에서 파생**한다 — 손 목록을 또 만들지 않는다. 열 번째 언어가 들어오면
# 아래 `cm_src` 가 빈 문자열을 내 이 가드가 실패하고, 사람이 그 언어의 계약을 판정하게 된다.
_cm_langs="$(df_tree_langs "$ROOT")"
assert_ok test -n "$_cm_langs"

_seen=0
for L in $_cm_langs; do
  _src="$(cm_src "$L")"
  _e=1; [ -n "$_src" ] && [ -f "$ROOT/$_src" ] && _e=0
  assert_eq "ok" "$(ok_if "$_e" MISSING)" \
    "[config-mask] $L 의 설정 소스를 못 찾았다($_src) — 열 번째 언어라면 이 표에 그 계약을 적어라"
  [ "$_e" = 0 ] || continue

  if [ "$L" = java ]; then
    # java 는 마스킹 훅이 없다 — 안전 근거가 **선언의 부재**다(`toString` 을 안 써서 `Object`
    # 의 `클래스@해시`가 나온다). 그래서 여기서는 **모양**을 잠근다.
    #
    # ⚠️ **모양 단언의 근거를 정정한다(실측 JDK 21, 2026-09-13).** 예전 문구는 「record 가 되면
    # 컴파일러 toString 이 clientSecret 을 찍는다」였는데 **거짓이다** — `clientSecret` 은
    # `char[]` 이고, record 의 toString 은 `Arrays.toString` 이 아니라 **배열 identity**
    # (`[C@7c41…`)를 찍는다. 즉 record 화만으로는 안 샌다.
    # ⚠️ 그렇다고 이 단언이 쓸모없지는 않다 — 진짜 위험은 **조합**이다(record + 비밀을 `String`
    # 으로 바꾸기). 모양 변화가 그 조합의 **보이는 절반**이라 여기서 잠근다.
    # ⚠️ **행위 자체는 여기서 안 본다** — `KeycloakConfigTest#toString_doesNotLeakClientSecret`
    # 과 `#builderToString_doesNotLeakClientSecret` 이 언어 로컬에서 본다(프로브 확인: 손으로 쓴
    # 누출 toString 을 그쪽이 잡는다. 모양 단언은 그것을 **못 잡는다**).
    _r=0; cm_java_record "$ROOT/$_src" && _r=1
    assert_eq "ok" "$(ok_if "$_r" IS-RECORD)" \
      "[config-mask] java KeycloakConfig 가 record 다 — 지금은 char[] 라 안 새지만, 비밀을 String 으로 바꾸는 순간 컴파일러 toString 이 원문을 찍는다. 마스킹 toString 을 손으로 덮거나 final class 로 되돌려라"
    _c=1; grep -qF -- 'final class KeycloakConfig' "$ROOT/$_src" && _c=0
    assert_eq "ok" "$(ok_if "$_c" MISSING)" \
      "[config-mask] java KeycloakConfig 의 선언 형태가 바뀌었다 — 이 축의 안전 근거가 무너졌는지 다시 판정하라"
    _seen=$((_seen + 1))
    continue
  fi

  _a="$(cm_anchor "$L")"
  _e=1; [ -n "$_a" ] && _e=0
  assert_eq "ok" "$(ok_if "$_e" NO-ANCHOR)" "[config-mask] $L 의 마스킹 앵커가 비었다 — 표가 낡았다"
  [ "$_e" = 0 ] || continue
  _h=1; cm_masks "$ROOT" "$L" && _h=0
  assert_eq "ok" "$(ok_if "$_h" MISSING)" \
    "[config-mask] $L 이 설정의 클라이언트 시크릿을 기본 표현에서 가리지 않는다($_src 에 '$_a' 없음) — 소비자가 기동 시 설정을 로깅하면 시크릿이 원문으로 남는다"
  _seen=$((_seen + 1))
done

# 공허 방어 — 루프가 실제로 파생된 언어 전부를 돌았는가. `_cm_langs` 가 비거나 경로 규칙이
# 바뀌면 어서션이 0건 실행되고 이 파일은 조용히 통과한다.
_want=$(printf '%s\n' $_cm_langs | grep -c .)
assert_eq "$_want" "$_seen" "[config-mask] 판정한 언어 수가 파생된 언어 수와 다르다"

# ⚠️ **음성 대조군 — 이 가드가 파일을 실제로 읽는가.** 위 단언은 「지금 앵커가 있다」만 본다.
# 그 형태는 **grep 이 무엇을 넣어도 참이면** 통과한다. 이 세션에서 같은 구멍을 두 번 냈다
# (#486·#487). 그래서 앵커를 지운 사본에서 **실패하는지**를 본다 — 위 루프와 **같은 `cm_masks`** 로,
# 앵커가 있는 언어 전부에서(예전엔 go 하나에 grep 을 다시 적어 판정 줄이 깨져도 초록이었다).
_nc="$(mktemp -d)"
trap 'rm -rf "$_nc"' EXIT
_nc_n=0
for L in $_cm_langs; do
  _src="$(cm_src "$L")"; _a="$(cm_anchor "$L")"
  [ -n "$_src" ] && [ -n "$_a" ] && [ -f "$ROOT/$_src" ] || continue
  mkdir -p "$_nc/$(dirname "$_src")"
  A="$_a" awk '{ while ((i = index($0, ENVIRON["A"])) > 0) $0 = substr($0, 1, i - 1) "UNMASKED" substr($0, i + length(ENVIRON["A"])) } { print }' \
    "$ROOT/$_src" > "$_nc/$_src"
  _nc_hit=1; cm_masks "$_nc" "$L" && _nc_hit=0
  assert_eq "1" "$_nc_hit" \
    "[config-mask·음성대조] $L 의 마스킹을 지운 사본에서도 앵커가 잡힌다 — 이 가드는 파일을 안 읽거나 앵커가 너무 느슨하다"
  _nc_n=$((_nc_n + 1))
done
# 공허 하한 — 앵커가 있는 언어 전부(파생 언어 중 java 만 빠진다)를 돌았는가.
assert_eq "$((_want - 1))" "$_nc_n" "[config-mask·음성대조] 앵커를 지운 사본으로 잰 언어 수가 모자란다"

# ⚠️ **java 부재 검사의 양성 대조** — 「record 가 아니다」는 라이브에서 늘 참이라, 판정이 깨져 영원히 「아니다」를
# 말해도 초록이었다(실측 2026-11-14 SILENT). record 로 바꾼 사본에서 **울어야** 한다.
_jsrc="$(cm_src java)"
mkdir -p "$_nc/$(dirname "$_jsrc")"
sed 's/final class KeycloakConfig/record KeycloakConfig/' "$ROOT/$_jsrc" > "$_nc/$_jsrc"
_jr=0; cm_java_record "$_nc/$_jsrc" && _jr=1
assert_eq "1" "$_jr" \
  "[config-mask·양성대조] record 로 바꾼 java 사본을 record 로 못 본다 — 부재 검사가 늘 「아니다」를 말한다"

assert_report
