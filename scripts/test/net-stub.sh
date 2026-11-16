#!/usr/bin/env sh
# net-stub.mjs 를 사전 적재하는 NODE_OPTIONS 조각 — 자가테스트가 가드를 CI 와 같은 argv 로 돌릴 때 쓴다(머리 주석은 그 파일).
# 부르는 쪽이 DIR(scripts/test)을 먼저 정한다. 파일 URL 은 윈도(`C:/…`)와 리눅스(`/…`)를 둘 다 받고, 공백은 %20 으로 적는다 —
# NODE_OPTIONS 는 공백에서 값을 가른다.
_ns_path="$(cd "$DIR" && { pwd -W 2>/dev/null || pwd; })/net-stub.mjs"
case "$_ns_path" in
  /*) NET_STUB_IMPORT="--import=file://$(printf '%s' "$_ns_path" | sed 's/ /%20/g')" ;;
  *) NET_STUB_IMPORT="--import=file:///$(printf '%s' "$_ns_path" | sed 's/ /%20/g')" ;;
esac

# 시험의 「CI 와 같은 호출」을 워크플로 글자에 묶는다(Grok 레그 — 워크플로에 플래그를 더하면 시험이 모른 채 갈린다).
# ci_call <워크플로> <가드 파일 이름> → 그 가드를 부르는 주석 밖 `run:` 한 줄의 명령. 없거나 둘 이상이면 빈 값.
ci_call() {
  _cc="$(grep -E "^[^#]*node scripts/$2( |\$)" "$1" | sed 's/^[[:space:]]*\(- \)\{0,1\}run:[[:space:]]*//; s/[[:space:]]*$//')"
  [ "$(printf '%s\n' "$_cc" | grep -c .)" = 1 ] && printf '%s' "$_cc"
  return 0
}
# ci_job_wd <워크플로> <가드 파일 이름> → 그 가드를 부르는 잡 안의 working-directory 줄들(없으면 빈 값 — 기본 루트는 저장소 루트다).
ci_job_wd() {
  awk -v g="node scripts/$2" '
    /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { if (hit) exit; wd = "" }
    /^[[:space:]]+working-directory:/ { wd = wd $0 }
    index($0, g) && $0 !~ /^[[:space:]]*#/ { hit = 1 }
    END { if (hit) print wd }' "$1"
}
