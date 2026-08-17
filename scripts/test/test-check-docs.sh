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
#
# 리뷰 결함(순 증거 0): 과거 버전은 other.md를 ok.md의 사본 + Alpha 값만
# 1.2.4로 바꿔 만들었다. 그런데 1.2.4는 실제 소스(src/build.gradle.kts의
# 1.2.3)와도 어긋나므로, 검사 2(문서 간 대조) 코드를 통째로 주석 처리해도
# 기존 검사 1(문서↔소스)만으로 이미 exit 1이 된다 — 실측: 검사 2 순회
# 블록을 삭제한 스크래치 사본으로 전체 스위트를 돌려도 "22 passed, 0
# failed"가 그대로 나왔다. 즉 이 assert_fails는 검사 2가 있든 없든 통과하는
# 순 증거 0의 어서션이었다.
#
# 고친 버전: 서로 다른 소스에 각자 스스로는 완전히 일치하는(검사 1 GREEN)
# 두 문서를 만들어, 오직 같은 좌표를 서로 다른 값으로 주장하는 것(검사 2)
# 만으로 실패가 나게 한다. 위 "Finding 1"(리액터 충돌) 블록과 같은 이유로
# 공유 $FIX 밖에서 조립한다 — 공유 픽스처에 두면 다른 모든 assert_ok
# 전체스캔이 이 의도된 충돌 때문에 깨진다.
rm -rf "$TMP" && mkdir -p "$TMP/cross/a" "$TMP/cross/b"
cat > "$TMP/cross/a/build.gradle.kts" <<'EOF'
dependencies {
    api("org.example:shared:1.0.0")
}
EOF
cat > "$TMP/cross/b/build.gradle.kts" <<'EOF'
dependencies {
    api("org.example:shared:2.0.0")
}
EOF
cat > "$TMP/cross-a.md" <<'EOF'
# cross-doc conflict fixture A — 자기 소스와는 일치(검사 1 GREEN)

<!-- doc-guard: kind=dep source=cross/a/build.gradle.kts min=1 -->

| 이름 | 좌표 | 버전 |
|---|---|---|
| Shared | `org.example:shared` | 1.0.0 |
EOF
cat > "$TMP/cross-b.md" <<'EOF'
# cross-doc conflict fixture B — 자기 소스와는 일치(검사 1 GREEN)

<!-- doc-guard: kind=dep source=cross/b/build.gradle.kts min=1 -->

| 이름 | 좌표 | 버전 |
|---|---|---|
| Shared | `org.example:shared` | 2.0.0 |
EOF
assert_fails node "$GUARD" "$TMP"
OUT="$(node "$GUARD" "$TMP" 2>&1)" || true
assert_contains "$OUT" "cross-a.md=1.0.0" "cross-doc conflict must name doc A's claimed version"
assert_contains "$OUT" "cross-b.md=2.0.0" "cross-doc conflict must name doc B's claimed version"
# 두 문서 모두 자기 소스와 정확히 일치하므로(검사 1 GREEN) 에러는 검사 2의
# 단 1건뿐이어야 한다 — 검사 1의 실제-불일치 에러("실제=")가 섞여 있다면
# 이 어서션이 다시 검사 1에 얹혀 가는 것이므로 명시적으로 배제한다.
assert_not_contains "$OUT" "실제=" "cross-doc conflict must be Check-2-only (no Check-1 mismatch noise)"
assert_contains "$OUT" "문서 드리프트 1건" "cross-doc conflict must produce exactly one error (Check 2 only)"

# 이 블록이 만든 cross-*.md/cross/ 디렉터리는 cp -r로 지워지지 않고 남는다 —
# 검사 3의 assert_ok를 오염시키지 않도록 다시 리셋한다.
rm -rf "$TMP" && mkdir -p "$TMP"

# 검사 3: 최소 런타임 주장이 소스와 다르면 실패해야 한다.
cp -r "$FIX/." "$TMP/"
printf '%s\n' '<!-- doc-guard: kind=runtime lang=node -->' 'Node `>=22` 이상이 필요하다.' > "$TMP/runtime.md"
mkdir -p "$TMP/node" && printf '%s\n' '{"engines":{"node":">=22"}}' > "$TMP/node/package.json"
assert_ok node "$GUARD" "$TMP"
sed -i 's/`>=22`/`>=20`/' "$TMP/runtime.md"
assert_fails node "$GUARD" "$TMP"

# 검사 3의 assert_fails가 만든 runtime.md/node/는 cp -r로 지워지지 않고 남는다 —
# 아래 정규화 어서션들의 assert_ok를 오염시키지 않도록 다시 리셋한다.
rm -rf "$TMP" && mkdir -p "$TMP"

# ---- Finding 2: 검사 3은 추출기의 원문 선언 형식(">=22"·">= 3.2"[공백
# 있는 연산자]·"^8.3"·"1.25.0"[3단계]·"net8.0"[언어 접두])과 이 프로젝트
# 문서 관용("Node 22+"·"Go 1.25+" 등)이 형식만 다를 뿐 같은 값이면 통과해야
# 한다. 정규화 이전(순수 strict-equality)이었다면 아래 5개 언어 사례 모두
# 형식 차이만으로 거짓 FAIL이었다 — 값이 아니라 형식만 흡수했음을 언어별로
# 증명한다. 진짜 불일치(node 20+)는 여전히 실패해야 정규화가 검사를
# 무력화하지 않았다는 증거가 된다. ----
cp -r "$FIX/." "$TMP/"

# node: 연산자 접두(">=22") ↔ 문서 관용("22+")
mkdir -p "$TMP/node" && printf '%s\n' '{"engines":{"node":">=22"}}' > "$TMP/node/package.json"
printf '%s\n' '<!-- doc-guard: kind=runtime lang=node -->' 'Node.js `22+` 이상이 필요하다.' > "$TMP/runtime-node.md"

# ruby: 공백 있는 연산자(">= 3.2") ↔ 문서 관용("3.2+")
mkdir -p "$TMP/ruby"
printf '%s\n' 'Gem::Specification.new do |spec|' '  spec.required_ruby_version = ">= 3.2"' 'end' > "$TMP/ruby/keycloak-sdk.gemspec"
printf '%s\n' '<!-- doc-guard: kind=runtime lang=ruby -->' 'Ruby `3.2+` 이상이 필요하다.' > "$TMP/runtime-ruby.md"

# php: 캐럿 범위("^8.3") ↔ 문서 관용("8.3+")
mkdir -p "$TMP/php" && printf '%s\n' '{"require":{"php":"^8.3"}}' > "$TMP/php/composer.json"
printf '%s\n' '<!-- doc-guard: kind=runtime lang=php -->' 'PHP `8.3+` 이상이 필요하다.' > "$TMP/runtime-php.md"

# go: 3단계 버전("1.25.0") ↔ 문서 관용("1.25+")
mkdir -p "$TMP/go" && printf '%s\n' 'module test' '' 'go 1.25.0' > "$TMP/go/go.mod"
printf '%s\n' '<!-- doc-guard: kind=runtime lang=go -->' 'Go `1.25+` 이상이 필요하다.' > "$TMP/runtime-go.md"

# dotnet: "net" 언어 접두("net8.0") ↔ 문서가 정확한 2부 값을 그대로 쓴 "8.0"
# (여기서 더 깎아 "8"과 비교하면 안 된다 — 규칙 4의 "구성요소 2개는 보존" 조건).
mkdir -p "$TMP/dotnet"
printf '%s\n' '<Project><PropertyGroup><TargetFramework>net8.0</TargetFramework></PropertyGroup></Project>' > "$TMP/dotnet/Directory.Build.props"
printf '%s\n' '<!-- doc-guard: kind=runtime lang=dotnet -->' '.NET `8.0` 이상이 필요하다.' > "$TMP/runtime-dotnet.md"

assert_ok node "$GUARD" "$TMP"

# 진짜 불일치는 여전히 실패해야 한다(정규화가 검사를 무력화하지 않았다는 증거).
sed -i 's/`22+`/`20+`/' "$TMP/runtime-node.md"
assert_fails node "$GUARD" "$TMP"

# 이 블록의 runtime-*.md/node|ruby|php|go|dotnet 디렉터리는 cp -r로 지워지지
# 않고 남는다 — 다음 블록의 assert_ok를 오염시키지 않도록 다시 리셋한다.
rm -rf "$TMP" && mkdir -p "$TMP"

