#!/usr/bin/env sh
# rules 명령 참조 실재 검사(`scripts/check-rules-commands.mjs`) 자가테스트 — 픽스처만(툴체인 불필요). 실제 트리 대조는
# repo-hygiene 의 비-required 잡 `rules-commands` 다(오탐 하나가 모든 PR 을 막지 않게 — 그 머리).
#   (1) 양성 — 참조가 다 있는 작은 트리에서 exit 0 과 정확한 계수. 줄머리 cd 는 루트 기준(node 꼴) · `cd kotlin` 한 줄과
#       `cd dotnet && …` 뒤의 줄은 그 디렉터리(셸의 지속) · 따옴표 안의 `&&` 와 따옴표 밖 `#` 뒤 주석 · 줄 끝 `\` 이음.
#   (2) 음성 — 참조를 하나씩 지우면 exit 1 과 그 MISSING 줄. #423 이 사람 눈으로 잡은 꼴(`"$PY" -m build` — build 가
#       [dev] 에 없다)이 그 하나다.
#   (3) 공허 — rules 디렉터리가 없거나 펜스 줄이 0 이면 exit 2(대조할 것이 없으면 초록이 아니다).
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
TOOL="$DIR/../check-rules-commands.mjs"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fresh() {
  T="$TMP/t$((${N:-0} + 1))"
  N=$((${N:-0} + 1))
  mkdir -p "$T/.claude/rules" "$T/node" "$T/kotlin" "$T/python" "$T/java" "$T/rust/tests" "$T/ruby/spec/integration" \
    "$T/php" "$T/go" "$T/dotnet" "$T/scripts"
  cat > "$T/.claude/rules/node.md" <<'EOF'
Outside a fence nothing is read: `npm run nope`.

```bash
cd node && npm ci
cd node && npm test -- --grep "a && b"
cd node && npm run build   # then: npm run nope && cd nowhere
```
EOF
  printf '{ "scripts": { "test": "vitest", "build": "tsc" } }\n' > "$T/node/package.json"
  printf '{}\n' > "$T/node/package-lock.json"
  cat > "$T/.claude/rules/kotlin.md" <<'EOF'
```bash
cd kotlin
./gradlew test
./gradlew integrationTest koverVerify
```
EOF
  : > "$T/kotlin/gradlew"
  cat > "$T/kotlin/build.gradle.kts" <<'EOF'
plugins {
    kotlin("jvm") version "2.4.21"
    id("org.jetbrains.kotlinx.kover") version "0.9.11"
}
testing {
    suites {
        val integrationTest by registering(JvmTestSuite::class) {
        }
    }
}
EOF
  cat > "$T/.claude/rules/python.md" <<'EOF'
```bash
cd python && "$PY" -m pytest -m "not integration"   # unit
cd python && "$PY" -m pip install build && "$PY" -m build
```
EOF
  printf '[project.optional-dependencies]\ndev = [\n  "pytest>=9.0",\n  "ruff>=0.6,<0.18",\n]\n\n[tool.ruff]\n' > "$T/python/pyproject.toml"
  cat > "$T/.claude/rules/java.md" <<'EOF'
```bash
JAVA_HOME="${KCSDK_JDK21:?see \`node scripts/doctor.mjs java\`}" \
mvn -f java/pom.xml -pl core verify
```
EOF
  printf '<project><modules><module>core</module></modules></project>\n' > "$T/java/pom.xml"
  cat > "$T/.claude/rules/rust.md" <<'EOF'
```bash
cd rust && cargo test --test integration_test -- --ignored
```
EOF
  printf '[package]\nname = "k"\n' > "$T/rust/Cargo.toml"
  : > "$T/rust/tests/integration_test.rs"
  cat > "$T/.claude/rules/ruby.md" <<'EOF'
```bash
cd ruby && RUN_INTEGRATION=1 bundle exec rspec spec/integration --tag integration
cd ruby && gem build k.gemspec
```
EOF
  printf 'source "https://rubygems.org"\ngroup :development do\n  gem "rspec", "~> 3.13"\nend\n' > "$T/ruby/Gemfile"
  : > "$T/ruby/k.gemspec"
  cat > "$T/.claude/rules/php.md" <<'EOF'
```bash
cd php && vendor/bin/phpunit --testsuite unit
```
EOF
  printf '{ "require-dev": { "phpunit/phpunit": "^12" } }\n' > "$T/php/composer.json"
  printf '<phpunit><testsuites>\n<testsuite name="unit"><directory>tests</directory></testsuite>\n</testsuites></phpunit>\n' > "$T/php/phpunit.xml"
  cat > "$T/.claude/rules/go.md" <<'EOF'
```bash
go -C go test -tags=integration -run TestE2E ./...
gofmt -l go
```
EOF
  printf 'module k\n' > "$T/go/go.mod"
  printf '//go:build integration\n\npackage k\n\nfunc TestE2E(t *testing.T) {}\n' > "$T/go/e2e_test.go"
  cat > "$T/.claude/rules/dotnet.md" <<'EOF'
```bash
cd dotnet && dotnet format K.sln --verify-no-changes
```

- Coverage:
  ```bash
  cd dotnet && dotnet test --filter "Category!=Integration" \
    --collect:"XPlat Code Coverage"
  node ../scripts/check-coverage.mjs /tmp/cov --min-line 90
  ```
EOF
  : > "$T/dotnet/K.sln"
  : > "$T/scripts/check-coverage.mjs"
  printf '# no fences here\n' > "$T/.claude/rules/ci.md"
}
run() { OUT="$(node "$TOOL" "$T" 2>&1)" && RC=0 || RC=$?; }

