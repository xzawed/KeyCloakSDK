#!/bin/sh
# 런타임 엔트리포인트(php) — install-net에서 실행된다(docker run --network install-net).
# 1) install: Satis(satis-web)에 게시된 xzawed/keycloak-sdk@0.1.0을 레지스트리 설치(실제 소비자 명령).
# 2) quickstart 스모크: 설치된 패키지로 실 Keycloak에 대해 php/examples/quickstart.php 실행.
# 3) app boot: harness/apps/php/public/index.php를 설치된 패키지 의존으로 기동(php 내장 서버).
# 상태는 호스트 마운트 /status의 마커 파일로 회수한다(컨테이너 생존 여부와 무관하게 오케스트레이터가 읽음).
set -u
STATUS="${STATUS_DIR:-/status}"
REG="${REGISTRY_URL:-http://satis-web}"
# 릴리스 버전 — 오케스트레이터(install-verify.sh)가 -e PKG_VER로 주입한다(기본값은 단독 실행용).
PKG_VER="${PKG_VER:-0.1.0}"
mkdir -p "$STATUS"
rm -f "$STATUS/installed.ok" "$STATUS/quickstart.ok"

# composer가 root로 실행됨을 허용(컨테이너는 단일 프로세스) + 캐시/홈을 컨테이너 로컬로 고정.
export COMPOSER_ALLOW_SUPERUSER=1
export COMPOSER_HOME=/tmp/composer-home

echo "[php-run] 1/3 install — composer require xzawed/keycloak-sdk:$PKG_VER (registry=$REG)"
# ⚠️ 캐럿 범위(`^0.1`)가 아니라 **정확 버전**으로 요구한다. 두 가지 이유가 있다:
#  (1) 이 게이트의 요점은 "태그된 그 버전이 설치되는가"다 — 범위는 레지스트리에 있는 아무 버전이나
#      집어올 수 있어(예: 0.1.0이 남아 있으면 0.2.0 태그를 검증하면서 0.1.0을 설치한다) 게이트가
#      엉뚱한 산출물을 통과시킨다.
#  (2) composer 기본 `minimum-stability: stable`은 프리릴리스를 **범위에서 제외**한다 — DEPLOY.md가
#      권하는 첫 태그(RC)가 `^0.1`로는 아예 해석되지 않아 이 단계가 통째로 실패한다. 정확 버전에
#      안정성 접미사가 그대로 들어가면 composer가 그 패키지에 한해 stability 플래그를 세워준다.
if composer config repositories.local composer "$REG" >/tmp/install.log 2>&1 \
    && composer config secure-http false >>/tmp/install.log 2>&1 \
    && composer require "xzawed/keycloak-sdk:$PKG_VER" --no-interaction --no-progress >>/tmp/install.log 2>&1; then
  echo "[php-run] composer require 성공 — 출처 확인 중"
  # ⚠️ **출처를 기록한다**(이슈 #167). `composer config repositories.local`은 Packagist를 **비활성화하지
  # 않는다** — 같은 좌표·같은 버전이 Packagist에도 있으면 거기서 받아도 초록이고, 그 순간 검증 대상은
  # 방금 만든 산출물이 아니라 공개 패키지다. composer.lock의 `dist.url`이 실제 받은 자리를 기록한다.
  php -r '
    $l = json_decode(file_get_contents("composer.lock"), true);
    foreach (($l["packages"] ?? []) as $p) {
      if (($p["name"] ?? "") === "xzawed/keycloak-sdk") { echo ($p["dist"]["url"] ?? "<no dist url>"), "\n"; }
    }' >"$STATUS/provenance.txt" 2>/dev/null || true
  echo "[php-run] SDK 출처: $(cat "$STATUS/provenance.txt" 2>/dev/null)"
  # ⚠️ **출처 단언**(이슈 #167) — Packagist가 살아 있으므로 같은 좌표가 거기 있으면 거기서
  # 받아도 초록이다. 판정을 출처에 의존시킨다(python-run.sh와 동형).
  # ⚠️ **전부 로컬이라야 한다** + 빈 파일도 실패(여섯 언어 공통 규칙).
  # ⚠️ `$REG`가 비면 `grep -v -F ""`가 모든 줄을 걸러내 음성 조건이 **자동 참**이 된다 — 공개
  # 레지스트리에서 받아도 통과한다(실측 재현). env로는 도달 불가하지만(`:-`가 빈 값도 기본값으로
  # 대체한다) 스크립트 변이로는 도달하므로 비어있음을 명시 검사한다(2026-08-12 부류 재스캔).
  # ⚠️ python-run.sh와 같은 하드닝(B0 런타임 테스트가 드러냈다) — 음성 조건은 "모든 줄이 `$REG`를
  # **포함**"만 보므로 dist zip을 안 받은 기록·중간 임베드·호스트 경계 침범이 통과한다. origin
  # 정규화 + 양성 조건으로 닫는다. satis는 `archive.format=zip`이라 dist URL이 `.zip`으로 끝난다
  # (`registries/php-satis.json`).
  # >>> provenance-gate
  [ -n "$REG" ] && REG="${REG%/}/"
  _art_local=0
  if [ -n "$REG" ] && [ -s "$STATUS/provenance.txt" ]; then
    while IFS= read -r _pline || [ -n "$_pline" ]; do
      case "$_pline" in "$REG"*.zip) _art_local=1; break ;; esac
    done <"$STATUS/provenance.txt"
  fi
  if [ -n "$REG" ] && [ -s "$STATUS/provenance.txt" ] \
     && ! grep -v -F "$REG" "$STATUS/provenance.txt" | grep -q . \
     && [ "$_art_local" = 1 ]; then
    PROVENANCE_OK=1
  else
    PROVENANCE_OK=0
  fi
  # <<< provenance-gate
  if [ "$PROVENANCE_OK" = 1 ]; then
    : > "$STATUS/installed.ok"
    echo "[php-run] install OK (로컬 레지스트리에서 받았다)"
  else
    echo "[php-run] install FAILED — SDK를 로컬($REG)이 아닌 곳에서 받았다: $(cat "$STATUS/provenance.txt" 2>/dev/null)"
    cp /tmp/install.log "$STATUS/install.log" 2>/dev/null || true
    sleep 3600; exit 1
  fi
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
