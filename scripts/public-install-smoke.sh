#!/usr/bin/env bash
# public-install-smoke.sh — **공개 레지스트리에 게시된 SDK** 를 새 소비자처럼 설치해 README 예제를 실 Keycloak 에 대고 돌린다.
#
# 왜: 설치 하네스(harness/install)는 아티팩트를 빌드해 **로컬** 레지스트리에 올린 뒤 설치한다 — 게시 전 게이트다. 게시된
# 판이 지금의 생태계(전이 의존 · 레지스트리 처리)에서 실제로 설치되고 동작하는지는 아무도 재지 않았다(등록부
# public-registry-install-smoke). 예: python 1.0.7 은 선언 `joserfc>=1.7,<2` 로 오늘 1.8.0 을 받는다.
#
# 판은 SSOT 가 아니라 **레지스트리가 고른다** — 판 없이 설치하면 새 소비자가 받는 최신 안정판이다(JVM 은 판이 필수라
# maven-metadata 의 <release>). SSOT 는 범프가 태그보다 먼저 오르므로(런북 §4) 그것으로 고르면 그 창에서 거짓 빨강이 난다
# (published-floor.yml 과 같은 원칙). 받은 판은 출력에 남긴다.
# ⚠️ 예제는 **main 의 것**이다 — README 가 blob/main 의 예제를 링크하므로, 소비자가 복사하는 바로 그 예제가 게시판과
# 맞아야 한다. 예제가 아직 게시되지 않은 API 를 쓰면 여기서 빨개진다 — 그것이 신호다(예제를 고치거나 릴리스를 낸다).
#
# 사용:
#   scripts/public-install-smoke.sh keycloak-up        # 하네스 렐름(it-realm)으로 Keycloak 을 띄우고 준비될 때까지 기다린다
#   scripts/public-install-smoke.sh <lang>             # java|kotlin|python|node|go|dotnet|php|rust|ruby
# 환경: KC_BASE(기본 http://localhost:8080). 예제마다 읽는 이름이 다르므로(KC_SERVER_URL · KC_URL · KEYCLOAK_URL) 셋 다 내보낸다.
#
# ⚠️ 작업 디렉터리는 **저장소 밖**(mktemp)이다 — 저장소 안이면 python 이 src 를, node 가 자기 이름을 해석해 게시판이 아니라
# 트리를 재게 된다. 설치도 그 안에만 한다(venv · node_modules · vendor · --install-dir) — 사용자 환경을 건드리지 않는다.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KC_BASE="${KC_BASE:-http://localhost:8080}"
export KC_SERVER_URL="$KC_BASE" KC_URL="$KC_BASE" KEYCLOAK_URL="$KC_BASE"
export KC_REALM=it-realm KEYCLOAK_REALM=it-realm
export KC_CLIENT_ID=it-client KEYCLOAK_CLIENT_ID=it-client
export KC_CLIENT_SECRET=it-secret KEYCLOAK_CLIENT_SECRET=it-secret

die() { echo "::error::public-install-smoke: $*" >&2; exit 1; }
say() { echo "[public-install-smoke] $*"; }
# Maven Central 이 고르는 최신 안정판(<release>) — 판이 필수인 JVM 소비자의 「판 없이 설치」 에 해당한다.
central_release() { # $1 = group 경로(io/github/xzawed) $2 = artifact
  curl -fsS "https://repo1.maven.org/maven2/$1/$2/maven-metadata.xml" | sed -n 's:.*<release>\(.*\)</release>.*:\1:p'
}

lang="${1:-}"
[ -n "$lang" ] || die "usage: $0 keycloak-up | <lang>"