# ---- Finding 3: 앵커 뒤 첫 백틱 스팬이 아니라, 숫자를 포함해 "버전 모양"인
# 첫 백틱 스팬을 주장으로 삼아야 한다 ----
# 문서가 버전보다 먼저 다른 백틱 용어(코드명 등)를 언급하면, 구버전(무조건
# 첫 백틱 스팬)은 디코이(숫자 없음)를 주장으로 오인해 실제 버전과 무관하게
# 항상 불일치로 실패한다 — 고친 버전은 숫자를 포함한 첫 스팬(진짜 버전)까지
# 건너뛰어 찾아야 한다.
mkdir -p "$TMP/node"
printf '%s\n' '{"engines":{"node":">=22"}}' > "$TMP/node/package.json"
printf '%s\n' '<!-- doc-guard: kind=runtime lang=node -->' '코드명 `carbon` 릴리스, Node.js `22+` 이상이 필요하다.' > "$TMP/decoy.md"
assert_ok node "$GUARD" "$TMP"

# 이 블록의 decoy.md/node/는 cp -r로 지워지지 않고 남는다 — 아래 검사 4~6 블록의
# assert_ok를 오염시키지 않도록 다시 리셋한다.
rm -rf "$TMP" && mkdir -p "$TMP"

# ---- 검사 4: 커버리지 게이트 임계값 — 문서 주장이 빌드 설정과 다르면 --strict 에서
# 실패해야 한다(기본은 경고). .claude/rules/java.md 스타일의 "게이트 NN/MM" 표기 대
# 실제 java/pom.xml <minimum> 값을 대조한다 — 이 트리엔 그 문서·소스 쌍만 있으면 된다
# (다른 언어의 문서·소스가 없어도 조용히 스킵되어야 한다 — 부재는 에러가 아니다).
mkdir -p "$TMP/.claude/rules" "$TMP/java"
printf '%s\n' '- 전체 빌드+검증: `mvn -f java/pom.xml verify` (커버리지 게이트 90/85 포함)' > "$TMP/.claude/rules/java.md"
cat > "$TMP/java/pom.xml" <<'EOF'
<project>
  <build><plugins><plugin><configuration><rules><rule><limits>
    <limit><counter>LINE</counter><value>COVEREDRATIO</value><minimum>0.50</minimum></limit>
    <limit><counter>BRANCH</counter><value>COVEREDRATIO</value><minimum>0.40</minimum></limit>
  </limits></rule></rules></configuration></plugin></plugins></build>
</project>
EOF
assert_ok node "$GUARD" "$TMP"             # 기본은 경고
assert_fails node "$GUARD" "$TMP" --strict # --strict 는 실패(문서 90/85 ≠ 실제 50/40)

# 이 블록의 .claude/·java/는 cp -r로 지워지지 않고 남는다 — 다음 블록을 오염시키지
# 않도록 다시 리셋한다.
rm -rf "$TMP" && mkdir -p "$TMP"

# ---- 검사 5: 깨진 마크다운 링크는 --strict 에서 실패해야 한다(기본은 경고) ----
cp -r "$FIX/." "$TMP/"
printf '%s\n' '[없는문서](./nope.md)' >> "$TMP/ok.md"
assert_ok node "$GUARD" "$TMP"             # 기본은 경고
assert_fails node "$GUARD" "$TMP" --strict # --strict 는 실패

# 이 블록도 ok.md를 오염시켰다 — 다음 블록을 위해 다시 리셋한다.
rm -rf "$TMP" && mkdir -p "$TMP"

# ---- 검사 5 확장(#193): 맨상대경로(점·슬래시 없는 저장소 경로)도 존재 검사 ----
# 구버전 정규식은 `./`·`../`·선두 `/`만 봐서 `[없는문서](nope.md)` · `[x](docs/gone.md)`는
# 대상이 없어도 --strict 가 통과한다. CLAUDE.md·CHANGELOG.md 의 맨경로 링크가 그 구멍이다.
# 해석은 기존과 같다 — 링크는 그 문서의 부모 디렉터리 기준(루트 문서에서는 ROOT 와 같다).
# ROOT 단독으로 보면 하위 문서의 형제 링크(docs/README.md → guides/…)가 전부 오탐이다.
cp -r "$FIX/." "$TMP/"
printf '%s\n' '[없는문서](nope.md)' >> "$TMP/ok.md"
assert_ok node "$GUARD" "$TMP"             # 기본은 경고
assert_fails node "$GUARD" "$TMP" --strict
OUT="$(node "$GUARD" "$TMP" --strict 2>&1)" || true
assert_contains "$OUT" "nope.md" "bare relative path (*.md) must be flagged under --strict"

rm -rf "$TMP" && mkdir -p "$TMP"
cp -r "$FIX/." "$TMP/"
printf '%s\n' '[없는문서](docs/gone.md)' >> "$TMP/ok.md"
assert_fails node "$GUARD" "$TMP" --strict
OUT="$(node "$GUARD" "$TMP" --strict 2>&1)" || true
assert_contains "$OUT" "docs/gone.md" "bare path containing / must be flagged under --strict"

# 살아 있는 맨경로·같은 디렉터리 형제 링크는 통과해야 한다(오탐 0).
rm -rf "$TMP" && mkdir -p "$TMP"
cp -r "$FIX/." "$TMP/"
mkdir -p "$TMP/sub"
printf '%s\n' '[ok](ok.md)' > "$TMP/bare-ok.md"
printf '%s\n' '[peer](peer.md)' > "$TMP/sub/a.md"
printf '%s\n' '# peer' > "$TMP/sub/peer.md"
assert_ok node "$GUARD" "$TMP" --strict

# 오탐 억제: 스킴·순수 앵커·경로로 볼 근거가 없는 식별자는 잡지 않는다.
# LICENSE 처럼 확장자 없는 루트 파일명은 `/` 도 `.md` 도 없어 스킵 — 식별자 오탐을
# 막으려는 필터의 대조군이다(살아 있는 LICENSE 를 검사하지 않는 것이 목적).
rm -rf "$TMP" && mkdir -p "$TMP"
cp -r "$FIX/." "$TMP/"
printf '%s\n' \
  '[웹](https://example.com/nope.md)' \
  '[메일](mailto:dev@example.com)' \
  '[앵커](#nope)' \
  '[식별자](SomeType)' \
  '[라이선스](LICENSE)' >> "$TMP/ok.md"
assert_ok node "$GUARD" "$TMP" --strict
OUT="$(node "$GUARD" "$TMP" --strict 2>&1)" || true
assert_not_contains "$OUT" "nope.md" "http(s) dest must never be flagged"
assert_not_contains "$OUT" "mailto:" "mailto dest must never be flagged"
assert_not_contains "$OUT" "#nope" "pure anchor must never be flagged"
assert_not_contains "$OUT" "SomeType" "bare identifier without / or .md must never be flagged"
assert_not_contains "$OUT" "LICENSE" "extensionless basename is not a path under the filter"

rm -rf "$TMP" && mkdir -p "$TMP"

# ---- 검사 6: "N개 언어" 기수가 scripts/lib/deploy-facts.sh 의 DEPLOY_LANGS 언어 수와
# 다르면 --strict 에서 실패해야 한다(기본은 경고). deploy-facts.sh 가 아예 없는 트리
# (위 다른 모든 블록)에서는 이 검사가 조용히 스킵됨을 그 블록들의 assert_ok가 이미
# 방증한다 — 여기서는 반대로 파일이 있고 기수가 어긋나는 경우를 확인한다. ----
mkdir -p "$TMP/scripts/lib"
printf '%s\n' 'DEPLOY_LANGS="a b c"' > "$TMP/scripts/lib/deploy-facts.sh"
printf '%s\n' '# fixture' '9개 언어를 지원한다.' > "$TMP/langs.md"
assert_ok node "$GUARD" "$TMP"             # 기본은 경고 (DEPLOY_LANGS는 3개, 문서는 9개)
assert_fails node "$GUARD" "$TMP" --strict # --strict 는 실패

# 이 블록의 scripts/·langs.md는 cp -r로 지워지지 않고 남는다 — 아래 회귀테스트들의
# assert_ok를 오염시키지 않도록 다시 리셋한다.
rm -rf "$TMP" && mkdir -p "$TMP"

# ---- 회귀 1: 검사 5는 펜스(```) 안의 링크를 진짜 링크로 오인하면 안 된다 ----
# 끝난 계획서의 실제 사례(펜스 안
# `./nope.md`가 문법 예시일 뿐인데도 링크 대상 부재로 거짓 경고됐던 것)를 재현한다.
# 앵커 스캐너는 이미 펜스를 건너뛰므로, checkLinks도 독립적으로 같은 규칙을 지켜야
# 한다 — 기본 실행뿐 아니라 --strict에서도 전혀 등장하지 않아야 진짜 억제다(기본
# 실행만 통과하는 건 "경고가 에러로 안 올라갔다"일 뿐일 수도 있어 증거가 약하다).
cat > "$TMP/fenced-link.md" <<'EOF'
# fenced link fixture

