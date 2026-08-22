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

assert_report
