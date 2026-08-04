#!/usr/bin/env bash
# 설치·동작 검증 하네스 공유 셸 헬퍼. install-verify.sh가 source한다 — 직접 실행하지 않는다.
# harness/verify.sh의 셸 관용(로그·신호·헬스체크 폴링)을 재구현한 것(소싱 아님).
#
# 제공 함수:
#   log(msg)                          — 타임스탬프 붙여 stderr로 출력.
#   emit_signal(lang, key=val ...)     — report/signals/<lang>.install.json 을 읽어 key=val 쌍을 병합해 다시 쓴다.
#   wait_healthy(url, timeout_s=120)   — curl로 url을 폴링, 200 응답이면 0, 타임아웃이면 1.
#   fail_lang(lang, stage, msg)        — 신호에 installed/appBoot=false + error 기록, 항상 1 반환(호출자는 continue).
#
# 이 파일 자신의 디렉터리를 기준으로 signals 경로를 계산하므로, 호출자의 cwd와 무관하게 동작한다
# (report/install-matrix.mjs가 __dirname 기준으로 report/signals/를 읽는 것과 동일한 이유).
LIB_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SIGNALS_DIR="$LIB_SH_DIR/report/signals"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}

# emit_signal <lang> [key=value ...]
# - 파일: $SIGNALS_DIR/<lang>.install.json (없으면 새로 생성)
# - 병합: 기존 JSON을 읽어(파싱 실패/부재 시 빈 객체로 취급) key=value 쌍을 덮어쓰기 병합 후 다시 씀.
# - 값 타입 추론: "true"/"false" → JSON boolean, 숫자 문자열 → JSON number,
#   그 외는 JSON으로 파싱 시도(예: conformance={"passed":5,"failed":0}) → 실패하면 원문 문자열.
# - jq 없이 node로 병합한다(리포지토리 전역 관용 — score.mjs/install-matrix.mjs도 순수 node).
emit_signal() {
  local lang="$1"; shift
  mkdir -p "$SIGNALS_DIR"
  local relfile="${lang}.install.json"
  # ⚠️ node -e에는 SIGNALS_DIR의 절대경로가 아니라 상대 파일명만 넘긴다: 이 리포지토리(Git Bash/MSYS)에서
  # 호출자가 docker 볼륨 마운트 때문에 MSYS_NO_PATHCONV=1을 켜 두면, MSYS가 절대 유닉스식 경로
  # (/d/...)를 윈도우 경로로 자동변환하지 않아 네이티브 node.exe가 그 문자열을 있는 그대로 받고
  # "드라이브 루트 기준 상대경로"로 오해석해 D:\d\Source\...처럼 드라이브 문자가 중복 삽입된다
  # (실측 확인됨). 상대 파일명은 이 변환 대상이 아니므로 MSYS_NO_PATHCONV 설정과 무관하게 항상 안전하다
  # — 서브셸에서 SIGNALS_DIR로 cd한 뒤 상대경로만 전달해 호출자의 cwd에도 영향을 주지 않는다.
  (
    cd "$SIGNALS_DIR" && node -e '
      const fs = require("node:fs");
      const file = process.argv[1];
      const lang = process.argv[2];
      const pairs = process.argv.slice(3);
      let cur = {};
      try { cur = JSON.parse(fs.readFileSync(file, "utf8")); } catch { cur = {}; }
      cur.lang = lang;
      for (const kv of pairs) {
        const i = kv.indexOf("=");
        if (i === -1) continue;
        const k = kv.slice(0, i);
        const raw = kv.slice(i + 1);
        let v;
        if (raw === "true") v = true;
        else if (raw === "false") v = false;
        else if (raw !== "" && !Number.isNaN(Number(raw))) v = Number(raw);
        else {
          try { v = JSON.parse(raw); } catch { v = raw; }
        }
        cur[k] = v;
      }
      fs.writeFileSync(file, JSON.stringify(cur, null, 2) + "\n");
    ' "$relfile" "$lang" "$@"
  )
}

# wait_healthy <url> [timeout_s=120]
# curl -fsS 로 url을 폴링한다(2xx 이외 응답 또는 연결 실패는 재시도). 준비되면 0, 타임아웃이면 1.
# hostpath <msys-path> — 네이티브 Windows docker에 넘길 '호스트 경로'를 Docker가 받는 형식으로 변환한다.
# install-verify.sh가 컨테이너 경로 보호를 위해 MSYS_NO_PATHCONV=1을 전역 설정하므로 호스트 경로(build
# 컨텍스트·`-v`의 호스트측·`-f`)는 자동 변환되지 않는다 → docker.exe가 `/d/Source/...`를 못 찾는다.
# Git Bash(Windows)에선 cygpath -m으로 `D:/Source/...`(forward-slash, docker 허용)로, Linux CI에선 그대로.
# 컨테이너측 경로(`:/work` 등)는 감싸지 말 것 — 그대로 리터럴이어야 한다.
hostpath() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
}

