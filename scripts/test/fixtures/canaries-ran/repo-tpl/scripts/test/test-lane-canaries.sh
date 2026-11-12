#!/usr/bin/env sh
# 픽스처 — 레인 표의 템플릿 제목 행(`${route}` 는 정의 때 값이 박힌다 — `%s` 처럼 아무 글자).
lc_dump_canary() {
  case "$1" in
    none) ;;
  esac
}
lc_bearer_canary() {
  case "$1" in
    node) printf '%s\n' 'node/test/unit/t.test.ts|it.each(ROWS)(`%s — ${route} 가 보낸다`' ;;
  esac
}
