#!/usr/bin/env sh
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
DOC="$DIR/../doctor.mjs"
ROOT="$(cd "$DIR/../.." && pwd)"

# 이 테스트는 "툴체인이 깔려 있는가"를 검사하지 않는다(러너마다 다르므로 그건
# 검사 불가능한 명제다). 검사하는 것은 **진단기 자신이 거짓말하지 않는가**다:
# 요구 버전을 빌드 파일에서 읽는가, 좌표가 깨졌을 때 통과가 아니라 실패하는가.

OUT="$(node "$DOC" --json)" || true
assert_contains "$OUT" '"ok"' 'JSON 출력에 ok 필드'

# ── 1. 요구 버전이 빌드 파일과 실제로 일치하는가 ─────────────────────────────
# 진단기에 숫자를 하드코딩하면 여기서 갈라진다. 빌드 파일에서 직접 뽑은 값과
# 진단기가 보고한 required를 대조한다.
req_of() { # tool -> required
  printf '%s' "$OUT" | node -e '
    let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
      const t=process.argv[1];
      const r=JSON.parse(s).results.find(x=>x.tool===t);
      process.stdout.write(String(r&&r.required));
    })' "$1"
}
assert_eq "$(grep -o '<maven.compiler.release>[0-9]*' "$ROOT/java/pom.xml" | head -1 | tr -dc '0-9')" \
  "$(req_of 'java (JDK)')" 'java 요구버전 = pom.xml maven.compiler.release'
assert_eq "$(grep -o 'rust-version = "[0-9.]*"' "$ROOT/rust/Cargo.toml" | head -1 | sed 's/[^0-9.]//g; s/\.$//')" \
  "$(req_of 'cargo')" 'cargo 요구버전 = Cargo.toml rust-version'
assert_eq "$(grep -o '"node": *">=[0-9.]*"' "$ROOT/node/package.json" | head -1 | sed 's/[^0-9.]//g; s/\.$//')" \
  "$(req_of 'node')" 'node 요구버전 = package.json engines.node'

# ── 2. 좌표가 깨지면 침묵 통과가 아니라 에러여야 한다 ────────────────────────
# 빌드 파일이 옮겨지거나 선언 형태가 바뀌면 진단기는 "요구 없음 = 통과"로
# 흘러가면 안 된다. 그건 정확히 가드가 죽는 방식이다.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/scripts" "$TMP/java"
cp "$DOC" "$TMP/scripts/doctor.mjs"
# java/pom.xml만 최소 런타임 선언 없이 만들어 두면 추출이 실패해야 한다.
printf '<project></project>\n' > "$TMP/java/pom.xml"
assert_fails node "$TMP/scripts/doctor.mjs" java

# ── 3. 알 수 없는 언어 인자는 조용히 무시되면 안 된다 ────────────────────────
assert_fails node "$DOC" nosuchlang

# ── 4. 언어 필터가 실제로 좁히는가(전체 결과보다 항목이 적어야 한다) ─────────
n_all="$(printf '%s' "$OUT" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(String(JSON.parse(s).results.length)))')"
n_one="$(node "$DOC" node --json | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(String(JSON.parse(s).results.length)))' || true)"
if [ "$n_one" -lt "$n_all" ]; then
  assert_eq 1 1 '언어 필터가 결과를 좁힌다'
else
  assert_eq "적음" "$n_one/$n_all" '언어 필터가 결과를 좁힌다'
fi

# ── 5. 규약 경로(KCSDK_*)와 **버전 오탐** ────────────────────────────────────
# 둘 다 실측된 결함이다:
#  (a) doctor 가 PATH 와 JAVA_HOME 만 봐서, 저장소 규약(`${KCSDK_TOOLS:-$HOME/tools}`·
#      `KCSDK_PY`·`KCSDK_JDK21`·`KCSDK_PHP`)대로 설치한 도구를 MISSING 으로 보고하고
#      "설치 방법"을 가리켰다 — 이미 가진 것을 다시 설치하게 만드는 오진이다.
#  (b) 그 규약 경로를 후보로 넣자 **경로에 박힌 숫자가 버전으로 읽혔다**. 실패 메시지가
#      호출 경로를 되뇌기 때문이다(`…/php-8.3/composer` → `composer 8.3 ok`).
#      MISSING 보다 나쁘다: 틀린 값이 초록으로 보고된다.
#
# ⚠️ 이 PC 의 설치 상태에 기대지 않는다 — "무엇이 있는가"가 아니라 **"없는 것을 있다고
# 하지 않는가"**를 본다.
T5="$(mktemp -d)"
trap 'rm -rf "$TMP" "$T5"' EXIT

# (b) 버전이 박힌 디렉터리 안의 실행 불가 파일 — 후보로는 잡히나 실행은 실패한다.
mkdir -p "$T5/tools/bogus-9.9"
: > "$T5/tools/bogus-9.9/go"
OUT5="$(KCSDK_TOOLS="$T5/tools" node "$DOC" go 2>&1 || true)"
assert_not_contains "$OUT5" "9.9" '경로에 박힌 버전이 도구 버전으로 보고되면 안 된다'