# ── (1) 양성 ───────────────────────────────────────────────────────────────────────────────────────────
fresh
run
assert_eq 0 "$RC" "참조가 다 있으면 exit 0 — 출력: $OUT"
assert_eq "rules-commands: OK — 18 fenced lines in 10 files · 35 references checked (bundle exec 1 · cargo --test 1 · cd 12 · go -C 1 · go -run 1 · gradle 3 · manifest 2 · mvn 1 · mvn -pl 1 · npm 2 · path 5 · phpunit --testsuite 1 · python -m 3 · vendor/bin 1) · 0 commands not checked" \
  "$OUT" "양성의 계수"

# ── (2) 음성 — 참조 하나씩 ─────────────────────────────────────────────────────────────────────────────
miss() { # 설명 기대줄 — fresh 와 변이 뒤에 부른다
  run
  assert_eq 1 "$RC" "[$1] exit 1 — 출력: $OUT"
  assert_contains "$OUT" "$2" "[$1] 그 참조를 댄다"
  assert_eq 1 "$(printf '%s\n' "$OUT" | grep -c '^MISSING')" "[$1] 없는 참조는 하나다 — 출력: $OUT"
}
fresh; printf '{ "scripts": { "test": "vitest" } }\n' > "$T/node/package.json"
miss "npm 스크립트" 'MISSING .claude/rules/node.md:6 npm — node/package.json has no script "build"'
fresh; rm "$T/node/package-lock.json"
miss "npm ci 의 잠금 파일" 'MISSING .claude/rules/node.md:4 manifest — npm ci needs node/package-lock.json'
fresh; sed -i 's/val integrationTest by/val itTest by/' "$T/kotlin/build.gradle.kts"
miss "Gradle 스위트 이름" 'MISSING .claude/rules/kotlin.md:4 gradle — task integrationTest:'
fresh; sed -i '/kotlinx.kover/d' "$T/kotlin/build.gradle.kts"
miss "Gradle 플러그인" 'MISSING .claude/rules/kotlin.md:4 gradle — task koverVerify:'
fresh; printf '```bash\ncd python && "$PY" -m build\n```\n' > "$T/.claude/rules/python.md"
miss "#423 꼴 — build 가 [dev] 에 없다" 'MISSING .claude/rules/python.md:2 python -m — module build: not in python/pyproject.toml'
fresh; printf '<project><modules><module>auth</module></modules></project>\n' > "$T/java/pom.xml"
miss "Maven 모듈" 'MISSING .claude/rules/java.md:2 mvn -pl — module core is not in java/pom.xml <modules>'
fresh; rm "$T/rust/tests/integration_test.rs"
miss "cargo 시험 대상" 'MISSING .claude/rules/rust.md:2 cargo --test — rust/tests/integration_test.rs is missing'
fresh; sed -i '/rspec/d' "$T/ruby/Gemfile"
miss "bundle exec 의 gem" 'MISSING .claude/rules/ruby.md:2 bundle exec — gem rspec (for rspec) is not in ruby/Gemfile or a gemspec'
fresh; rm "$T/ruby/k.gemspec"
miss "gem build 의 파일" 'MISSING .claude/rules/ruby.md:3 path — ruby/k.gemspec does not exist'
fresh; printf '{ "require-dev": { "phpstan/phpstan": "^2" } }\n' > "$T/php/composer.json"
miss "vendor/bin 의 패키지" 'MISSING .claude/rules/php.md:2 vendor/bin — phpunit/phpunit (for phpunit) is not in php/composer.json'
fresh; sed -i 's/name="unit"/name="Unit"/' "$T/php/phpunit.xml"
miss "phpunit 스위트 이름" 'MISSING .claude/rules/php.md:2 phpunit --testsuite — php/phpunit.xml has no <testsuite name="unit">'
fresh; sed -i 's/func TestE2E/func TestEndToEnd/' "$T/go/e2e_test.go"
miss "go 시험 함수" 'MISSING .claude/rules/go.md:2 go -run — no func TestE2E( in a _test.go under go'
fresh; rm "$T/scripts/check-coverage.mjs"
miss "cd 가 남은 줄의 node 스크립트" 'MISSING .claude/rules/dotnet.md:9 path — scripts/check-coverage.mjs does not exist'
fresh; rmdir "$T/ruby/spec/integration"
miss "rspec 경로 인자" 'MISSING .claude/rules/ruby.md:2 path — ruby/spec/integration does not exist'
fresh; mv "$T/rust" "$T/rust2"
miss "cd 디렉터리" 'MISSING .claude/rules/rust.md:2 cd — rust is not a directory'

