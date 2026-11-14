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
mkdir -p "$TMP/scripts/lib" "$TMP/java"
cp "$DOC" "$TMP/scripts/doctor.mjs"
# ⚠️ doctor.mjs 가 import 하는 모듈도 함께 옮긴다 — 빠지면 아래 실패가 **모듈을 못 찾아서** 나고,
# 단언은 「추출 실패를 실패로 낸다」가 아니라 「import 가 깨졌다」를 재며 초록으로 남는다.
cp "$DIR/../lib/dotnet-tfm.mjs" "$TMP/scripts/lib/dotnet-tfm.mjs"
# java/pom.xml만 최소 런타임 선언 없이 만들어 두면 추출이 실패해야 한다.
printf '<project></project>\n' > "$TMP/java/pom.xml"
assert_fails node "$TMP/scripts/doctor.mjs" java
OUT2="$(node "$TMP/scripts/doctor.mjs" java 2>&1 || true)"
assert_contains "$OUT2" "찾지 못함" '실패 사유가 추출 실패다(모듈 누락 같은 다른 이유가 아니다)'

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
# ⚠️ 판정은 **go 줄**에서 하고 표식은 실제 도구 판과 겹치지 않는 값(97.531)이다. 출력 전체에서 「9.9」를 찾던
# 판은 docker 29.9.2 인 PC 에서 음성 단언이 거짓 실패하고 양성 대조군이 go 판 없이도 통과했다(실측 2026-10-27 —
# 출력의 [공통] 칸이 이 PC 의 실제 도구 판을 찍는다).
go_line() { printf '%s\n' "$1" | grep -E '^[[:space:]]+go[[:space:]]' | head -1; }

# (b) 버전이 박힌 디렉터리 안의 실행 불가 파일 — 후보로는 잡히나 실행은 실패한다.
mkdir -p "$T5/tools/bogus-97.531"
: > "$T5/tools/bogus-97.531/go"
OUT5="$(KCSDK_TOOLS="$T5/tools" node "$DOC" go 2>&1 || true)"
assert_contains "$(go_line "$OUT5")" "go" 'go 줄이 있어야 아래 음성 단언이 뜻을 갖는다'
assert_not_contains "$(go_line "$OUT5")" "97.531" '경로에 박힌 버전이 도구 버전으로 보고되면 안 된다'

# 대조군 — 위 단언이 "97.531 은 어차피 안 나온다"로 공허해지지 않았는지. 같은 이름이
# **실제로 출력한** 버전은 보고돼야 한다.
mkdir -p "$T5/real/x"
printf '%s\n' '#!/bin/sh' 'echo "go version go97.531.0"' > "$T5/real/x/go"
chmod +x "$T5/real/x/go"
OUT5b="$(KCSDK_TOOLS="$T5/real" node "$DOC" go 2>&1 || true)"
assert_contains "$(go_line "$OUT5b")" "97.531" '규약 경로의 도구가 실제로 출력한 버전은 보고돼야 한다'

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
printf '%s\n' '#!/bin/sh' 'echo "go version go97.531.9"' > "$T5/shim/xyz/sibling"
chmod +x "$T5/shim/xyz/go" "$T5/shim/xyz/sibling"
OUT6="$(KCSDK_TOOLS="$T5/shim" node "$DOC" go 2>&1 || true)"
assert_contains "$(go_line "$OUT6")" "97.531.9" 'shim 이 형제를 맨 이름으로 불러도 잡혀야 한다(자기 디렉터리가 PATH 앞)'

# 음성 대조 — 「shim 은 어차피 통과한다」로 공허해지지 않았는가. 형제가 **없으면** 잡히면 안 된다.
mkdir -p "$T5/noshim/xyz"
printf '%s\n' '#!/bin/sh' 'exec nothing-here "$@"' > "$T5/noshim/xyz/go"
chmod +x "$T5/noshim/xyz/go"
OUT6b="$(KCSDK_TOOLS="$T5/noshim" node "$DOC" go 2>&1 || true)"
assert_contains "$(go_line "$OUT6b")" "go" 'go 줄이 있어야 아래 음성 단언이 뜻을 갖는다'
assert_not_contains "$(go_line "$OUT6b")" "97.531.9" '형제가 없는 shim 이 버전을 보고하면 안 된다'

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

# ── 8. dotnet 여러 대상 — 요구 SDK 는 **가장 높은** TFM 이다 ─────────────────────
# `<TargetFrameworks>net8.0;net10.0</TargetFrameworks>` 는 SDK 8 로 복원조차 안 된다(NETSDK1045) — 그래서
# 진단기가 요구하는 SDK 는 가장 높은 대상이다(소비자 하한 = 가장 낮은 대상은 check-docs 의 몫이다).
# 선언 순서로 고르면 한 순서에서, 문자열 정렬(「net10.0」<「net8.0」)로 고르면 다른 순서에서 갈라진다.
T8="$(mktemp -d)"
trap 'rm -rf "$TMP" "$T5" "$T8"' EXIT
mkdir -p "$T8/scripts/lib"
cp "$DOC" "$T8/scripts/doctor.mjs"
cp "$DIR/../lib/dotnet-tfm.mjs" "$T8/scripts/lib/dotnet-tfm.mjs"
# ⚠️ 진단기는 언어 필터와 무관하게 **모든** 언어의 선언을 먼저 읽는다 — 하나라도 없으면 dotnet 에 닿기 전에
# 「빌드 파일 없음」으로 멈춘다. 그래서 읽는 파일 전부를 실제 트리에서 옮겨 두고 dotnet 것만 바꾼다.
for f in $(grep -oE "req\('[^']+'" "$DOC" | sed -E "s/^req\('//; s/'$//" | sort -u); do
  mkdir -p "$T8/$(dirname "$f")" && cp "$ROOT/$f" "$T8/$f"
