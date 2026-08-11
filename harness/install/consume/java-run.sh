#!/bin/sh
# 런타임 엔트리포인트(java 참조 구현) — install-net에서 실행된다(docker run --network install-net).
# 1) install: mvn-repo(nginx 정적 .m2)에 게시된 io.github.xzawed:keycloak-sdk@0.1.0을 저장소 해석
#    (실제 소비자 명령 — `mvn dependency:get`은 프로젝트 없이도 좌표 하나의 해석 가능 여부를 검증하는
#    표준 방법이다).
# 2) quickstart 스모크: 설치된 패키지로 실 Keycloak에 대해 quickstart 실행.
# 3) app boot: harness/apps/java/src(무변경)를 설치된 패키지 의존으로 spring-boot:run 기동.
# 상태는 호스트 마운트 /status의 마커 파일로 회수한다(컨테이너 생존 여부와 무관하게 오케스트레이터가 읽음).
#
# ⚠️ install(settings.xml의 mvn-repo 저장소) · quickstart · app boot 전부 이 스크립트(런타임)에서
# 수행한다 — consume/java.Dockerfile은 파일만 담고 빌드타임 네트워크 의존 단계가 없다(node-run.sh와
# 동형 설계 — BuildKit이 build-time custom --network을 지원하지 않기 때문).
set -u
STATUS="${STATUS_DIR:-/status}"
SETTINGS=/work/settings.xml
# 릴리스 버전 — 오케스트레이터(install-verify.sh)가 -e PKG_VER로 주입한다(기본값은 단독 실행용).
PKG_VER="${PKG_VER:-0.1.0}"
mkdir -p "$STATUS"
rm -f "$STATUS/installed.ok" "$STATUS/quickstart.ok"

# 두 소비자 POM(app·quickstart)은 컨테이너에 구워진 파일이라 환경변수 보간이 통하지 않는다 —
# BOM import의 <version>만 런타임에 치환한다. `/keycloak-sdk-bom/{n;…}`는 "artifactId 줄 바로
# 다음 줄"만 건드리므로 앱 자신의 <version>0.0.1</version>이나 spring-boot parent 버전은 손대지
# 않는다(rust-run.sh가 app Cargo.toml에 쓰는 sed 치환과 같은 관용).
for POM in /work/app/pom.xml /work/quickstart/pom.xml; do
  sed -i "/<artifactId>keycloak-sdk-bom<\/artifactId>/{n;s#<version>[^<]*</version>#<version>${PKG_VER}</version>#;}" "$POM"
  if ! grep -A1 '<artifactId>keycloak-sdk-bom</artifactId>' "$POM" | grep -q "<version>${PKG_VER}</version>"; then
    echo "[java-run] $POM 의 BOM 버전 치환 FAILED — keycloak-sdk-bom 다음 줄이 <version>이 아닌가?"
    sed -n '/keycloak-sdk-bom/,+2p' "$POM"
    sleep 3600; exit 1
  fi
done
echo "[java-run] 소비자 POM의 keycloak-sdk-bom 버전을 ${PKG_VER}로 치환 완료"