```
[문법 예시](./nope.md)
```
EOF
assert_ok node "$GUARD" "$TMP"
OUT="$(node "$GUARD" "$TMP" 2>&1)" || true
assert_not_contains "$OUT" "nope.md" "fenced link must never be flagged (not even a warning)"
assert_ok node "$GUARD" "$TMP" --strict # 억제됐다면 --strict도 통과해야 한다

rm -rf "$TMP" && mkdir -p "$TMP"

# ---- 회귀 2: python/.venv/**(vendored 서드파티 site-packages) 는 문서로 취급하면
# 안 된다 ----
# 실제 사례: python/.venv/Lib/site-packages/**/README.md가 상대 링크를 못 찾는 대상을
# 가리켜 검사 5를 오염시켰다. .venv 디렉터리 자체가 SKIP 대상이어야 그 안의 어떤
# README도 애초에 스캔되지 않는다 — --strict에서도 등장하지 않아야 진짜 억제다.
mkdir -p "$TMP/python/.venv/Lib/site-packages/somepkg"
cat > "$TMP/python/.venv/Lib/site-packages/somepkg/README.md" <<'EOF'
# vendored package
See [license](./LICENSE-that-does-not-exist.txt).
EOF
assert_ok node "$GUARD" "$TMP"
OUT="$(node "$GUARD" "$TMP" 2>&1)" || true
assert_not_contains "$OUT" "LICENSE-that-does-not-exist" ".venv/site-packages must never be scanned (not even a warning)"
assert_ok node "$GUARD" "$TMP" --strict # 억제됐다면 --strict도 통과해야 한다

rm -rf "$TMP" && mkdir -p "$TMP"

# ---- 회귀 3: 검사 6은 "다른 N개 언어"류 상대 기수를 절대 언어 총수 주장으로 오인하면
# 안 된다 — 절대 주장(예: "9개 언어")은 여전히 잡아야 한다 ----
# DEPLOY_LANGS는 3개뿐인 트리에서: "다른 8개 언어"(관계상 늘 전체와 다름 — 상대 기수라
# 애초에 대조 대상이 아님)는 절대 걸리면 안 되고, "9개 언어"(전체 언어 수에 대한 절대
# 주장)는 3개와 어긋나므로 여전히 걸려야 한다. 같은 실행 안에서 둘을 함께 확인해야
# "상대 기수를 억제하려다 절대 주장까지 죽였다"는 회귀를 놓치지 않는다.
mkdir -p "$TMP/scripts/lib"
printf '%s\n' 'DEPLOY_LANGS="a b c"' > "$TMP/scripts/lib/deploy-facts.sh"
printf '%s\n' '# fixture' '이 SDK는 다른 8개 언어와 동일한 근본 한계를 공유한다.' '이 SDK는 9개 언어를 지원한다.' > "$TMP/mixed-langs.md"
assert_ok node "$GUARD" "$TMP" # 기본은 경고(절대 주장 "9개"만 어긋남)
OUT="$(node "$GUARD" "$TMP" 2>&1)" || true
assert_not_contains "$OUT" '"8개 언어"' "relative count (다른 8개 언어) must never be flagged"
assert_contains "$OUT" '"9개 언어" ≠ DEPLOY_LANGS 3개' "absolute count mismatch (9개 언어) must still be flagged"
assert_fails node "$GUARD" "$TMP" --strict # 절대 주장 어긋남은 --strict에서 실패해야 한다
OUT="$(node "$GUARD" "$TMP" --strict 2>&1)" || true
assert_not_contains "$OUT" '"8개 언어"' "relative count must not surface even under --strict"

rm -rf "$TMP" && mkdir -p "$TMP"

# ---- 회귀 4(Fix 1): --strict 는 위치 인자(루트 경로)보다 앞에 오든 뒤에 오든 동일하게
# 동작해야 한다 ----
# 고치기 전 버전은 `process.argv[2]`를 무조건 루트로 가정했다 — 검사 4~6을 --strict로
# 승격하는 문서화된 다음 단계의 가장 자연스러운 실행형인 `check-docs.mjs --strict`(명시적
# `.` 없이)와 똑같은 패턴인 `node check-docs.mjs --strict "$TMP"`에서 "--strict" 문자열
# 자체가 존재하지 않는 디렉터리로 resolve되어 ENOENT로 크래시했다(부비트랩). 고친 버전은
# 두 순서가 완전히 같은 결과(크래시 없이, 같은 종료코드, 같은 "checked N facts" 성공
# 문구)를 내야 한다.
cp -r "$FIX/." "$TMP/"
if node "$GUARD" "$TMP" --strict >/dev/null 2>&1; then RC_PATH_FIRST=0; else RC_PATH_FIRST=$?; fi
if node "$GUARD" --strict "$TMP" >/dev/null 2>&1; then RC_FLAG_FIRST=0; else RC_FLAG_FIRST=$?; fi
assert_eq "$RC_PATH_FIRST" "$RC_FLAG_FIRST" "--strict before the root path must exit identically to --strict after it"
OUT_FLAG_FIRST="$(node "$GUARD" --strict "$TMP" 2>&1)" || true
assert_not_contains "$OUT_FLAG_FIRST" "ENOENT" "--strict before the root path must not crash with ENOENT (argv booby-trap)"
assert_contains "$OUT_FLAG_FIRST" "checked" "--strict before the root path must produce the normal 'checked N facts' output, not a crash"

rm -rf "$TMP" && mkdir -p "$TMP"

# ---- 회귀 5(Fix 2): fact/anchor 최저치(floor)는 --min-facts/--min-anchors로만 켜지고
# (기본 0=미적용, 픽스처 무영향), 켜지면 앵커/표 삭제처럼 검사 커버리지가 줄어든 트리를
# 실패시켜야 한다 ----
# 정상 픽스처(scripts/test/fixtures/doc-guard)는 항상 "checked 4 facts across 3 anchors"다
# — 그 실측치보다 낮은 하한(--min-facts 미만이 아니라 그 값을 밑도는 경우)은 통과해야
# 하고, 넘는 하한은 실패해야 한다. 플래그를 전혀 안 주면(기본 0) 같은 픽스처가 여전히
# 통과해야 한다 — floor가 opt-in이지 항상 켜진 게 아니라는 증거.
cp -r "$FIX/." "$TMP/"
assert_ok node "$GUARD" "$TMP" # 플래그 없음 — floor 미적용, 정상 통과
assert_ok node "$GUARD" "$TMP" --min-facts=4 --min-anchors=3   # 실측치와 정확히 같으면 통과
assert_fails node "$GUARD" "$TMP" --min-facts=5                # 실측(4) < 요구(5) — 실패
OUT="$(node "$GUARD" "$TMP" --min-facts=5 2>&1)" || true
assert_contains "$OUT" "facts 4 < --min-facts=5" "floor failure must name the actual fact count and the requested floor"
assert_fails node "$GUARD" "$TMP" --min-anchors=4               # 실측(3) < 요구(4) — 실패
OUT="$(node "$GUARD" "$TMP" --min-anchors=4 2>&1)" || true
assert_contains "$OUT" "anchors 3 < --min-anchors=4" "floor failure must name the actual anchor count and the requested floor"

rm -rf "$TMP" && mkdir -p "$TMP"

# ---- 회귀 6: 검사 6의 카디널리티 제외는 docs/governance/verification-log*.md 까지
# 덮어야 한다 — 운영 트리에는 그 파일이 없지만, 이 픽스처가 합성하는 같은 경로의
# 이력 기록은 그 시절 언어 수를 정당하게 말하므로 제외가 유지돼야 한다. 같은 숫자
# 불일치라도 CLAUDE.md처럼 현재-사실을 주장하는 문서에서는 여전히 잡혀야 한다
# (제외 패턴이 과도해 진짜 드리프트까지 죽이지 않았다는 증거) ----
mkdir -p "$TMP/scripts/lib" "$TMP/docs/governance"
printf '%s\n' 'DEPLOY_LANGS="a b c"' > "$TMP/scripts/lib/deploy-facts.sh"
printf '%s\n' '# verification log' '6개 언어 시절 검증 기록.' > "$TMP/docs/governance/verification-log.md"
printf '%s\n' '# verification log (lang-specific)' '6개 언어 시절 검증 기록.' > "$TMP/docs/governance/verification-log-python.md"
# 이 픽스처가 docs/ 를 만드는 순간 검사 9(문서 지도)도 발동한다 — 지도가 없으면 그쪽에서 실패해
# 검사 6에 대한 이 assert_ok 가 엉뚱한 이유로 빨개진다. 지도를 함께 둔다(그 자체가 검사 9의
# "docs/ 가 있으면 지도가 있어야 한다"를 다시 확인하는 셈이다).
printf '%s\n' '# map' '' '| 문서 | 상태 | 여기서만 알 수 있는 것 |' '|---|---|---|' \
  '| [vl](governance/verification-log.md) | 운영 | 이 문서에만 있는 것을 충분히 길게 적어 둔 마지막 칸이다 |' \
  '| [vlp](governance/verification-log-python.md) | 운영 | 이 문서에만 있는 것을 충분히 길게 적어 둔 마지막 칸이다 |' > "$TMP/docs/README.md"
