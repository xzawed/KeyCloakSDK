#!/bin/sh
# 런타임 엔트리포인트(Kotlin 참조 구현) — install-net에서 실행된다(docker run --network install-net).
# 1) install: mvn-repo-kotlin(nginx 정적 .m2)에 게시된 io.github.xzawed:keycloak-sdk-kotlin@0.1.0을 저장소
#    해석 + 다운로드해 앱을 컴파일한다(gradle classes — 게시 패키지가 해석·다운로드·API 호환돼야만 성공하는
#    실질 설치 검증; 전이 의존성은 Central에서 해석).
# 2) quickstart 스모크: 설치된 패키지로 실 Keycloak에 client-credentials 토큰을 받아 검증(gradle runQuickstart).
# 3) app boot: harness/apps/kotlin/src(무변경) Ktor 앱을 installDist 후 기동.
# 상태는 호스트 마운트 /status의 마커 파일로 회수한다(컨테이너 생존 여부와 무관하게 오케스트레이터가 읽음).
#
# ⚠️ install·quickstart·boot 전부 이 스크립트(런타임)에서 수행 — consume/kotlin.Dockerfile은 파일만 담고
# 빌드타임 네트워크 의존 단계가 없다(java-run.sh 동형 — BuildKit이 build-time custom --network 미지원).
# ⚠️ gradlew는 CRLF 스트립 후 `sh`로 호출한다(Windows 워킹트리 gradlew는 CRLF라 Alpine sh가 exit 127).
set -u
STATUS="${STATUS_DIR:-/status}"
mkdir -p "$STATUS"
rm -f "$STATUS/installed.ok" "$STATUS/quickstart.ok"

cd /work/app || { echo "[kotlin-run] /work/app 부재"; sleep 3600; exit 1; }
sed -i 's/\r$//' gradlew

# 릴리스 버전 — 오케스트레이터(install-verify.sh)가 -e PKG_VER로 주입한다(기본값은 단독 실행용).
PKG_VER="${PKG_VER:-0.1.0}"
# build.gradle.kts는 컨테이너에 구워진 파일이라 환경변수 보간이 통하지 않는다 — SDK 좌표의 버전만
# 런타임에 치환한다(rust-run.sh의 Cargo.toml sed 치환과 같은 관용). 좌표를 앵커로 삼으므로 Ktor 등
# 다른 의존성 버전은 건드리지 않는다.
sed -i "s#\(implementation(\"io\.github\.xzawed:keycloak-sdk-kotlin:\)[^\"]*#\1${PKG_VER}#" build.gradle.kts
if ! grep -q "implementation(\"io.github.xzawed:keycloak-sdk-kotlin:${PKG_VER}\")" build.gradle.kts; then
  echo "[kotlin-run] build.gradle.kts SDK 버전 치환 FAILED — 좌표 표기 형식이 바뀌었나?"
  grep -n 'keycloak-sdk-kotlin' build.gradle.kts
  sleep 3600; exit 1
fi
echo "[kotlin-run] build.gradle.kts의 keycloak-sdk-kotlin 버전을 ${PKG_VER}로 치환 완료"