echo "[java-run] 1/3 install — mvn dependency:get -Dartifact=io.github.xzawed:keycloak-sdk:$PKG_VER (mvn-repo)"
if mvn -s "$SETTINGS" -B -q dependency:get "-Dartifact=io.github.xzawed:keycloak-sdk:$PKG_VER" >/tmp/install.log 2>&1; then
  echo "[java-run] dependency:get 성공 — 출처 확인 중"
  # ⚠️ **출처를 기록한다**(이슈 #167). settings.xml은 Central을 유지한 채 mvn-repo를 **추가**한다
  # (부록 §java의 "`<mirror>*</mirror>` 금지" 준수 결과) — 같은 좌표·같은 버전이 Central에도 있으면
  # 거기서 받아도 초록이다. Maven은 받은 아티팩트 옆에 `_remote.repositories`로 **저장소 id**를
  # 남기므로(`keycloak-sdk-<ver>.jar>mvn-repo=`) 그것이 이 언어의 기계가독 출처 기록이다.
  _rr="${HOME}/.m2/repository/io/github/xzawed/keycloak-sdk/${PKG_VER}/_remote.repositories"
  if [ -f "$_rr" ]; then
    grep -E '\.(jar|pom)>' "$_rr" >"$STATUS/provenance.txt" 2>/dev/null || true
  else
    echo "<_remote.repositories 부재 — 로컬 빌드 산출물이거나 경로가 바뀌었다>" >"$STATUS/provenance.txt"
  fi
  echo "[java-run] SDK 출처: $(tr '\n' ' ' <"$STATUS/provenance.txt" 2>/dev/null)"
  # ⚠️ **출처 단언**(이슈 #167). 저장소 id는 settings.xml에서 파생한다 — 하드코딩하면 id를 바꿀 때
  # 가드가 **낡은 id를 지키며 초록**이 된다(node 스코프 가드가 package.json에서 파생하는 것과 같은 이유).
  # `_remote.repositories`의 `<파일>><id>=` 형식에서 그 id가 보이면 로컬이 서빙한 것이다.
  # ⚠️ **`<repositories>` 블록으로 스코프를 좁힌다.** 예전 구현은 파일 전체의 첫 `<id>`를 집었는데,
  # settings.xml에는 `<mirror>`·`<server>`·`<proxy>`·`<profile>`에도 `<id>`가 있다. 그게 오늘 맞는
  # 값을 낸 것은 profile id와 repository id의 철자가 우연히 같기 때문이었다. `<server>`(XSD상
  # `<mirrors>`보다 위에 와야 한다)를 하나 추가하면 오탐으로 뒤집히고, `<mirror><id>central</id>`를
  # 추가하면 **거짓 통과**가 된다(Central에서 받은 아티팩트가 `>central=`로 기록되므로).
  _repo_ids="$(sed -n '/<repositories>/,/<\/repositories>/{ s|.*<id>\([^<]*\)</id>.*|\1|p; }' "$SETTINGS")"
  # ⚠️ **"하나라도 로컬"이 아니라 "전부 로컬"이라야 한다.** `_remote.repositories`는 파일마다 한 줄이라
  # jar는 central, pom은 mvn-repo인 **부분 출처**가 성립한다 — 실측으로 확인했다(`jar>central=` +
  # `pom>mvn-repo=` 조합이 "하나라도" 규칙을 통과했다). 비어 있는 것도 실패다(fail-closed).
  # 선언된 로컬 저장소 id 중 하나로 **전부** 기록돼 있고, 그중 **jar**가 있어야 통과다
  # (pom만 로컬인 부분 출처 차단 · `central`은 로컬이 아니므로 후보에서 제외).
  PROVENANCE_OK=0
  _repo_id=""
  for _id in $_repo_ids; do
    [ "$_id" = central ] && continue
    if [ -s "$STATUS/provenance.txt" ] \
       && ! grep -v ">${_id}=" "$STATUS/provenance.txt" | grep -q . \
       && grep -q "\.jar>${_id}=" "$STATUS/provenance.txt"; then
      PROVENANCE_OK=1; _repo_id="$_id"; break
    fi
  done
  [ -n "$_repo_id" ] || _repo_id="$(printf '%s' "$_repo_ids" | tr '\n' ' ')"
  if [ "$PROVENANCE_OK" = 1 ]; then
    : > "$STATUS/installed.ok"
    echo "[java-run] install OK (저장소 ${_repo_id}가 서빙했다)"
  else
    echo "[java-run] install FAILED — SDK를 로컬 저장소(${_repo_id})가 아닌 곳에서 받았다: $(tr '\n' ' ' <"$STATUS/provenance.txt" 2>/dev/null)"
    cp /tmp/install.log "$STATUS/install.log" 2>/dev/null || true
    sleep 3600; exit 1
  fi
else
  echo "[java-run] install FAILED"; cat /tmp/install.log
  cp /tmp/install.log "$STATUS/install.log" 2>/dev/null || true
  sleep 3600; exit 1   # 컨테이너를 살려둬 진단 가능하게(오케스트레이터는 마커 부재로 실패 판정)
fi

echo "[java-run] 2/3 quickstart 스모크 — mvn -f /work/quickstart/pom.xml compile exec:java"
if mvn -s "$SETTINGS" -B -q -f /work/quickstart/pom.xml compile exec:java >/tmp/qs.log 2>&1; then
  : > "$STATUS/quickstart.ok"
  echo "[java-run] quickstart OK"
else
  echo "[java-run] quickstart FAILED(비치명 — app boot·conformance는 계속)"; cat /tmp/qs.log
  cp /tmp/qs.log "$STATUS/quickstart.log" 2>/dev/null || true
fi

echo "[java-run] 3/3 app boot — mvn -f /work/app/pom.xml spring-boot:run (APP_PORT=${APP_PORT:-8090})"
# -q를 빼서 컨테이너 로그(docker logs)에 Spring Boot 부팅 로그가 그대로 남게 한다(node의 exec node
# server.js와 동형 — 실패 진단은 여기서부터는 healthz 미응답으로 오케스트레이터가 판정).
exec mvn -s "$SETTINGS" -B -f /work/app/pom.xml spring-boot:run
