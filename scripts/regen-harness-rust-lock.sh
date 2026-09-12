#!/bin/sh
# harness/apps/rust/Cargo.lock 을 재생성한다.
#
# 왜 스크립트인가: 이 락은 `security-audit.yml` 이 `cargo audit -f` 로 **감사하는 대상**이고
# `harness/apps/rust/Dockerfile` 이 `--locked` 로 **빌드하는 대상**이다. 둘이 같아야 감사가
# 의미를 갖는다(실측 사고 2026-09-12: 락이 keycloak-sdk 0.1.0 을 고정한 채 SDK 는 1.0.0 이었고,
# 야간 감사는 1.0 이전 그래프를 6주째 감사하며 초록을 냈다).
#
# ⚠️ 트리 안에서 직접 `cargo generate-lockfile` 을 돌릴 수 없다 — `harness/apps/rust/Cargo.toml` 의
# path 의존은 `/src/rust`(**컨테이너 안** 경로)라 호스트에서 해석되지 않는다. 그래서 임시 사본에서
# path 만 이 저장소의 `rust/` 로 바꿔 생성하고 락만 되가져온다. 락은 path 의존의 **경로를 기록하지
# 않으므로**(이름·버전·의존만) 이렇게 만든 락은 컨테이너에서 생성한 것과 같다.
#
# ⚠️ MSRV 인지 해석을 켠다 — 이 앱은 `rust:<MSRV>-alpine` 에서 `--locked` 로 빌드되므로, MSRV 를
# 넘는 크레이트가 락에 들어가면 컨테이너 빌드가 깨진다. edition 2021 은 resolver v2 라 기본으로는
# MSRV 를 보지 않는다(cargo 1.89 실측) — `incompatible-rust-versions=fallback` 이 그것을 켠다.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

# ⚠️ Windows(MSYS)에서 `pwd` 는 `/d/Source/...` 를 주는데 cargo 는 네이티브 Windows 바이너리라
# 그것을 드라이브 `d` 아래로 읽어 경로를 못 찾는다(실측: os error 3). `cygpath -m` 이 있으면
# 그것으로 변환한다 — Linux/macOS 에는 없으므로 없을 때는 그대로 쓴다.
if command -v cygpath >/dev/null 2>&1; then
  HOSTROOT=$(cygpath -m "$ROOT")
else
  HOSTROOT=$ROOT
fi

APP="$ROOT/harness/apps/rust"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cp "$APP/Cargo.toml" "$TMP/Cargo.toml"
mkdir -p "$TMP/src"
cp -R "$APP/src/." "$TMP/src/"

# ⚠️ `sed -i` 를 쓰지 않는다 — BSD sed(macOS)는 `-i` 다음 인자를 **백업 접미사**로 읽어 거기서
# 죽는다(독립 레그 지목). 리다이렉트 + mv 는 GNU·BSD·MSYS 에서 같게 돈다.
sed "s#path = \"/src/rust\"#path = \"$HOSTROOT/rust\"#" "$TMP/Cargo.toml" > "$TMP/Cargo.toml.new"
mv "$TMP/Cargo.toml.new" "$TMP/Cargo.toml"

( cd "$TMP" && cargo generate-lockfile --config 'resolver.incompatible-rust-versions="fallback"' )

cp "$TMP/Cargo.lock" "$APP/Cargo.lock"
echo "재생성 완료: harness/apps/rust/Cargo.lock"
echo "확인: node scripts/check-versions.mjs"
