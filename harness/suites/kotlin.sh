#!/usr/bin/env bash
# harness/suites/kotlin.sh — Kotlin SDK 자체 단위테스트 + Kover 커버리지 + ktlint를 eclipse-temurin:21-jdk-alpine
# 컨테이너에서 gradle wrapper(kotlin/gradlew, 9.5.0)로 실행한다(CLAUDE.md Kotlin 툴체인: `gradle -p kotlin
# test koverVerify ktlintCheck` — 게이트 라인90/브랜치85). 마지막 줄에 JSON 신호 1줄 출력.
#
# ⚠️ 미실행 검증(untested-here) — java.sh 등과 동일하게 이 스위트는 8언어 전체 CI 야간/수동 범위에서
# 실행하며, 첫 실행은 gradle 9.5.0 배포 다운로드 + 의존성 해석으로 느리다(코루틴/Nimbus/keycloak-admin).
set -uo pipefail
cd "$(dirname "$0")/.."          # -> harness/
ROOT="$(cd .. && pwd)"           # 리포 루트 (kotlin/ 는 $ROOT/kotlin)
export MSYS_NO_PATHCONV=1

if ! command -v docker >/dev/null 2>&1; then
  echo "[kotlin.sh] docker not found on PATH" >&2
  exit 1
fi

RAW=$(docker run --rm -v "$ROOT/kotlin:/src-ro:ro" eclipse-temurin:21-jdk-alpine sh -c '
  cp -r /src-ro /src && cd /src
  # ⚠️ 정직한 컨테이너 실행을 위해 Windows 로컬 build/.gradle(절대경로 임베드·스테일 결과)을 정리한다 —
  # 남기면 gradle이 이를 오해하거나(up-to-date 오판) 스테일 산출물을 실행 없이 읽어버린다.
  rm -rf build .gradle
  # ⚠️ gradlew도 CRLF 스트립 후 `sh`로 호출한다 — Windows 워킹트리 gradlew는 CRLF라 `./gradlew`가
  # shebang 실패로 exit 127로 죽는다(그러면 gradle이 아예 안 돌고 위 스테일 build/만 읽힌다). Dockerfile 동형.
  sed -i "s/\r$//" gradlew
  find . -name "*.kt" -o -name "*.kts" | xargs -r sed -i "s/\r$//" 2>/dev/null || true
  # koverXmlReport가 계측 test를 트리거해 build/test-results/test/*.xml + build/reports/kover/report.xml 생성.
  # --continue: ktlintCheck 실패해도 커버리지 리포트는 생성되도록.
  sh ./gradlew --no-daemon --continue test koverXmlReport ktlintCheck 2>&1
  echo "___BUILDEXIT=$?"
  UNIT=$(find build/test-results/test -name "TEST-*.xml" 2>/dev/null -exec grep -hoE "tests=\"[0-9]+\"" {} + \
    | grep -oE "[0-9]+" | awk "{s+=\$1} END{print s+0}")
  echo "___UNIT=$UNIT"
  REPORT=build/reports/kover/report.xml
  if [ -f "$REPORT" ]; then
    # 루트 롤업 counter는 파일 최말미(모든 package 뒤). 마지막 LINE/BRANCH를 취해 백분율 계산.
    LC=$(grep -oE "<counter type=\"LINE\" missed=\"[0-9]+\" covered=\"[0-9]+\"" "$REPORT" | tail -1)
    BC=$(grep -oE "<counter type=\"BRANCH\" missed=\"[0-9]+\" covered=\"[0-9]+\"" "$REPORT" | tail -1)
    printf "%s\n" "$LC"   | awk -F"\"" "{m=\$4;c=\$6; printf \"___COV_LINE=%.2f\n\",   (m+c>0?100*c/(m+c):0)}"
    printf "%s\n" "$BC"   | awk -F"\"" "{m=\$4;c=\$6; printf \"___COV_BRANCH=%.2f\n\", (m+c>0?100*c/(m+c):0)}"
  else
    echo "___COV_LINE=0"
    echo "___COV_BRANCH=0"
  fi
' 2>&1)
DOCKER_RC=$?

OUT=$(printf '%s' "$RAW" | sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g')

if [ "$DOCKER_RC" -ne 0 ] && [ -z "$OUT" ]; then
  echo "[kotlin.sh] docker run produced no output (rc=$DOCKER_RC)" >&2
  exit 1
fi

UNIT=$(printf '%s\n' "$OUT" | grep -oE '___UNIT=[0-9]+' | tail -1 | cut -d= -f2)
LINE=$(printf '%s\n' "$OUT" | grep -oE '___COV_LINE=[0-9]+(\.[0-9]+)?' | tail -1 | cut -d= -f2)
BRANCH=$(printf '%s\n' "$OUT" | grep -oE '___COV_BRANCH=[0-9]+(\.[0-9]+)?' | tail -1 | cut -d= -f2)
BUILDEXIT=$(printf '%s\n' "$OUT" | grep -oE '___BUILDEXIT=[0-9]+' | tail -1 | cut -d= -f2)
if [ "${BUILDEXIT:-1}" = "0" ]; then LINTCLEAN=true; else LINTCLEAN=false; fi

# 통합테스트(Testcontainers, 실제 Keycloak)는 Docker-in-Docker 필요 — best-effort opt-in.
INTEGRATION=0
if [ "${SUITE_INTEGRATION:-0}" = "1" ]; then
  IRAW=$(docker run --rm -v "$ROOT/kotlin:/src-ro:ro" -v /var/run/docker.sock:/var/run/docker.sock \
    eclipse-temurin:21-jdk-alpine sh -c '
      cp -r /src-ro /src && cd /src
      rm -rf .gradle
      sed -i "s/\r$//" gradlew
      find . -name "*.kt" -o -name "*.kts" | xargs -r sed -i "s/\r$//" 2>/dev/null || true
      sh ./gradlew --no-daemon integrationTest 2>&1
    ' 2>&1 || true)
  IOUT=$(printf '%s' "$IRAW" | sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g')
  INTEGRATION=$(printf '%s\n' "$IOUT" | grep -hoE 'tests="[0-9]+"' 2>/dev/null | grep -oE '[0-9]+' | awk '{s+=$1} END{print s+0}')
fi

echo "{\"lang\":\"kotlin\",\"unit\":${UNIT:-0},\"integration\":${INTEGRATION:-0},\"coverageLine\":${LINE:-0},\"coverageBranch\":${BRANCH:-0},\"lintClean\":${LINTCLEAN},\"ran\":true}"
