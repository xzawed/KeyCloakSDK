#!/usr/bin/env sh
# 루트 README(영·한)가 §4 계약을 코드와 다르게 말하지 않는가 — 두 문장을 원천에서 파생해 대조한다.
#
# (1) **파사드 은닉의 예외.** README 는 「하위 라이브러리 타입은 파사드 뒤 — 예외는 넷」을 적는다. 예외의
#     원천은 `rust/src/lib.rs` 의 foreign 재노출이다(`cargo test --test reexport_surface` 가 컴파일로 고정한다).
#     `keycloak` 크레이트 재노출(representation · `raw()` 와 그 오류)은 README 가 「admin representations and
#     `raw()`」로 적는 둘이라 빼고, **그 밖의 foreign 재노출은 예외 문장이 이름으로 적어야 한다.** 예전 문장은
#     「인증 경로 타입은 파사드 뒤 · 예외는 representation 과 raw()」뿐이라 Rust 의 둘(`reqwest` · `Jwk`)이 빠져
#     거짓이었다(readme-mirror-contract). 로컬 모듈 목록도 손으로 적지 않고 lib.rs 의 `pub mod` 에서 읽는다.
# (2) **nonce 생략.** 예전 문장은 「아홉 모두, 생략하면 id_token 검증을 건너뛴다」였다 — node 는 openid-client
#     (oauth4webapi)가 nonce 를 실은 id_token 을 거부해 교환이 실패한다. 근거는 진짜 openid-client 를 태우는 node
#     시험이고, README 의 그 문장이 node 를 따로 적는지와 그 시험이 아직 있는지를 함께 본다.
#
# ⚠️ 끝에 음성 대조가 있다 — README 에서 `Jwk` 를 지운 사본으로 이 파일을 자식으로 돌려 실패해야 한다.
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
ROOT="${RC_ROOT:-$DIR/../..}"
EN="$ROOT/README.md"
KO="$ROOT/README.ko.md"
LIB="$ROOT/rust/src/lib.rs"
NODE_T="$ROOT/node/test/unit/auth-id-token-signature.test.ts"

# ── (1) 파사드 은닉의 예외 ────────────────────────────────────────────────
_mods="$(sed -n 's/^pub mod \([a-z_][a-z0-9_]*\);.*/\1/p' "$LIB" | tr '\n' ' ')"
assert_eq "ok" "$([ -n "$_mods" ] && echo ok || echo EMPTY)" "[README 계약] lib.rs 에서 pub mod 를 못 읽었다 — 대조가 공허해진다"

_foreign_names() { # lib.rs 줄 머리 `pub use …;` 중 로컬 모듈 · keycloak 이 아닌 것의 이름(한 줄에 하나)
  sed -n 's/^pub use \(.*\);[[:space:]]*$/\1/p' "$LIB" | while IFS= read -r _p; do
    _crate="${_p%%::*}"
    case " $_mods keycloak " in *" $_crate "*) continue ;; esac
    _rest="${_p#*::}"
    if [ "$_rest" = "$_p" ]; then printf '%s\n' "$_crate"; continue; fi   # 크레이트 전체 재노출
    _rest="${_rest% as *}"
    case "$_rest" in
      *'{'*) printf '%s\n' "${_rest#*\{}" | tr -d '}' | tr ',' '\n' | sed 's/^ *//; s/ *$//; s/.*:://' ;;
      *) printf '%s\n' "${_rest##*::}" ;;
    esac
  done
}
_names="$(_foreign_names)"
assert_eq "ok" "$([ -n "$_names" ] && echo ok || echo EMPTY)" \
  "[README 계약] lib.rs 의 foreign 재노출이 0 이다 — 파서가 빗나갔거나 재노출이 사라졌다"

_en_line="$(grep -m1 'behind the facade' "$EN" || true)"
_ko_line="$(grep -m1 '파사드 뒤' "$KO" || true)"
assert_eq "ok" "$([ -n "$_en_line" ] && [ -n "$_ko_line" ] && echo ok || echo MISSING)" \
  "[README 계약] 영·한 README 에서 파사드 은닉 문장을 못 찾았다(영 'behind the facade' · 한 '파사드 뒤')"
# 이름은 코드 스팬 경계까지 본다 — `` `Jwk` `` 이거나 `` `reqwest::…` `` 의 머리. 맨 부분 문자열이면 `JwkSet` 안의
# `Jwk` 에 맞는다(아래 음성 대조가 처음에 그렇게 통과해 이 경계가 생겼다).
_names_in() { # <줄> <이름> → ok | MISSING
  case "$1" in *"\`$2\`"* | *"\`$2::"*) echo ok ;; *) echo MISSING ;; esac
}
for _n in $_names; do
  assert_eq "ok" "$(_names_in "$_en_line" "$_n")" "[README 계약] README.md 의 은닉 예외 문장이 Rust 재노출 \`$_n\` 을 적지 않는다"
  assert_eq "ok" "$(_names_in "$_ko_line" "$_n")" "[README 계약] README.ko.md 의 은닉 예외 문장이 Rust 재노출 \`$_n\` 을 적지 않는다"
done

# ── (2) nonce 생략 ─────────────────────────────────────────────────────────
_en_nonce="$(grep -m1 'nonce on the authorization request' "$EN" || true)"
_ko_nonce="$(grep -m1 'nonce를 발급' "$KO" || true)"
assert_contains "$_en_nonce" "Node" "[README 계약] README.md 의 nonce 생략 문장이 node 의 거부를 따로 적지 않는다"
assert_contains "$_ko_nonce" "Node" "[README 계약] README.ko.md 의 nonce 생략 문장이 node 의 거부를 따로 적지 않는다"
_nt="$(cat "$NODE_T" 2>/dev/null || true)"
assert_contains "$_nt" "nonce 를 넘기지 않으면 nonce 를 실은 id_token 의 교환을 openid-client 가 거부한다" \
  "[README 계약] 그 문장의 근거인 node 시험이 없다"
assert_contains "$_nt" 'unexpected ID Token "nonce" claim value' "[README 계약] 근거 시험이 openid-client 의 거부 문구를 단언하지 않는다"

# ── 음성 대조 — 이 검사가 실제로 무는가 ──────────────────────────────────
if [ -z "${RC_NEGATIVE:-}" ]; then
  _fx="$(mktemp -d)"
  trap 'rm -rf "$_fx"' EXIT
  mkdir -p "$_fx/rust/src" "$_fx/node/test/unit"
  cp "$LIB" "$_fx/rust/src/lib.rs"
  cp "$NODE_T" "$_fx/node/test/unit/"
  cp "$KO" "$_fx/README.ko.md"
  sed 's/`Jwk`/`JwkSet`/g; s/Jwk /JwkSet /g' "$EN" > "$_fx/README.md"   # README.md 에서만 이름 하나를 흐린다
  if RC_NEGATIVE=1 RC_ROOT="$_fx" sh "$0" >/dev/null 2>&1; then _neg=PASSED; else _neg=FAILED; fi
  assert_eq "FAILED" "$_neg" "[README 계약] 음성 대조: README.md 에서 Jwk 를 흐린 사본이 통과했다 — 이 검사가 공허하다"
fi

assert_report
