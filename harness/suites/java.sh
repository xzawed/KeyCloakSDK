#!/usr/bin/env bash
# harness/suites/java.sh — Java SDK 자체 단위테스트+커버리지(JaCoCo)+빌드를 maven:3.9-eclipse-temurin-21-alpine
# 컨테이너에서 실행한다(CLAUDE.md Java 툴체인: `mvn verify -DskipITs=true`, 커버리지 게이트 90/85 —
# jacoco-maven-plugin이 verify 단계에 report+check로 이미 배선되어 있다). 마지막 줄에 JSON 신호 1줄 출력.
#
# ⚠️ Alpine(musl) 이미지 사용: 기존 Debian `maven:3.9-eclipse-temurin-21`은 Docker Desktop(Windows)
# 내장 DNS가 Maven Central의 CNAME 체인을 glibc 리졸버에 실패로 돌려줘 의존성 다운로드가 막힌다(다른 8개
# suite/app 이미지와 동일한 Alpine 정책 — CLAUDE.md 하네스 게차). Alpine에서 전 모듈 132 단위테스트 통과
# 실측(CI Linux는 Debian도 무해하나 정책 일치·로컬 Windows 실행 가능화를 위해 통일). 리액터 전체 첫 실행은
# 의존성 다운로드로 느리다.
set -uo pipefail
cd "$(dirname "$0")/.."          # -> harness/
ROOT="$(cd .. && pwd)"           # 리포 루트 (java/ 는 $ROOT/java)
export MSYS_NO_PATHCONV=1

if ! command -v docker >/dev/null 2>&1; then
  echo "[java.sh] docker not found on PATH" >&2
  exit 1
fi

RAW=$(docker run --rm -v "$ROOT/java:/src-ro:ro" maven:3.9-eclipse-temurin-21-alpine sh -c '
  cp -r /src-ro /src && cd /src
  find . -name "*.java" -exec sed -i "s/\r$//" {} +
  mvn -B -f pom.xml verify -DskipITs=true 2>&1
  echo "___BUILDEXIT=$?"
  FILES=$(find . -path "*/target/site/jacoco/jacoco.csv" 2>/dev/null)
  if [ -n "$FILES" ]; then
    awk -F, "FNR>1{lm+=\$8;lc+=\$9;bm+=\$6;bc+=\$7} END{printf \"___COV_LINE=%.2f\n___COV_BRANCH=%.2f\n\", (lm+lc>0?100*lc/(lm+lc):0), (bm+bc>0?100*bc/(bm+bc):0)}" $FILES
  else
    echo "___COV_LINE=0"
    echo "___COV_BRANCH=0"
  fi
' 2>&1)
DOCKER_RC=$?

OUT=$(printf '%s' "$RAW" | sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g')

if [ "$DOCKER_RC" -ne 0 ] && [ -z "$OUT" ]; then
  echo "[java.sh] docker run produced no output (rc=$DOCKER_RC)" >&2
  exit 1
fi

# surefire의 모듈별 "Results:" 요약 행만(클래스별 "-- in X" 행은 제외)을 합산.
UNIT=$(printf '%s\n' "$OUT" | grep -E 'Tests run: [0-9]+, Failures: [0-9]+, Errors: [0-9]+, Skipped: [0-9]+$' \
  | grep -oE 'Tests run: [0-9]+' | grep -oE '[0-9]+' | awk '{s+=$1} END{print s+0}')
LINE=$(printf '%s\n' "$OUT" | grep -oE '___COV_LINE=[0-9]+(\.[0-9]+)?' | tail -1 | cut -d= -f2)
BRANCH=$(printf '%s\n' "$OUT" | grep -oE '___COV_BRANCH=[0-9]+(\.[0-9]+)?' | tail -1 | cut -d= -f2)
BUILDEXIT=$(printf '%s\n' "$OUT" | grep -oE '___BUILDEXIT=[0-9]+' | tail -1 | cut -d= -f2)
if [ "${BUILDEXIT:-1}" = "0" ]; then LINTCLEAN=true; else LINTCLEAN=false; fi

# surefire의 모듈별 "Results:" 요약 행에서 Failures/Errors 합계를 센다. mvn verify는
# 커버리지 게이트 실패로도 0이 아닌 종료코드를 내므로 BUILDEXIT만으로는 "테스트가 통과했는가"를
# 알 수 없다(테스트 실패와 린트/게이트 실패가 구분되지 않는다).
# 요약 행이 하나도 없으면(빌드가 테스트 단계 전에 죽음) 실패로 간주한다 — fail-closed.
SUMMARY_LINES=$(printf '%s\n' "$OUT" | grep -cE 'Tests run: [0-9]+, Failures: [0-9]+, Errors: [0-9]+, Skipped: [0-9]+$')
FAILCOUNT=$(printf '%s\n' "$OUT" | grep -E 'Tests run: [0-9]+, Failures: [0-9]+, Errors: [0-9]+, Skipped: [0-9]+$' \
  | grep -oE 'Failures: [0-9]+|Errors: [0-9]+' | grep -oE '[0-9]+' | awk '{s+=$1} END{print s+0}')
if [ "${SUMMARY_LINES:-0}" -gt 0 ] && [ "${FAILCOUNT:-1}" = "0" ]; then TESTSPASSED=true; else TESTSPASSED=false; fi

INTEGRATION=0
if [ "${SUITE_INTEGRATION:-0}" = "1" ]; then
  # Testcontainers(실제 Keycloak) 통합테스트는 Docker-in-Docker 필요 — best-effort opt-in.
  IRAW=$(docker run --rm -v "$ROOT/java:/src-ro:ro" -v /var/run/docker.sock:/var/run/docker.sock \
    maven:3.9-eclipse-temurin-21-alpine sh -c '
      cp -r /src-ro /src && cd /src
      find . -name "*.java" -exec sed -i "s/\r$//" {} +
      mvn -B -f pom.xml verify 2>&1
    ' 2>&1 || true)
  IOUT=$(printf '%s' "$IRAW" | sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g')
  INTEGRATION=$(printf '%s\n' "$IOUT" | grep -E 'Tests run: [0-9]+, Failures: [0-9]+, Errors: [0-9]+, Skipped: [0-9]+$' \
    | grep -oE 'Tests run: [0-9]+' | grep -oE '[0-9]+' | awk '{s+=$1} END{print s+0}')
fi

echo "{\"lang\":\"java\",\"unit\":${UNIT:-0},\"integration\":${INTEGRATION:-0},\"coverageLine\":${LINE:-0},\"coverageBranch\":${BRANCH:-0},\"lintClean\":${LINTCLEAN},\"testsPassed\":${TESTSPASSED},\"ran\":true}"
