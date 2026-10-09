#!/usr/bin/env sh
# 커버리지 omit 조인 가드(`scripts/coverage-boundary.mjs`) 자가테스트.
#
# ⚠️ **커밋된 픽스처만 쓴다** — 실제 트리를 읽지 않는다. 실제 트리의 대조는 repo-hygiene 의
# `coverage-boundary` 잡이 한다(비-required). 여기서 재는 것은 「가드가 드리프트를 잡는가 · 잡으면
# 안 되는 것을 잡지는 않는가 · 못 읽는 것을 통과로 넘기지 않는가」 셋이다.
# 가드는 `git ls-files` 로 파일을 세므로 픽스처 사본을 git 저장소로 만든다(커밋은 필요 없다).
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
FIX="$DIR/fixtures/coverage-boundary"
GUARD="$DIR/../coverage-boundary.mjs"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
T="$TMP/t"

fresh() {
  rm -rf "$T"
  mkdir -p "$T"
  cp -r "$FIX/." "$T/"
  git -C "$T" init -q
  # 개발 PC 의 전역 autocrlf 가 줄마다 경고를 쏟지 않게 — 가드는 CRLF 를 스스로 정규화한다.
  git -C "$T" config core.autocrlf false
  git -C "$T" add -A
}
# 가드를 돌려 OUT·RC 에 담는다(`set -e` 아래에서 비영 종료를 삼키지 않고 값으로 받는다).
run() {
  git -C "$T" add -A
  OUT="$(node "$GUARD" "$@" 2>&1)" && RC=0 || RC=$?
}

# ── 대조군: 정상 픽스처는 통과한다 ──────────────────────────────────────────────────────────
fresh
run check "$T"
assert_eq 0 "$RC" "정상 픽스처는 exit 0 이어야 한다 — 출력: $OUT"
assert_contains "$OUT" "coverage-boundary: OK" "통과 요약을 찍는다"
# 펼친 집합이 도구의 의미론대로인가(수가 아니라 이름으로 본다).
run list "$T"
assert_eq 0 "$RC" "list 는 exit 0"
assert_contains "$OUT" "python/src/keycloak_sdk/aio/auth.py" "[python] coverage.py 의 선두 */ 는 aio/auth.py 까지 잡는다"
assert_not_contains "$OUT" "python/src/keycloak_sdk/config.py" "[python] 주석 속 omit 항목은 세지 않는다"
assert_contains "$OUT" "[java] SSOT java/pom.xml:14 (jacoco <excludes>) → 2 / 4 files" "[java] 주석 속 exclude 는 세지 않는다 · jacoco.skip 모듈은 통째로 omit"
assert_contains "$OUT" "java/mod-examples/src/main/java/p/examples/Demo.java  (jacoco.skip)" "[java] skip 모듈의 파일은 이유와 함께 omit 으로 든다"
assert_contains "$OUT" "kotlin/src/main/kotlin/p/admin/AdminClient.kt" "[kotlin] admin.* 는 파일 파사드(AdminClientKt)까지 덮는다"
assert_not_contains "$OUT" "kotlin/src/main/kotlin/p/config.kt" "[kotlin] config.kt(ConfigKt) 는 재는 쪽이다"
assert_contains "$OUT" "[dotnet] SSOT dotnet/coverlet.runsettings:9 (coverlet <Exclude>) → 2 / 4 files" "[dotnet] 중첩 타입은 부모를 따른다 · 제약절의 class 는 선언이 아니다"
assert_not_contains "$OUT" "node/src/transport.ts" "[node] test.exclude·thresholds.exclude 는 커버리지 목록이 아니다"
assert_contains "$OUT" "[ruby] SSOT ruby/spec/spec_helper.rb:7 (SimpleCov skip) → 2 / 4 files" "[ruby] 문자열·정규식 skip 을 SimpleCov 1.2 의미론으로 편다"
run list "$T" --lang rust
assert_contains "$OUT" "[rust]" "--lang 은 그 언어를 찍는다"
assert_not_contains "$OUT" "[go]" "--lang 은 다른 언어를 찍지 않는다"
# `list --json` — 통합 전용 커버리지 리포트(`scripts/integration-coverage.mjs`)가 파일 집합을 파생하는 계약.
run list "$T" --json
assert_eq 0 "$RC" "list --json 은 exit 0"
assert_contains "$OUT" '"python/src/keycloak_sdk/aio/auth.py"' "[json] 텍스트 판과 같은 전개를 낸다"
assert_contains "$OUT" '"site": "python/pyproject.toml:9"' "[json] SSOT 자리를 함께 낸다"
assert_contains "$OUT" '"findings": []' "[json] 건강한 트리는 findings 가 비었다"

