#!/usr/bin/env bash
# 전체 하네스 파이프라인. Usage: ./run.sh [go dotnet node python java]  (기본 go)
set -euo pipefail
cd "$(dirname "$0")"
LANGS=("${@:-go}")
NET=harness_default
# Windows Git Bash의 MSYS 경로변환이 -v 컨테이너 경로를 망가뜨리는 것 방지(Linux CI엔 무해).
export MSYS_NO_PATHCONV=1

# 모든 앱은 컨테이너 내부 8090 사용(계약 단순화). 함수는 첫 사용 전에 정의.
app_port() { echo 8090; }

cleanup() { docker compose --profile apps down -v >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "== Keycloak 기동 =="
docker compose up -d keycloak
timeout 220 bash -c 'until [ "$(docker inspect -f "{{.State.Health.Status}}" "$(docker compose ps -q keycloak)")" = healthy ]; do sleep 3; done'

rc=0
for LANG in "${LANGS[@]}"; do
  echo "== [$LANG] 앱 빌드·기동 =="
  docker compose --profile apps up -d --build "app-$LANG"
  PORT=$(docker compose port "app-$LANG" "$(app_port "$LANG")" 2>/dev/null | sed 's/.*://')
  timeout 90 bash -c "until curl -fsS http://localhost:$PORT/healthz >/dev/null 2>&1; do sleep 2; done"
  echo "== [$LANG] k6 실행 =="
  docker run --rm --network "$NET" -v "$PWD/driver:/scripts" -v "$PWD/report:/report" \
    -e "BASE_URL=http://app-$LANG:$(app_port "$LANG")" -e KC_URL=http://keycloak:8080 -e "LANG=$LANG" \
    grafana/k6 run /scripts/scenarios.js || rc=1
  docker compose --profile apps stop "app-$LANG" >/dev/null
done

echo "== 리포트 취합 =="
node report/aggregate.mjs "${LANGS[@]}" || rc=1
echo "== 완료 (rc=$rc) — report/RESULTS.md =="
exit $rc
