#!/bin/sh
# 런타임 엔트리포인트(rust 참조 구현) — install-net에서 실행된다(docker run --network install-net).
# 로컬 cargo-local-registry 디렉터리는 docker run -v로 /opt/local-registry에 read-only 마운트되어
# 있다(publish/rust.sh 산출물).
#
# 1) install: .cargo/config.toml 소스 치환 배치 → app Cargo.toml 조립(path=/src/rust →
#    keycloak-sdk="0.1.0" 직접 기입, cargo add #10926 회피) → cargo build --offline(quickstart+app
#    둘 다 — 실제 소비자가 겪는 "설치"와 동형: 네트워크 레지스트리 대신 로컬 디렉터리 소스일 뿐,
#    의존성 해석·다운로드(로컬)·컴파일까지 전부 실제로 일어난다).
# 2) quickstart 스모크: 빌드된 quickstart 바이너리를 실 Keycloak에 대해 실행.
# 3) app boot: harness/apps/rust(axum)를 registry 의존성으로 빌드된 바이너리로 기동.
# 상태는 호스트 마운트 /status의 마커 파일로 회수한다(컨테이너 생존 여부와 무관하게 오케스트레이터가 읽음).
#
# ⚠️ cargo build --offline은 오프라인이어도 SDK 전체(keycloak/openidconnect/jsonwebtoken/reqwest/
# tokio/axum 등, ring·rustls 네이티브 컴파일 포함) 컴파일이 실제로 일어난다 — harness/apps/rust/
# Dockerfile 게차 코멘트와 동일 이유로 15~25분 안팎 걸릴 수 있다(install-verify.sh의
# run_lang_rust()가 node(180s)보다 훨씬 긴 wait_healthy 타임아웃을 쓰는 이유).
set -u
STATUS="${STATUS_DIR:-/status}"
mkdir -p "$STATUS"
rm -f "$STATUS/installed.ok" "$STATUS/quickstart.ok"

echo "[rust-run] 0/3 .cargo/config.toml 배치(source replace → /opt/local-registry)"
mkdir -p /app/.cargo
cp /app/cargo-config.toml.template /app/.cargo/config.toml

echo "[rust-run] 0/3 app Cargo.toml 조립(path=/src/rust → keycloak-sdk=\"0.1.0\")"
sed 's#keycloak-sdk = { path = "/src/rust" }#keycloak-sdk = "0.1.0"#' /app/app/Cargo.toml.orig > /app/app/Cargo.toml
if ! grep -q 'keycloak-sdk = "0.1.0"' /app/app/Cargo.toml; then
  echo "[rust-run] app Cargo.toml 조립 FAILED — sed 치환이 매칭되지 않았다(원본 라인 형식 변경?)"
  cp /app/app/Cargo.toml.orig "$STATUS/install.log" 2>/dev/null || true
  sleep 3600; exit 1
fi

# quickstart·app이 같은 CARGO_TARGET_DIR을 공유하게 해 공통 의존성(keycloak-sdk·keycloak·tokio·
# reqwest 등)을 한 번만 컴파일한다(둘 다 --offline·같은 프로파일(debug)이라 fingerprint가 같으면
# 재사용 — 15~25분 안팎인 컴파일을 두 번 반복하지 않기 위한 최적화, 정확성에는 영향 없음).
export CARGO_TARGET_DIR=/app/target

echo "[rust-run] 1/3 install — cargo build --offline (quickstart)"
if (cd /app/quickstart && cargo build --offline) >/tmp/install-quickstart.log 2>&1; then
  echo "[rust-run] quickstart build OK"
else
  echo "[rust-run] quickstart build FAILED"; cat /tmp/install-quickstart.log
  cp /tmp/install-quickstart.log "$STATUS/install.log" 2>/dev/null || true
  sleep 3600; exit 1   # 컨테이너를 살려둬 진단 가능하게(오케스트레이터는 마커 부재로 실패 판정)
fi

echo "[rust-run] 1/3 install — cargo build --offline (app)"
if (cd /app/app && cargo build --offline) >/tmp/install-app.log 2>&1; then
  : > "$STATUS/installed.ok"
  echo "[rust-run] install OK (quickstart + app)"
else
  echo "[rust-run] app build FAILED"; cat /tmp/install-app.log
  cp /tmp/install-app.log "$STATUS/install.log" 2>/dev/null || true
  sleep 3600; exit 1
fi

echo "[rust-run] 2/3 quickstart 스모크"
if "$CARGO_TARGET_DIR/debug/quickstart" >/tmp/qs.log 2>&1; then
  : > "$STATUS/quickstart.ok"
  echo "[rust-run] quickstart OK"
elif grep -qE 'Conflict|409' /tmp/qs.log; then
  # quickstart(rust/examples/quickstart.rs, 무변경)는 공유 it-realm에 고정 사용자 demo-user를 생성한다 —
  # 다른 언어의 quickstart가 이미 만들어뒀다면 409 Conflict가 정상 응답이다(SDK가 요청을 보내고 충돌을
  # 올바르게 매핑했다는 뜻 — harness-local 판정, SDK 예제 자체는 손대지 않는다).
  : > "$STATUS/quickstart.ok"
  echo "[rust-run] quickstart Conflict(409) — 공유 realm에 demo-user 기존재, 무해한 충돌로 간주해 OK 처리"
else
  echo "[rust-run] quickstart FAILED(비치명 — app boot·conformance는 계속)"; cat /tmp/qs.log
  cp /tmp/qs.log "$STATUS/quickstart.log" 2>/dev/null || true
fi

echo "[rust-run] 3/3 app boot — \$CARGO_TARGET_DIR/debug/app-rust (APP_PORT=${APP_PORT:-8090})"
exec "$CARGO_TARGET_DIR/debug/app-rust"