# ── 드리프트 1: Sonar 글롭이 게이트가 재는 파일을 삼킨다(php `Admin/**` 의 원형) ───────────
fresh
sed -i 's|php/src/Admin/AdminClient.php|php/src/Admin/**|' "$T/sonar-project.properties"
run check "$T"
assert_eq 1 "$RC" "Sonar 가 더 많이 빼면 DRIFT(exit 1)"
assert_contains "$OUT" "DRIFT sonar-project.properties:12 [php] vs SSOT php/phpunit.xml:10 — extra: php/src/Admin/ErrorTranslation.php" "빠진 파일을 이름으로 댄다"

# ── 드리프트 2: 게이트는 재는데 Sonar 가 빼는 손 목록 항목(node transport 의 원형) ─────────
fresh
sed -i 's|node/src/index.ts,|node/src/index.ts,node/src/transport.ts,|' "$T/sonar-project.properties"
run check "$T"
assert_eq 1 "$RC" "사본만 빼는 파일은 DRIFT"
assert_contains "$OUT" "[node] vs SSOT node/vitest.config.ts:12 — extra: node/src/transport.ts" "node extra"

# ── 드리프트 3: SSOT 가 빼는데 Sonar 가 안 빼면 missing ──────────────────────────────────
fresh
sed -i 's|rust/src/client.rs,||' "$T/sonar-project.properties"
run check "$T"
assert_eq 1 "$RC" "사본이 덜 빼도 DRIFT"
assert_contains "$OUT" "[rust] vs SSOT .github/workflows/rust-ci.yml:8 — missing: rust/src/client.rs" "rust missing"

# ── 드리프트 4: 하네스 정규식이 앵커를 잃는다(rust.sh 의 원형) — 집합 차이까지 댄다 ─────
fresh
sed -i 's#"(^|\[\\\\\\\\/\])(auth|admin|client)\\.rs\\\$"#"(auth|admin|client)\\.rs"#' "$T/harness/suites/rust.sh"
assert_contains "$(cat "$T/harness/suites/rust.sh")" '"(auth|admin|client)\.rs"' "(변이가 착지했는지 먼저 본다)"
run check "$T"
assert_eq 1 "$RC" "무앵커 사본은 DRIFT"
assert_contains "$OUT" "DRIFT harness/suites/rust.sh:5 [rust] regex differs from SSOT .github/workflows/rust-ci.yml:8 — copy: (auth|admin|client)\\.rs · ssot: (^|[\\\\/])(auth|admin|client)\\.rs\$ — files extra: rust/src/oauth.rs" "무앵커는 oauth.rs 를 삼킨다"

# ── 드리프트 5: 인용을 벗긴 값으로 비교한다 — 글자는 같아 보여도 안쪽 셸이 `\\` 를 먹는다 ──
fresh
sed -i 's#\[\\\\\\\\/\]#[\\\\/]#' "$T/harness/suites/rust.sh"
assert_contains "$(cat "$T/harness/suites/rust.sh")" '"(^|[\\/])(auth' "(변이가 착지했는지 먼저 본다)"
run check "$T"
assert_eq 1 "$RC" "큰따옴표 안의 [\\\\/] 는 [\\/] 가 된다 — 문자 그대로는 같아 보여도 DRIFT"
assert_contains "$OUT" "copy: (^|[\\/])(auth|admin|client)\\.rs\$" "벗긴 값을 보고한다"

# ── 드리프트 6: 규칙 문서의 전사가 낡는다 ────────────────────────────────────────────────
fresh
sed -i 's#admin|admin_users)#admin)#' "$T/.claude/rules/go.md"
run check "$T"
assert_eq 1 "$RC" "go.md 전사가 갈리면 DRIFT"
assert_contains "$OUT" "DRIFT .claude/rules/go.md:3 [go]" "go.md 자리"
assert_contains "$OUT" "files missing: go/admin_users.go" "go.md 의 집합 차이"

# ── 드리프트 7: kotlin.md 가 예로 드는 패턴이 SSOT 에서 사라진다 ─────────────────────────
fresh
sed -i 's#"p.AuthClient\*"#"p.AuthClientImpl*"#' "$T/kotlin/build.gradle.kts"
run check "$T"
assert_contains "$OUT" "DRIFT .claude/rules/kotlin.md:3 [kotlin] mentions Kover pattern \`AuthClient*\`" "낡은 예시를 잡는다"