if [ "$lang" = keycloak-up ]; then
  # harness/install/compose.install.yml 의 keycloak 서비스와 같은 설정 — 렐름 파일 이름은 Keycloak 의 <realm>-realm.json 규칙.
  docker rm -f public-install-kc >/dev/null 2>&1 || true
  # ⚠️ Git Bash(MSYS)는 `-v a:b` 를 경로 목록으로 읽어 컨테이너 쪽 경로까지 `C:/Program Files/Git/...` 로 바꾼다(실측) —
  # 호스트 경로는 cygpath 로 Windows 형식으로 주고 docker 에는 변환을 끈다. 리눅스에서는 둘 다 아무 일도 하지 않는다.
  realm="$ROOT/harness/keycloak/harness-realm.json"
  command -v cygpath >/dev/null 2>&1 && realm="$(cygpath -m "$realm")"
  MSYS_NO_PATHCONV=1 docker run -d --name public-install-kc -p 8080:8080 -p 9000:9000 \
    -e KC_BOOTSTRAP_ADMIN_USERNAME=admin -e KC_BOOTSTRAP_ADMIN_PASSWORD=admin -e KC_HEALTH_ENABLED=true \
    -v "$realm:/opt/keycloak/data/import/it-realm-realm.json:ro" \
    quay.io/keycloak/keycloak:26.6 start-dev --import-realm >/dev/null
  for _ in $(seq 1 90); do
    if curl -fsS "$KC_BASE/realms/it-realm/.well-known/openid-configuration" >/dev/null 2>&1; then
      say "Keycloak 준비됨 — $KC_BASE/realms/it-realm"
      exit 0
    fi
    sleep 2
  done
  docker logs public-install-kc 2>&1 | tail -30
  die "Keycloak 이 180초 안에 it-realm 을 내지 않았다"
fi

WORK="$(mktemp -d)"
say "$lang — 작업 디렉터리 $WORK (저장소 밖)"
cd "$WORK"

