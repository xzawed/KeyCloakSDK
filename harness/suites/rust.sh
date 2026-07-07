#!/usr/bin/env bash
# harness/suites/rust.sh — Rust SDK 자체 단위테스트+커버리지(cargo-llvm-cov)+린트를 rust:alpine
# 컨테이너에서 실행한다(CLAUDE.md Rust 툴체인: `cargo test` + `cargo clippy --all-targets -- -D
# warnings` + `cargo fmt --all --check` + `cargo llvm-cov --ignore-filename-regex '(auth|admin|client)\.rs'`).
# 마지막 줄에 JSON 신호 1줄을 출력한다.
#
# ⚠️ 미실행 검증(untested-here) — node/go 2개 언어로 이 스위트 메커니즘을 검증했고, 이 스크립트는
# CLAUDE.md 커맨드로 작성했으나 실제 컨테이너 실행으로 확인하지 않았다(8언어 전체 실행은 CI 야간/수동
# 범위). cargo-llvm-cov 설치+ring/rsa 등 네이티브 의존성 컴파일이 무거워 첫 실행은 특히 느리다 —
# 설치/컴파일 실패 시 커버리지는 0으로 폴백(단위테스트 수 파싱은 영향 없음).
set -uo pipefail
cd "$(dirname "$0")/.."          # -> harness/
ROOT="$(cd .. && pwd)"           # 리포 루트 (rust/ 는 $ROOT/rust)
export MSYS_NO_PATHCONV=1

if ! command -v docker >/dev/null 2>&1; then
  echo "[rust.sh] docker not found on PATH" >&2
  exit 1
fi

RAW=$(docker run --rm -v "$ROOT/rust:/src-ro:ro" rust:alpine sh -c '
  cp -r /src-ro /src && cd /src
  find . -name "*.rs" -exec sed -i "s/\r$//" {} +
  apk add --no-cache build-base pkgconfig openssl-dev perl musl-dev >/dev/null 2>&1
  cargo fmt --all --check >/tmp/fmt.log 2>&1
  echo "___FMTEXIT=$?"
  cargo clippy --all-targets -- -D warnings >/tmp/clippy.log 2>&1
  echo "___CLIPPYEXIT=$?"
  cargo test 2>&1
  echo "___TESTEXIT=$?"
  rustup component add llvm-tools-preview >/tmp/llvmtools.log 2>&1 \
    && cargo install cargo-llvm-cov --locked >/tmp/llvmcov-install.log 2>&1 \
    && cargo llvm-cov --ignore-filename-regex "(auth|admin|client)\.rs" --summary-only 2>&1
  echo "___COVEXIT=$?"
' 2>&1)
DOCKER_RC=$?

OUT=$(printf '%s' "$RAW" | sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g')

if [ "$DOCKER_RC" -ne 0 ] && [ -z "$OUT" ]; then
  echo "[rust.sh] docker run produced no output (rc=$DOCKER_RC)" >&2
  exit 1
fi

# "test result: ok. 34 passed; 0 failed; ..." — 여러 테스트 바이너리(lib+doctest)에 걸쳐 합산.
UNIT=$(printf '%s\n' "$OUT" | grep -oE '[0-9]+ passed' | grep -oE '[0-9]+' | awk '{s+=$1} END{print s+0}')
# cargo-llvm-cov --summary-only 테이블의 TOTAL 행에서 Line % 추출(실패 시 빈 값 → 0 폴백)
LINE=$(printf '%s\n' "$OUT" | grep -E '^TOTAL' | tail -1 | grep -oE '[0-9]+\.[0-9]+' | sed -n '3p')
FMTEXIT=$(printf '%s\n' "$OUT" | grep -oE '___FMTEXIT=[0-9]+' | tail -1 | cut -d= -f2)
CLIPPYEXIT=$(printf '%s\n' "$OUT" | grep -oE '___CLIPPYEXIT=[0-9]+' | tail -1 | cut -d= -f2)
if [ "${FMTEXIT:-1}" = "0" ] && [ "${CLIPPYEXIT:-1}" = "0" ]; then LINTCLEAN=true; else LINTCLEAN=false; fi

INTEGRATION=0
if [ "${SUITE_INTEGRATION:-0}" = "1" ]; then
  # testcontainers E2E(#[ignore], 실제 Keycloak, Docker-in-Docker) 필요 — best-effort opt-in.
  IRAW=$(docker run --rm -v "$ROOT/rust:/src-ro:ro" -v /var/run/docker.sock:/var/run/docker.sock \
    rust:alpine sh -c '
      cp -r /src-ro /src && cd /src
      apk add --no-cache build-base pkgconfig openssl-dev perl musl-dev docker-cli >/dev/null 2>&1
      cargo test --test integration_test -- --ignored 2>&1
    ' 2>&1 || true)
  IOUT=$(printf '%s' "$IRAW" | sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g')
  INTEGRATION=$(printf '%s\n' "$IOUT" | grep -oE '[0-9]+ passed' | grep -oE '[0-9]+' | awk '{s+=$1} END{print s+0}')
fi

echo "{\"lang\":\"rust\",\"unit\":${UNIT:-0},\"integration\":${INTEGRATION:-0},\"coverageLine\":${LINE:-0},\"coverageBranch\":0,\"lintClean\":${LINTCLEAN},\"ran\":true}"
