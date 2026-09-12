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

ok_if() { if [ "$1" = 0 ]; then printf 'ok'; else printf '%s' "${2:-NOT-OK}"; fi; }

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
    # java 는 훅이 없다. 안전 근거가 「필드를 안 찍는 기본 toString」이므로 그 근거를 겨눈다.
    _r=0; grep -qE 'record[[:space:]]+KeycloakConfig' "$ROOT/$_src" && _r=1
    assert_eq "ok" "$(ok_if "$_r" IS-RECORD)" \
      "[config-mask] java KeycloakConfig 가 record 다 — 컴파일러 toString 이 clientSecret 을 찍는다. 마스킹 toString 을 손으로 덮거나 final class 로 되돌려라"
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
  _h=1; grep -qF -- "$_a" "$ROOT/$_src" && _h=0
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
# (#486·#487). 그래서 앵커를 지운 사본에서 **실패하는지**를 본다.
_nc="$(mktemp -d)"
mkdir -p "$_nc/$(dirname "$(cm_src go)")"
sed 's|mask(c.ClientSecret)|c.ClientSecret|' "$ROOT/$(cm_src go)" > "$_nc/$(cm_src go)"
_nc_hit=1; grep -qF -- "$(cm_anchor go)" "$_nc/$(cm_src go)" && _nc_hit=0
rm -rf "$_nc"
assert_eq "1" "$_nc_hit" \
  "[config-mask·음성대조] 마스킹을 지운 사본에서도 앵커가 잡힌다 — 이 가드는 파일을 안 읽거나 앵커가 너무 느슨하다"

assert_report
