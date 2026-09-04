#!/usr/bin/env sh
# JVM 바이트코드 하한 가드의 자가테스트.
#
# 이 가드가 막는 사고: 두 JVM 레인은 **JDK 21 로 빌드하고 17 을 방출**한다(java `release=17`,
# kotlin `jvmTarget=17` + `-Xjdk-release=17`). 그 설정 중 하나만 빠져도 빌드는 성공하고 CI 도
# 초록인데 major 65 짜리 jar 가 나가서 **JDK 17 소비자만** 죽는다. CI 가 21 에서 도는 한 그
# 사고는 CI 에 보이지 않으므로, 산출물의 클래스파일 버전을 직접 읽는 것만이 잡는다.
#
# 그래서 테스트의 무게는 「통과한다」가 아니라 **「위반을 실제로 잡는가」와 「0개를 훑고
# 통과하지 않는가」**에 있다. 픽스처는 클래스파일 헤더(CAFEBABE + minor + major)만 담는다 —
# 가드가 읽는 것이 정확히 그 두 바이트다.
#
# ⚠️ 픽스처를 **커밋하지 않고 런타임에 만든다.** 저장소의 `.gitignore:3` 이 `*.class` 를 막고
# 있어서, 커밋해 두면 로컬에서만 통과하고 CI 에서는 파일이 없어 실패한다(실측으로 걸렸다).
# 헤더만 있으면 되는 이유는 가드가 읽는 것이 바이트 6~7(major) 뿐이기 때문이다.
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
GUARD="$DIR/../check-jvm-bytecode-floor.mjs"

FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT
node -e '
const fs=require("fs"),path=require("path");
const R=process.argv[1];
// 최소 클래스파일 헤더: CAFEBABE(4) + minor(2) + major(2).
const cls=(m)=>{const b=Buffer.alloc(10);b.writeUInt32BE(0xCAFEBABE,0);b.writeUInt16BE(0,4);b.writeUInt16BE(m,6);return b;};
const w=(rel,buf)=>{const p=path.join(R,rel);fs.mkdirSync(path.dirname(p),{recursive:true});fs.writeFileSync(p,buf);};
for(const n of ["A","B","C"]) w("ok/io/x/"+n+".class", cls(61));           // 전부 Java 17
for(const n of ["A","B"])     w("mixed/io/x/"+n+".class", cls(61));
w("mixed/io/x/Bad.class", cls(65));                                        // 하나만 Java 21
w("mr/io/x/A.class", cls(61));
w("mr/META-INF/versions/21/io/x/A.class", cls(65));                        // MR-jar 는 제외 대상
fs.mkdirSync(path.join(R,"empty"),{recursive:true});                       // 클래스 0개
' "$FIX"

# 전부 major 61 → 통과.
assert_ok node "$GUARD" "$FIX/ok" --max-major=61 --min-classes=3

# ⚠️ 핵심 대조군 — 하나라도 상한을 넘으면 실패해야 한다. 이것이 없으면 가드를 항등함수로
# 바꿔도 위 assert_ok 가 그대로 통과해 테스트가 공허해진다.
assert_fails node "$GUARD" "$FIX/mixed" --max-major=61 --min-classes=3
out=$(node "$GUARD" "$FIX/mixed" --max-major=61 --min-classes=3 2>&1 || true)
assert_contains "$out" "bytecode-above-floor" "상한 초과는 bytecode-above-floor 로 보고"
assert_contains "$out" "Bad.class" "위반한 파일을 지목한다"

# 상한을 올리면 같은 트리가 통과한다 — 가드가 상한을 실제로 읽는다는 대조군.
assert_ok node "$GUARD" "$FIX/mixed" --max-major=65 --min-classes=3

# Multi-Release jar 의 `META-INF/versions/<n>/` 아래는 **의도적으로** 높다 — 제외해야 한다.
# 제외하지 않으면 정당한 MR-jar 를 막게 되고, 그러면 이 가드는 꺼지게 된다.
assert_ok node "$GUARD" "$FIX/mr" --max-major=61 --min-classes=1
out=$(node "$GUARD" "$FIX/mr" --max-major=61 --min-classes=1 2>&1 || true)
assert_contains "$out" "Multi-Release 제외" "MR 제외를 출력에 밝힌다"

# ── 공허성 ──────────────────────────────────────────────────────────────────
# 산출 경로가 바뀌어 0개를 훑으면 「위반 없음」이 된다 — 이 저장소의 단골 실패다.
assert_fails node "$GUARD" "$FIX/empty" --max-major=61 --min-classes=1
out=$(node "$GUARD" "$FIX/empty" --max-major=61 --min-classes=1 2>&1 || true)
assert_contains "$out" "vacuous-scan" "0개 스캔은 vacuous-scan 으로 실패"

# 하한을 실측보다 높이면 실패한다(위 empty 와 같은 판별자, 클래스가 있는 트리에서).
assert_fails node "$GUARD" "$FIX/ok" --max-major=61 --min-classes=999

# 없는 디렉터리를 통과로 읽지 않는다.
assert_fails node "$GUARD" "$FIX/does-not-exist" --max-major=61
out=$(node "$GUARD" "$FIX/does-not-exist" --max-major=61 2>&1 || true)
assert_contains "$out" "missing-dir" "없는 디렉터리는 missing-dir 로 실패"

# 인자 없이 부르면 실패한다(사용법 오류를 통과로 읽지 않는다).
assert_fails node "$GUARD"
# 비수치 상한도 설정 오류다.
assert_fails node "$GUARD" "$FIX/ok" --max-major=abc

assert_report