printf '%s\n' '# CLAUDE' '이 SDK는 8개 언어를 지원한다.' > "$TMP/CLAUDE.md"
# CHANGELOG.md도 같은 성격이다 — 항목마다 날짜가 붙은 append-only 이력이라 "8개 언어 (2026-07-07)"는
# 당시 사실로 옳다. 제외하지 않으면 언어가 늘 때마다 과거 항목이 자동으로 경고가 되고, 그걸 없애는
# 유일한 방법이 이력을 거짓으로 고쳐 쓰는 것이라 가드가 잘못된 수정을 유도한다.
printf '%s\n' '# Changelog' '- **(harness) 8개 언어 하네스.** (2026-07-07)' > "$TMP/CHANGELOG.md"
assert_ok node "$GUARD" "$TMP" # 기본은 경고(CLAUDE.md의 절대주장만 어긋남 — verification-log*·CHANGELOG는 제외)
OUT="$(node "$GUARD" "$TMP" 2>&1)" || true
assert_not_contains "$OUT" "verification-log.md" "verification-log.md cardinality mismatch must be excluded from Check 6"
assert_not_contains "$OUT" "verification-log-python.md" "verification-log-<lang>.md cardinality mismatch must be excluded from Check 6"
assert_not_contains "$OUT" "CHANGELOG.md" "CHANGELOG.md cardinality mismatch must be excluded from Check 6 (dated append-only history)"
assert_contains "$OUT" 'CLAUDE.md "8개 언어" ≠ DEPLOY_LANGS 3개' "CLAUDE.md absolute count mismatch must still be flagged"

rm -rf "$TMP" && mkdir -p "$TMP"

# ---- 회귀 7: fromComposer — require 와 require-dev 를 병합해 "vendor/package" -> 버전
# 범위 문자열을 추출해야 한다 ----
# PHP/Rust/Ruby 3개 언어 의존성 표 앵커 확장(check-docs.mjs)의 신규 추출기 중 하나. require에만
# 있는 좌표(runtime dep)와 require-dev에만 있는 좌표(dev dep) 둘 다 같은 맵에서 해석돼야
# 앵커가 두 절 어느 쪽을 가리키는 표 행이든 검증할 수 있다. 드리프트(버전 훼손)도 여전히
# 잡혀야 한다(추출기 추가가 검사 자체를 무력화하지 않았다는 증거).
mkdir -p "$TMP/php"
cat > "$TMP/php/composer.json" <<'EOF'
{
  "require": { "firebase/php-jwt": "^7.1" },
  "require-dev": { "phpunit/phpunit": "^12" }
}
EOF
cat > "$TMP/composer.md" <<'EOF'
# composer fixture

<!-- doc-guard: kind=dep source=php/composer.json min=2 -->

| 이름 | 좌표 | 버전 |
|---|---|---|
| JWT | `firebase/php-jwt` | `^7.1` |
| Test | `phpunit/phpunit` | `^12` |
EOF
assert_ok node "$GUARD" "$TMP"
sed -i 's/\^7\.1/^9.9/' "$TMP/composer.md"
assert_fails node "$GUARD" "$TMP"

rm -rf "$TMP" && mkdir -p "$TMP"

# ---- 회귀 8: fromCargo — bare(`name = "..."`)와 inline-table
# (`name = { version = "...", features = [...] }`) 두 선언 형태 모두에서 "name" -> 버전을
# 뽑아야 하고, [package] 섹션(크레이트 자신의 name/version)은 의존성이 아니므로 무시해야
# 한다 ----
# [package]의 `version = "0.1.0"`을 의존성으로 잘못 주워 담으면(섹션 추적 누락) 이 픽스처의
# "keycloak" 좌표 검사와는 무관해 보이지만, 섹션 경계를 안 지키는 구현은 실제 Cargo.toml에서
# 우연히 이름이 겹치는 의존성이 생기면 조용히 틀린 값을 반환할 수 있다 — 그 회귀를 막기 위해
# [package] 섹션을 표 뒤에 실제로 포함한 픽스처로 검증한다.
mkdir -p "$TMP/rust"
cat > "$TMP/rust/Cargo.toml" <<'EOF'
[package]
name = "keycloak-sdk"
version = "0.1.0"

[dependencies]
keycloak = { version = "=26.6.2", default-features = false, features = ["tags-all"] }
thiserror = "2.0"

[dev-dependencies]
testcontainers = "0.27.3"
EOF
cat > "$TMP/cargo.md" <<'EOF'
# cargo fixture

<!-- doc-guard: kind=dep source=rust/Cargo.toml min=3 -->

| 이름 | 좌표 | 버전 |
|---|---|---|
| Admin | `keycloak` | `=26.6.2` |
| Errors | `thiserror` | 2.0 |
| IT | `testcontainers` | 0.27.3 |
EOF
assert_ok node "$GUARD" "$TMP"
sed -i 's/| 2\.0 |/| 9.9 |/' "$TMP/cargo.md"
assert_fails node "$GUARD" "$TMP"

rm -rf "$TMP" && mkdir -p "$TMP"

# ---- 회귀 9: fromGemspec — `add_dependency`와 `add_runtime_dependency` 둘 다 인식해야
# 한다 ----
mkdir -p "$TMP/ruby"
cat > "$TMP/ruby/keycloak-sdk.gemspec" <<'EOF'
Gem::Specification.new do |spec|
  spec.add_dependency "faraday", "~> 2.0"
  spec.add_runtime_dependency "jwt", "~> 3.2"
end
EOF
cat > "$TMP/gemspec.md" <<'EOF'
# gemspec fixture

<!-- doc-guard: kind=dep source=ruby/keycloak-sdk.gemspec min=2 -->

| 이름 | gem | 버전 |
|---|---|---|
| HTTP | `faraday` | `~> 2.0` |
| JWT | `jwt` | `~> 3.2` |
EOF
assert_ok node "$GUARD" "$TMP"
sed -i 's/~> 3\.2/~> 9.9/' "$TMP/gemspec.md"
assert_fails node "$GUARD" "$TMP"

rm -rf "$TMP" && mkdir -p "$TMP"

# ---- 회귀 10: kind=dep 대조는 **연산자까지 포함해** 한다(normalizeRequirement) ----
# ⚠️ 이 테스트는 한때 정반대를 단언했다 — 매니페스트가 "=26.6.2"여도 문서가 맨 "26.6.2"로
# 적으면 통과해야 한다고. 그게 진짜 드리프트를 통과시킨 사각지대였다: Rust 3개 크레이트를
# 정확 핀에서 캐럿/틸드로 바꿨는데 문서는 여전히 "="를 주장한 채 doc-facts가 초록이었다.
# 의존성 선언에서 연산자는 포맷이 아니라 **값**이다 — 라이브러리에서 "="(정확 핀)는 소비자의
# 의존성 해소를 하드 실패시키고 "~"·"^"는 그렇지 않다. 지금 계약은 "표 셀을 매니페스트가
# 쓴 그대로 적는다"이다.
# 대조군: kind=runtime은 여전히 연산자를 벗긴다(위 회귀의 "22+" ≡ ">=22"). 두 경로가 갈린다는
# 것 자체가 이 변경의 요지이므로, 그쪽 어서션을 지우면 이 구분이 증명되지 않는다.
mkdir -p "$TMP/rust" "$TMP/ruby"
printf '%s\n' '[dependencies]' 'keycloak = { version = "=26.6.2" }' > "$TMP/rust/Cargo.toml"
cat > "$TMP/norm-rust.md" <<'EOF'
# rust pin-operator fixture

<!-- doc-guard: kind=dep source=rust/Cargo.toml min=1 -->

| 이름 | 좌표 | 버전 |
|---|---|---|
| Admin | `keycloak` | `=26.6.2` |
EOF
printf '%s\n' 'Gem::Specification.new do |spec|' '  spec.add_dependency "faraday", "~> 2.0"' 'end' > "$TMP/ruby/keycloak-sdk.gemspec"
cat > "$TMP/norm-ruby.md" <<'EOF'
# ruby pessimistic-operator fixture

<!-- doc-guard: kind=dep source=ruby/keycloak-sdk.gemspec min=1 -->

| 이름 | gem | 버전 |
|---|---|---|
| HTTP | `faraday` | `~> 2.0` |
EOF
# 연산자 표기 차이는 흡수한다 — gemspec은 "~> 2.0"(연산자 뒤 공백), 문서도 같은 표기.
assert_ok node "$GUARD" "$TMP"

