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
run_lang_go()     { not_implemented go; }     # TODO(T2.2): publish/go.sh(file GOPROXY) → consume/go.Dockerfile
run_lang_dotnet() { not_implemented dotnet; } # TODO(T2.3): publish/dotnet.sh(BaGetter) → consume/dotnet.Dockerfile

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

  log "[$lang] consume 이미지 빌드 (quickstart 설치 스모크가 RUN 단계에 내장 — 실패 시 빌드 자체가 실패)"
  if ! docker build --network install-net -f "$PWD/consume/node.Dockerfile" -t install-consume-node "$harness_dir/.."; then
    fail_lang "$lang" install "consume/node.Dockerfile 빌드 실패(설치 또는 quickstart 스모크 실패 가능성)"
    return
  fi
  emit_signal "$lang" "installed=true" "quickstartOk=true"

  log "[$lang] 앱 컨테이너 기동(설치된 패키지 소비)"
  docker rm -f "$app_container" >/dev/null 2>&1 || true
  if ! docker run -d --name "$app_container" --network install-net \
      -e KC_SERVER_URL=http://keycloak:8080 -e KC_REALM=it-realm \
      -e KC_CLIENT_ID=it-client -e KC_CLIENT_SECRET=it-secret -e APP_PORT=8090 \
      -p "${app_port_host}:8090" install-consume-node >/dev/null; then
    fail_lang "$lang" install "앱 컨테이너 기동(docker run) 실패"
    return
  fi
  if ! wait_healthy "http://localhost:${app_port_host}/healthz" 60; then
    fail_lang "$lang" install "앱 healthz 타임아웃"
    docker logs "$app_container" 2>&1 | tail -n 100 >&2 || true
    docker rm -f "$app_container" >/dev/null 2>&1 || true
    return
  fi
  emit_signal "$lang" "appBoot=true"

  # conformance/security — harness/verify.sh와 동일한 러너(node:20-alpine + conformance.mjs/probe.mjs)를
  # install-net에서 재사용한다. install-net은 compose.install.yml에 명시 name(install-net)으로 고정돼
  # 있으므로(verify.sh와 달리) 동적 네트워크명 조회가 필요 없다. BASE는 컨테이너명(도커 DNS 별칭)으로 지정.
  log "[$lang] conformance"
  docker run --rm --network install-net -v "$harness_dir/conformance:/c" -v "$PWD/report/signals:/out" \
    -e "BASE=http://${app_container}:8090" -e KC_URL=http://keycloak:8080 -e "LANG=$lang" \
    node:20-alpine node /c/conformance.mjs || true

  log "[$lang] security"
  docker run --rm --network install-net -v "$harness_dir/security:/s" -v "$PWD/report/signals:/out" \
    -e "BASE=http://${app_container}:8090" -e KC_URL=http://keycloak:8080 -e "LANG=$lang" \
    node:20-alpine node /s/probe.mjs || true

  # conformance.mjs/probe.mjs가 report/signals/node.{conformance,security}.json에 쓴 원본 신호를
  # install.json의 conformance/security 키로 반영(lib.sh 공유 헬퍼 — 8언어 공통 재사용 대상).
  emit_conformance_security "$lang"

  docker rm -f "$app_container" >/dev/null 2>&1 || true
  log "[$lang] 완료"
}

run_lang_python() { not_implemented python; } # TODO(T2.1): publish/python.sh(pypiserver) → consume/python.Dockerfile
run_lang_java()   { not_implemented java; }   # TODO(T2.4): publish/java.sh(정적 .m2 nginx) → consume/java.Dockerfile
run_lang_php()    { not_implemented php; }    # TODO(T2.6): publish/php.sh(Satis) → consume/php.Dockerfile
run_lang_rust()   { not_implemented rust; }   # TODO(T2.7): publish/rust.sh(cargo-local-registry) → consume/rust.Dockerfile
run_lang_ruby()   { not_implemented ruby; }   # TODO(T2.5): publish/ruby.sh(정적 gem repo) → consume/ruby.Dockerfile

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
  run_lang "$L"
done

log "== 설치 매트릭스 생성 =="
node report/install-matrix.mjs || true
log "== 완료 — report/INSTALL-MATRIX.md =="
exit 0
