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

# 실패의 **원인**을 아티팩트에 남긴다. 신호 JSON은 증상만 담는다 — `{"ok":false,"detail":"500"}`는
# 500을 낸 이유를 말하지 않는다. 실측 2026-09-16: 야간 score-all이 여덟 밤 빨갰는데 앱이 던진
# 예외 문장이 어디에도 없어, 원인 규명에 로컬 재빌드와 통제 실험이 필요했다. 업로드되는 것은
# report/signals/ 뿐이므로(harness.yml) 증거도 그곳에 쓴다.
capture_app_log() { # $1=lang — 성공·실패 무관하게 남긴다(분기가 없으면 분기를 틀릴 일도 없다)
  if docker compose logs --no-color --tail 300 "app-$1" > "report/signals/$1.app.log" 2>&1; then
    # ⚠️ 빈 파일은 「증거 없음」과 구분되지 않는다 — 비었으면 비었다고 적는다.
    [ -s "report/signals/$1.app.log" ] || printf '(빈 로그 — app-%s 가 stdout/stderr 에 아무것도 쓰지 않았다)\n' "$1" > "report/signals/$1.app.log"
  else
    # ⚠️ `2>&1` 이라 실패하면 파일에 든 것은 **앱 출력이 아니라 CLI 오류**다(실측: 없는 서비스 →
    # `no such service: app-x` 28B). 비어 있지 않으므로 위 표시가 안 붙고, 28B 가 「증거가 있다」로
    # 읽힌다 — 그래서 무엇인지 적는다. ⚠️ **프로필 때문은 아니다**: `--profile apps` 없이도
    # `logs`·`ps -a` 는 앱 컨테이너를 본다(실측 2026-09-16 — 기동·정지·삭제 세 상태 전부).
    _cli="$(cat "report/signals/$1.app.log" 2>/dev/null || true)"
    printf '(docker compose logs 실패 — 아래는 앱 출력이 아니라 CLI 오류다)\n%s\n' "$_cli" > "report/signals/$1.app.log"
  fi
}
# 컨테이너 목록 — 빌드·기동 실패의 원인과 증상을 가른다. 중단된 런이 남긴 이름 충돌
# (`Conflict. The container name ... is already in use`)은 빌드가 성공해도 up을 실패시키는데,
# 신호에는 "build/up failed"로만 남아 코드를 뒤지게 만든다.
capture_compose_ps() { # $1=lang
  docker compose ps -a > "report/signals/$1.compose-ps.txt" 2>&1 || true
}

for L in "${LANGS[@]}"; do
  echo "== [$L] 앱 빌드·기동 =="
  if ! docker compose --profile apps up -d --build "app-$L"; then capture_compose_ps "$L"; capture_app_log "$L"; echo "{\"lang\":\"$L\",\"error\":\"build/up failed\"}" > "report/signals/$L.error.json"; FAILED_LANGS="$FAILED_LANGS $L"; continue; fi
  PORT=$(docker compose port "app-$L" 8090 2>/dev/null | sed 's/.*://')
  if ! timeout 120 bash -c "until curl -fsS http://localhost:$PORT/healthz >/dev/null 2>&1; do sleep 2; done"; then capture_app_log "$L"; capture_compose_ps "$L"; echo "{\"lang\":\"$L\",\"error\":\"healthz timeout\"}" > "report/signals/$L.error.json"; FAILED_LANGS="$FAILED_LANGS $L"; docker compose --profile apps stop "app-$L" >/dev/null 2>&1; continue; fi

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
  # ⚠️ stop 앞에서 남긴다 — EXIT 트랩의 `down -v` 뒤에는 읽을 컨테이너가 없다.
  capture_app_log "$L"
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