# 대조군 — 위 단언이 "9.9 는 어차피 안 나온다"로 공허해지지 않았는지. 같은 이름이
# **실제로 출력한** 버전은 보고돼야 한다.
mkdir -p "$T5/real/x"
printf '%s\n' '#!/bin/sh' 'echo "go version go9.9.0"' > "$T5/real/x/go"
chmod +x "$T5/real/x/go"
OUT5b="$(KCSDK_TOOLS="$T5/real" node "$DOC" go 2>&1 || true)"
assert_contains "$OUT5b" "9.9" '규약 경로의 도구가 실제로 출력한 버전은 보고돼야 한다'

# (a) 규약 디렉터리가 비었거나 없어도 PATH 폴백으로 진단은 계속된다(죽지 않는다).
mkdir -p "$T5/empty"
OUT5c="$(KCSDK_TOOLS="$T5/empty" node "$DOC" node 2>&1 || true)"
assert_contains "$OUT5c" "node" '빈 규약 디렉터리에서도 PATH 폴백으로 진단은 계속돼야 한다'
OUT5d="$(KCSDK_TOOLS="$T5/does-not-exist" node "$DOC" node 2>&1 || true)"
assert_contains "$OUT5d" "node" '없는 규약 디렉터리는 조용히 무시하고 PATH 로 넘어가야 한다'

# ── 6. shim 이 **형제를 맨 이름으로** 부르는 경우 ────────────────────────────
# 실측된 결함(2026-09-22): 이 저장소의 `composer` 는 `exec php "$(dirname "$0")/composer.phar"`
# 인 POSIX shim 이고, 그 `php` 는 문서가 시키는 `export PATH="$KCSDK_PHP:$PATH"` 를 했을
# 때만 풀린다. 그 export 없이 doctor 를 돌리면 shim 이 죽어 **설치돼 있는 composer 가
# MISSING** 으로 보고됐다(`::error::` + exit 1). doctor 의 존재 이유가 「환경 export 없이도
# 이 PC 에 무엇이 있는지 말한다」이므로, 후보를 부를 때 그 디렉터리를 PATH 앞에 둔다.
mkdir -p "$T5/shim/xyz"
printf '%s\n' '#!/bin/sh' 'exec sibling "$@"' > "$T5/shim/xyz/go"
printf '%s\n' '#!/bin/sh' 'echo "go version go9.9.9"' > "$T5/shim/xyz/sibling"
chmod +x "$T5/shim/xyz/go" "$T5/shim/xyz/sibling"
OUT6="$(KCSDK_TOOLS="$T5/shim" node "$DOC" go 2>&1 || true)"
assert_contains "$OUT6" "9.9.9" 'shim 이 형제를 맨 이름으로 불러도 잡혀야 한다(자기 디렉터리가 PATH 앞)'

# 음성 대조 — 「shim 은 어차피 통과한다」로 공허해지지 않았는가. 형제가 **없으면** 잡히면 안 된다.
mkdir -p "$T5/noshim/xyz"
printf '%s\n' '#!/bin/sh' 'exec nothing-here "$@"' > "$T5/noshim/xyz/go"
chmod +x "$T5/noshim/xyz/go"
OUT6b="$(KCSDK_TOOLS="$T5/noshim" node "$DOC" go 2>&1 || true)"
assert_not_contains "$OUT6b" "9.9.9" '형제가 없는 shim 이 버전을 보고하면 안 된다'

# ── 7. 요구를 **만족하는** 후보를 끝까지 찾는가 ─────────────────────────────
# 실측된 결함(2026-09-22): `evaluate` 가 첫 성공에서 `break` 해서, JAVA_HOME 이 17 을
# 가리키면 이 PC 에 실재하는 JDK 21 을 **보지도 않고** `TOO OLD` 라며 설치 가이드를
# 가리켰다 — 이미 가진 것을 또 설치하라는 오진이다.
# ⚠️ 디렉터리 이름으로 순서를 고정한다(`aaa` 가 먼저 훑힌다) — 낡은 것이 먼저 잡혀도
# 만족하는 뒤쪽이 이겨야 한다는 것이 이 단언의 요지다.
T7a="$T5/pref"
mkdir -p "$T7a/aaa" "$T7a/zzz"
printf '%s\n' '#!/bin/sh' 'echo "go version go1.0.0"' > "$T7a/aaa/go"
printf '%s\n' '#!/bin/sh' 'echo "go version go99.0.0"' > "$T7a/zzz/go"
chmod +x "$T7a/aaa/go" "$T7a/zzz/go"
OUT7="$(KCSDK_TOOLS="$T7a" node "$DOC" go 2>&1 || true)"
assert_contains "$OUT7" "99.0.0" '요구를 만족하는 후보가 낡은 것을 이겨야 한다'
# 짝 단언 — 위가 「99 가 어디선가 보인다」로 공허해지지 않게, **낡은 값에 눌러앉지
# 않았는지**를 같이 본다. 이것이 실제 결함의 모양이다(첫 성공에서 멈춰 17 을 보고).
# ⚠️ 환경·순서에 기대지 않는다: readdir 순서는 OS 마다 다르고(NTFS 는 사전순, ext4 는
# 해시순) PATH 에 진짜 go 가 있을 수도 없을 수도 있다. 두 단언 다 그 어느 쪽에도 안 걸린다.
assert_not_contains "$OUT7" "1.0.0" '낡은 후보에 눌러앉아 보고하면 안 된다'

assert_report
