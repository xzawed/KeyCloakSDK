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
# 릴리스 버전 — 오케스트레이터(install-verify.sh)가 -e PKG_VER로 주입한다(기본값은 단독 실행용).
PKG_VER="${PKG_VER:-0.1.0}"
# 로컬 cargo-local-registry 마운트 경로 — rust-cargo-config.toml의 [source.local] local-registry와
# 반드시 일치해야 한다(§구조 격리는 이미 그 파일이 담당 — 이 상수는 그게 실제로 발동했는지 아래에서
# 관측하기 위한 값일 뿐, REG처럼 오케스트레이터가 주입하는 것이 아니다: rust엔 상시 레지스트리
# 서비스가 없다).
LOCAL_REG="/opt/local-registry"
mkdir -p "$STATUS"
rm -f "$STATUS/installed.ok" "$STATUS/quickstart.ok"

echo "[rust-run] 0/3 .cargo/config.toml 배치(source replace → /opt/local-registry)"
mkdir -p /app/.cargo
cp /app/cargo-config.toml.template /app/.cargo/config.toml

echo "[rust-run] 0/3 app Cargo.toml 조립(path=/src/rust → keycloak-sdk=\"$PKG_VER\")"
sed "s#keycloak-sdk = { path = \"/src/rust\" }#keycloak-sdk = \"${PKG_VER}\"#" /app/app/Cargo.toml.orig > /app/app/Cargo.toml
if ! grep -q "keycloak-sdk = \"${PKG_VER}\"" /app/app/Cargo.toml; then
  echo "[rust-run] app Cargo.toml 조립 FAILED — sed 치환이 매칭되지 않았다(원본 라인 형식 변경?)"
  cp /app/app/Cargo.toml.orig "$STATUS/install.log" 2>/dev/null || true
  sleep 3600; exit 1
fi

# quickstart Cargo.toml(harness/install/quickstart/rust/Cargo.toml)은 컨테이너에 구워진 파일이라
# 환경변수 보간이 통하지 않는다 — SDK 의존성 줄만 치환한다. `^keycloak-sdk = ` 앵커라 이 크레이트
# 자신의 `version = "…"`(install-quickstart-rust의 버전)은 건드리지 않는다.
echo "[rust-run] 0/3 quickstart Cargo.toml의 keycloak-sdk 버전 → \"$PKG_VER\""
sed -i "s#^keycloak-sdk = \".*\"#keycloak-sdk = \"${PKG_VER}\"#" /app/quickstart/Cargo.toml
if ! grep -q "^keycloak-sdk = \"${PKG_VER}\"" /app/quickstart/Cargo.toml; then
  echo "[rust-run] quickstart Cargo.toml 치환 FAILED — 의존성 표기 형식이 바뀌었나?"
  grep -n 'keycloak-sdk' /app/quickstart/Cargo.toml
  sleep 3600; exit 1
fi

# quickstart·app이 같은 CARGO_TARGET_DIR을 공유하게 해 공통 의존성(keycloak-sdk·keycloak·tokio·
# reqwest 등)을 한 번만 컴파일한다(둘 다 --offline·같은 프로파일(debug)이라 fingerprint가 같으면
# 재사용 — 15~25분 안팎인 컴파일을 두 번 반복하지 않기 위한 최적화, 정확성에는 영향 없음).
export CARGO_TARGET_DIR=/app/target