# 읽지 못한 꼴의 명령도 실패다(Grok 레그 — 「확인하지 않음」이 조용히 쌓이면 손 표가 좁아진다).
fresh; printf '```bash\ntime npm ci\n```\n' > "$T/.claude/rules/node.md"
run
assert_eq 1 "$RC" "읽지 못한 명령이면 exit 1 — 출력: $OUT"
assert_contains "$OUT" "UNCHECKED .claude/rules/node.md:2 time — no resolver reads this command" "그 명령을 댄다"
assert_eq 0 "$(printf '%s\n' "$OUT" | grep -c '^MISSING')" "없는 참조로 세지 않는다 — 출력: $OUT"
# 기본값을 펼친 인터프리터(옛 python.md 의 꼴)도 파이썬이다 — 앞 판은 그것을 「읽지 못한 명령」으로 냈다(역사 220 줄).
fresh; printf '```bash\ncd python && "${KCSDK_PY:-.venv/Scripts/python.exe}" -m pytest\ncd python && .venv/bin/python3.12 -m ruff check\n```\n' > "$T/.claude/rules/python.md"
run
assert_eq 0 "$RC" "기본값 펼침 · 경로 붙은 인터프리터 — 출력: $OUT"
# 맨 gradle 은 체크아웃에 없다 — 저장소는 래퍼를 준다(kotlin 규칙 · 옛 kotlin.md 의 `gradle -p kotlin`).
fresh; printf '```bash\ngradle -p kotlin test\n```\n' > "$T/.claude/rules/kotlin.md"
miss "맨 gradle" 'MISSING .claude/rules/kotlin.md:2 gradle — bare gradle is not in the checkout — the repository ships kotlin/gradlew (use ./gradlew)'
rm "$T/kotlin/gradlew"
miss "맨 gradle · 래퍼도 없다" 'MISSING .claude/rules/kotlin.md:2 gradle — bare gradle is not in the checkout, and kotlin/gradlew is missing'
# [dev] 가 한 줄 배열이고 파일의 마지막 절이어도 읽는다(앞 판은 다음 `[` 머리가 없으면 빈 집합이었다).
fresh; printf '[project]\nname = "k"\n\n[project.optional-dependencies]\ndev = ["pytest>=9.0", "ruff"]  # one line\n' > "$T/python/pyproject.toml"
run
assert_eq 0 "$RC" "한 줄 · 마지막 절의 [dev] — 출력: $OUT"

# ── (3) 공허 ───────────────────────────────────────────────────────────────────────────────────────────
fresh; rm -r "$T/.claude/rules"
run
assert_eq 2 "$RC" "rules 디렉터리가 없으면 exit 2 — 출력: $OUT"
assert_contains "$OUT" "rules-commands: FAIL — .claude/rules is missing under" "그렇게 말한다"
fresh; for f in "$T"/.claude/rules/*.md; do printf 'no fences\n' > "$f"; done
run
assert_eq 2 "$RC" "펜스 줄이 0 이면 exit 2 — 출력: $OUT"
assert_contains "$OUT" "no fenced command lines in .claude/rules/*.md — nothing was checked" "그렇게 말한다"

assert_report