echo "[kotlin-run] 1/3 install — gradle classes(mvn-repo-kotlin에서 keycloak-sdk-kotlin:$PKG_VER 해석·다운로드·컴파일)"
# ⚠️ `--info`는 **출처를 기록하기 위한 것**이다(이슈 #167). 이 앱의 repositories는 mvn-repo-kotlin을
# **추가**할 뿐 mavenCentral을 끄지 않는다 — 같은 좌표·같은 버전이 Central에도 있으면 거기서 받아도
# 초록이고, 그 순간 검증 대상은 방금 만든 산출물이 아니라 공개 패키지다. Gradle은 Maven과 달리
# 아티팩트 옆에 저장소 id를 남기지 않으므로 info 레벨의 다운로드 로그가 유일한 관측 지점이다.
if sh ./gradlew --no-daemon --info classes >/tmp/install.log 2>&1; then
  echo "[kotlin-run] gradle classes 성공 — 출처 확인 중"
  # ⚠️ **잘라내지 않는다.** 예전 구현은 `sort -u | head -3`이었는데, `http://`가 `https://`보다 먼저
  # 정렬되므로 로컬 URL 세 개가 앞자리를 채우면 **공개 저장소 URL이 잘려나가** 기록에서 사라진다.
  # 그러면 아래 "전부 로컬" 규칙이 잘린 증거만 보고 통과한다(공허). 전부 남긴다.
  grep -oE 'https?://[^ ]*keycloak-sdk-kotlin[^ ]*\.(jar|pom|module)' /tmp/install.log | sort -u >"$STATUS/provenance.txt" 2>/dev/null || true
  [ -s "$STATUS/provenance.txt" ] || echo "<--info 로그에서 SDK 다운로드 URL을 찾지 못했다(캐시 히트?)>" >"$STATUS/provenance.txt"
  echo "[kotlin-run] SDK 출처: $(tr '\n' ' ' <"$STATUS/provenance.txt" 2>/dev/null)"
  # ⚠️ **출처 단언**(이슈 #167). 레지스트리 URL은 build.gradle.kts의 `maven { url = uri(...) }`에서
  # 파생한다 — 하드코딩하면 URL을 바꿀 때 가드가 낡은 값을 지키며 초록이 된다.
  _kreg="$(sed -n 's|.*uri("\(http[^"]*\)").*|\1|p' build.gradle.kts | head -1)"
  # ⚠️ **전부 로컬이라야 한다.** Gradle은 --info에서 *실패한 시도*의 URL도 남긴다("Resource missing"
  # 등) — 그래서 "로컬 URL이 하나라도 있으면 통과"로 두면, 로컬에서 pom을 못 찾고 **Central에서
  # 받은** 실행도 로컬 URL이 로그에 있다는 이유로 통과한다. 기록된 SDK URL이 전부 로컬일 때만
  # 통과시키면 성공/시도를 구분하지 않고도 그 구멍이 닫힌다.
  # ⚠️ 음성 조건(외부 URL 없음)만으로는 "아무것도 안 받았는데 통과"가 가능하다 — **양성 조건**을
  # 함께 건다: 로컬에서 실제로 `.jar`를 받은 줄이 최소 하나 있어야 한다.
  if [ -n "$_kreg" ] && [ -s "$STATUS/provenance.txt" ] \
     && ! grep -v -F "$_kreg" "$STATUS/provenance.txt" | grep -q . \
     && grep -q -e "^${_kreg}.*\.jar$" "$STATUS/provenance.txt"; then
    PROVENANCE_OK=1
  else
    PROVENANCE_OK=0
  fi
  if [ "$PROVENANCE_OK" = 1 ]; then
    : > "$STATUS/installed.ok"
    echo "[kotlin-run] install OK (로컬 레지스트리 ${_kreg}에서 받았다)"
  else
    echo "[kotlin-run] install FAILED — SDK를 로컬(${_kreg:-URL 추출 실패})이 아닌 곳에서 받았거나 다운로드 기록이 없다: $(tr '\n' ' ' <"$STATUS/provenance.txt" 2>/dev/null)"
    cp /tmp/install.log "$STATUS/install.log" 2>/dev/null || true
    sleep 3600; exit 1
  fi
else
  echo "[kotlin-run] install FAILED"; cat /tmp/install.log
  cp /tmp/install.log "$STATUS/install.log" 2>/dev/null || true
  sleep 3600; exit 1   # 컨테이너를 살려둬 진단 가능하게(오케스트레이터는 마커 부재로 실패 판정)
fi

echo "[kotlin-run] 2/3 quickstart 스모크 — gradle runQuickstart(실 Keycloak)"
if sh ./gradlew --no-daemon -q runQuickstart >/tmp/qs.log 2>&1; then
  : > "$STATUS/quickstart.ok"
  echo "[kotlin-run] quickstart OK"
else
  echo "[kotlin-run] quickstart FAILED(비치명 — app boot·conformance는 계속)"; cat /tmp/qs.log
  cp /tmp/qs.log "$STATUS/quickstart.log" 2>/dev/null || true
fi

echo "[kotlin-run] 3/3 app boot — gradle installDist + 실행(APP_PORT=${APP_PORT:-8090})"
if ! sh ./gradlew --no-daemon installDist >/tmp/boot.log 2>&1; then
  echo "[kotlin-run] installDist FAILED"; cat /tmp/boot.log
  sleep 3600; exit 1
fi
exec ./build/install/harness-app-kotlin/bin/harness-app-kotlin
