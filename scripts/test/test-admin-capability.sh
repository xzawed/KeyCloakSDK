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
DOC="$ROOT/docs/reference/admin-capability.md"
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

# (b) 반대 방향: 표가 present 인데 소스에 선언이 없으면 실패해야 한다.
#
# ⚠️ 예전엔 "Rust U를 present로 뒤집는다"로 이 방향을 냈다. Rust가 25/25가 되면서
# 그 변이는 더 이상 거짓이 아니게 됐고 이 케이스가 조용히 공허해졌다(CI가 잡았다).
# 아홉이 전부 25/25인 지금 이 방향은 **소스를 건드려야만** 표현된다 — 그래서 소스를
# 임시 트리에 복제하고 거기서 선언을 지운다. 원본 트리는 만지지 않는다.
#
# 경로 목록은 가드가 스스로 낸다(--print-sources). 여기 손으로 적으면 2차 정의 자리가
# 생겨, 소스가 옮겨갔을 때 테스트만 낡는다.
FAKE="$TMP/root"
node "$GUARD" "$ROOT" --print-sources | while IFS= read -r rel; do
  mkdir -p "$FAKE/$(dirname "$rel")"
  cp "$ROOT/$rel" "$FAKE/$rel"
done

# 대조군: 복제 자체는 변이가 아니다 — 손대지 않은 복제본은 통과해야 한다.
# (이게 없으면 아래 실패가 "선언을 지워서"인지 "복제가 깨져서"인지 구분되지 않는다.)
assert_ok node "$GUARD" "$FAKE" --doc="$DOC"

# rust의 update_user 선언만 지운다 → Rust users.U 는 표=present, 소스=absent.
sed -i.bak 's/pub async fn update_user/pub async fn update_user_REMOVED_BY_TEST/' \
  "$FAKE/rust/src/admin.rs"
rm -f "$FAKE/rust/src/admin.rs.bak"
assert_fails node "$GUARD" "$FAKE" --doc="$DOC"

# 대조군: U가 아닌 C 열만 뒤집으면 이 가드는 통과해야 한다(스코프가 U뿐임을 고정).
node "$DIR/fixtures/admin-capability/flip-c.mjs" "$DOC" "Java" > "$TMP/java-c-absent.md"
assert_ok node "$GUARD" "$ROOT" --doc="$TMP/java-c-absent.md"

# 표를 지우면 침묵 통과가 아니라 실패해야 한다.
: > "$TMP/empty.md"
assert_fails node "$GUARD" "$ROOT" --doc="$TMP/empty.md"

# 언어 행이 빠지면 실패(9행 미만). Direct coverage 안의 행만 지운다.
# ⚠️ 이 슬라이싱은 표가 `getting-started.md` 안에 있던 시절의 유산이 아니다 — 그때는 파일
# 앞쪽 런타임 표에도 `**PHP**` 가 있어 첫 히트를 지우면 변이가 공허했다. 표를 전용 파일로
# 옮긴 지금도 유지하는 이유는, 같은 파일에 두 번째 `**PHP**` 행이 생기는 순간 변이가 다시
# 공허해지기 때문이다(조준을 위치가 아니라 구조에 건다).
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
