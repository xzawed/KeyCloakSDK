#!/usr/bin/env bash
# 하네스 Docker 빌드 재시도 — 빌드하는 하네스 스크립트가 전부 source 한다(직접 실행하지 않는다).
#
# ⚠️ **실측이 이 헬퍼를 만들었다**(등록부 harness-nightly-upstream-transients). 야간 harness 가 Docker 빌드 안에서 상류
# fetch 가 일시로 실패해 빨개지고, 코드가 그대로인 채 다음 밤 저절로 닫혔다 — php 앱 이미지의 composer `HTTP/2 504`
# (run 42441515425, 2026-11-08), java · kotlin 앱 이미지의 Maven Central 일시 미해석(run 44979301872, 2026-11-22 —
# 아티팩트는 있었다). 빌드를 다시 돌리면 지나가는 실패가 사람을 깨우지 않게, 빌드만 몇 번 더 시도한다.
#
# build_with_retry <label> <retries-file> <command...>
#   command 를 최대 3 번 돌리고, 시도 사이에 ${HARNESS_BUILD_RETRY_DELAY:-60} 초 잔다. **마지막 시도의 종료코드를
#   그대로** 돌려준다(성공이면 0) — 호출 자리의 기존 실패 처리가 세 번 실패를 그대로 받는다.
#   재시도할 실패마다 GitHub Actions 경고 주석 하나(stdout)와 retries-file 한 줄(UTC 시각 · label · 시도 · 종료코드)을
#   남긴다 — 그 파일을 업로드되는 신호 디렉터리에 두면 재시도가 아티팩트에 보인다. 첫 시도에 성공하면 아무것도 쓰지 않는다.
#   세 번째 실패에는 포기 표지(제목 `harness build retry exhausted` · 끝말 `— giving up`) 하나만 stdout 에 찍는다(retries-file 엔 안 쓴다).
#   두 주석의 본문은 꼬리표로 시작한다 — `[harness-build-retry]` · `[harness-build-retry-exhausted]`(판정기가 그것을 본다).
#   label 은 빌드하는 이미지 · 서비스 이름이다(`install-consume-go` · `app-$L`).
#
# ⚠️ **빌드만 감싼다 — 기동(`up`)은 감싸지 않는다.** `docker compose … up -d --build X` 자리는
# `build_with_retry … docker compose … build X` 와 `--build` 없는 `up -d X` 로 갈랐다. 기동 실패는 상류의 일시 장애가
# 아니라 앱 · 설정의 신호이고, 다시 돌리면 그것을 가린다.
# ⚠️ **하네스 셸 스크립트의 빌드는 전부 이것을 거친다** — 헬퍼 밖 빌드(`docker build` · `docker compose … build` ·
# `… --build`)는 `scripts/test/test-harness-build-retry.sh` 가 정적으로 잡고, 자리마다 행동(3 회 · 실패 처리 보존)을 잰다.
build_with_retry() {
  local label="$1" retries_file="$2" attempt=1 rc
  shift 2
  while :; do
    rc=0
    "$@" || rc=$?
    [ "$rc" -eq 0 ] && return 0
    if [ "$attempt" -ge 3 ]; then
      # 포기 표지 — scripts/harness-upstream-signature.mjs 가 이것으로 「재시도로 회복된 거절」과 「끝내 받지 못한 거절」을 가른다.
      # 판정은 **본문의 꼬리표**(`[harness-build-retry-exhausted]` · 재시도는 `[harness-build-retry]`)에 건다 — 러너는 로그에
      # `##[warning]<글>` 만 남겨 제목(title=)이 안 보일 수 있다. `|| true` — stdout 오류가 마지막 시도의 종료코드를 바꾸지 않게.
      printf '::warning title=harness build retry exhausted::[harness-build-retry-exhausted] %s attempt %s failed (exit %s) — giving up\n' "$label" "$attempt" "$rc" || true
      return "$rc"
    fi
    printf '::warning title=harness build retry::[harness-build-retry] %s attempt %s failed (exit %s) — retrying\n' "$label" "$attempt" "$rc" || true
    # 기록 · 지연이 실패해도 재시도는 계속한다 — 호출자가 `set -e` 여도(run.sh) 여기서 끊기지 않게.
    { mkdir -p "$(dirname "$retries_file")" \
      && printf '%s %s attempt %s failed (exit %s) — retrying\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$label" "$attempt" "$rc" >> "$retries_file"; } || true
    sleep "${HARNESS_BUILD_RETRY_DELAY:-60}" || true
    attempt=$((attempt + 1))
  done
}
