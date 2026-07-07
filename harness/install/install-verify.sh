#!/usr/bin/env bash
# 설치·동작 검증 오케스트레이터. Usage: ./install-verify.sh [go dotnet node python java php rust ruby]  (기본 전체)
#
# 언어별 4단계(harness/install/README 설계 §3 — Publish→Install→Operate→Report)를 순차 실행한다:
#   A. Publish  publish/<lang>.sh 가 실 배포 산출물을 빌드해 로컬 레지스트리에 게시.
#   B. Install  consume/<lang>.Dockerfile 이 소스 트리 없는 클린 컨테이너에서 실제 설치 명령으로 설치
#               + quickstart 스모크 + 하네스 앱을 '설치된 패키지' 소비로 재빌드·기동.
#   C. Operate  설치된-패키지 앱에 대해 기존 conformance.mjs(계약 체크) + security/probe.mjs(JWT 프로브) 재실행.
#   D. Report   전 언어 루프 후 report/install-matrix.mjs 가 report/signals/*.install.json → INSTALL-MATRIX.md.
#
# 각 언어 태스크는 아직 publish/consume을 채우지 않았으므로(run_lang_<lang> 스텁), 현재는
# 모든 언어가 "not implemented" 신호를 emit하고 계속 진행한다 — 이후 언어별 태스크가
# run_lang_<lang>() 본문을 실제 파이프라인으로 교체한다.
#
# 한 언어의 실패가 나머지 언어를 막지 않도록 harness/verify.sh 관용을 재구현한다(소싱 아님):
# set -e 없이 각 단계를 명시적으로 처리하고 실패 시 fail_lang → continue.
set -uo pipefail
cd "$(dirname "$0")"
# shellcheck source=lib.sh
. ./lib.sh

DEFAULT_LANGS="go dotnet node python java php rust ruby"
LANGS=("${@:-$DEFAULT_LANGS}")
[ "${#LANGS[@]}" -eq 1 ] && read -ra LANGS <<< "${LANGS[0]}"

export MSYS_NO_PATHCONV=1
mkdir -p report/signals

# not_implemented <lang> — 아직 publish/consume이 없는 언어의 공통 스텁 신호.
# artifactBuilt 이하 전부 false + error로 명시해 INSTALL-MATRIX.md에서 "미구현"이 실패와
# 혼동되지 않게 한다(사유 열에 이유가 남는다).
not_implemented() {
  local lang="$1"
  log "[$lang] TODO: publish/consume이 아직 구현되지 않았다(해당 언어 태스크 대기 중) — not implemented로 기록"
  emit_signal "$lang" \
    "artifactBuilt=false" "published=false" "installed=false" "quickstartOk=false" "appBoot=false" \
    'conformance={"passed":0,"failed":0}' 'security={"defended":0,"total":0}' \
    "error=not implemented (language task pending)"
}

