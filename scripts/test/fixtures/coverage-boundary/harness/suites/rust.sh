#!/usr/bin/env bash
# 픽스처 — 안쪽 셸의 큰따옴표 안에서는 `\\` 가 `\` 로, `\$` 가 `$` 로 벗겨진다.
RAW=$(docker run --rm rust sh -c '
  cargo test
  cargo llvm-cov --ignore-filename-regex "(^|[\\\\/])(auth|admin|client)\.rs\$" --summary-only
' 2>&1)
echo "$RAW"
