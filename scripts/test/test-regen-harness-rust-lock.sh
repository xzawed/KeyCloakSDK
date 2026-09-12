#!/usr/bin/env sh
# `regen-harness-rust-lock.sh` 자가테스트 — 락 재생성기가 **실제로 무엇을 하는지** 고정한다.
#
# 왜 필요한가: 이 스크립트가 만드는 락은 `security-audit.yml` 이 감사하고 하네스 Dockerfile 이
# `--locked` 로 빌드하는 대상이다. 즉 **이 스크립트가 틀리면 감사와 빌드가 함께 틀린다.**
# 그런데 진짜 `cargo generate-lockfile` 은 네트워크와 툴체인을 요구해 CI 에서 돌릴 수 없다 —
# 그래서 `cargo` 를 스텁으로 갈아끼우고 **스크립트가 cargo 에게 무엇을 시키는지**를 단언한다.
#
# ⚠️ 고정하는 것 셋은 전부 「없으면 조용히 틀리는」 것들이다:
#   (1) MSRV 인지 해석 플래그 — 없으면 MSRV 를 넘는 크레이트가 락에 들어가 컨테이너 빌드가 깨진다.
#   (2) path 의존 재기입 — `/src/rust` 는 컨테이너 안 경로라 호스트에서 해석되지 않는다.
#   (3) 산출물이 `harness/apps/rust/Cargo.lock` 에 실제로 놓이는가.
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
SCRIPT="$DIR/../regen-harness-rust-lock.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 최소 트리 — 스크립트는 자기 위치에서 ROOT 를 얻으므로 사본을 그 자리에 둔다.
mkdir -p "$TMP/scripts" "$TMP/rust" "$TMP/harness/apps/rust/src" "$TMP/bin"
cp "$SCRIPT" "$TMP/scripts/regen-harness-rust-lock.sh"
chmod +x "$TMP/scripts/regen-harness-rust-lock.sh"
printf '[package]\nname = "keycloak-sdk"\nversion = "1.0.0"\n' > "$TMP/rust/Cargo.toml"
printf 'fn main() {}\n' > "$TMP/harness/apps/rust/src/main.rs"
cat > "$TMP/harness/apps/rust/Cargo.toml" <<'TOML'
[package]
name = "app-rust"
version = "0.1.0"
rust-version = "1.88"

[dependencies]
keycloak-sdk = { path = "/src/rust" }
TOML
printf 'STALE\n' > "$TMP/harness/apps/rust/Cargo.lock"

# cargo 스텁 — 인자와 그때의 Cargo.toml 을 기록하고 락을 하나 놓는다.
cat > "$TMP/bin/cargo" <<'STUB'
#!/bin/sh
echo "$@" > "$STUB_ARGS"
cp Cargo.toml "$STUB_MANIFEST"
printf 'version = 4\n' > Cargo.lock
STUB
chmod +x "$TMP/bin/cargo"

STUB_ARGS="$TMP/args.txt"
STUB_MANIFEST="$TMP/seen-manifest.toml"
export STUB_ARGS STUB_MANIFEST
assert_ok env PATH="$TMP/bin:$PATH" sh "$TMP/scripts/regen-harness-rust-lock.sh"

ARGS="$(cat "$STUB_ARGS")"
assert_contains "$ARGS" "generate-lockfile" "cargo 에게 락 생성을 시켜야 한다"
# (1) MSRV 인지 해석 — 이 플래그가 빠지면 resolver v2 가 MSRV 를 무시하고 최신 크레이트를 고른다.
assert_contains "$ARGS" "incompatible-rust-versions" "MSRV 인지 해석을 켜야 한다(edition 2021 은 기본이 아니다)"

# (2) path 의존이 호스트에서 해석 가능한 경로로 바뀌었는가 — 컨테이너 경로가 남으면 안 된다.
SEEN="$(cat "$STUB_MANIFEST")"
assert_not_contains "$SEEN" 'path = "/src/rust"' "컨테이너 경로가 그대로면 호스트에서 해석되지 않는다"
assert_contains "$SEEN" "rust-version" "재기입이 매니페스트의 나머지를 지우면 안 된다"

# (3) 산출물이 제자리에 놓였는가 — 낡은 락이 실제로 교체돼야 한다.
assert_not_contains "$(cat "$TMP/harness/apps/rust/Cargo.lock")" "STALE" "낡은 락이 교체돼야 한다"
assert_contains "$(cat "$TMP/harness/apps/rust/Cargo.lock")" "version = 4" "생성된 락이 제자리에 놓여야 한다"

# ⚠️ 대조군 — cargo 가 실패하면 스크립트도 실패해야 한다(`set -e`). 조용히 낡은 락을 남기면
# 재생성했다고 믿은 채 감사와 빌드가 계속 갈라진다.
printf '#!/bin/sh\nexit 1\n' > "$TMP/bin/cargo"
chmod +x "$TMP/bin/cargo"
printf 'STALE\n' > "$TMP/harness/apps/rust/Cargo.lock"
assert_fails env PATH="$TMP/bin:$PATH" sh "$TMP/scripts/regen-harness-rust-lock.sh"
assert_contains "$(cat "$TMP/harness/apps/rust/Cargo.lock")" "STALE" "실패했으면 락을 건드리지 않아야 한다"

assert_report