# ---------------------------------------------------------------------------------------
# run_lang_<lang> — 언어별 파이프라인 진입점. 각 언어 태스크(T1.1 node 참조구현 + T2.x)가
# 아래 스텁을 다음 실제 흐름으로 교체한다(브리프 Step 3 그대로):
#
#   publish/<lang>.sh 실행                                    # 실패 시: fail_lang lang publish "<msg>"; return
#     └ 성공 시 emit_signal lang artifactBuilt=true published=true
#   consume/<lang>.Dockerfile build + run(설치된 패키지 소비)   # 실패 시: fail_lang lang install "<msg>"; return
#     └ 성공 시 emit_signal lang installed=true quickstartOk=true appBoot=true
#   컨테이너 내부 네트워크(install-net)에서 conformance.mjs 실행 # BASE=설치된-패키지 앱 URL, KC_URL=keycloak
#   컨테이너 내부 네트워크(install-net)에서 probe.mjs 실행       # 동일 BASE/KC_URL
#     └ 결과 JSON({passed,failed}/{defended,total})을 emit_signal lang conformance=... security=...
#
# 지금은 언어 태스크가 아직 이 본문을 채우지 않았으므로 전부 not_implemented로 위임한다.
# ---------------------------------------------------------------------------------------
run_lang_go() {
  local lang="go"
  local app_container="install-app-go"
  local app_port_host="18092"
  local harness_dir
  harness_dir="$(cd .. && pwd)"   # harness/ (conformance·security 스크립트 위치)

  log "[$lang] publish (publish/go.sh) — file GOPROXY 합성(레지스트리 데몬 없음, 격리 git repo+go mod download)"
  if ! ./publish/go.sh; then
    fail_lang "$lang" publish "publish/go.sh 실패(위 로그 참고)"
    return
  fi
  emit_signal "$lang" "artifactBuilt=true" "published=true"

  # consume 이미지는 파일만 담는다(빌드타임 네트워크 의존 없음 — BuildKit이 build-time custom --network을
  # 지원하지 않으므로 기본 빌더로 빌드되도록, 그리고 app-boot/conformance와 동일한 install-net 서비스명
  # 해석 경로를 재사용하려는 의도). install(go get)/quickstart/boot는 런타임 엔트리포인트(go-run.sh)가
  # install-net에서 수행.
  log "[$lang] consume 이미지 빌드(빌드타임 네트워크 없음)"
  if ! docker build -f "$(hostpath "$PWD/consume/go.Dockerfile")" -t install-consume-go "$(hostpath "$harness_dir/..")"; then
    fail_lang "$lang" install "consume/go.Dockerfile 빌드 실패"
    return
  fi

  log "[$lang] 앱 컨테이너 기동(install→quickstart→boot @ install-net)"
  local status_dir="$PWD/report/status/$lang"
  rm -rf "$status_dir"; mkdir -p "$status_dir"
  docker rm -f "$app_container" >/dev/null 2>&1 || true
  # /proxy: publish/go.sh가 합성한 file GOPROXY 디렉터리(레지스트리 컨테이너가 아니라 볼륨) — 읽기전용
  # 마운트. GOPROXY 체인은 로컬(SDK)→공개 proxy.golang.org(전이 의존성 gocloak/go-jose/oauth2 등
  # 폴스루)→direct 순.  ⚠️ GOPRIVATE는 설정 금지(설정 시 GONOPROXY로 전이돼 file 프록시를 우회한다).
  if ! docker run -d --name "$app_container" --network install-net \
      -v "$(hostpath "$status_dir"):/status" \
      -v "$(hostpath "$PWD/publish/out/go/proxy"):/proxy:ro" \
      -e GOPROXY="file:///proxy,https://proxy.golang.org,direct" \
      -e KC_SERVER_URL=http://keycloak:8080 -e KC_REALM=it-realm \
      -e KC_CLIENT_ID=it-client -e KC_CLIENT_SECRET=it-secret -e APP_PORT=8090 \
      -p "${app_port_host}:8090" install-consume-go >/dev/null; then
    fail_lang "$lang" install "앱 컨테이너 기동(docker run) 실패"
    return
  fi

  # 런타임 run.sh가 install→quickstart→boot 수행: install/quickstart는 /status 마커로, boot는 healthz로 판정.
  wait_healthy "http://localhost:${app_port_host}/healthz" 180 || true
  if [ ! -f "$status_dir/installed.ok" ]; then
    fail_lang "$lang" install "설치 마커 부재 — file GOPROXY 설치(go get) 실패"
    docker logs "$app_container" 2>&1 | tail -n 80 >&2 || true
    docker rm -f "$app_container" >/dev/null 2>&1 || true
    return
  fi
  emit_signal "$lang" "installed=true"
  [ -f "$status_dir/quickstart.ok" ] && emit_signal "$lang" "quickstartOk=true"
  if curl -fsS "http://localhost:${app_port_host}/healthz" >/dev/null 2>&1; then
    emit_signal "$lang" "appBoot=true"
  else
    fail_lang "$lang" boot "앱 healthz 미응답(부팅 실패)"
    docker rm -f "$app_container" >/dev/null 2>&1 || true
    return
  fi

  # conformance/security — harness/verify.sh와 동일한 러너(node:20-alpine + conformance.mjs/probe.mjs)를
  # install-net에서 재사용한다. install-net은 compose.install.yml에 명시 name(install-net)으로 고정돼
  # 있으므로 동적 네트워크명 조회가 필요 없다. BASE는 컨테이너명(도커 DNS 별칭)으로 지정.
  log "[$lang] conformance"
  docker run --rm --network install-net -v "$(hostpath "$harness_dir/conformance"):/c" -v "$(hostpath "$PWD/report/signals"):/out" \
    -e "BASE=http://${app_container}:8090" -e KC_URL=http://keycloak:8080 -e "LANG=$lang" \
    node:20-alpine node /c/conformance.mjs || true

  log "[$lang] security"
  docker run --rm --network install-net -v "$(hostpath "$harness_dir/security"):/s" -v "$(hostpath "$PWD/report/signals"):/out" \
    -e "BASE=http://${app_container}:8090" -e KC_URL=http://keycloak:8080 -e "LANG=$lang" \
    node:20-alpine node /s/probe.mjs || true

  # conformance.mjs/probe.mjs가 report/signals/go.{conformance,security}.json에 쓴 원본 신호를
  # install.json의 conformance/security 키로 반영(lib.sh 공유 헬퍼 — node 참조 구현과 동일 재사용).
  emit_conformance_security "$lang"

  docker rm -f "$app_container" >/dev/null 2>&1 || true
  log "[$lang] 완료"
}
run_lang_dotnet() {
  local lang="dotnet"
  local app_container="install-app-dotnet"
  local app_port_host="18093"
  local harness_dir
  harness_dir="$(cd .. && pwd)"   # harness/ (conformance·security 스크립트 위치)

  log "[$lang] BaGetter(레지스트리) 기동"
  if ! docker compose -f compose.install.yml up -d bagetter; then
    fail_lang "$lang" registry "bagetter 기동(docker compose up) 실패"
    return
  fi
  # /healthz는 이 이미지에서 404(실측) — 실제 NuGet V3 서비스 인덱스로 판정(레지스트리 API가
  # 실제로 응답 가능함을 검증하므로 더 의미 있는 신호이기도 하다).
  if ! wait_healthy "http://localhost:18180/v3/index.json" 120; then
    fail_lang "$lang" registry "bagetter가 제한시간 내 healthy 상태가 되지 않았다"
    return
  fi

  log "[$lang] publish (publish/dotnet.sh)"
  if ! ./publish/dotnet.sh; then
    fail_lang "$lang" publish "publish/dotnet.sh 실패(위 로그 참고)"
    return
  fi
  emit_signal "$lang" "artifactBuilt=true" "published=true"

  # consume 이미지는 파일만 담는다(빌드타임 네트워크 의존 없음 — BuildKit이 build-time custom --network을
  # 지원하지 않으므로). install(add package)/quickstart/boot는 런타임 엔트리포인트(dotnet-run.sh)가
  # install-net에서 수행한다(node 참조 구현과 동형 — dotnet은 컴파일 언어라 "설치=복원"이라 이 설계가
  # 더 자연스럽다).
  log "[$lang] consume 이미지 빌드(빌드타임 네트워크 없음)"
  if ! docker build -f "$(hostpath "$PWD/consume/dotnet.Dockerfile")" -t install-consume-dotnet "$(hostpath "$harness_dir/..")"; then
    fail_lang "$lang" install "consume/dotnet.Dockerfile 빌드 실패"
    return
  fi

  log "[$lang] 앱 컨테이너 기동(install→quickstart→boot @ install-net)"
  local status_dir="$PWD/report/status/$lang"
  rm -rf "$status_dir"; mkdir -p "$status_dir"
  docker rm -f "$app_container" >/dev/null 2>&1 || true
  if ! docker run -d --name "$app_container" --network install-net \
      -v "$(hostpath "$status_dir"):/status" \
      -e REGISTRY_URL=http://bagetter:8080/v3/index.json \
      -e KC_SERVER_URL=http://keycloak:8080 -e KC_REALM=it-realm \
      -e KC_CLIENT_ID=it-client -e KC_CLIENT_SECRET=it-secret -e APP_PORT=8090 \
      -p "${app_port_host}:8090" install-consume-dotnet >/dev/null; then
    fail_lang "$lang" install "앱 컨테이너 기동(docker run) 실패"
    return
  fi

  # 런타임 run.sh가 nuget.config 배치→install(add package)→quickstart→app publish+boot 수행:
  # install/quickstart는 /status 마커로, boot는 healthz로 판정. dotnet은 런타임에 실제 컴파일
  # (dotnet publish)까지 수행하므로 node보다 타임아웃을 넉넉히 둔다(실측: 전 단계 합쳐 약 25초 —
  # 240초는 콜드 NuGet 캐시·느린 CI 러너까지 감안한 여유값).
  wait_healthy "http://localhost:${app_port_host}/healthz" 240 || true
  if [ ! -f "$status_dir/installed.ok" ]; then
    fail_lang "$lang" install "설치 마커 부재 — 레지스트리 설치(dotnet add package) 실패"
    docker logs "$app_container" 2>&1 | tail -n 80 >&2 || true
    docker rm -f "$app_container" >/dev/null 2>&1 || true
    return
  fi
  emit_signal "$lang" "installed=true"
  [ -f "$status_dir/quickstart.ok" ] && emit_signal "$lang" "quickstartOk=true"
  if curl -fsS "http://localhost:${app_port_host}/healthz" >/dev/null 2>&1; then
    emit_signal "$lang" "appBoot=true"
  else
    fail_lang "$lang" boot "앱 healthz 미응답(부팅 실패)"
    docker rm -f "$app_container" >/dev/null 2>&1 || true
    return
  fi

  # conformance/security — harness/verify.sh와 동일한 러너(node:20-alpine + conformance.mjs/probe.mjs)를
  # install-net에서 재사용한다. install-net은 compose.install.yml에 명시 name(install-net)으로 고정돼
  # 있으므로 동적 네트워크명 조회가 필요 없다. BASE는 컨테이너명(도커 DNS 별칭)으로 지정.
  log "[$lang] conformance"
  docker run --rm --network install-net -v "$(hostpath "$harness_dir/conformance"):/c" -v "$(hostpath "$PWD/report/signals"):/out" \
    -e "BASE=http://${app_container}:8090" -e KC_URL=http://keycloak:8080 -e "LANG=$lang" \
    node:20-alpine node /c/conformance.mjs || true

  log "[$lang] security"
  docker run --rm --network install-net -v "$(hostpath "$harness_dir/security"):/s" -v "$(hostpath "$PWD/report/signals"):/out" \
    -e "BASE=http://${app_container}:8090" -e KC_URL=http://keycloak:8080 -e "LANG=$lang" \
    node:20-alpine node /s/probe.mjs || true

  # conformance.mjs/probe.mjs가 report/signals/dotnet.{conformance,security}.json에 쓴 원본 신호를
  # install.json의 conformance/security 키로 반영(lib.sh 공유 헬퍼).
  emit_conformance_security "$lang"

  docker rm -f "$app_container" >/dev/null 2>&1 || true
  log "[$lang] 완료"
}