# ── 드리프트 8: 등록 안 된 새 사본(워크플로 run 스크립트) ───────────────────────────────
fresh
printf '      - run: cargo llvm-cov --ignore-filename-regex %s\n' "'(auth)\\.rs'" >> "$T/.github/workflows/other.yml"
run check "$T"
assert_eq 1 "$RC" "등록 안 된 사본은 DRIFT"
assert_contains "$OUT" "DRIFT .github/workflows/other.yml:8 [rust] unregistered copy" "새 사본 자리를 댄다"

# ── 게이트가 **통째로** 안 재는 파일도 omit 이다(Grok 레그가 찾은 SILENT 셋) ─────────────
# jacoco.skip 모듈 — 모집단에서 빼 버리면 모듈 하나를 skip 해도 아무도 안 본다.
fresh
sed -i 's#<artifactId>mod-auth</artifactId>#<artifactId>mod-auth</artifactId><properties><jacoco.skip>true</jacoco.skip></properties>#' "$T/java/mod-auth/pom.xml"
run check "$T"
assert_eq 1 "$RC" "jacoco.skip 모듈의 파일을 Sonar 가 안 빼면 DRIFT"
assert_contains "$OUT" "[java] vs SSOT java/pom.xml:14 — missing: java/mod-auth/src/main/java/p/auth/Pkce.java" "skip 모듈 전부가 omit"
# 비색인 대조군 — examples 는 sonar.exclusions 로 색인되지 않으므로 skip 이어도 사본이 뺄 필요가 없다.
fresh
sed -i 's#^sonar.exclusions=\*\*/examples/\*\*,#sonar.exclusions=#' "$T/sonar-project.properties"
run check "$T"
assert_eq 1 "$RC" "색인되는 skip 모듈 파일은 Sonar 가 빼야 한다"
assert_contains "$OUT" "missing: java/mod-examples/src/main/java/p/examples/Demo.java" "색인되면 드리프트"
# vitest coverage.include 밖 — include 를 좁히면 빠진 파일은 게이트 밖이다.
fresh
sed -i "s#include: \['src/\*\*/\*.ts'\],#include: ['src/index.ts', 'src/auth.ts', 'src/config.ts', 'src/admin/*.ts'],#" "$T/node/vitest.config.ts"
assert_contains "$(cat "$T/node/vitest.config.ts")" "'src/admin/*.ts'" "(변이가 착지했는지 먼저 본다)"
run check "$T"
assert_eq 1 "$RC" "include 를 좁혔는데 Sonar 가 안 따라오면 DRIFT"
assert_contains "$OUT" "[node] vs SSOT node/vitest.config.ts:12 — missing: node/src/transport.ts" "include 밖 파일을 댄다"
# phpunit <include> 밖 — 같은 판정.
fresh
sed -i 's#<include><directory>src</directory></include>#<include><directory>src/Admin</directory><file>src/AuthClient.php</file></include>#' "$T/php/phpunit.xml"
run check "$T"
assert_eq 1 "$RC" "phpunit include 를 좁혔는데 Sonar 가 안 따라오면 DRIFT"
assert_contains "$OUT" "[php] vs SSOT php/phpunit.xml:10 — missing: php/src/Config.php" "php include 밖"
# SimpleCov 모듈 메서드 호출 — 블록 밖 `SimpleCov.add_filter` 도 같은 필터다.
fresh
printf 'SimpleCov.add_filter("lib/sdk/config.rb")\n' >> "$T/ruby/spec/spec_helper.rb"
run check "$T"
assert_eq 1 "$RC" "SimpleCov.add_filter 로 늘린 omit 을 Sonar 가 모르면 DRIFT"
assert_contains "$OUT" "[ruby] vs SSOT ruby/spec/spec_helper.rb:7 — missing: ruby/lib/sdk/config.rb" "모듈 메서드 필터를 읽는다"