done
dotnet_req() {
  node "$T8/scripts/doctor.mjs" dotnet --json 2>/dev/null | node -e '
    let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
      const r=JSON.parse(s).results.find(x=>x.tool==="dotnet (SDK)");
      process.stdout.write(String(r&&r.required));
    })'
}
for tfms in 'net10.0;net8.0' 'net8.0;net10.0'; do
  printf '%s\n' "<Project><PropertyGroup><TargetFrameworks>$tfms</TargetFrameworks></PropertyGroup></Project>" > "$T8/dotnet/Directory.Build.props"
  assert_eq '10.0' "$(dotnet_req)" "dotnet 요구 SDK = 가장 높은 대상 ($tfms)"
done
printf '%s\n' '<Project><PropertyGroup><TargetFramework>net8.0</TargetFramework></PropertyGroup></Project>' > "$T8/dotnet/Directory.Build.props"
assert_eq '8.0' "$(dotnet_req)" 'dotnet 요구 SDK = 단수 대상'
# 선언이 없으면 「요구 없음 = 통과」가 아니라 실패다(2절과 같은 이유).
printf '%s\n' '<Project><PropertyGroup></PropertyGroup></Project>' > "$T8/dotnet/Directory.Build.props"
assert_fails node "$T8/scripts/doctor.mjs" dotnet
OUT8="$(node "$T8/scripts/doctor.mjs" dotnet 2>&1 || true)"
assert_contains "$OUT8" "찾지 못함" 'dotnet 대상 선언이 없으면 추출 실패로 보고한다'

# ── 9. 규약 변수의 SSOT — 규칙 · 문서 · 진단기가 부르는 KCSDK_* 는 전부 가이드의 표에 행이 있다 ──────
# 등록부 docs-kcsdk-env-ssot: CLAUDE.md 는 「설치 · 환경변수 규약은 development-setup.md」라 가리키는데 그 표에는
# 셋(KCSDK_TOOLS · KCSDK_JDK21 · KCSDK_PY)만 있었고, php.md 가 쓰는 KCSDK_PHP · KCSDK_OPENSSL_CNF 는 규칙 파일에만
# 있었다(실측 2026-11-14). 스크립트 내부 변수(KCSDK_ITCOV_*)는 규약이 아니라 뺀다.
GUIDE9="$ROOT/docs/guides/development-setup.md"
_used9() { # $1 = 가이드 — 규칙 · CLAUDE.md · 가이드 · doctor.mjs 가 부르는 이름
  cat "$ROOT"/.claude/rules/*.md "$ROOT/CLAUDE.md" "$1" "$DOC" \
    | grep -oE 'KCSDK_[A-Z0-9_]+' | grep -v '^KCSDK_ITCOV_' | sort -u
}
_rows9() { # $1 = 가이드 — 표의 행 머리(`| `KCSDK_X` |`)
  grep -oE '^\| `KCSDK_[A-Z0-9_]+`' "$1" | grep -oE 'KCSDK_[A-Z0-9_]+' | sort -u
}
_missing9() { # $1 = 가이드 — 표에 행이 없는 이름(공백으로 이음)
  _rows="$(_rows9 "$1")"
  _used9 "$1" | while IFS= read -r v; do
    printf '%s\n' "$_rows" | grep -qxF -- "$v" || printf '%s ' "$v"
  done
}
# 공허 하한 — 추출이 깨지면 두 집합이 다 비어 조용히 통과한다. ⚠️ 세어서 박는다: 실측 5(2026-11-14).
_n9="$(_used9 "$GUIDE9" | grep -c . || true)"
_short=1; [ "$_n9" -ge 5 ] && _short=0
assert_eq "ok" "$(ok_if "$_short" "$_n9")" "[KCSDK] 부르는 규약 변수를 5개 미만 찾았다($_n9) — 추출이 깨졌나?"
assert_eq "" "$(_missing9 "$GUIDE9")" "[KCSDK] development-setup.md 의 표에 행이 없는 규약 변수 — 표에 더하라"
# 음성 대조 — 표에서 한 행을 빼면 울어야 한다(대조가 공허하지 않다는 증거).
grep -v '^| `KCSDK_PY`' "$GUIDE9" > "$T5/guide9.md"
assert_eq "KCSDK_PY " "$(_missing9 "$T5/guide9.md")" "[KCSDK·음성대조] 표에서 KCSDK_PY 행을 빼도 검출기가 침묵했다"

assert_report
