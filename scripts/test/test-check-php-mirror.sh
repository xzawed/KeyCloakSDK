#!/usr/bin/env sh
# check-php-mirror.sh 의 자가테스트 — **네트워크 없이** 실물 스크립트를 그대로 태운다.
#
# ⚠️ 판정 로직을 이 파일에 베끼지 않는다. `test-release-readiness.sh` 가 실제로 그 함정에
# 빠져 스크립트의 분기를 지워도 통과한 적이 있다. 여기서는 `git`·`curl` 을 **PATH 스텁**으로
# 갈아끼워 네 갈래를 만들고 진짜 스크립트를 실행한다 — 네트워크는 한 번도 타지 않는다.
#
# 검사의 요지는 값이 아니라 **세 상태가 종료코드로 어떻게 접히는가**다:
#   확인됨(0) → exit 0 · 확인된 불일치(1) → exit 1 · 확인 불가(2) → **exit 0**
# ⚠️ 마지막 줄이 이 저장소의 다른 규칙과 **반대**라는 점이 요지다. readiness 는 사람이 보는
# 도구라 "모른다"를 "안전하다"로 반올림하지 않는다. 이 CI 검사는 문을 막는 자동화라 반대로
# 관대해야 한다 — 그러지 않으면 Packagist 장애가 저장소 머지를 막는다. 그 비대칭을 고정한다.
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
SH="$DIR/../check-php-mirror.sh"

assert_ok test -x "$SH"
assert_ok sh -n "$SH"

STUB="$(mktemp -d)"
FX="$(mktemp -d)"
trap 'rm -rf "$STUB" "$FX"' EXIT

_mkstub() { # <name> <exit> <stdout>
  printf '#!/bin/sh\nprintf %s "%s"\nexit %s\n' "'%s'" "$3" "$2" > "$STUB/$1"
  chmod +x "$STUB/$1"
}
_run() { # → "<exit>|<출력 한 줄>"
  _o="$(PATH="$STUB:$PATH" sh "$SH" 0.2.0 2>&1)" && _c=0 || _c=$?
  printf '%s|%s' "$_c" "$(printf '%s' "$_o" | tr '\n' ',')"
}

# (1) 전부 확인됨 — git 이 태그 줄을 내고, curl 이 미러 이름과 그 버전을 담은 본문을 낸다
# (p2 본문의 실제 모양: `"version":"v1.5.2"` — 실측 2026-11-14).
_P2_OK='{"packages":{"xzawed/keycloak-sdk":[{"version":"v0.2.0","source":{"url":"https://github.com/xzawed/keycloak-sdk-php.git"}}]}}'
_mkstub git 0 'abc123	refs/tags/v0.2.0'
_mkstub curl 0 "$_P2_OK"
assert_contains "$(_run)" "0|" '전부 확인되면 exit 0'
assert_contains "$(_run)" "✅ 미러에 v0.2.0 태그가 있다" '미러 확인 문구'
assert_contains "$(_run)" "✅ Packagist 가 v0.2.0 을 서빙한다" 'Packagist 버전 확인 문구'

# (2) 미러에 태그 없음 — git 이 성공하되 **빈 출력**(ls-remote 가 매치 없을 때의 실제 모양).
_mkstub git 0 ''
assert_contains "$(_run)" "1|" '미러에 태그가 없으면 exit 1(확인된 불일치)'
assert_contains "$(_run)" "::error::미러에 v0.2.0 태그가 없다" '그 이유를 말한다'

# (3) Packagist 가 다른 소스 — 본문에 미러 이름이 없다.
_mkstub git 0 'abc123	refs/tags/v0.2.0'
_mkstub curl 0 '{"packages":{"xzawed/keycloak-sdk":[{"source":{"url":"https://example.invalid/other.git"}}]}}'
assert_contains "$(_run)" "1|" 'Packagist 소스가 다르면 exit 1'
assert_contains "$(_run)" "::error::Packagist" '그 이유를 말한다'

# (4) 확인 불가 — 두 도구가 비정상 종료(네트워크 장애·미설치와 같은 모양).
_mkstub git 127 ''
_mkstub curl 127 ''
assert_contains "$(_run)" "0|" '⚠️ 조회 실패는 exit 0 — 바깥 장애가 머지를 막지 않는다'
assert_contains "$(_run)" "실패로 치지 않는다" '확인 불가를 명시한다'
assert_not_contains "$(_run)" "::error::" '확인 불가를 오류로 지어내지 않는다'

