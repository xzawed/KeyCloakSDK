#!/usr/bin/env sh
# Admin capability matrix의 U(update) 열 — 표 45셀 ↔ 아홉 언어 소스.
#
# 왜 U만인가: C/G/L 이름은 언어마다 갈린다(PHP `import`·`all`, Ruby `list`,
# Java `findByClientId`/`search`). 정규식이 문맥 없이 수렴하지 않아 225셀은
# 만들지 않는다. U는 `update`/`Update`/`UpdateAsync`/`update_<resource>`로
# 아홉이 모이고, 이번 세션에 실제로 드리프트한 축이다(README 거짓, PHP 0/5→5/5).
#
# 이 파일이 생긴 이유: 표가 권위였는데 자기는 무보호였다
# (`grep -rln "capability matrix\|C G L U D" scripts/` → 0).
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
ROOT="$DIR/../.."
GUARD="$DIR/../check-admin-capability.mjs"
DOC="$ROOT/docs/guides/getting-started.md"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 정상 트리: 표와 소스가 맞으면 통과해야 한다.
assert_ok node "$GUARD" "$ROOT"

# 가드가 실제로 45셀을 봤는지 — 추출이 0건으로 떨어져도 초록이 되는 공허를 막는다.
out="$(node "$GUARD" "$ROOT" 2>&1 || true)"
assert_contains "$out" "checked 45" "가드가 45셀을 봤다고 보고해야 한다"

# ---------------------------------------------------------------------------
# 표 변이는 복사본에서만 한다(원본을 만지지 않으면 복원 자체가 없다).
# ---------------------------------------------------------------------------
flip_u() { # $1=언어표시 $2=present|absent  $3=out
  node "$DIR/fixtures/admin-capability/flip-u.mjs" "$DOC" "$1" "$2" > "$3"
}

# (a) PHP users U 를 부재로 바꾸면 — 소스에는 update 가 있으므로 — 실패해야 한다.
flip_u "PHP" absent "$TMP/php-u-absent.md"
assert_fails node "$GUARD" "$ROOT" --doc="$TMP/php-u-absent.md"

# 반대 방향: Rust users U 를 존재로 바꾸면 — 소스에는 update_user 가 없으므로 — 실패.
flip_u "Rust" present "$TMP/rust-u-present.md"
assert_fails node "$GUARD" "$ROOT" --doc="$TMP/rust-u-present.md"

# 대조군: U가 아닌 C 열만 뒤집으면 이 가드는 통과해야 한다(스코프가 U뿐임을 고정).
node "$DIR/fixtures/admin-capability/flip-c.mjs" "$DOC" "Java" > "$TMP/java-c-absent.md"
assert_ok node "$GUARD" "$ROOT" --doc="$TMP/java-c-absent.md"

# 표를 지우면 침묵 통과가 아니라 실패해야 한다.
: > "$TMP/empty.md"
assert_fails node "$GUARD" "$ROOT" --doc="$TMP/empty.md"

# 언어 행이 빠지면 실패(9행 미만). Direct coverage 안의 행만 지운다 —
# 파일 앞쪽 런타임 표에도 `**PHP**` 가 있어 첫 히트를 지우면 변이가 공허하다.
node -e "
const fs = require('fs');
const t = fs.readFileSync(process.argv[1], 'utf8');
const start = t.indexOf('### Direct coverage');
if (start < 0) { console.error('no Direct coverage'); process.exit(2); }
const head = t.slice(0, start);
const rest = t.slice(start).replace(/^\| \*\*PHP\*\*.*$/m, '');
fs.writeFileSync(process.argv[2], head + rest);
" "$DOC" "$TMP/no-php.md"
assert_fails node "$GUARD" "$ROOT" --doc="$TMP/no-php.md"

assert_report