# run_lang_node — node 참조 구현(T1.1). 이후 7개 언어가 이 함수 구조(레지스트리 기동→publish→
# consume 빌드(quickstart 스모크 내장)→앱 기동→conformance/security 재실행→emit)를 복제한다.
#
#   A. Publish  publish/node.sh가 harness/apps/node/Dockerfile의 기존 "sdk" 스테이지를 재사용해
#               tgz를 빌드하고, Verdaccio(레지스트리)에 그대로 게시한다.
#   B. Install  consume/node.Dockerfile이 harness/node(SDK 소스) 접근 없이 Verdaccio에서
#               `npm install @xzawed/keycloak-sdk@0.1.0`으로 설치 → quickstart 상당 스모크(RUN 단계,
#               실패 시 빌드 자체가 실패) → harness/apps/node/server.js(무변경) 기동.
#   C. Operate  기존 conformance.mjs/security probe.mjs를 설치된-패키지 앱 컨테이너에 대해 재실행.
#   D. Report   결과를 report/signals/node.install.json(emit_signal)에 기록.
run_lang_node() {
  local lang="node"
  local app_container="install-app-node"
  local app_port_host="18090"
  local harness_dir
  harness_dir="$(cd .. && pwd)"   # harness/ (conformance·security 스크립트 위치)

  log "[$lang] Verdaccio(레지스트리) 기동"
  if ! docker compose -f compose.install.yml up -d verdaccio; then
    fail_lang "$lang" registry "verdaccio 기동(docker compose up) 실패"
    return
  fi
  if ! wait_healthy "http://localhost:4873/-/ping" 120; then
    fail_lang "$lang" registry "verdaccio가 제한시간 내 healthy 상태가 되지 않았다"
    return
  fi

  log "[$lang] publish (publish/node.sh)"
  if ! ./publish/node.sh; then
    fail_lang "$lang" publish "publish/node.sh 실패(위 로그 참고)"
    return
  fi
  emit_signal "$lang" "artifactBuilt=true" "published=true"

  # consume 이미지는 파일만 담는다(빌드타임 네트워크 의존 없음 — BuildKit이 build-time custom --network을
  # 지원하지 않으므로). install/quickstart/boot는 런타임 엔트리포인트(node-run.sh)가 install-net에서 수행.
  log "[$lang] consume 이미지 빌드(빌드타임 네트워크 없음)"
  if ! docker build -f "$(hostpath "$PWD/consume/node.Dockerfile")" -t install-consume-node "$(hostpath "$harness_dir/..")"; then
    fail_lang "$lang" install "consume/node.Dockerfile 빌드 실패"
    return
  fi

  log "[$lang] 앱 컨테이너 기동(install→quickstart→boot @ install-net)"
  local status_dir="$PWD/report/status/$lang"
  rm -rf "$status_dir"; mkdir -p "$status_dir"
  docker rm -f "$app_container" >/dev/null 2>&1 || true
  if ! docker run -d --name "$app_container" --network install-net \
      -v "$(hostpath "$status_dir"):/status" \
      -e REGISTRY_URL=http://verdaccio:4873 \
      -e KC_SERVER_URL=http://keycloak:8080 -e KC_REALM=it-realm \
      -e KC_CLIENT_ID=it-client -e KC_CLIENT_SECRET=it-secret -e APP_PORT=8090 \
      -p "${app_port_host}:8090" install-consume-node >/dev/null; then
    fail_lang "$lang" install "앱 컨테이너 기동(docker run) 실패"
    return
  fi

  # 런타임 run.sh가 install→quickstart→boot 수행: install/quickstart는 /status 마커로, boot는 healthz로 판정.
  wait_healthy "http://localhost:${app_port_host}/healthz" 180 || true
  if [ ! -f "$status_dir/installed.ok" ]; then
    fail_lang "$lang" install "설치 마커 부재 — 레지스트리 설치(npm install) 실패"
    docker logs "$app_container" 2>&1 | tail -n 80 >&2 || true
    docker rm -f "$app_container" >/dev/null 2>&1 || true
    return
  fi
  emit_signal "$lang" "installed=true"
  [ -f "$status_dir/quickstart.ok" ] && emit_signal "$lang" "quickstartOk=true"
  if curl -fsS "http://localhost:${app_port_host}/healthz" >/dev/null 2>&1; then
    emit_signal "$lang" "appBoot=true"
  else
    fail_lang "$lang" boot "앱 healthz 미응답(부팅 실패)"
    docker rm -f "$app_container" >/dev/null 2>&1 || true
    return
  fi

  # conformance/security — harness/verify.sh와 동일한 러너(node:20-alpine + conformance.mjs/probe.mjs)를
  # install-net에서 재사용한다. install-net은 compose.install.yml에 명시 name(install-net)으로 고정돼
  # 있으므로(verify.sh와 달리) 동적 네트워크명 조회가 필요 없다. BASE는 컨테이너명(도커 DNS 별칭)으로 지정.
  log "[$lang] conformance"
  docker run --rm --network install-net -v "$(hostpath "$harness_dir/conformance"):/c" -v "$(hostpath "$PWD/report/signals"):/out" \
    -e "BASE=http://${app_container}:8090" -e KC_URL=http://keycloak:8080 -e "LANG=$lang" \
    node:20-alpine node /c/conformance.mjs || true

  log "[$lang] security"
  docker run --rm --network install-net -v "$(hostpath "$harness_dir/security"):/s" -v "$(hostpath "$PWD/report/signals"):/out" \
    -e "BASE=http://${app_container}:8090" -e KC_URL=http://keycloak:8080 -e "LANG=$lang" \
    node:20-alpine node /s/probe.mjs || true

  # conformance.mjs/probe.mjs가 report/signals/node.{conformance,security}.json에 쓴 원본 신호를
  # install.json의 conformance/security 키로 반영(lib.sh 공유 헬퍼 — 8언어 공통 재사용 대상).
  emit_conformance_security "$lang"

  docker rm -f "$app_container" >/dev/null 2>&1 || true
  log "[$lang] 완료"
}