# (a) 문서가 연산자를 누락 — 매니페스트는 정확 핀인데 표는 맨숫자. 예전에는 통과했다.
sed -i 's/`=26\.6\.2`/`26.6.2`/' "$TMP/norm-rust.md"
assert_fails node "$GUARD" "$TMP"
sed -i 's/`26\.6\.2`/`=26.6.2`/' "$TMP/norm-rust.md"
assert_ok node "$GUARD" "$TMP" # 되돌리면 다시 통과(위 실패가 연산자 때문임을 고정)

# (b) 핀 방식 자체가 바뀜 — 정확 핀 → 캐럿(실제로 일어났던 그 변경). 값은 그대로다.
sed -i 's/"=26\.6\.2"/"^26.6.2"/' "$TMP/rust/Cargo.toml"
assert_fails node "$GUARD" "$TMP"
sed -i 's/"\^26\.6\.2"/"=26.6.2"/' "$TMP/rust/Cargo.toml"

# (c) 값 자체의 드리프트도 여전히 잡혀야 한다(26.6.2 ≠ 26.6.3) — 연산자 인식이 값 검사를
# 대체한 게 아니라는 증거.
sed -i 's/26\.6\.2/26.6.3/' "$TMP/norm-rust.md"
assert_fails node "$GUARD" "$TMP"

rm -rf "$TMP" && mkdir -p "$TMP"

# ---- 회귀 11: fromGoMod — 괄호 블록·단일 줄·다중 require 블록·// indirect 를 모두
# 파싱해야 하고, module/go 지시어는 의존성 맵에 섞이면 안 된다 ----
# Go 의존성 표 앵커 확장의 신규 추출기. go mod tidy 가 직접 의존과 간접 의존을 서로 다른
# require ( ... ) 블록으로 나누는 것이 관례이므로 **두 번째 블록**의 // indirect 좌표도
# 표가 참조하면 해석돼야 한다(한 블록만 보면 "찾지 못함"으로 거짓 실패). 단일 줄
# `require module v1.2.3` 도 go.mod 문법이 허용하므로 같은 맵에 들어와야 한다.
# ⚠️ 디코이: `go 1.25` 지시어와 `module github.com/...` 줄은 의존성이 아니다 — naive
# 줄 분할 파서가 `go` 를 좌표로 주워 담으면 표 행 `go` | `1.25` 가 조용히 통과한다.
# 그 행은 반드시 "좌표를 찾지 못함"으로 실패해야 한다(런타임 앵커 RUNTIME.go 와 의존성
# 맵이 섞이는 부류의 결함).
mkdir -p "$TMP/go"
cat > "$TMP/go/go.mod" <<'EOF'
module github.com/example/sdk/go

go 1.25

require (
	github.com/Nerzal/gocloak/v13 v13.9.0
	golang.org/x/oauth2 v0.36.0
)

require (
	github.com/golang-jwt/jwt/v5 v5.2.1 // indirect
	github.com/Azure/go-ansiterm v0.0.0-20250102033503-faa5f7b0171c // indirect
)

require github.com/go-jose/go-jose/v4 v4.1.4
EOF
cat > "$TMP/gomod.md" <<'EOF'
# gomod fixture

<!-- doc-guard: kind=dep source=go/go.mod min=4 -->

| 이름 | 좌표 | 버전 |
|---|---|---|
| Admin | `github.com/Nerzal/gocloak/v13` | `v13.9.0` |
| OAuth2 | `golang.org/x/oauth2` | `v0.36.0` |
| Indirect | `github.com/golang-jwt/jwt/v5` | `v5.2.1` |
| JOSE | `github.com/go-jose/go-jose/v4` | `v4.1.4` |
| Pseudo | `github.com/Azure/go-ansiterm` | `v0.0.0-20250102033503-faa5f7b0171c` |
EOF
assert_ok node "$GUARD" "$TMP"

# 버전 드리프트 — 추출기가 살아 있어 실제로 대조함을 고정(빈 맵· vacuous min 통과 금지).
sed -i 's/v13\.9\.0/v99.0.0/' "$TMP/gomod.md"
assert_fails node "$GUARD" "$TMP"
sed -i 's/v99\.0\.0/v13.9.0/' "$TMP/gomod.md"
assert_ok node "$GUARD" "$TMP" # 되돌리면 다시 통과(위 실패가 버전 대조 때문임을 고정)

# 디코이: 좌표 `go` 는 go.mod 의 `go 1.25` 지시어에서 새어 나오면 안 된다.
# 표 행을 디코이 좌표로 바꾼 뒤 "찾지 못함" 메시지를 어서션한다 — assert_fails 만으로는
# min 미달 등 다른 이유로 실패해도 통과하므로(과거 전례) 메시지를 고정한다.
cat > "$TMP/gomod.md" <<'EOF'
# gomod fixture (go-directive decoy)

<!-- doc-guard: kind=dep source=go/go.mod min=1 -->

| 이름 | 좌표 | 버전 |
|---|---|---|
| Runtime leak | `go` | `1.25` |
EOF
OUT="$(node "$GUARD" "$TMP" 2>&1 || true)"
assert_fails node "$GUARD" "$TMP"
assert_contains "$OUT" "좌표 'go' 를 go/go.mod 에서 찾지 못함" "go directive must not leak into the dep map as coordinate 'go'"

rm -rf "$TMP" && mkdir -p "$TMP"

# ---- 회귀 12: fromPyproject — [project].dependencies 와 [project.optional-dependencies]
# 그룹을 병합하고, 복합 지정자·# 주석·extras·환경 마커를 올바르게 다루며, classifiers /
# build-system requires 는 맵에 새면 안 된다 ----
# Python 의존성 표 앵커 확장의 신규 추출기(9/9 언어 커버). fromComposer 와 같이 runtime+dev
# 를 한 맵에 합친다. 실제 python/pyproject.toml 은 `"joserfc>=1.7,<2",   # 보안…` 형태라
# 따옴표 밖 주석을 항목에 붙이면 지정자가 오염되고, classifiers 를 스캔하면
# "Programming Language :: Python :: 3.10" 같은 쓰레기 키가 들어간다 — 둘 다 픽스처에 넣어
# 회귀를 고정한다.
mkdir -p "$TMP/python"
cat > "$TMP/python/pyproject.toml" <<'EOF'
[build-system]
requires = ["hatchling>=1.30"]
build-backend = "hatchling.build"

[project]
name = "keycloak-sdk"
classifiers = [
  "Programming Language :: Python :: 3.10",
  "Development Status :: 4 - Beta",
]
dependencies = [
  "python-keycloak>=7.1,<8",
  "joserfc>=1.7,<2",   # 보안 핵심(JWT 검증) — major 상한 고정
  "uvicorn[standard]>=0.30",
  "tomli>=2 ; python_version < '3.11'",
]

[project.optional-dependencies]
dev = [
  "pytest>=9.0",
  "ruff>=0.6",
]
EOF
cat > "$TMP/pyproject.md" <<'EOF'
# pyproject fixture

<!-- doc-guard: kind=dep source=python/pyproject.toml min=5 -->

| 이름 | 좌표 | 버전 |
|---|---|---|
| Admin | `python-keycloak` | `>=7.1,<8` |
| JWT | `joserfc` | `>=1.7,<2` |
| ASGI | `uvicorn` | `>=0.30` |
| Compat | `tomli` | `>=2` |
| Test | `pytest` | `>=9.0` |
EOF
assert_ok node "$GUARD" "$TMP"

# 버전 드리프트 — 추출기가 살아 있어 실제로 대조함을 고정(빈 맵·vacuous min 통과 금지).
sed -i 's/>=7\.1,<8/>=9.9/' "$TMP/pyproject.md"
assert_fails node "$GUARD" "$TMP"
sed -i 's/>=9\.9/>=7.1,<8/' "$TMP/pyproject.md"
assert_ok node "$GUARD" "$TMP" # 되돌리면 다시 통과(위 실패가 버전 대조 때문임을 고정)

# 디코이: build-system 의 hatchling 은 의존성 맵에 새면 안 된다.
# 표 행을 hatchling 으로 바꾼 뒤 "찾지 못함" 을 어서션 — assert_fails 만으로는 min 미달
# 등 다른 이유로 실패해도 통과하므로(go.mod 디코이와 동일 패턴) 메시지를 고정한다.
# classifiers 문자열("Programming Language :: Python :: 3.10")도 같은 부류라, 맵에 키로
# 들어가면 hatchling 과 무관하게 다른 경로로 오염되지만, hatchling 미해결이 핵심 증거다.
cat > "$TMP/pyproject.md" <<'EOF'
# pyproject fixture (build-system / classifiers decoy)

<!-- doc-guard: kind=dep source=python/pyproject.toml min=1 -->