# wait_healthy <url> [timeout_s] [container]
#
# ⚠️ `container`를 주면 **죽은 컨테이너를 기다리지 않는다**. 이게 없으면 앱이 부팅 1초 만에
# 크래시해도 타임아웃 전체를 소진한다 — rust는 소비자 쪽에서 실제 컴파일을 하느라 타임아웃이
# 2400초라, 컴파일 오류 하나가 **40분의 침묵**이 됐다(2026-08-01 install-all 실측: 빌드 실패
# 17:05:02 → 실패 보고 17:45:02). install-smoke가 릴리스 게이트가 된 뒤로는 그 40분이 매
# 릴리스 시도에 붙는다. 종료 코드와 마지막 로그를 즉시 보여주는 편이 진단에도 낫다.
wait_healthy() {
  local url="$1" timeout_s="${2:-120}" container="${3:-}"
  local start now
  start=$(date +%s)
  log "wait_healthy: waiting for $url (timeout ${timeout_s}s${container:+, watching container $container})"
  while true; do
    # NOTE: `curl -o /dev/null`는 Windows mingw curl에서 /dev/null을 유효 출력 경로로 못 열어
    # HTTP 200에도 exit 23(write error)을 내 wait_healthy가 성공을 감지 못 한다(MSYS_NO_PATHCONV=1로
    # 경로 변환도 안 됨). 셸 리다이렉트 `>/dev/null`은 bash가 처리하므로 Windows/Linux 양쪽 이식.
    if curl -fsS "$url" >/dev/null 2>&1; then
      log "wait_healthy: $url is up"
      return 0
    fi
    # 컨테이너가 이미 죽었으면 더 기다릴 이유가 없다 — 남은 타임아웃을 태우는 대신 즉시 실패한다.
    # `docker inspect`가 실패하는 경우(컨테이너가 아직 안 생겼거나 이름이 사라짐)는 판단을
    # 보류하고 계속 기다린다 — 기동 직전의 경합을 크래시로 오인하면 안 된다.
    if [ -n "$container" ]; then
      local state
      state="$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null || true)"
      if [ "$state" = "false" ]; then
        local code
        code="$(docker inspect -f '{{.State.ExitCode}}' "$container" 2>/dev/null || echo '?')"
        log "wait_healthy: container $container exited (code=$code) — 남은 타임아웃을 기다리지 않고 중단"
        log "wait_healthy: --- $container 마지막 로그 40줄 ---"
        docker logs --tail 40 "$container" 2>&1 | sed "s/^/    /" || true
        return 1
      fi
    fi
    now=$(date +%s)
    if [ $((now - start)) -ge "$timeout_s" ]; then
      log "wait_healthy: timeout waiting for $url after ${timeout_s}s"
      if [ -n "$container" ]; then
        log "wait_healthy: --- $container 마지막 로그 40줄 ---"
        docker logs --tail 40 "$container" 2>&1 | sed "s/^/    /" || true
      fi
      return 1
    fi
    sleep 3
  done
}

# fail_lang <lang> <stage> <msg>
# 언어 파이프라인 중 임의 단계 실패를 신호에 격리 기록한다: installed=false, appBoot=false, error="<stage>: <msg>".
# 항상 1을 반환하므로 호출자는 `run_lang_x || fail_lang ... ; continue` 형태로 다음 언어로 넘어간다.
fail_lang() {
  local lang="$1" stage="$2" msg="$3"
  log "[$lang] FAIL at $stage: $msg"
  emit_signal "$lang" "installed=false" "appBoot=false" "error=${stage}: ${msg}"
  return 1
}

# emit_conformance_security <lang>
# harness/verify.sh와 동일한 conformance.mjs/probe.mjs를 설치된-패키지 앱에 대해 재실행한 뒤(호출자
# 책임 — 이 함수는 실행하지 않는다) 그 결과 파일 $SIGNALS_DIR/<lang>.conformance.json({passed,failed,checks})
# 및 $SIGNALS_DIR/<lang>.security.json({defended,total,probes})을 읽어, install-matrix.mjs가 기대하는
# emit_signal 키(conformance={"passed":..,"failed":..} / security={"defended":..,"total":..})로 반영한다.
# 파일 부재·JSON 파싱 실패 시 0으로 폴백(크래시 방지) — 9개 언어의 run_lang_<lang>이 conformance.mjs/
# probe.mjs를 동일하게 $SIGNALS_DIR/<lang>.{conformance,security}.json에 쓰도록 두면(LANG=<lang> env로
# 자연히 그렇게 된다) 이 헬퍼를 그대로 재사용할 수 있다 — node 참조 구현이 확립한 패턴.
emit_conformance_security() {
  local lang="$1"
  local cjson sjson
  cjson=$(cd "$SIGNALS_DIR" && node -e '
    const fs = require("node:fs");
    try {
      const j = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      console.log(JSON.stringify({ passed: j.passed ?? 0, failed: j.failed ?? 0 }));
    } catch { console.log(JSON.stringify({ passed: 0, failed: 0 })); }
  ' "${lang}.conformance.json" 2>/dev/null)
  [ -z "$cjson" ] && cjson='{"passed":0,"failed":0}'
  sjson=$(cd "$SIGNALS_DIR" && node -e '
    const fs = require("node:fs");
    try {
      const j = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      console.log(JSON.stringify({ defended: j.defended ?? 0, total: j.total ?? 0 }));
    } catch { console.log(JSON.stringify({ defended: 0, total: 0 })); }
  ' "${lang}.security.json" 2>/dev/null)
  [ -z "$sjson" ] && sjson='{"defended":0,"total":0}'
  emit_signal "$lang" "conformance=$cjson" "security=$sjson"
}
