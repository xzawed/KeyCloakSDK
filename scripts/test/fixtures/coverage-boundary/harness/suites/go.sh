#!/usr/bin/env bash
# 픽스처 — 바깥 작은따옴표 안의 명령은 안쪽 셸이 한 층으로 읽는다.
RAW=$(docker run --rm golang sh -c '
  go test ./... -coverprofile=/tmp/cover.out
  grep -vE "/(auth|admin|admin_users)\.go:" /tmp/cover.out > /tmp/cover.filtered
' 2>&1)
echo "$RAW"