| 이름 | 좌표 | 버전 |
|---|---|---|
| Build leak | `hatchling` | `>=1.30` |
EOF
OUT="$(node "$GUARD" "$TMP" 2>&1 || true)"
assert_fails node "$GUARD" "$TMP"
assert_contains "$OUT" "좌표 'hatchling' 를 python/pyproject.toml 에서 찾지 못함" "build-system requires must not leak into the dep map as coordinate 'hatchling'"

rm -rf "$TMP" && mkdir -p "$TMP"

# ---- 회귀 13: 검사 8 — 파일 크기 래칫(`<!-- doc-budget: max-bytes=N -->`) ----
# 산문 규칙("CLAUDE.md는 33 KB 이하로 유지한다")은 실패한 전례가 있다 — 이관 직후 44 KB였던
# 파일이 13일 만에 66 KB가 됐다(+50%). 아무도 규칙을 어기려 하지 않았는데도 그렇게 됐다:
# 한 줄씩 늘어나는 것을 사람은 알아챌 수 없다. 래칫은 그 자리를 메운다.
printf '%s\n' '# budget fixture' '<!-- doc-budget: max-bytes=100000 -->' 'x' > "$TMP/under.md"
assert_ok node "$GUARD" "$TMP"

printf '%s\n' '# budget fixture' '<!-- doc-budget: max-bytes=10 -->' 'padding padding padding padding' > "$TMP/over.md"
assert_fails node "$GUARD" "$TMP"
OUT="$(node "$GUARD" "$TMP" 2>&1)" || true
assert_contains "$OUT" "doc-budget" "초과 시 doc-budget 위반을 명시해야 한다"
assert_contains "$OUT" "over.md" "위반 파일명을 지목해야 한다"

# ⚠️ 대조군 — 앵커가 없는 파일은 크기와 무관하게 통과해야 한다. 없으면 "전 문서 크기 제한"이라는
# 전혀 다른(그리고 저장소를 잠그는) 가드가 되어버린 것을 알 수 없다.
rm -f "$TMP/over.md"
printf '%s\n' '# no anchor' 'padding padding padding padding padding padding' > "$TMP/noanchor.md"
assert_ok node "$GUARD" "$TMP"

rm -rf "$TMP" && mkdir -p "$TMP"

# ---- 회귀 13-b: 검사 8은 **적재되는 내용**을 재야 한다(블록 HTML 주석 제외) ----
# 블록 레벨 HTML 주석은 컨텍스트 주입 **전에** 제거되므로 토큰을 1바이트도 쓰지 않는다
# (code.claude.com/docs/en/memory#how-claude-md-files-load). 그런데 래칫이 raw를 재면 그 주석이
# 예산을 잠식한다 — 그리고 이 저장소는 **가드·이관의 설계 근거를 블록 주석으로 남기는** 관용을
# 쓴다. 즉 계상 기준이 틀리면 "근거를 지우는 것"이 예산을 맞추는 최소저항 경로가 된다.
# 이 저장소가 가장 값지게 여기는 바로 그것을. (선례: Claude Code 자신이 v2.1.211에서 같은
# 버그를 고쳤다 — raw를 재던 것을 적재분 기준으로 바꿨다.)
printf '%s\n' '# f' '<!-- doc-budget: max-bytes=60 -->' '<!-- 이 주석은 길지만 적재되지 않는다. 설계 근거를 남기는 자리다. -->' 'x' > "$TMP/c.md"
assert_ok node "$GUARD" "$TMP"

# 대조군 — 같은 분량이 **본문**이면 여전히 실패한다(주석만 면제이지 예산이 헐거워진 것이 아니다).
printf '%s\n' '# f' '<!-- doc-budget: max-bytes=60 -->' '이 문장은 주석이 아니라 본문이라 예산에 그대로 계상된다. 충분히 길게 적는다.' > "$TMP/c.md"
assert_fails node "$GUARD" "$TMP"

# ⚠️ 코드블록 **안**의 주석은 보존된다(같은 공식 문서). 펜스를 무시하고 지우면 예산이 조용히
# 헐거워지고, 주석을 보여주는 문서일수록 더 헐거워진다.
printf '%s\n' '# f' '<!-- doc-budget: max-bytes=40 -->' '```html' '<!-- 코드블록 안이라 보존된다 -->' '```' > "$TMP/c.md"
assert_fails node "$GUARD" "$TMP"
# 대조군 — 같은 주석이 펜스 **밖**이면 제거된다.
printf '%s\n' '# f' '<!-- doc-budget: max-bytes=40 -->' '<!-- 코드블록 밖이라 제거된다 -->' > "$TMP/c.md"
assert_ok node "$GUARD" "$TMP"

# ⚠️ **인라인** 주석은 블록이 아니다 — 앞에 본문이 있으면 그 줄은 통째로 적재된다.
printf '%s\n' '# f' '<!-- doc-budget: max-bytes=30 -->' '본문이 먼저 오고 <!-- 인라인 주석 --> 뒤에도 본문이 있다.' > "$TMP/c.md"
assert_fails node "$GUARD" "$TMP"

# 에러 메시지는 적재분과 raw를 **둘 다** 보여야 한다. 하나만 보이면 "왜 파일 크기와 숫자가
# 다른가"를 사람이 추측하게 되고, 그 추측이 틀리면 상한을 엉뚱하게 올린다.
printf '%s\n' '# f' '<!-- doc-budget: max-bytes=10 -->' '본문이 길다 본문이 길다 본문이 길다' '<!-- 주석 -->' > "$TMP/c.md"
OUT="$(node "$GUARD" "$TMP" 2>&1)" || true
assert_contains "$OUT" "적재" "메시지가 적재 기준임을 밝혀야 한다"
assert_contains "$OUT" "raw" "raw 크기도 함께 보여야 차이를 설명할 수 있다"

# ---- 줄 수 축(`max-lines=N`) — 공식 권고가 줄 기준이므로 바이트만으로는 그 축을 못 본다 ----
printf '%s\n' '# f' '<!-- doc-budget: max-bytes=100000 max-lines=3 -->' 'a' 'b' 'c' 'd' 'e' > "$TMP/c.md"
assert_fails node "$GUARD" "$TMP"
OUT="$(node "$GUARD" "$TMP" 2>&1)" || true
assert_contains "$OUT" "max-lines" "줄 수 초과를 지목해야 한다"
# 대조군 — 상한 안이면 통과한다.
printf '%s\n' '# f' '<!-- doc-budget: max-bytes=100000 max-lines=10 -->' 'a' 'b' > "$TMP/c.md"
assert_ok node "$GUARD" "$TMP"
# 하위호환 — `max-lines`가 없으면 줄 수는 보지 않는다(기존 앵커를 깨지 않는다).
printf '%s\n' '# f' '<!-- doc-budget: max-bytes=100000 -->' 'a' 'b' 'c' 'd' 'e' 'f' 'g' 'h' > "$TMP/c.md"
assert_ok node "$GUARD" "$TMP"

# ⚠️ 앵커는 있는데 `max-bytes`가 없으면 **실패**여야 한다. 오타 하나(`maxbytes=`)로 래칫이
# 조용히 사라지는 것이 가드를 무력화하는 최소저항 경로가 되어서는 안 된다 — 검사 9가
# "지도를 지우는 것으로 검사를 없앨 수 없다"를 고정한 것과 같은 이유다.
printf '%s\n' '# f' '<!-- doc-budget: maxbytes=100 -->' 'x' > "$TMP/c.md"
assert_fails node "$GUARD" "$TMP"
OUT="$(node "$GUARD" "$TMP" 2>&1)" || true
assert_contains "$OUT" "max-bytes" "앵커에 max-bytes가 없으면 지목해야 한다"

rm -rf "$TMP" && mkdir -p "$TMP"

# ---- 회귀 14: 검사 9 — docs/ 지도 완전성 + 상태 대조 ----
# 두 가지 드리프트가 실제로 일어난다: 문서를 추가하고 지도에 안 넣는 것, 문서를 지우고 지도를
# 안 고치는 것. 한 방향만 검사하면 반대쪽이 그대로 통과하므로 양방향으로 본다. 세 번째로,
# 지도의 상태 칸은 손으로 적는 값이라 그 자체가 복제본이 된다 — 그래서 각 문서의
# `<!-- doc-status: -->` 마커를 진실 원천으로 두고 대조한다.
mkdir -p "$TMP/docs/sub"
printf '%s\n' '# a' '<!-- doc-status: complete -->' > "$TMP/docs/sub/a.md"
printf '%s\n' '# map' '' '| 문서 | 상태 | 여기서만 알 수 있는 것 |' '|---|---|---|' '| [a](sub/a.md) | 완료 | 이 문서에만 있는 것을 충분히 길게 적어 둔 마지막 칸이다 |' > "$TMP/docs/README.md"
assert_ok node "$GUARD" "$TMP"