# ── 정규식 사본의 모양 — 긴 옵션 · 종류별 등록 · 전개 ────────────────────────────────────
fresh
sed -i 's#^\(  grep -vE .*/tmp/cover.filtered\)$#\1\n  grep --extended-regexp --invert-match "/(auth)\\.go:" /tmp/cover.out > /tmp/cover.2#' "$T/harness/suites/go.sh"
assert_contains "$(cat "$T/harness/suites/go.sh")" "--invert-match" "(변이가 착지했는지 먼저 본다)"
run check "$T"
assert_eq 1 "$RC" "긴 옵션으로 쓴 둘째 필터도 사본이다"
assert_contains "$OUT" "DRIFT harness/suites/go.sh:6 [go] regex differs" "긴 옵션 필터를 읽는다"
fresh
printf '  grep -v "/(auth)\\.go:" /tmp/cover.out\n' >> "$T/harness/suites/go.sh"
run check "$T"
assert_eq 2 "$RC" "-E 없는 반전 grep 은 문법이 달라 FAIL"
fresh
sed -i 's#^      - uses: SonarSource#      - run: grep -vE "/(nope)\\.go:" cover.out > x\n      - uses: SonarSource#' "$T/.github/workflows/sonarcloud.yml"
run check "$T"
assert_eq 1 "$RC" "llvm-cov 사본 자리라도 grep 사본은 등록 밖이다"
assert_contains "$OUT" "DRIFT .github/workflows/sonarcloud.yml:12 [go] unregistered copy" "종류별 등록"
fresh
sed -i 's#"(^|\[\\\\\\\\/\])(auth|admin|client)\\.rs\\\$"#"$COV_IGNORE"#' "$T/harness/suites/rust.sh"
assert_contains "$(cat "$T/harness/suites/rust.sh")" '"$COV_IGNORE"' "(변이가 착지했는지 먼저 본다)"
run check "$T"
assert_eq 2 "$RC" "셸 전개가 낀 값은 FAIL"
assert_contains "$OUT" "FAIL harness/suites/rust.sh:5 [rust]" "전개 자리를 댄다"

# ── 파생 규칙: dotnet 은 Sonar 리포트가 없으므로 Sonar 가 **전부** 빼야 한다 ──────────────
fresh
sed -i 's#dotnet/src/\*\*,##' "$T/sonar-project.properties"
run check "$T"
assert_eq 1 "$RC" "리포트 없는 언어를 Sonar 가 안 빼면 DRIFT"
assert_contains "$OUT" "[dotnet] vs derived rule (no dotnet coverage report in sonar-project.properties → all 4 files) — missing:" "파생 규칙으로 판정한다(면제 목록이 아니다)"
# 리포트 경로가 생기면 기대값이 SSOT 로 바뀐다 — 이제는 전부 빼는 것이 드리프트다.
fresh
printf 'sonar.cs.opencover.reportsPaths=x\nsonar.cs.vscoveragexml.reportPaths=dotnet/coverage.xml\n' >> "$T/sonar-project.properties"
run check "$T"
assert_eq 1 "$RC" "C# 리포트가 생긴 뒤 dotnet/src/** 는 DRIFT"
assert_contains "$OUT" "[dotnet] vs SSOT dotnet/coverlet.runsettings:9 — extra:" "기대값이 coverlet SSOT 로 바뀐다"
# 선두 `./` 도 같은 리포트 경로다.
fresh
printf 'sonar.cs.opencover.reportsPaths=./dotnet/coverage.opencover.xml\n' >> "$T/sonar-project.properties"
run check "$T"
assert_eq 1 "$RC" "./dotnet/… 리포트 경로도 파생 규칙을 뒤집는다"
assert_contains "$OUT" "[dotnet] vs SSOT dotnet/coverlet.runsettings:9 — extra:" "./ 정규화"

# ── 오탐 방지: 주석·테스트 파일·모양 안내는 사본이 아니다 ────────────────────────────────
fresh
printf '# cargo llvm-cov --ignore-filename-regex %s\n' "'nope'" >> "$T/harness/suites/other.sh"
printf 'sonar.coverage.exclusions.note=unused\n' >> "$T/sonar-project.properties"
sed -i 's|go/\*\*/\*_test.go|go/**/*_test.go,go/config_test.go|' "$T/sonar-project.properties"
run check "$T"
assert_eq 0 "$RC" "셸 주석 속 명령 · 테스트 파일만 건드리는 Sonar 항목은 드리프트가 아니다 — 출력: $OUT"