echo "[rust-run] 1/3 install — cargo build --offline -v (quickstart)"
if (cd /app/quickstart && cargo build --offline -v) >/tmp/install-quickstart.log 2>&1; then
  echo "[rust-run] quickstart build OK — 출처 확인 중"
  # ⚠️ **출처를 기록한다**(이슈 #167). cargo의 소스 치환([source.crates-io] replace-with = "local")은
  # 설계상 **투명**하다 — 실측: `cargo metadata --format-version 1 --offline`의 keycloak-sdk
  # `source` 필드도, 빌드가 만드는 `Cargo.lock`의 `source =` 줄도 로컬로 받았는지와 무관하게 항상
  # `registry+https://github.com/rust-lang/crates.io-index`로 보고한다(로컬 우회가 실제로 일어났다는
  # 신호가 그 필드에는 없다 — 관측 지점으로 못 쓴다, 후보로 시도했다가 기각). 대신 `-v`(verbose)
  # 빌드 로그의 "Unpacking" 줄이 실제 압축해제 **경로**를 낸다(실측: `Unpacking keycloak-sdk
  # v0.1.0-rc.1 (registry \`/opt/local-registry\`)`, `cargo fetch --offline -v`·`cargo build
  # --offline -v` 둘 다 동일 — 이건 메타데이터가 아니라 크레이트 **본문**(.crate 압축해제) 자체의
  # 출처라 §rust 트랩(메타데이터만 로컬이고 본문은 공개에서 받는 경우, ruby 선례)에 걸리지 않는다.
  # 컨테이너마다 CARGO_HOME이 새로 생기므로 이 줄은 이 최초 빌드(quickstart)에서만 나온다 — app
  # 빌드는 같은 CARGO_TARGET_DIR·CARGO_HOME을 공유해 이미 압축해제된 소스를 재사용, 다시 찍지 않는다.
  grep 'Unpacking keycloak-sdk' /tmp/install-quickstart.log > "$STATUS/provenance.txt" 2>/dev/null || true
  echo "[rust-run] SDK 출처: $(cat "$STATUS/provenance.txt" 2>/dev/null)"
else
  echo "[rust-run] quickstart build FAILED"; cat /tmp/install-quickstart.log
  cp /tmp/install-quickstart.log "$STATUS/install.log" 2>/dev/null || true
  sleep 3600; exit 1   # 컨테이너를 살려둬 진단 가능하게(오케스트레이터는 마커 부재로 실패 판정)
fi

echo "[rust-run] 1/3 install — cargo build --offline (app)"
if (cd /app/app && cargo build --offline) >/tmp/install-app.log 2>&1; then
  echo "[rust-run] app build OK"
  # ⚠️ **출처 단언**(이슈 #167) — 기록만으로는 부족하다. 기록은 사람이 읽어야 동작하고 야간
  # 실행의 로그를 매일 읽는 사람은 없다. 판정(`installed.ok`)이 출처에 의존해야 한다.
  # ⚠️ **전부 로컬이라야 한다**(기록된 줄이 하나라도 로컬이 아니면 실패) + 빈 파일도 실패.
  # 여덟 언어가 같은 규칙을 쓴다 — "하나라도 로컬"은 부분 출처·시도 URL 혼입을 통과시킨다.
  # ⚠️ `$LOCAL_REG`가 비면 `grep -v -F ""`가 모든 줄을 걸러내 음성 조건이 **자동 참**이 된다 —
  # 공개 crates.io에서 받아도 통과한다(실측 재현). 현재는 상수 대입이라 도달 불가하지만 스크립트
  # 변이로는 도달하므로 비어있음을 명시 검사한다(2026-08-12 부류 재스캔).
  # ⚠️ rust는 URL 목록이 아니라 **cargo 로그 줄**을 기록한다(`Unpacking keycloak-sdk …(/opt/local-registry/…)`).
  # 그래서 origin 접두 정규화가 성립하지 않고(경로가 문장 가운데 있다) 양성 조건도 기록 단계가
  # 이미 건다(`grep 'Unpacking keycloak-sdk'`로 걸러 넣으므로 파일에 그 줄만 있다). 부분문자열
  # 대조가 여기서는 옳은 도구다 — 다른 언어와 형태가 다른 이유를 적어 둔다.
  # >>> provenance-gate
  if [ -n "$LOCAL_REG" ] && [ -s "$STATUS/provenance.txt" ] && ! grep -v -F "$LOCAL_REG" "$STATUS/provenance.txt" | grep -q .; then
    PROVENANCE_OK=1
  else
    PROVENANCE_OK=0
  fi
  # <<< provenance-gate
  if [ "$PROVENANCE_OK" = 1 ]; then
    : > "$STATUS/installed.ok"
    echo "[rust-run] install OK (quickstart + app, 로컬 레지스트리에서 받았다)"
  else
    echo "[rust-run] install FAILED — SDK를 로컬($LOCAL_REG)이 아닌 곳에서 받았다: $(cat "$STATUS/provenance.txt" 2>/dev/null)"
    cp /tmp/install-app.log "$STATUS/install.log" 2>/dev/null || true
    sleep 3600; exit 1
  fi
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
