#!/usr/bin/env sh
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
FIX="$DIR/fixtures/doc-guard"
GUARD="$DIR/../check-docs.mjs"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 정상 픽스처는 통과해야 한다.
cp -r "$FIX/." "$TMP/"
assert_ok node "$GUARD" "$TMP"

# 변이 1: 문서의 값을 훼손하면 실패해야 한다.
cp -r "$FIX/." "$TMP/"
sed -i 's/| 1\.2\.3 |/| 9.9.9 |/' "$TMP/ok.md"
assert_fails node "$GUARD" "$TMP"

# 변이 2: 표를 지우면 min 미달로 실패해야 한다(침묵 금지).
cp -r "$FIX/." "$TMP/"
sed -i '/org.example/d' "$TMP/ok.md"
assert_fails node "$GUARD" "$TMP"

# 변이 3: 소스를 비우면 실패해야 한다.
cp -r "$FIX/." "$TMP/"
: > "$TMP/src/build.gradle.kts"
assert_fails node "$GUARD" "$TMP"

# ---- Defect 1: 앵커는 바로 뒤 표만 소유한다 ----
# 앵커 바로 다음 줄이 산문이고, 그 뒤에 (min을 충족하는) 디코이 표가 오고,
# 그보다 더 뒤에 실제로 드리프트된 진짜 표가 있는 문서. 구버전은 산문·디코이
# 표를 건너뛰어 디코이를 "앵커의 표"로 오인해 통과(0종료)하고 진짜 드리프트
# (Beta 9.9.9)는 검사하지 않는다 — 고친 버전은 앵커 직후가 표가 아니므로
# "앵커 뒤에 표가 없다"로 즉시 잡아야 한다(침묵 통과 금지).
cp -r "$FIX/." "$TMP/"
cat > "$TMP/ok.md" <<'EOF'
# fixture

<!-- doc-guard: kind=dep source=src/build.gradle.kts min=2 -->
앵커 바로 다음 줄에 산문이 온다 — 표가 아니다.

| 무관한 항목 | 좌표 | 버전 |
|---|---|---|
| Alpha decoy | `org.example:alpha` | 1.2.3 |
| Beta decoy | `org.example:beta` | 4.5.6 |

| 이름 | 좌표 | 버전 |
|---|---|---|
| Alpha | `org.example:alpha` | 1.2.3 |
| Beta | `org.example:beta` | 9.9.9 |
EOF
assert_fails node "$GUARD" "$TMP"

# ---- Defect 2: min= 은 1 이상의 정수만 허용한다 ----
# min=0: 표를 완전히 비워도(추출 0건) "0 < 0"은 거짓이라 통과해선 안 된다
# ("추출이 0건으로 떨어짐" 탐지기를 min=0이 무력화하는 정확한 시나리오).
cp -r "$FIX/." "$TMP/"
sed -i 's/min=2/min=0/' "$TMP/ok.md"
sed -i '/org.example/d' "$TMP/ok.md"
assert_fails node "$GUARD" "$TMP"

# min=oops: 표가 멀쩡해도 숫자가 아닌 min 값 자체를 거부해야 한다
# ("checked < NaN"은 항상 거짓이라 구버전은 침묵 통과한다).
cp -r "$FIX/." "$TMP/"
sed -i 's/min=2/min=oops/' "$TMP/ok.md"
assert_fails node "$GUARD" "$TMP"

# ---- Defect 3~5: 확장된 픽스처(pom 리액터·package-lock.json·펜스 앵커)가
# 전부 통과해야 한다. 구버전은 pom-reactor.md(단일파일 파싱이라 좌표를 못 찾음)와
# fenced.md(펜스 안 앵커를 진짜로 오인해 존재하지 않는 소스 추출 실패)에서
# 거짓 FAIL을 낸다. ----
cp -r "$FIX/." "$TMP/"
assert_ok node "$GUARD" "$TMP"

# Defect 3 드리프트 확인: 리액터 해석이 비교 자체를 무력화하지 않는다
# (부모 pom의 property + 자식 pom의 dependency를 정확히 병합해도, 문서 값이
# 실제와 다르면 여전히 잡혀야 한다).
cp -r "$FIX/." "$TMP/"
sed -i 's/| 2\.0\.0 |/| 9.9.9 |/' "$TMP/pom-reactor.md"
assert_fails node "$GUARD" "$TMP"