run_lang_python() {
  local lang="python"
  local app_container="install-app-python"
  local app_port_host="18091"
  local harness_dir
  harness_dir="$(cd .. && pwd)"   # harness/ (conformance·security 스크립트 위치)

  log "[$lang] pypiserver(레지스트리) 기동"
  if ! docker compose -f compose.install.yml up -d pypiserver; then
    fail_lang "$lang" registry "pypiserver 기동(docker compose up) 실패"
    return
  fi
  if ! wait_healthy "http://localhost:18892/simple/" 120; then
    fail_lang "$lang" registry "pypiserver가 제한시간 내 healthy 상태가 되지 않았다"
    return
  fi

  log "[$lang] publish (publish/python.sh)"
  if ! ./publish/python.sh; then
    fail_lang "$lang" publish "publish/python.sh 실패(위 로그 참고)"
    return
  fi
  emit_signal "$lang" "artifactBuilt=true" "published=true"

  # consume 이미지는 파일만 담는다(빌드타임 네트워크 의존 없음 — node.Dockerfile과 동형 이유).
  log "[$lang] consume 이미지 빌드(빌드타임 네트워크 없음)"
  if ! docker build -f "$(hostpath "$PWD/consume/python.Dockerfile")" -t install-consume-python "$(hostpath "$harness_dir/..")"; then
    fail_lang "$lang" install "consume/python.Dockerfile 빌드 실패"
    return
  fi

  log "[$lang] 앱 컨테이너 기동(install→quickstart→boot @ install-net)"
  local status_dir="$PWD/report/status/$lang"
  rm -rf "$status_dir"; mkdir -p "$status_dir"
  docker rm -f "$app_container" >/dev/null 2>&1 || true
  if ! docker run -d --name "$app_container" --network install-net \
      -v "$(hostpath "$status_dir"):/status" \
      -e REGISTRY_URL=http://pypiserver:8080 \
      -e KC_SERVER_URL=http://keycloak:8080 -e KC_REALM=it-realm \
      -e KC_CLIENT_ID=it-client -e KC_CLIENT_SECRET=it-secret -e APP_PORT=8090 \
      -p "${app_port_host}:8090" install-consume-python >/dev/null; then
    fail_lang "$lang" install "앱 컨테이너 기동(docker run) 실패"
    return
  fi

  # 런타임 run.sh가 install→quickstart→boot 수행: install/quickstart는 /status 마커로, boot는 healthz로 판정.
  wait_healthy "http://localhost:${app_port_host}/healthz" 180 || true
  if [ ! -f "$status_dir/installed.ok" ]; then
    fail_lang "$lang" install "설치 마커 부재 — 레지스트리 설치(pip install) 실패"
    docker logs "$app_container" 2>&1 | tail -n 80 >&2 || true
    docker rm -f "$app_container" >/dev/null 2>&1 || true
    return
  fi
  emit_signal "$lang" "installed=true"
  [ -f "$status_dir/quickstart.ok" ] && emit_signal "$lang" "quickstartOk=true"
  if curl -fsS "http://localhost:${app_port_host}/healthz" >/dev/null 2>&1; then
    emit_signal "$lang" "appBoot=true"
  else
    fail_lang "$lang" boot "앱 healthz 미응답(부팅 실패)"
    docker rm -f "$app_container" >/dev/null 2>&1 || true
    return
  fi

  # conformance/security — harness/verify.sh와 동일한 러너(node:20-alpine + conformance.mjs/probe.mjs)를
  # install-net에서 재사용한다. BASE는 컨테이너명(도커 DNS 별칭)으로 지정.
  log "[$lang] conformance"
  docker run --rm --network install-net -v "$(hostpath "$harness_dir/conformance"):/c" -v "$(hostpath "$PWD/report/signals"):/out" \
    -e "BASE=http://${app_container}:8090" -e KC_URL=http://keycloak:8080 -e "LANG=$lang" \
    node:20-alpine node /c/conformance.mjs || true

  log "[$lang] security"
  docker run --rm --network install-net -v "$(hostpath "$harness_dir/security"):/s" -v "$(hostpath "$PWD/report/signals"):/out" \
    -e "BASE=http://${app_container}:8090" -e KC_URL=http://keycloak:8080 -e "LANG=$lang" \
    node:20-alpine node /s/probe.mjs || true

  # conformance.mjs/probe.mjs가 report/signals/python.{conformance,security}.json에 쓴 원본 신호를
  # install.json의 conformance/security 키로 반영(lib.sh 공유 헬퍼).
  emit_conformance_security "$lang"

  docker rm -f "$app_container" >/dev/null 2>&1 || true
  log "[$lang] 완료"
}
run_lang_java() {
  local lang="java"
  local app_container="install-app-java"
  local app_port_host="18094"
  local harness_dir
  harness_dir="$(cd .. && pwd)"   # harness/ (conformance·security 스크립트 위치)

  log "[$lang] mvn-repo(레지스트리, nginx 정적 .m2) 기동"
  if ! docker compose -f compose.install.yml up -d mvn-repo; then
    fail_lang "$lang" registry "mvn-repo 기동(docker compose up) 실패"
    return
  fi
  # autoindex on 덕에 publish 이전(빈 staging-m2)에도 루트 "/"가 200을 낸다 — 헬스체크가 콘텐츠 유무와
  # 무관하게 즉시 통과한다(registries/java-nginx.conf 주석 참고).
  if ! wait_healthy "http://localhost:18080/" 60; then
    fail_lang "$lang" registry "mvn-repo가 제한시간 내 healthy 상태가 되지 않았다"
    return
  fi

  log "[$lang] publish (publish/java.sh)"
  if ! ./publish/java.sh; then
    fail_lang "$lang" publish "publish/java.sh 실패(위 로그 참고)"
    return
  fi
  emit_signal "$lang" "artifactBuilt=true" "published=true"

  # consume 이미지는 파일만 담는다(빌드타임 네트워크 의존 없음 — BuildKit이 build-time custom --network을
  # 지원하지 않으므로). install(mvn-repo 저장소 해석)/quickstart/boot는 런타임 엔트리포인트(java-run.sh)가
  # install-net에서 수행.
  log "[$lang] consume 이미지 빌드(빌드타임 네트워크 없음)"
  if ! docker build -f "$(hostpath "$PWD/consume/java.Dockerfile")" -t install-consume-java "$(hostpath "$harness_dir/..")"; then
    fail_lang "$lang" install "consume/java.Dockerfile 빌드 실패"
    return
  fi

  log "[$lang] 앱 컨테이너 기동(install→quickstart→boot @ install-net)"
  local status_dir="$PWD/report/status/$lang"
  rm -rf "$status_dir"; mkdir -p "$status_dir"
  docker rm -f "$app_container" >/dev/null 2>&1 || true
  if ! docker run -d --name "$app_container" --network install-net \
      -v "$(hostpath "$status_dir"):/status" \
      -e KC_SERVER_URL=http://keycloak:8080 -e KC_REALM=it-realm \
      -e KC_CLIENT_ID=it-client -e KC_CLIENT_SECRET=it-secret -e APP_PORT=8090 \
      -p "${app_port_host}:8090" install-consume-java >/dev/null; then
    fail_lang "$lang" install "앱 컨테이너 기동(docker run) 실패"
    return
  fi

  # 런타임 run.sh가 install(mvn dependency:get)→quickstart(mvn exec:java)→boot(mvn spring-boot:run) 수행:
  # install/quickstart는 /status 마커로, boot는 healthz로 판정. mvn 콜드스타트(전이 의존성 다운로드가
  # node의 npm install보다 훨씬 무거움 — spring-boot-starter-web 트리 전체를 이 컨테이너의 빈 .m2에서
  # 매번 새로 받는다, 실측 약 2~3분)를 반영해 node(180s)보다 넉넉한 타임아웃을 둔다.
  wait_healthy "http://localhost:${app_port_host}/healthz" 300 || true
  if [ ! -f "$status_dir/installed.ok" ]; then
    fail_lang "$lang" install "설치 마커 부재 — 저장소 해석(mvn dependency:get) 실패"
    docker logs "$app_container" 2>&1 | tail -n 80 >&2 || true
    docker rm -f "$app_container" >/dev/null 2>&1 || true
    return
  fi
  emit_signal "$lang" "installed=true"
  [ -f "$status_dir/quickstart.ok" ] && emit_signal "$lang" "quickstartOk=true"
  if curl -fsS "http://localhost:${app_port_host}/healthz" >/dev/null 2>&1; then
    emit_signal "$lang" "appBoot=true"
  else
    fail_lang "$lang" boot "앱 healthz 미응답(부팅 실패)"
    docker rm -f "$app_container" >/dev/null 2>&1 || true
    return
  fi

  # conformance/security — harness/verify.sh와 동일한 러너(node:20-alpine + conformance.mjs/probe.mjs)를
  # install-net에서 재사용한다. BASE는 컨테이너명(도커 DNS 별칭)으로 지정.
  log "[$lang] conformance"
  docker run --rm --network install-net -v "$(hostpath "$harness_dir/conformance"):/c" -v "$(hostpath "$PWD/report/signals"):/out" \
    -e "BASE=http://${app_container}:8090" -e KC_URL=http://keycloak:8080 -e "LANG=$lang" \
    node:20-alpine node /c/conformance.mjs || true

  log "[$lang] security"
  docker run --rm --network install-net -v "$(hostpath "$harness_dir/security"):/s" -v "$(hostpath "$PWD/report/signals"):/out" \
    -e "BASE=http://${app_container}:8090" -e KC_URL=http://keycloak:8080 -e "LANG=$lang" \
    node:20-alpine node /s/probe.mjs || true

  emit_conformance_security "$lang"

  docker rm -f "$app_container" >/dev/null 2>&1 || true
  log "[$lang] 완료"
}
run_lang_php() {
  local lang="php"
  local app_container="install-app-php"
  local app_port_host="18096"
  local registry_port_host="18099"
  local harness_dir
  harness_dir="$(cd .. && pwd)"   # harness/ (conformance·security 스크립트 위치)

  # A. Publish — subtree-split(php/ → 격리 git repo, vendor/.git 제외)→v0.1.0 태그→composer/satis:latest로
  # output/(정적 packages.json+p2+dist zip)을 빌드한다. 순수 로컬 파일 작업이라 install-net 불요.
  # ⚠️ satis-web(nginx)은 정적 파일 서버라 verdaccio(빈 상태로 먼저 기동 가능한 실서버)와 달리 콘텐츠가
  # 있어야 헬스체크가 의미 있다 — 그래서 publish가 registry 기동보다 먼저다(node와 순서가 반대).
  log "[$lang] publish (publish/php.sh — subtree-split→satis build, install-net 불요)"
  if ! ./publish/php.sh; then
    fail_lang "$lang" publish "publish/php.sh 실패(위 로그 참고)"
    return
  fi
  emit_signal "$lang" "artifactBuilt=true"

  log "[$lang] satis-web(레지스트리) 기동 — publish가 채운 output/를 정적 서빙"
  if ! docker compose -f compose.install.yml up -d satis-web; then
    fail_lang "$lang" registry "satis-web 기동(docker compose up) 실패"
    return
  fi
  if ! wait_healthy "http://localhost:${registry_port_host}/packages.json" 60; then
    fail_lang "$lang" registry "satis-web이 제한시간 내 healthy 상태가 되지 않았다"
    return
  fi
  emit_signal "$lang" "published=true"

  # B. Install — consume 이미지는 파일만 담는다(빌드타임 네트워크 의존 없음 — apk add는 Alpine 기본
  # 브리지만 필요, install-net과 무관). install(composer require)/quickstart/boot는 런타임 엔트리포인트
  # (php-run.sh)가 install-net에서 수행(node 참조 구현과 동형).
  log "[$lang] consume 이미지 빌드(빌드타임 install-net 없음)"
  if ! docker build -f "$(hostpath "$PWD/consume/php.Dockerfile")" -t install-consume-php "$(hostpath "$harness_dir/..")"; then
    fail_lang "$lang" install "consume/php.Dockerfile 빌드 실패"
    return
  fi

  log "[$lang] 앱 컨테이너 기동(install→quickstart→boot @ install-net)"
  local status_dir="$PWD/report/status/$lang"
  rm -rf "$status_dir"; mkdir -p "$status_dir"
  docker rm -f "$app_container" >/dev/null 2>&1 || true
  if ! docker run -d --name "$app_container" --network install-net \
      -v "$(hostpath "$status_dir"):/status" \
      -e REGISTRY_URL=http://satis-web \
      -e KC_SERVER_URL=http://keycloak:8080 -e KC_REALM=it-realm \
      -e KC_CLIENT_ID=it-client -e KC_CLIENT_SECRET=it-secret -e APP_PORT=8090 \
      -p "${app_port_host}:8090" install-consume-php >/dev/null; then
    fail_lang "$lang" install "앱 컨테이너 기동(docker run) 실패"
    return
  fi

  # 런타임 run.sh가 install→quickstart→boot 수행: install/quickstart는 /status 마커로, boot는 healthz로 판정.
  wait_healthy "http://localhost:${app_port_host}/healthz" 180 || true
  if [ ! -f "$status_dir/installed.ok" ]; then
    fail_lang "$lang" install "설치 마커 부재 — 레지스트리 설치(composer require) 실패"
    docker logs "$app_container" 2>&1 | tail -n 80 >&2 || true
    docker rm -f "$app_container" >/dev/null 2>&1 || true
    return
  fi
  emit_signal "$lang" "installed=true"
  # ⚠️ quickstart는 php/examples/quickstart.php를 무변경 재사용한다 — admin API로 'demo-user'를 생성하는
  # 비-idempotent 호출이 있어(exists면 409), 동일 Keycloak을 재사용하는 반복 실행에서는 이 스텝만
  # 논-fatal로 실패할 수 있다(quickstartOk=false여도 install/appBoot/conformance/security는 영향 없음 —
  # 아래처럼 지속 진행). 최초 1회 실행에서는 정상 통과(실측 확인됨).
  [ -f "$status_dir/quickstart.ok" ] && emit_signal "$lang" "quickstartOk=true"
  if curl -fsS "http://localhost:${app_port_host}/healthz" >/dev/null 2>&1; then
    emit_signal "$lang" "appBoot=true"
  else
    fail_lang "$lang" boot "앱 healthz 미응답(부팅 실패)"
    docker rm -f "$app_container" >/dev/null 2>&1 || true
    return
  fi

  # C. Operate — harness/verify.sh와 동일한 conformance.mjs/probe.mjs를 설치된-패키지 앱 컨테이너에 대해
  # install-net에서 재실행한다(BASE는 컨테이너명으로 지정 — 도커 DNS 별칭).
  log "[$lang] conformance"
  docker run --rm --network install-net -v "$(hostpath "$harness_dir/conformance"):/c" -v "$(hostpath "$PWD/report/signals"):/out" \
    -e "BASE=http://${app_container}:8090" -e KC_URL=http://keycloak:8080 -e "LANG=$lang" \
    node:20-alpine node /c/conformance.mjs || true

  log "[$lang] security"
  docker run --rm --network install-net -v "$(hostpath "$harness_dir/security"):/s" -v "$(hostpath "$PWD/report/signals"):/out" \
    -e "BASE=http://${app_container}:8090" -e KC_URL=http://keycloak:8080 -e "LANG=$lang" \
    node:20-alpine node /s/probe.mjs || true

  # D. Report — conformance.mjs/probe.mjs가 report/signals/php.{conformance,security}.json에 쓴 원본 신호를
  # install.json의 conformance/security 키로 반영(lib.sh 공유 헬퍼).
  emit_conformance_security "$lang"

  docker rm -f "$app_container" >/dev/null 2>&1 || true
  log "[$lang] 완료"
}
# run_lang_rust — rust 구현(node 참조 구조를 복제, go와 동형으로 "레지스트리=디렉터리 볼륨"이라
# compose.install.yml에 rust 전용 서비스가 없다 — publish/rust.sh가 산출한 cargo-local-registry
# 디렉터리를 run_lang_rust()가 docker run -v로 직접 마운트한다).
#
#   A. Publish  publish/rust.sh(→publish/rust.Dockerfile)가 rust:1.88-alpine 빌더로 keycloak-sdk를
#               cargo package(cargo publish와 동일 tarball)하고, harness/apps/rust(axum 등 앱 전용
#               의존성 포함)를 클로저 매니페스트 삼아 cargo local-registry sync로 트랜지티브 의존성을
#               미러링 → keycloak-sdk 자신(path 소스라 sync 미대상)을 .crate 복사 + index/ke/yc/
#               keycloak-sdk에 v2 JSON 한 줄로 수동 주입 → 산출물을 호스트 publish/out/
#               rust-local-registry/로 추출.
#   B. Install  consume/rust.Dockerfile이 rust/(SDK 소스) 접근 없이 파일만 담고, 런타임(rust-run.sh)에
#               로컬 레지스트리 디렉터리(볼륨 마운트)를 .cargo/config.toml 소스 치환으로 오프라인
#               `cargo build --offline`(quickstart+app) → quickstart 스모크 → harness/apps/rust(axum,
#               무변경) 기동. rust는 8언어 중 유일하게 consume 단계에서도 실제 컴파일이 일어난다
#               (다른 언어는 사전 컴파일된 아티팩트를 받기만 함) — wait_healthy 타임아웃을 node(180s)
#               보다 훨씬 길게 잡는다.
#   C. Operate  기존 conformance.mjs/security probe.mjs를 설치된-패키지 앱 컨테이너에 대해 재실행.
#   D. Report   결과를 report/signals/rust.install.json(emit_signal)에 기록.
run_lang_rust() {
  local lang="rust"
  local app_container="install-app-rust"
  local app_port_host="18097"
  local harness_dir
  harness_dir="$(cd .. && pwd)"   # harness/ (conformance·security 스크립트 위치)

  log "[$lang] publish (publish/rust.sh — cargo-local-registry 디렉터리 빌드, 상시 구동 서비스 없음)"
  if ! ./publish/rust.sh; then
    fail_lang "$lang" publish "publish/rust.sh 실패(위 로그 참고)"
    return
  fi
  emit_signal "$lang" "artifactBuilt=true" "published=true"

  local registry_dir="$PWD/publish/out/rust-local-registry"
  if [ ! -d "$registry_dir" ]; then
    fail_lang "$lang" publish "로컬 레지스트리 디렉터리 부재: $registry_dir"
    return
  fi

  # consume 이미지는 파일만 담는다(빌드타임 네트워크 의존 없음). install(cargo build --offline)·
  # quickstart·boot는 런타임 엔트리포인트(rust-run.sh)가 수행한다 — cargo 자체는 오프라인(로컬
  # 레지스트리 볼륨만 읽음)이지만 quickstart 스모크·app boot는 실 Keycloak 접근이 필요해 install-net
  # 에서 실행되어야 한다.
  log "[$lang] consume 이미지 빌드(빌드타임 네트워크 없음)"
  if ! docker build -f "$(hostpath "$PWD/consume/rust.Dockerfile")" -t install-consume-rust "$(hostpath "$harness_dir/..")"; then
    fail_lang "$lang" install "consume/rust.Dockerfile 빌드 실패"
    return
  fi

  log "[$lang] 앱 컨테이너 기동(install[cargo build --offline]→quickstart→boot @ install-net, 로컬 레지스트리는 ro 볼륨)"
  local status_dir="$PWD/report/status/$lang"
  rm -rf "$status_dir"; mkdir -p "$status_dir"
  docker rm -f "$app_container" >/dev/null 2>&1 || true
  if ! docker run -d --name "$app_container" --network install-net \
      -v "$(hostpath "$status_dir"):/status" \
      -v "$(hostpath "$registry_dir"):/opt/local-registry:ro" \
      -e KC_SERVER_URL=http://keycloak:8080 -e KC_REALM=it-realm \
      -e KC_CLIENT_ID=it-client -e KC_CLIENT_SECRET=it-secret -e APP_PORT=8090 \
      -p "${app_port_host}:8090" install-consume-rust >/dev/null; then
    fail_lang "$lang" install "앱 컨테이너 기동(docker run) 실패"
    return
  fi

  # cargo build --offline(quickstart+app, 오프라인이지만 SDK 전체 컴파일이 실제로 일어남)이 15~25분
  # 안팎씩(둘째 빌드는 CARGO_TARGET_DIR 공유로 대부분 캐시 재사용) 걸릴 수 있어 node(180s)보다 훨씬
  # 긴 타임아웃을 둔다.
  wait_healthy "http://localhost:${app_port_host}/healthz" 2400 || true
  if [ ! -f "$status_dir/installed.ok" ]; then
    fail_lang "$lang" install "설치 마커 부재 — 오프라인 설치(cargo build --offline) 실패"
    docker logs "$app_container" 2>&1 | tail -n 80 >&2 || true
    docker rm -f "$app_container" >/dev/null 2>&1 || true
    return
  fi
  emit_signal "$lang" "installed=true"
  [ -f "$status_dir/quickstart.ok" ] && emit_signal "$lang" "quickstartOk=true"
  if curl -fsS "http://localhost:${app_port_host}/healthz" >/dev/null 2>&1; then
    emit_signal "$lang" "appBoot=true"
  else
    fail_lang "$lang" boot "앱 healthz 미응답(부팅 실패)"
    docker rm -f "$app_container" >/dev/null 2>&1 || true
    return
  fi

  # conformance/security — harness/verify.sh와 동일한 러너(node:20-alpine + conformance.mjs/probe.mjs)를
  # install-net에서 재사용한다(node 참조 구현과 동형 — rust 앱 자체는 실행 중인 axum 프로세스일 뿐,
  # 이 러너는 무관한 node 컨테이너다).
  log "[$lang] conformance"
  docker run --rm --network install-net -v "$(hostpath "$harness_dir/conformance"):/c" -v "$(hostpath "$PWD/report/signals"):/out" \
    -e "BASE=http://${app_container}:8090" -e KC_URL=http://keycloak:8080 -e "LANG=$lang" \
    node:20-alpine node /c/conformance.mjs || true

  log "[$lang] security"
  docker run --rm --network install-net -v "$(hostpath "$harness_dir/security"):/s" -v "$(hostpath "$PWD/report/signals"):/out" \
    -e "BASE=http://${app_container}:8090" -e KC_URL=http://keycloak:8080 -e "LANG=$lang" \
    node:20-alpine node /s/probe.mjs || true

  emit_conformance_security "$lang"

  docker rm -f "$app_container" >/dev/null 2>&1 || true
  log "[$lang] 완료"
}
run_lang_ruby() {
  local lang="ruby"
  local app_container="install-app-ruby"
  local app_port_host="18095"
  local harness_dir
  harness_dir="$(cd .. && pwd)"   # harness/ (conformance·security 스크립트 위치)

  # gemserver(compose)가 마운트하는 호스트 디렉터리를 미리 만들어 둔다 — 존재하지 않는 호스트 경로를
  # 빈 볼륨으로 자동 생성해줄지가 플랫폼(Windows Docker Desktop)마다 불확실하므로 선제 mkdir로 회피.
  mkdir -p "$PWD/publish/ruby-repo/gems"

  log "[$lang] gemserver(레지스트리) 기동"
  if ! docker compose -f compose.install.yml up -d --build gemserver; then
    fail_lang "$lang" registry "gemserver 기동(docker compose up) 실패"
    return
  fi
  if ! wait_healthy "http://localhost:18808/" 120; then
    fail_lang "$lang" registry "gemserver가 제한시간 내 healthy 상태가 되지 않았다"
    return
  fi

  log "[$lang] publish (publish/ruby.sh)"
  if ! ./publish/ruby.sh; then
    fail_lang "$lang" publish "publish/ruby.sh 실패(위 로그 참고)"
    return
  fi
  emit_signal "$lang" "artifactBuilt=true" "published=true"

  # consume 이미지는 파일만 담는다(빌드타임 네트워크 의존 없음). install/quickstart/boot는 런타임
  # 엔트리포인트(ruby-run.sh)가 install-net에서 수행.
  log "[$lang] consume 이미지 빌드(빌드타임 네트워크 없음)"
  if ! docker build -f "$(hostpath "$PWD/consume/ruby.Dockerfile")" -t install-consume-ruby "$(hostpath "$harness_dir/..")"; then
    fail_lang "$lang" install "consume/ruby.Dockerfile 빌드 실패"
    return
  fi

  log "[$lang] 앱 컨테이너 기동(install→quickstart→boot @ install-net)"
  local status_dir="$PWD/report/status/$lang"
  rm -rf "$status_dir"; mkdir -p "$status_dir"
  docker rm -f "$app_container" >/dev/null 2>&1 || true
  if ! docker run -d --name "$app_container" --network install-net \
      -v "$(hostpath "$status_dir"):/status" \
      -e REGISTRY_URL=http://gemserver:8808 \
      -e KC_SERVER_URL=http://keycloak:8080 -e KC_REALM=it-realm \
      -e KC_CLIENT_ID=it-client -e KC_CLIENT_SECRET=it-secret -e APP_PORT=8090 \
      -p "${app_port_host}:8090" install-consume-ruby >/dev/null; then
    fail_lang "$lang" install "앱 컨테이너 기동(docker run) 실패"
    return
  fi

  # 런타임 run.sh가 install→quickstart→boot 수행: install/quickstart는 /status 마커로, boot는 healthz로 판정.
  # ⚠️ gem install은 네이티브 확장(activesupport/rack-oauth2 전이의존 bigdecimal·json·bindata 등) 컴파일이
  # 필요해 npm install(순수 JS)보다 느리다 — 타임아웃을 node(180s)보다 넉넉히 잡는다.
  wait_healthy "http://localhost:${app_port_host}/healthz" 240 || true
  if [ ! -f "$status_dir/installed.ok" ]; then
    fail_lang "$lang" install "설치 마커 부재 — 레지스트리 설치(gem install) 실패"
    docker logs "$app_container" 2>&1 | tail -n 80 >&2 || true
    docker rm -f "$app_container" >/dev/null 2>&1 || true
    return
  fi
  emit_signal "$lang" "installed=true"
  [ -f "$status_dir/quickstart.ok" ] && emit_signal "$lang" "quickstartOk=true"
  if curl -fsS "http://localhost:${app_port_host}/healthz" >/dev/null 2>&1; then
    emit_signal "$lang" "appBoot=true"
  else
    fail_lang "$lang" boot "앱 healthz 미응답(부팅 실패)"
    docker rm -f "$app_container" >/dev/null 2>&1 || true
    return
  fi

  # conformance/security — harness/verify.sh와 동일한 러너(node:20-alpine + conformance.mjs/probe.mjs)를
  # install-net에서 재사용한다(SDK 구현 언어와 무관 — HTTP 계약만 검증). BASE는 컨테이너명(도커 DNS 별칭).
  log "[$lang] conformance"
  docker run --rm --network install-net -v "$(hostpath "$harness_dir/conformance"):/c" -v "$(hostpath "$PWD/report/signals"):/out" \
    -e "BASE=http://${app_container}:8090" -e KC_URL=http://keycloak:8080 -e "LANG=$lang" \
    node:20-alpine node /c/conformance.mjs || true

  log "[$lang] security"
  docker run --rm --network install-net -v "$(hostpath "$harness_dir/security"):/s" -v "$(hostpath "$PWD/report/signals"):/out" \
    -e "BASE=http://${app_container}:8090" -e KC_URL=http://keycloak:8080 -e "LANG=$lang" \
    node:20-alpine node /s/probe.mjs || true

  # conformance.mjs/probe.mjs가 report/signals/ruby.{conformance,security}.json에 쓴 원본 신호를
  # install.json의 conformance/security 키로 반영(lib.sh 공유 헬퍼).
  emit_conformance_security "$lang"

  docker rm -f "$app_container" >/dev/null 2>&1 || true
  log "[$lang] 완료"
}

