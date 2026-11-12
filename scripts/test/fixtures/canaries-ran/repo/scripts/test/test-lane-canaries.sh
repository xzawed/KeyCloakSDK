#!/usr/bin/env sh
# 픽스처 — 레인 카나리아 표(검사기가 표 함수만 떼어 실행한다). 실제 표와 같은 함수 이름 · 같은 행 모양이다.
lc_dump_canary() {
  case "$1" in
    java) printf '%s\n' 'java/core/src/test/java/io/x/TokenTest.java|void reachableObjectsDoNotRenderSecrets(' ;;
  esac
}
lc_bearer_canary() {
  case "$1" in
    java) printf '%s\n' 'java/core/src/test/java/io/x/TokenTest.java|void bearerCanonicalTable(' ;;
  esac
}