# Defect 4 드리프트 확인: package-lock.json에서 뽑은 해석된 버전도 실제로 대조된다.
cp -r "$FIX/." "$TMP/"
sed -i 's/| 3\.2\.1 |/| 9.9.9 |/' "$TMP/npm-lock.md"
assert_fails node "$GUARD" "$TMP"

# ---- Fix A: 앵커 문법 자체를 설명하는 산문은 앵커로 파싱되면 안 된다 ----
# 앵커 앞뒤에 다른 텍스트가 함께 있는 줄은 선언이 아니라 설명이다. 구버전은
# 이런 줄에서도 doc-guard 정규식이 매치해 `source=<경로>`(플레이스홀더 문자
# 그대로) 추출을 시도하다 ENOENT로 죽는다 — 고친 버전은 trim한 줄 전체가
# 앵커 문법과 정확히 일치할 때만 선언으로 인정해 이 줄들을 조용히 건너뛴다.
cp -r "$FIX/." "$TMP/"
cat > "$TMP/prose.md" <<'EOF'
# prose fixture

- Produces: 앵커 문법 `<!-- doc-guard: kind=dep source=<경로> min=<정수> -->` + 뒤따르는 마크다운 표.
- Produces: 앵커 `kind=runtime` — `<!-- doc-guard: kind=runtime lang=<언어> -->` 뒤 인라인 코드로 표기된 버전 1개를 검사
EOF
assert_ok node "$GUARD" "$TMP"

# ---- Fix B: 저장소 루트 스캔은 가드 자신의 테스트 픽스처를 문서로 취급하지
# 않는다 ----
# scripts/test/fixtures/*.md의 source= 경로는 격리된 임시 디렉터리 기준 상대경로다.
# 그 픽스처를 실제 저장소와 같은 상대경로(scripts/test/fixtures/)에 두고 그
# 루트를 스캔하면, 픽스처 제외가 없는 구버전은 source=를 그 루트 기준으로 잘못
# 해석해 ENOENT로 실패한다 — 고친 버전은 scripts/test/fixtures를 통째로
# 건너뛰어야 한다.
rm -rf "$TMP" && mkdir -p "$TMP/scripts/test/fixtures"
cp -r "$FIX/." "$TMP/scripts/test/fixtures/"
assert_ok node "$GUARD" "$TMP"

# ---- Finding 1: 리액터 안에서 같은 좌표를 서로 다른 pom이 서로 다른 리터럴
# 버전으로 선언하면 침묵 병합(파일시스템 순회 순서에 좌우되는 거짓 PASS/거짓
# FAIL)이 아니라, 양쪽 버전·양쪽 pom 경로를 명시한 에러로 fail-closed 해야
# 한다. 이 픽스처는 공유 $FIX 디렉터리 밖에서(cp -r 없이) 직접 조립한다 —
# $FIX 안에 두면 다른 모든 assert_ok 시나리오(정상 픽스처 전체 스캔)가 이
# 의도된 충돌 에러 때문에 깨진다.
rm -rf "$TMP" && mkdir -p "$TMP/reactor-conflict/module-a" "$TMP/reactor-conflict/module-b"
cat > "$TMP/reactor-conflict/pom.xml" <<'EOF'
<project>
  <modelVersion>4.0.0</modelVersion>
  <groupId>test.conflict</groupId>
  <artifactId>conflict-parent</artifactId>
  <version>0.0.1</version>
  <packaging>pom</packaging>
  <modules>
    <module>module-a</module>
    <module>module-b</module>
  </modules>
</project>
EOF
cat > "$TMP/reactor-conflict/module-a/pom.xml" <<'EOF'
<project>
  <modelVersion>4.0.0</modelVersion>
  <parent>
    <groupId>test.conflict</groupId>
    <artifactId>conflict-parent</artifactId>
    <version>0.0.1</version>
  </parent>
  <artifactId>module-a</artifactId>
  <dependencies>
    <dependency>
      <groupId>org.example</groupId>
      <artifactId>conflicted</artifactId>
      <version>1.0.0</version>
    </dependency>
  </dependencies>