case "$lang" in
  node)
    npm init -y >/dev/null
    npm pkg set type=module
    npm install --no-audit --no-fund @xzawed/keycloak-sdk >/dev/null
    resolved="$(npm ls @xzawed/keycloak-sdk --json | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const d=JSON.parse(s).dependencies["@xzawed/keycloak-sdk"];console.log(d.version+" "+d.resolved)})')"
    say "설치: @xzawed/keycloak-sdk $resolved"
    case "$resolved" in *" https://registry.npmjs.org/"*) ;; *) die "npm 공개 레지스트리에서 받지 않았다: $resolved" ;; esac
    cp "$ROOT/node/examples/quickstart.ts" .
    node --experimental-strip-types quickstart.ts
    ;;
  python)
    python3 -m venv venv 2>/dev/null || python -m venv venv
    py="$WORK/venv/bin/python"; [ -x "$py" ] || py="$WORK/venv/Scripts/python.exe"
    "$py" -m pip install -q --disable-pip-version-check keycloak-sdk
    say "설치: keycloak-sdk $("$py" -c 'import importlib.metadata as m; print(m.version("keycloak-sdk"))')"
    cp "$ROOT/python/examples/quickstart.py" "$ROOT/python/examples/async_quickstart.py" .
    "$py" quickstart.py
    "$py" async_quickstart.py
    ;;
  java)
    ver="$(central_release io/github/xzawed keycloak-sdk-bom)"
    [ -n "$ver" ] || die "Maven Central 에서 keycloak-sdk-bom 의 <release> 를 못 읽었다"
    say "설치: io.github.xzawed:keycloak-sdk-bom $ver (Maven Central <release>)"
    # 하네스의 퀵스타트 pom(BOM import + 무버전 keycloak-sdk)을 그대로 쓴다 — 로컬 저장소는 settings.xml 에만 있으므로
    # 여기서는 Maven 기본(Central)으로 해석된다. BOM 판만 바꾼다.
    sed "s#<version>0.1.0</version>#<version>$ver</version>#" "$ROOT/harness/install/consume/java-quickstart-pom.xml" > pom.xml
    grep -q "<version>$ver</version>" pom.xml || die "퀵스타트 pom 의 BOM 판을 $ver 로 바꾸지 못했다"
    mkdir -p src/main/java
    cp -r "$ROOT/java/keycloak-sdk-examples/src/main/java/io" src/main/java/
    mvn -q -B compile exec:java
    ;;
  kotlin)
    ver="$(central_release io/github/xzawed keycloak-sdk-kotlin)"
    [ -n "$ver" ] || die "Maven Central 에서 keycloak-sdk-kotlin 의 <release> 를 못 읽었다"
    say "설치: io.github.xzawed:keycloak-sdk-kotlin $ver (Maven Central <release>)"
    cp -r "$ROOT/harness/install/consume/kotlin-app/." .
    sed -i "s#\(implementation(\"io\.github\.xzawed:keycloak-sdk-kotlin:\)[^\"]*#\1$ver#" build.gradle.kts
    grep -q "keycloak-sdk-kotlin:$ver\")" build.gradle.kts || die "build.gradle.kts 의 SDK 판을 $ver 로 바꾸지 못했다"
    mkdir -p src/main/kotlin
    cp "$ROOT/kotlin/examples/quickstart.kt" src/main/kotlin/
    # 컨테이너 전용 저장소(mvn-repo-kotlin)를 걷어 Central 로 해석한다 — 주간 OSV 감사와 같은 init script.
    sh ./gradlew -q --no-daemon -I "$ROOT/scripts/gradle/osv-audit-init.gradle" runQuickstart
    ;;
  go)
    # README 가 링크하는 go 예제는 example_test.go(테스트 파일)라 돌릴 수 없다 — 하네스의 퀵스타트를 쓴다.
    go mod init smoke >/dev/null 2>&1
    cp "$ROOT/harness/install/quickstart/go/main.go" .
    GOFLAGS=-mod=mod go get github.com/xzawed/KeyCloakSDK/go@latest >/dev/null
    go mod tidy >/dev/null
    say "설치: $(go list -m github.com/xzawed/KeyCloakSDK/go) (GOPROXY=$(go env GOPROXY))"
    go run .
    ;;
  dotnet)
    # README 에 .NET 예제 파일이 없다 — 하네스의 퀵스타트(Program.cs · csproj)를 쓴다.
    cp "$ROOT/harness/install/quickstart/dotnet/Quickstart.csproj" "$ROOT/harness/install/quickstart/dotnet/Program.cs" .
    dotnet add package Xzawed.Keycloak.Sdk >/dev/null
    say "설치: $(grep -oE 'Include="Xzawed\.Keycloak\.Sdk" Version="[^"]+"' Quickstart.csproj)"
    dotnet run
    ;;
  php)
    composer require -q --no-interaction xzawed/keycloak-sdk
    say "설치: xzawed/keycloak-sdk $(php -r '$j = json_decode(file_get_contents("vendor/composer/installed.json"), true); foreach ($j["packages"] ?? $j as $p) { if ($p["name"] === "xzawed/keycloak-sdk") { echo $p["version"]; } }')"
    mkdir -p examples
    cp "$ROOT/php/examples/quickstart.php" examples/
    php examples/quickstart.php
    ;;
  rust)
    # 새 소비자처럼 keycloak-sdk 와 tokio 만 의존한다 — 예제가 쓰는 타입은 keycloak_sdk 가 재노출해야 한다(CLAUDE.md §4(b)).
    cargo new -q --bin qs && cd qs
    cargo add -q keycloak-sdk
    cargo add -q tokio --features rt-multi-thread,macros
    say "설치: $(grep -E '^keycloak-sdk' Cargo.toml)"
    cp "$ROOT/rust/examples/quickstart.rs" src/main.rs
    cargo run -q
    ;;
  ruby)
    # 환경 변수로 넘기는 경로는 Git Bash 가 바꿔 주지 않는다 — 네이티브 Ruby 가 읽게 Windows 형식으로 준다(리눅스는 그대로).
    gems="$WORK/gems"; command -v cygpath >/dev/null 2>&1 && gems="$(cygpath -m "$gems")"
    gem install --no-document --install-dir "$gems" keycloak-sdk >/dev/null
    # GEM_PATH 를 작업 디렉터리로만 두면 Ruby 에 딸린 기본 gem 경로가 빠진다 — 그 뒤에 붙인다(구분자는 Ruby 의 것).
    export GEM_HOME="$gems" GEM_PATH="$gems$(ruby -e 'print File::PATH_SEPARATOR, Gem.default_dir')"
    say "설치: keycloak-sdk $(ruby -e 'require "keycloak_sdk"; print KeycloakSdk::VERSION')"
    cp "$ROOT/ruby/examples/quickstart.rb" .
    ruby quickstart.rb
    ;;
  *)
    die "모르는 언어: $lang"
    ;;
esac
say "$lang — README 예제가 공개 레지스트리의 게시판으로 실 Keycloak 에 대고 끝까지 돌았다"
