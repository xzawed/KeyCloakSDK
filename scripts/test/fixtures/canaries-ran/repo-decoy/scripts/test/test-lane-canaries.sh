#!/usr/bin/env sh
# 픽스처 — 자리표시 제목의 꼴에 맞는 다른 시험 제목이 같은 파일에 있다(#1033 레그 N2 · N3) → 판정 불가.
lc_dump_canary() {
  case "$1" in
    none) ;;
  esac
}
lc_bearer_canary() {
  case "$1" in
    node) printf '%s\n' "node/test/unit/d.test.ts|it.each(ROWS)('%s — 생성 때 확보한다'" ;;
  esac
}
