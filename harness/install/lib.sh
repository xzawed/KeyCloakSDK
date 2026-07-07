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
wait_healthy() {
  local url="$1" timeout_s="${2:-120}"
  local start now
  start=$(date +%s)
  log "wait_healthy: waiting for $url (timeout ${timeout_s}s)"
  while true; do
    if curl -fsS -o /dev/null "$url" 2>/dev/null; then
      log "wait_healthy: $url is up"
      return 0
    fi
    now=$(date +%s)
    if [ $((now - start)) -ge "$timeout_s" ]; then
      log "wait_healthy: timeout waiting for $url after ${timeout_s}s"
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
