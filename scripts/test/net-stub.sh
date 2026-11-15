#!/usr/bin/env sh
# net-stub.mjs 를 사전 적재하는 NODE_OPTIONS 조각 — 자가테스트가 가드를 CI 와 같은 argv 로 돌릴 때 쓴다(머리 주석은 그 파일).
# 부르는 쪽이 DIR(scripts/test)을 먼저 정한다. 파일 URL 은 윈도(`C:/…`)와 리눅스(`/…`)를 둘 다 받고, 공백은 %20 으로 적는다 —
# NODE_OPTIONS 는 공백에서 값을 가른다.
_ns_path="$(cd "$DIR" && { pwd -W 2>/dev/null || pwd; })/net-stub.mjs"
case "$_ns_path" in
  /*) NET_STUB_IMPORT="--import=file://$(printf '%s' "$_ns_path" | sed 's/ /%20/g')" ;;
  *) NET_STUB_IMPORT="--import=file:///$(printf '%s' "$_ns_path" | sed 's/ /%20/g')" ;;
esac
