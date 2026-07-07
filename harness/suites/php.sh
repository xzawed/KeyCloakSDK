#!/usr/bin/env bash
# harness/suites/php.sh — PHP SDK 자체 단위테스트+커버리지(Xdebug)+정적분석을 php:8.3-alpine
# 컨테이너에서 실행한다(CLAUDE.md PHP 툴체인: `composer install` + `phpunit --testsuite unit`
# [+ `XDEBUG_MODE=coverage` --coverage-text] + `phpstan analyse`). 마지막 줄에 JSON 신호 1줄 출력.
#
# ⚠️ 미실행 검증(untested-here) — node/go 2개 언어로 이 스위트 메커니즘을 검증했고, 이 스크립트는
# CLAUDE.md 커맨드로 작성했으나 실제 컨테이너 실행으로 확인하지 않았다(8언어 전체 실행은 CI 야간/수동
# 범위). php:8.3-alpine에는 xdebug가 기본 없어 pecl로 설치한다(빌드 의존성 필요, 느릴 수 있음) —
# 설치 실패 시 커버리지는 0으로 폴백(단위테스트 수 파싱은 영향 없음).
set -uo pipefail
cd "$(dirname "$0")/.."          # -> harness/
ROOT="$(cd .. && pwd)"           # 리포 루트 (php/ 는 $ROOT/php)
export MSYS_NO_PATHCONV=1

if ! command -v docker >/dev/null 2>&1; then
  echo "[php.sh] docker not found on PATH" >&2
  exit 1
fi

RAW=$(docker run --rm -v "$ROOT/php:/src-ro:ro" php:8.3-alpine sh -c '
  cp -r /src-ro /src && cd /src
  find . -name "*.php" -exec sed -i "s/\r$//" {} +
  apk add --no-cache git unzip $PHPIZE_DEPS openssl-dev libzip-dev >/dev/null 2>&1
  ( pecl install xdebug >/tmp/xdebug.log 2>&1 && docker-php-ext-enable xdebug ) >>/tmp/xdebug.log 2>&1
  php -r "copy(\"https://getcomposer.org/installer\", \"/tmp/ci.php\");" >/dev/null 2>&1
  php /tmp/ci.php --install-dir=/usr/local/bin --filename=composer >/dev/null 2>&1
  composer install --no-interaction --quiet >/tmp/install.log 2>&1
  echo "___INSTALLEXIT=$?"
  XDEBUG_MODE=coverage vendor/bin/phpunit --testsuite unit --coverage-text 2>&1
  echo "___TESTEXIT=$?"
  vendor/bin/phpstan analyse >/tmp/phpstan.log 2>&1
  echo "___LINTEXIT=$?"
  cat /tmp/phpstan.log
' 2>&1)
DOCKER_RC=$?

OUT=$(printf '%s' "$RAW" | sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g')

if [ "$DOCKER_RC" -ne 0 ] && [ -z "$OUT" ]; then
  echo "[php.sh] docker run produced no output (rc=$DOCKER_RC)" >&2
  exit 1
fi

# phpunit 요약: "OK (64 tests, 242 assertions)" 또는 실패 시 "Tests: 64, Assertions: 240, Failures: 2."
UNIT=$(printf '%s\n' "$OUT" | grep -oE '\(([0-9]+) tests?,' | head -1 | grep -oE '[0-9]+')
if [ -z "${UNIT:-}" ]; then
  UNIT=$(printf '%s\n' "$OUT" | grep -oE 'Tests: [0-9]+' | head -1 | grep -oE '[0-9]+')
fi
# --coverage-text 요약: "Lines:   93.45% (...)"
LINE=$(printf '%s\n' "$OUT" | grep -E '^ *Lines:' | head -1 | grep -oE '[0-9]+(\.[0-9]+)?' | head -1)
LINTEXIT=$(printf '%s\n' "$OUT" | grep -oE '___LINTEXIT=[0-9]+' | tail -1 | cut -d= -f2)
if [ "${LINTEXIT:-1}" = "0" ]; then LINTCLEAN=true; else LINTCLEAN=false; fi

INTEGRATION=0
if [ "${SUITE_INTEGRATION:-0}" = "1" ]; then
  # 통합테스트는 docker CLI 셸아웃(KeycloakContainerTrait)이라 컨테이너 안에 docker-cli +
  # docker.sock이 필요 — best-effort opt-in(기본 미실행).
  IRAW=$(docker run --rm -v "$ROOT/php:/src-ro:ro" -v /var/run/docker.sock:/var/run/docker.sock \
    php:8.3-alpine sh -c '
      cp -r /src-ro /src && cd /src
      apk add --no-cache git unzip docker-cli $PHPIZE_DEPS openssl-dev libzip-dev >/dev/null 2>&1
      php -r "copy(\"https://getcomposer.org/installer\", \"/tmp/ci.php\");" >/dev/null 2>&1
      php /tmp/ci.php --install-dir=/usr/local/bin --filename=composer >/dev/null 2>&1
      composer install --no-interaction --quiet >/dev/null 2>&1
      vendor/bin/phpunit --testsuite integration 2>&1
    ' 2>&1 || true)
  IOUT=$(printf '%s' "$IRAW" | sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g')
  INTEGRATION=$(printf '%s\n' "$IOUT" | grep -oE '\(([0-9]+) tests?,' | head -1 | grep -oE '[0-9]+')
fi

echo "{\"lang\":\"php\",\"unit\":${UNIT:-0},\"integration\":${INTEGRATION:-0},\"coverageLine\":${LINE:-0},\"coverageBranch\":0,\"lintClean\":${LINTCLEAN},\"ran\":true}"
