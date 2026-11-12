#!/usr/bin/env sh
# 픽스처 — 서브테스트를 같은 파일의 도우미가 여는 go 시험(#1033 레그 G2).
lc_dump_canary() {
  case "$1" in
    none) ;;
  esac
}
lc_bearer_canary() {
  case "$1" in
    go) printf '%s\n' 'go/h_test.go|func TestViaHelper(' ;;
  esac
}