</project>
EOF
cat > "$TMP/reactor-conflict/module-b/pom.xml" <<'EOF'
<project>
  <modelVersion>4.0.0</modelVersion>
  <parent>
    <groupId>test.conflict</groupId>
    <artifactId>conflict-parent</artifactId>
    <version>0.0.1</version>
  </parent>
  <artifactId>module-b</artifactId>
  <dependencies>
    <dependency>
      <groupId>org.example</groupId>
      <artifactId>conflicted</artifactId>
      <version>2.0.0</version>
    </dependency>
  </dependencies>
</project>
EOF
cat > "$TMP/reactor-conflict.md" <<'EOF'
# reactor conflict fixture

<!-- doc-guard: kind=dep source=reactor-conflict/pom.xml min=1 -->

| 이름 | 좌표 | 버전 |
|---|---|---|
| Conflicted | `org.example:conflicted` | 1.0.0 |
EOF
assert_fails node "$GUARD" "$TMP"
OUT="$(node "$GUARD" "$TMP" 2>&1)" || true
assert_contains "$OUT" "1.0.0" "reactor conflict error must name module-a's version"
assert_contains "$OUT" "2.0.0" "reactor conflict error must name module-b's version"
assert_contains "$OUT" "module-a/pom.xml" "reactor conflict error must name module-a's pom path"
assert_contains "$OUT" "module-b/pom.xml" "reactor conflict error must name module-b's pom path"

# ---- Finding 2: 자신만으로 한 줄을 이루지 않는(리스트 불릿 아래 들여쓰기 등)
# "거의 앵커"는 조용히 무시되면 안 된다 — 선언처럼 보이지만 이 가드에게는
# 절대 인식되지 않으므로 에러다. (인라인 백틱으로 감싼 산문 설명은 여전히
# 무시돼야 한다 — 그건 위 Fix A의 prose.md가 이미 커버·보존한다.)
rm -rf "$TMP" && mkdir -p "$TMP"
cat > "$TMP/near-miss.md" <<'EOF'
# near-miss anchor fixture

- <!-- doc-guard: kind=dep source=x min=1 -->
EOF
assert_fails node "$GUARD" "$TMP"
OUT="$(node "$GUARD" "$TMP" 2>&1)" || true
assert_contains "$OUT" "near-miss.md:3" "near-miss anchor must be reported at its own line"

# Finding 2는 $TMP를 near-miss.md 단독 트리로 재구성했다(위 rm -rf) — 그 상태로
# 남겨두면 이후 블록이 "cp -r "$FIX/." "$TMP/""로만 채워도 near-miss.md가 계속
# 섞여 있어(cp -r은 대상의 기존 파일을 지우지 않는다) 항상 에러를 유발한다.
# 검사 2·3은 그 오염 없는 깨끗한 상태에서 시작해야 한다.
rm -rf "$TMP" && mkdir -p "$TMP"

# 검사 2: 같은 좌표가 두 문서에서 다른 값을 말하면 실패해야 한다.
cp -r "$FIX/." "$TMP/"
cp "$TMP/ok.md" "$TMP/other.md"
sed -i 's/| 1\.2\.3 |/| 1.2.4 |/' "$TMP/other.md"
assert_fails node "$GUARD" "$TMP"

# 검사 2가 만든 other.md(other.md의 Alpha=1.2.4는 실제 소스 1.2.3과도 어긋난다)는
# cp -r로 지워지지 않고 남는다 — 검사 3의 assert_ok를 오염시키지 않도록 다시 리셋한다.
rm -rf "$TMP" && mkdir -p "$TMP"

# 검사 3: 최소 런타임 주장이 소스와 다르면 실패해야 한다.
cp -r "$FIX/." "$TMP/"
printf '%s\n' '<!-- doc-guard: kind=runtime lang=node -->' 'Node `>=22` 이상이 필요하다.' > "$TMP/runtime.md"
mkdir -p "$TMP/node" && printf '%s\n' '{"engines":{"node":">=22"}}' > "$TMP/node/package.json"
assert_ok node "$GUARD" "$TMP"
sed -i 's/`>=22`/`>=20`/' "$TMP/runtime.md"
assert_fails node "$GUARD" "$TMP"

assert_report