# run_lang <lang> — case 디스패치. 알려진 8언어는 각 run_lang_<lang>으로, 그 외(오탈자·미래 언어)는
# 크래시 없이 not_implemented로 수렴한다 — "언어 본문 없음"이 루프를 끊지 않고 신호만 남기고 계속된다.
run_lang() {
  local lang="$1"
  case "$lang" in
    go) run_lang_go ;;
    dotnet) run_lang_dotnet ;;
    node) run_lang_node ;;
    python) run_lang_python ;;
    java) run_lang_java ;;
    php) run_lang_php ;;
    rust) run_lang_rust ;;
    ruby) run_lang_ruby ;;
    *)
      log "[$lang] 알 수 없는 언어 — not implemented로 기록 후 계속"
      not_implemented "$lang"
      ;;
  esac
}

# Keycloak 기동 — SKIP_KEYCLOAK=1이면 건너뛴다(emit_signal→report 경로만 빠르게 스모크할 때 사용;
# 실제 언어 파이프라인은 Keycloak이 필요하므로 기본은 기동한다).
if [ "${SKIP_KEYCLOAK:-0}" != "1" ]; then
  log "== Keycloak 기동 =="
  docker compose -f compose.install.yml up -d keycloak
  if ! wait_healthy "http://localhost:9000/health/ready" 240; then
    log "Keycloak이 제한시간 내 healthy 상태가 되지 않았다 — 언어별 단계에서 개별 실패로 드러날 수 있다(계속 진행)"
  fi
else
  log "== SKIP_KEYCLOAK=1 — Keycloak 기동 생략 =="
fi

for L in "${LANGS[@]}"; do
  log "== [$L] 설치·동작 검증 시작 =="
  # 언어별 신호를 fresh로 리셋 — 이전(실패)실행의 stale error/필드가 누적 신호에 남지 않도록.
  printf '{"lang":"%s"}\n' "$L" > "report/signals/${L}.install.json"
  run_lang "$L"
done

log "== 설치 매트릭스 생성 =="
node report/install-matrix.mjs || true
log "== 완료 — report/INSTALL-MATRIX.md =="
exit 0
