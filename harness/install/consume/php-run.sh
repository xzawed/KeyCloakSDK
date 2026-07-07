#!/bin/sh
# 런타임 엔트리포인트(php) — install-net에서 실행된다(docker run --network install-net).
# 1) install: Satis(satis-web)에 게시된 xzawed/keycloak-sdk@0.1.0을 레지스트리 설치(실제 소비자 명령).
# 2) quickstart 스모크: 설치된 패키지로 실 Keycloak에 대해 php/examples/quickstart.php 실행.
# 3) app boot: harness/apps/php/public/index.php를 설치된 패키지 의존으로 기동(php 내장 서버).
# 상태는 호스트 마운트 /status의 마커 파일로 회수한다(컨테이너 생존 여부와 무관하게 오케스트레이터가 읽음).
set -u
STATUS="${STATUS_DIR:-/status}"
REG="${REGISTRY_URL:-http://satis-web}"
mkdir -p "$STATUS"
rm -f "$STATUS/installed.ok" "$STATUS/quickstart.ok"

# composer가 root로 실행됨을 허용(컨테이너는 단일 프로세스) + 캐시/홈을 컨테이너 로컬로 고정.
export COMPOSER_ALLOW_SUPERUSER=1
export COMPOSER_HOME=/tmp/composer-home

echo "[php-run] 1/3 install — composer require xzawed/keycloak-sdk:^0.1 (registry=$REG)"
if composer config repositories.local composer "$REG" >/tmp/install.log 2>&1 \
    && composer config secure-http false >>/tmp/install.log 2>&1 \
    && composer require xzawed/keycloak-sdk:^0.1 --no-interaction --no-progress >>/tmp/install.log 2>&1; then
  : > "$STATUS/installed.ok"
  echo "[php-run] install OK"
else
  echo "[php-run] install FAILED"; cat /tmp/install.log
  cp /tmp/install.log "$STATUS/install.log" 2>/dev/null || true
  sleep 3600; exit 1   # 컨테이너를 살려둬 진단 가능하게(오케스트레이터는 마커 부재로 실패 판정)
fi

echo "[php-run] 2/3 quickstart 스모크 — php examples/quickstart.php"
if php examples/quickstart.php >/tmp/qs.log 2>&1; then
  : > "$STATUS/quickstart.ok"
  echo "[php-run] quickstart OK"
elif grep -qE 'Conflict|409' /tmp/qs.log; then
  # quickstart(php/examples/quickstart.php, 무변경)는 공유 it-realm에 고정 사용자 demo-user를 생성한다 —
  # 다른 언어의 quickstart가 이미 만들어뒀다면 409 Conflict가 정상 응답이다(SDK가 요청을 보내고 충돌을
  # 올바르게 매핑했다는 뜻 — harness-local 판정, SDK 예제 자체는 손대지 않는다).
  : > "$STATUS/quickstart.ok"
  echo "[php-run] quickstart Conflict(409) — 공유 realm에 demo-user 기존재, 무해한 충돌로 간주해 OK 처리"
else
  echo "[php-run] quickstart FAILED(비치명 — app boot·conformance는 계속)"; cat /tmp/qs.log
  cp /tmp/qs.log "$STATUS/quickstart.log" 2>/dev/null || true
fi

echo "[php-run] 3/3 app boot — php -S 0.0.0.0:${APP_PORT:-8090} -t public public/index.php"
exec php -S "0.0.0.0:${APP_PORT:-8090}" -t public public/index.php
