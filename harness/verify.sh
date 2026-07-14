#!/usr/bin/env bash
# 종합 검증 파이프라인. Usage: ./verify.sh [go dotnet node python java php rust ruby kotlin]  (기본 전체)
set -uo pipefail
cd "$(dirname "$0")"
LANGS=("${@:-go dotnet node python java php rust ruby kotlin}")
[ "${#LANGS[@]}" -eq 1 ] && read -ra LANGS <<< "${LANGS[0]}"
export MSYS_NO_PATHCONV=1
mkdir -p report/signals
cleanup() { docker compose --profile apps down -v >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "== Keycloak 기동 =="
docker compose up -d keycloak
timeout 240 bash -c 'until [ "$(docker inspect -f "{{.State.Health.Status}}" "$(docker compose ps -q keycloak)")" = healthy ]; do sleep 3; done'
chmod -R 777 report 2>/dev/null || true

# NET는 docker-compose 프로젝트명이 디렉토리 basename("harness")과 같다고 가정한 서비스 DNS 네트워크명이다.
# COMPOSE_PROJECT_NAME을 다른 값으로 설정하거나 이 디렉토리를 리네임하면 이 가정이 깨져 앱 컨테이너가
# keycloak 서비스를 DNS로 못 찾고 전 언어 fetch-fail → 스코어카드 전체 0점으로 조용히 실패한다.
# keycloak이 기동된 뒤(위) 실제 compose 네트워크를 동적으로 조회하고, 실패 시에만 기본값으로 폴백한다.
NET="$(docker compose ps --format '{{.Networks}}' keycloak 2>/dev/null | head -1)"
[ -z "$NET" ] && NET=harness_default

# 언어별 실패를 누적한다. 부분실패 격리(한 언어가 깨져도 나머지를 계속 검증)는 유지하고
# 최종 종료코드에만 반영한다. k6(성능)는 게이트가 아니다 — 언어간 상대 점수일 뿐 절대 임계가 없다.
FAILED_LANGS=""

for L in "${LANGS[@]}"; do
  echo "== [$L] 앱 빌드·기동 =="
  if ! docker compose --profile apps up -d --build "app-$L"; then echo "{\"lang\":\"$L\",\"error\":\"build/up failed\"}" > "report/signals/$L.error.json"; FAILED_LANGS="$FAILED_LANGS $L"; continue; fi
  PORT=$(docker compose port "app-$L" 8090 2>/dev/null | sed 's/.*://')
  if ! timeout 120 bash -c "until curl -fsS http://localhost:$PORT/healthz >/dev/null 2>&1; do sleep 2; done"; then echo "{\"lang\":\"$L\",\"error\":\"healthz timeout\"}" > "report/signals/$L.error.json"; FAILED_LANGS="$FAILED_LANGS $L"; docker compose --profile apps stop "app-$L" >/dev/null 2>&1; continue; fi

  echo "== [$L] conformance =="
  docker run --rm --network "$NET" -v "$PWD/conformance:/c" -v "$PWD/report/signals:/out" \
    -e "BASE=http://app-$L:8090" -e KC_URL=http://keycloak:8080 -e "LANG=$L" node:20-alpine node /c/conformance.mjs || FAILED_LANGS="$FAILED_LANGS $L"
  echo "== [$L] security =="
  docker run --rm --network "$NET" -v "$PWD/security:/s" -v "$PWD/report/signals:/out" \
    -e "BASE=http://app-$L:8090" -e KC_URL=http://keycloak:8080 -e "LANG=$L" node:20-alpine node /s/probe.mjs || FAILED_LANGS="$FAILED_LANGS $L"
  echo "== [$L] k6 성능 =="
  # k6는 게이트가 아니다 — 성능은 언어간 상대 점수(최우수 대비)이지 절대 임계가 없다.
  # 측정 실패는 perf=null로 폴백되어 동형성 차원만 반영된다(무벌점).
  docker run --rm --network "$NET" -v "$PWD/driver:/scripts" -v "$PWD/report:/report" \
    -e "BASE_URL=http://app-$L:8090" -e KC_URL=http://keycloak:8080 -e "LANG=$L" grafana/k6 run /scripts/scenarios.js || true
  docker compose --profile apps stop "app-$L" >/dev/null 2>&1
done

echo "== SDK 스위트 집계 =="
./suites/run-suite.sh "${LANGS[@]}" || FAILED_LANGS="$FAILED_LANGS suite"
echo "== 스코어링 =="
node report/score.mjs "${LANGS[@]}"
echo "== 완료 — report/SCORECARD.md =="

# 실패한 언어(또는 suite)가 하나라도 있으면 0이 아닌 코드로 끝낸다. SCORECARD.md는 이미
# 생성됐으므로 CI 아티팩트로 회수 가능하다 — 실패해도 진단 자료는 남는다.
if [ -n "$FAILED_LANGS" ]; then
  # 중복 제거(한 언어가 conformance·security 양쪽에서 실패할 수 있다)
  UNIQ=$(printf '%s\n' $FAILED_LANGS | sort -u | tr '\n' ' ')
  echo "== 실패: $UNIQ =="
  exit 1
fi
echo "== 전 언어 통과 =="