# 지도에 없는 문서 → 실패
printf '%s\n' '# b' '<!-- doc-status: complete -->' > "$TMP/docs/sub/b.md"
assert_fails node "$GUARD" "$TMP"
OUT="$(node "$GUARD" "$TMP" 2>&1)" || true
assert_contains "$OUT" "docs/sub/b.md 이 docs/README.md 에 없다" "새 문서를 지도에 안 넣으면 지목해야 한다"
rm -f "$TMP/docs/sub/b.md"

# 지도가 없는 문서를 가리킴 → 실패
printf '%s\n' '# map' '' '| 문서 | 상태 | 여기서만 알 수 있는 것 |' '|---|---|---|' '| [a](sub/a.md) | 완료 | 이 문서에만 있는 것을 충분히 길게 적어 둔 마지막 칸이다 |' '| [gone](sub/gone.md) | 완료 | 이 문서에만 있는 것을 충분히 길게 적어 둔 마지막 칸이다 |' > "$TMP/docs/README.md"
assert_fails node "$GUARD" "$TMP"
OUT="$(node "$GUARD" "$TMP" 2>&1)" || true
assert_contains "$OUT" "존재하지 않는 docs/sub/gone.md" "지운 문서가 지도에 남아 있으면 지목해야 한다"

# 상태 불일치(문서=complete, 지도=진행) → 실패
printf '%s\n' '# map' '' '| 문서 | 상태 | 여기서만 알 수 있는 것 |' '|---|---|---|' '| [a](sub/a.md) | 진행 | 이 문서에만 있는 것을 충분히 길게 적어 둔 마지막 칸이다 |' > "$TMP/docs/README.md"
assert_fails node "$GUARD" "$TMP"
OUT="$(node "$GUARD" "$TMP" 2>&1)" || true
assert_contains "$OUT" "문서가 선언한 상태='완료'" "마커와 지도가 어긋나면 지목해야 한다"

# 마커 없는 문서는 '운영'이어야 한다 — 마커를 지우는 것으로 대조를 피할 수 없게 한다.
printf '%s\n' '# a' > "$TMP/docs/sub/a.md"
printf '%s\n' '# map' '' '| 문서 | 상태 | 여기서만 알 수 있는 것 |' '|---|---|---|' '| [a](sub/a.md) | 완료 | 이 문서에만 있는 것을 충분히 길게 적어 둔 마지막 칸이다 |' > "$TMP/docs/README.md"
assert_fails node "$GUARD" "$TMP"
printf '%s\n' '# map' '' '| 문서 | 상태 | 여기서만 알 수 있는 것 |' '|---|---|---|' '| [a](sub/a.md) | 운영 | 이 문서에만 있는 것을 충분히 길게 적어 둔 마지막 칸이다 |' > "$TMP/docs/README.md"
assert_ok node "$GUARD" "$TMP"

# ⚠️ 표 행이 아니라 산문 링크면 실패해야 한다. 여기서 조용히 넘어가면 표 서식이 바뀌는 순간
# 대조 대상이 0건이 되어 검사 전체가 공허하게 통과한다 — 이 가드가 막으려는 실패 그 자체다.
printf '%s\n' '# map' '' '- [a](sub/a.md) — 운영' > "$TMP/docs/README.md"
assert_fails node "$GUARD" "$TMP"
OUT="$(node "$GUARD" "$TMP" 2>&1)" || true
assert_contains "$OUT" "표 행으로 색인돼 있지 않다" "산문 링크만 있으면 지목해야 한다"

# 지도 자체를 지우는 것으로도 검사를 없앨 수 없다.
printf '%s\n' '# map' '' '| 문서 | 상태 | 여기서만 알 수 있는 것 |' '|---|---|---|' '| [a](sub/a.md) | 운영 | 이 문서에만 있는 것을 충분히 길게 적어 둔 마지막 칸이다 |' > "$TMP/docs/README.md"
assert_ok node "$GUARD" "$TMP"
rm -f "$TMP/docs/README.md"
assert_fails node "$GUARD" "$TMP"
OUT="$(node "$GUARD" "$TMP" 2>&1)" || true
assert_contains "$OUT" "docs/README.md 이 없다" "지도를 지우면 그 자체가 실패여야 한다"

# 완료 배너가 실행 지시보다 뒤에 있으면 실패해야 한다 — 존재만 검사하면 순서가 뒤집힌 것을
# 못 본다. 위에서부터 읽는 에이전트는 배너 전에 지시를 받게 되므로 배너가 무의미해진다.
printf '%s\n' '# plan' '> For agentic workers: implement this plan task-by-task.' '<!-- doc-status: complete -->' > "$TMP/docs/sub/a.md"
printf '%s\n' '# map' '' '| 문서 | 상태 | 여기서만 알 수 있는 것 |' '|---|---|---|' '| [a](sub/a.md) | 완료 | 이 문서에만 있는 것을 충분히 길게 적어 둔 마지막 칸이다 |' > "$TMP/docs/README.md"
assert_fails node "$GUARD" "$TMP"
OUT="$(node "$GUARD" "$TMP" 2>&1)" || true
assert_contains "$OUT" "실행 지시보다 뒤에 있다" "배너가 지시 뒤에 있으면 지목해야 한다"
# 순서를 바로잡으면 통과해야 한다(대조군 — 없으면 "지시가 있으면 무조건 실패"인 가드와 구분 못 함).
printf '%s\n' '# plan' '<!-- doc-status: complete -->' '> For agentic workers: implement this plan task-by-task.' > "$TMP/docs/sub/a.md"
assert_ok node "$GUARD" "$TMP"

# 마지막 칸("여기서만 알 수 있는 것")이 비어 있으면 실패해야 한다.
# ⚠️ 이게 없으면 가드가 **자기가 못 잡는 열화를 유도한다** — 검사 9가 새 문서마다 지도에 줄을
# 요구하므로 최소저항 경로가 "빈 칸으로 한 줄 추가"가 되고, 그 순간 지도는 파일 목록으로 퇴화한다.
printf '%s\n' '# plan' '<!-- doc-status: complete -->' > "$TMP/docs/sub/a.md"
printf '%s\n' '# map' '' '| 문서 | 상태 | 여기서만 알 수 있는 것 |' '|---|---|---|' '| [a](sub/a.md) | 완료 |  |' > "$TMP/docs/README.md"
assert_fails node "$GUARD" "$TMP"
OUT="$(node "$GUARD" "$TMP" 2>&1)" || true
assert_contains "$OUT" "마지막 칸" "빈 마지막 칸을 지목해야 한다"
# ⚠️ 채움문자로 길이만 맞춘 칸도 잡아야 한다. 처음에는 공백·`—`·`·`만 벗겼는데, 마침표나
# 하이픈을 20개 늘어놓으면 그대로 통과했다(실측 7종). 유니코드 구두점/기호 클래스로 벗긴다.
for filler in '....................' '--------------------' '____________________' '••••••••••••••••••••'; do
  printf '%s\n' '# map' '' '| 문서 | 상태 | 여기서만 알 수 있는 것 |' '|---|---|---|' "| [a](sub/a.md) | 완료 | $filler |" > "$TMP/docs/README.md"
  assert_fails node "$GUARD" "$TMP"
done
# 한 단어짜리도 잡아야 한다(비어있음만 보면 "분해."로 통과한다).
printf '%s\n' '# map' '' '| 문서 | 상태 | 여기서만 알 수 있는 것 |' '|---|---|---|' '| [a](sub/a.md) | 완료 | 태스크 분해. |' > "$TMP/docs/README.md"
assert_fails node "$GUARD" "$TMP"
# 대조군 — 충분히 적으면 통과한다(없으면 "마지막 칸은 무조건 실패"인 가드와 구분 못 함).
printf '%s\n' '# map' '' '| 문서 | 상태 | 여기서만 알 수 있는 것 |' '|---|---|---|' '| [a](sub/a.md) | 완료 | 이 문서에만 있는 것을 충분히 길게 적어 둔 마지막 칸이다 |' > "$TMP/docs/README.md"
assert_ok node "$GUARD" "$TMP"

# ⚠️ 배너 순서 검사는 마커의 **실제 위치**를 봐야 한다. 첫 `doc-status:` 문자열 등장을 쓰면,
# 이 규약을 설명하느라 본문에서 그 문자열을 언급하는 문서에서 검사가 공허하게 통과한다.
printf '%s\n' '# plan' '이 저장소는 doc-status: 마커로 문서 상태를 표시한다(본문의 언급).' \
  '> For agentic workers: implement this plan task-by-task.' '<!-- doc-status: complete -->' > "$TMP/docs/sub/a.md"