# (5) Packagist 가 미러를 서빙하지만 그 버전은 없다 — 미러가 갔는데 Packagist 가 집어 가지 않았다
# (자동 갱신이 끊겼거나, split 직후라 아직이다). 사람이 페이지를 보던 확인을 기계로 옮긴 자리다.
_mkstub git 0 'abc123	refs/tags/v0.2.0'
_mkstub curl 0 '{"packages":{"xzawed/keycloak-sdk":[{"version":"v0.1.9","source":{"url":"https://github.com/xzawed/keycloak-sdk-php.git"}}]}}'
assert_contains "$(_run)" "1|" 'Packagist 에 그 버전이 없으면 exit 1'
assert_contains "$(_run)" "::error::Packagist 에 v0.2.0 이 없다" '그 이유를 말한다'
assert_not_contains "$(_run)" "::error::Packagist 가 이 미러를" '소스는 맞다 — 소스 오류로 지어내지 않는다'

# (6) **CI 의 실제 호출 형태 — 인자 없이**(repo-hygiene `php-mirror` 잡). 위 다섯은 전부 버전을
# 명시해 이 경로를 한 번도 타지 않았다. 그 사이 무인자 기본값이 `df_published_version` 이었고,
# 그 값은 태그 **전** 커밋에서 움직이므로(DEPLOY.md §4 1단계) php 릴리스 PR 마다 「미러에
# v<새 버전> 이 없다」로 빨갰다(실측: #937 · #938 의 php-mirror 잡). 그 상태를 그대로 만든다 —
# SSOT 는 9.9.9 로 움직였고 기준선은 아직 직전 게시본 1.2.3 이다.
mkdir -p "$FX/lib"
cp "$SH" "$DIR/../release-readiness.sh" "$FX/"
cp "$DIR/../lib/deploy-facts.sh" "$FX/lib/"
cat >> "$FX/lib/deploy-facts.sh" <<'EOF'
df_published_version() { case "$1" in php) echo "9.9.9" ;; *) echo "" ;; esac; }
df_api_baseline() { case "$1" in php) echo "php-v1.2.3" ;; *) echo "" ;; esac; }
EOF
cat > "$STUB/git" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$STUB_LOG"
for a in "$@"; do last="$a"; done
[ "$last" = "refs/tags/v1.2.3" ] && printf 'abc123\trefs/tags/v1.2.3\n'
exit 0
EOF
chmod +x "$STUB/git"
_mkstub curl 0 '{"packages":{"xzawed/keycloak-sdk":[{"version":"v1.2.3","source":{"url":"https://github.com/xzawed/keycloak-sdk-php.git"}}]}}'
_LOG="$FX/git.log"
_o6="$(PATH="$STUB:$PATH" STUB_LOG="$_LOG" sh "$FX/check-php-mirror.sh" 2>&1)" && _c6=0 || _c6=$?
assert_eq "0" "$_c6" '무인자 + 릴리스 PR 상태 → exit 0(직전 게시본이 미러에 있다)'
assert_contains "$_o6" "✅ 미러에 v1.2.3 태그가 있다" '무인자 기본값은 기준선(직전 게시본)이다'
assert_contains "$(cat "$_LOG")" "refs/tags/v1.2.3" '스텁이 실제로 불렸다(공허 통과 대조)'
assert_not_contains "$(cat "$_LOG")" "v9.9.9" '태그 전에 움직이는 SSOT 버전을 미러에서 찾지 않는다'

# 소스 대조 — 두 번째 정의 자리를 만들지 않았는가.
_body="$(cat "$SH")"
assert_contains "$_body" 'rr_mirror_tag'       '판정을 release-readiness 의 프로브로 위임한다'
assert_contains "$_body" 'rr_packagist_source' '같음'
assert_contains "$_body" 'rr_packagist_version' '같음'
assert_contains "$_body" 'rr_php_last_published' '기본 버전도 release-readiness 의 한 정의를 쓴다'
assert_eq "0" "$(printf '%s' "$_body" | grep -cE '^[[:space:]]*(curl|git)[[:space:]]' || true)" \
  '이 스크립트가 curl·git 을 직접 부르지 않는다'

assert_report