# ── 실패(FAIL, exit 2): 못 읽는 것을 통과로 넘기지 않는다 ────────────────────────────────
# SSOT 가 0 파일로 펼쳐진다.
fresh
sed -i 's#"\*/auth.py"#"*/nope.py"#; s#"\*/admin/__init__.py"#"*/nope2.py"#' "$T/python/pyproject.toml"
run check "$T"
assert_eq 2 "$RC" "SSOT 가 0 파일이면 FAIL"
assert_contains "$OUT" "FAIL python/pyproject.toml:9 [python] SSOT 가 제품 소스 0 개로 펼쳐진다" "0 파일 FAIL 문구"
run list "$T" --json --lang python
assert_eq 2 "$RC" "[json] FAIL 인 언어가 있으면 exit 2(텍스트 판과 같다)"
assert_not_contains "$OUT" '"python": {' "[json] FAIL 인 언어는 langs 에 없다 — 빈 전개로 위장하지 않는다"
assert_contains "$OUT" '"lang": "python"' "[json] 그 FAIL 은 findings 로 온다"
# 사본 자리 파일이 없다.
fresh
rm "$T/harness/suites/go.sh"
run check "$T"
assert_eq 2 "$RC" "사본 파일이 없으면 FAIL"
assert_contains "$OUT" "FAIL harness/suites/go.sh [go] 자리 파일이 없다" "없는 자리를 댄다"
# 사본 자리에 명령이 주석으로만 남았다 — 표기가 바뀌어 공허해진 대조.
fresh
sed -i 's#^  cargo llvm-cov#  \# cargo llvm-cov#' "$T/harness/suites/rust.sh"
run check "$T"
assert_eq 2 "$RC" "사본이 주석으로만 남으면 FAIL"
assert_contains "$OUT" "FAIL harness/suites/rust.sh [rust] 사본 자리에서" "찾지 못함 FAIL"
# 클래스 단위 SSOT 가 파일을 반만 뺀다 — auth.kt 에 최상위 함수가 생기면 AuthKt 는 AuthClient* 밖이다.
fresh
printf '\ninternal fun authHelper(): Int = 1\n' >> "$T/kotlin/src/main/kotlin/p/auth.kt"
run check "$T"
assert_eq 2 "$RC" "부분 제외는 FAIL"
assert_contains "$OUT" "kotlin/src/main/kotlin/p/auth.kt 이(가) 부분만 빠진다" "부분 제외 파일을 댄다"
assert_contains "$OUT" "p.AuthKt" "남는 클래스(파사드)를 이름으로 댄다"
# java 익명 클래스는 `**/AuthClient.class` 가 빼지 않는 AuthClient$1 을 만든다.
fresh
sed -i 's#Runnable r = () -> {};#Runnable r = new Runnable() { public void run() {} };#' "$T/java/mod-auth/src/main/java/p/auth/AuthClient.java"
run check "$T"
assert_eq 2 "$RC" "java 익명 클래스 → 부분 제외 FAIL"
assert_contains "$OUT" 'AuthClient$1.class' "남는 클래스 파일을 댄다"
# 이 가드가 파일로 못 펴는 설정 형태는 FAIL 이다(스프레드 · 프로파일 · properties 밖 Sonar 제외).
fresh
sed -i "s#'src/admin/users.ts'\]#'src/admin/users.ts', ...extra]#" "$T/node/vitest.config.ts"
run check "$T"
assert_eq 2 "$RC" "vitest exclude 스프레드는 FAIL"
fresh
sed -i 's#args: -Dsonar.qualitygate.wait=true#args: -Dsonar.coverage.exclusions=go/** -Dsonar.qualitygate.wait=true#' "$T/.github/workflows/sonarcloud.yml"
run check "$T"
assert_eq 2 "$RC" "Sonar 제외를 워크플로에서 덮어쓰면 FAIL"
assert_contains "$OUT" "FAIL .github/workflows/sonarcloud.yml:14" "덮어쓰는 자리를 댄다"
fresh
sed -i 's#^  skip %r{lib/sdk/admin/}#  skip { |src| src.filename.include?("admin") }#' "$T/ruby/spec/spec_helper.rb"
run check "$T"
assert_eq 2 "$RC" "SimpleCov 블록 필터는 FAIL"
# 모델하지 않는 설정 손잡이 — 조용히 무시하지 않고 FAIL.
fresh
sed -i 's#^branch = true$#branch = true\ninclude = ["*/config.py"]#' "$T/python/pyproject.toml"
run check "$T"
assert_eq 2 "$RC" "coverage.py include 는 FAIL"
assert_contains "$OUT" "FAIL python/pyproject.toml:7 [python] [tool.coverage.run] include" "include 자리를 댄다"
fresh
sed -i 's#^source = \["keycloak_sdk"\]#source = ["keycloak_sdk.admin"]#' "$T/python/pyproject.toml"
run check "$T"
assert_eq 2 "$RC" "coverage.py source 가 바뀌면 모집단 가정이 깨진다 — FAIL"
fresh
sed -i 's#<Format>cobertura</Format>#<Format>cobertura</Format><ExcludeByAttribute>Obsolete</ExcludeByAttribute>#' "$T/dotnet/coverlet.runsettings"
run check "$T"
assert_eq 2 "$RC" "coverlet ExcludeByAttribute 는 FAIL"
fresh
sed -i 's#^  </source>$#  </source>\n  <source><exclude><file>src/Config.php</file></exclude></source>#' "$T/php/phpunit.xml"
run check "$T"
assert_eq 2 "$RC" "phpunit <source> 가 둘이면 FAIL"

assert_report
