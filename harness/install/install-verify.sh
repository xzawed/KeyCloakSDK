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
run_lang_node()   { not_implemented node; }   # TODO(T1.1, 참조구현): publish/node.sh(Verdaccio) → consume/node.Dockerfile
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
