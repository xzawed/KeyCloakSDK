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

assert_report