assert_fails node "$GUARD" "$TMP"
OUT="$(node "$GUARD" "$TMP" 2>&1)" || true
assert_contains "$OUT" "실행 지시보다 뒤에 있다" "본문 언급이 있어도 마커 위치로 판정해야 한다"
printf '%s\n' '# plan' '<!-- doc-status: complete -->' \
  '> For agentic workers: implement this plan task-by-task.' '본문에서 doc-status: 를 언급한다.' > "$TMP/docs/sub/a.md"
assert_ok node "$GUARD" "$TMP"

# ⚠️ 완전한 마커가 **둘 이상**이면 실패해야 한다. 본문에 규약의 *예시*로 마커를 적어둔 문서가
# 생기면 첫 매치가 배너가 아니게 되어, 배너 순서 검사와 상태 대조가 둘 다 예시 기준이 된다
# (그 상태로 배너를 지시 뒤로 옮겨도 통과한다). 어느 것이 진실인지 고를 수 없으니 실패시킨다.
printf '%s\n' '# plan' '예시: <!-- doc-status: active -->' \
  '> For agentic workers: implement this plan task-by-task.' '<!-- doc-status: complete -->' > "$TMP/docs/sub/a.md"
assert_fails node "$GUARD" "$TMP"
OUT="$(node "$GUARD" "$TMP" 2>&1)" || true
assert_contains "$OUT" "마커가 2개다" "마커가 둘 이상이면 지목해야 한다"

# ⚠️ 검사 9가 실패했는데 자기 초록 요약을 함께 찍으면 안 된다(요약이 검사가 돌았다는 신호이자
# 통과 신호로 읽힌다). 지도가 없는 파일을 가리키는 상태에서 요약이 나오면 안 된다.
printf '%s\n' '# plan' '<!-- doc-status: complete -->' > "$TMP/docs/sub/a.md"
printf '%s\n' '# map' '' '| 문서 | 상태 | 여기서만 알 수 있는 것 |' '|---|---|---|' \
  '| [a](sub/a.md) | 완료 | 이 문서에만 있는 것을 충분히 길게 적어 둔 마지막 칸이다 |' \
  '| [gone](sub/gone.md) | 완료 | 이 문서에만 있는 것을 충분히 길게 적어 둔 마지막 칸이다 |' > "$TMP/docs/README.md"
OUT="$(node "$GUARD" "$TMP" 2>&1)" || true
assert_not_contains "$OUT" "files linked" "실패한 검사가 자기 초록 요약을 찍으면 안 된다"

# ⚠️ 대조군 — docs/ 가 없는 트리는 이 검사의 대상이 아니다(가드 자신의 픽스처가 그렇다).
# 없으면 "모든 저장소에 docs/README.md를 요구"하는 전혀 다른 가드가 된 것을 알 수 없다.
rm -rf "$TMP/docs"
printf '%s\n' '# unrelated' > "$TMP/x.md"
assert_ok node "$GUARD" "$TMP"
rm -f "$TMP/x.md"

# ---- 회귀 15: 검사 9 — "미체크 0건인데 doc-status: active"(끝난 일이 「진행」을 가장) ----
# 검사 9의 마커↔지도 대조는 **둘이 함께 틀리면 침묵한다.** 실제로 그랬다: 하네스 계획서가
# 미체크 0 / 체크 69인 채 마커도 '진행' 지도도 '진행'이라 서로 정합이었고 가드는 초록이었다 —
# 일이 다 끝난 45 KB 문서가 「진행」을 주장하는데 기계가 볼 수 있는 자리가 없었다.
# 이 검사에는 외부 SSOT가 없다. 대신 `docs/README.md` 범례가 불변식을 **이미 선언한다**:
# 「진행 | 아직 열려 있는 작업. **체크박스가 실제 할 일이다**」. 그 선언을 기계로 집행한다.
mkdir -p "$TMP/docs/sub"
printf '%s\n' '# plan' '<!-- doc-status: active -->' '- [x] 하나' '- [x] 둘' > "$TMP/docs/sub/a.md"
printf '%s\n' '# map' '' '| 문서 | 상태 | 여기서만 알 수 있는 것 |' '|---|---|---|' '| [a](sub/a.md) | 진행 | 이 문서에만 있는 것을 충분히 길게 적어 둔 마지막 칸이다 |' > "$TMP/docs/README.md"
assert_fails node "$GUARD" "$TMP"
OUT="$(node "$GUARD" "$TMP" 2>&1)" || true
assert_contains "$OUT" "미체크 항목이 0건" "전 항목이 닫힌 계획서가 '진행'을 주장하면 지목해야 한다"

# 대조군 — 미체크가 하나라도 있으면 통과한다. 없으면 "active면 무조건 실패"인 전혀 다른
# 가드가 된 것을 알 수 없다(이 파일의 다른 대조군들과 같은 이유).
printf '%s\n' '# plan' '<!-- doc-status: active -->' '- [x] 하나' '- [ ] 둘' > "$TMP/docs/sub/a.md"
assert_ok node "$GUARD" "$TMP"

# ⚠️ **역방향은 구현하지 않는다** — "미체크 > 0 ⇒ 반드시 active"는 거짓이다. 기각한 항목은
# 미체크로 남는 것이 정상이고(계획서 전례: B1·B2·B3·D2가 그렇게 남았다), 그것을 실패시키면
# 가드가 "기각을 금지"하는 정책을 새로 만드는 셈이 된다. 미체크가 남은 'complete'는 통과다.
printf '%s\n' '# plan' '<!-- doc-status: complete -->' '> For agentic workers: implement this plan task-by-task.' '- [x] 한 일' '- [ ] 기각한 항목' > "$TMP/docs/sub/a.md"
printf '%s\n' '# map' '' '| 문서 | 상태 | 여기서만 알 수 있는 것 |' '|---|---|---|' '| [a](sub/a.md) | 완료 | 이 문서에만 있는 것을 충분히 길게 적어 둔 마지막 칸이다 |' > "$TMP/docs/README.md"
assert_ok node "$GUARD" "$TMP"

# ⚠️ 체크박스를 **전부 지우는 것**으로 우회할 수 없어야 한다. "체크된 것이 있는데 미체크가 0"만
# 보면 최소저항 경로가 "체크박스를 지운다"가 되고, 그 순간 지도의 '진행'은 아무것도 뜻하지 않게
# 된다 — 가드를 무력화하는 가장 쉬운 방법이 가드가 지키는 것을 지우는 것이어서는 안 된다.
printf '%s\n' '# plan' '<!-- doc-status: active -->' '체크박스가 하나도 없는 산문 계획서다.' > "$TMP/docs/sub/a.md"
printf '%s\n' '# map' '' '| 문서 | 상태 | 여기서만 알 수 있는 것 |' '|---|---|---|' '| [a](sub/a.md) | 진행 | 이 문서에만 있는 것을 충분히 길게 적어 둔 마지막 칸이다 |' > "$TMP/docs/README.md"
assert_fails node "$GUARD" "$TMP"

# ⚠️ 코드펜스 안의 **예시** 체크박스로 만족시킬 수 없어야 한다. doc-status 마커에서 이미 같은
# 부류에 당했다 — 규약을 *설명하는* 문서의 예시가 배너보다 먼저 잡혀 검사가 공허하게 통과했다.
# 여기서도 ``` 안의 `- [ ]` 하나면 끝난 계획서가 영원히 열린 것처럼 보일 수 있다.
printf '%s\n' '# plan' '<!-- doc-status: active -->' '- [x] 하나' '' '```sh' '- [ ] 예시일 뿐이다' '```' > "$TMP/docs/sub/a.md"
assert_fails node "$GUARD" "$TMP"
# 대조군 — 펜스 **밖**의 같은 문자열은 여전히 유효한 미체크다(펜스 제거가 과잉이면 이게 깨진다).
printf '%s\n' '# plan' '<!-- doc-status: active -->' '- [x] 하나' '' '```sh' 'echo 예시' '```' '- [ ] 진짜 남은 일' > "$TMP/docs/sub/a.md"
assert_ok node "$GUARD" "$TMP"

# 마커 없는 문서('운영')는 체크박스와 무관하다 — 이 검사는 'active'에만 건다. 운영 문서에
# 체크박스를 요구하면 `docs/governance/working-loop.md` 부류가 통째로 빨개진다.
printf '%s\n' '# living' '운영 문서에는 체크박스가 없어도 된다.' > "$TMP/docs/sub/a.md"
printf '%s\n' '# map' '' '| 문서 | 상태 | 여기서만 알 수 있는 것 |' '|---|---|---|' '| [a](sub/a.md) | 운영 | 이 문서에만 있는 것을 충분히 길게 적어 둔 마지막 칸이다 |' > "$TMP/docs/README.md"
assert_ok node "$GUARD" "$TMP"

rm -rf "$TMP" && mkdir -p "$TMP"

assert_report
