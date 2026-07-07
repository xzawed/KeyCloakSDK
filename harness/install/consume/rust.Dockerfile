# 설치 검증용 소비 이미지(rust 참조 구현) — rust/(SDK 소스 트리) 접근 없이, publish/rust.sh가 만든
# 로컬 cargo-local-registry **디렉터리**(볼륨, docker run 시 -v로 주입 — node의 Verdaccio HTTP 서비스와
# 달리 네트워크 서비스가 아니다)에서 `keycloak-sdk = "0.1.0"`을 소스 치환으로 오프라인 설치한다.
# harness/apps/rust/src와 rust/examples/quickstart.rs는 무변경으로 그대로 재사용한다(빌드 컨텍스트 =
# 리포지토리 루트).
#
# ⚠️ 설계: rust는 레지스트리가 디렉터리라 `cargo build --offline` 자체엔 install-net이 필요 없지만,
# node·기타 7언어와 동일한 설계 원칙("이미지는 파일만 담는다")을 유지한다 — install(cargo build)·
# quickstart 스모크·app boot를 전부 **런타임**(엔트리포인트 run.sh)에 수행해 install 단계의 성패·
# 소요시간이 상태 마커(/status)로 오케스트레이터에 보고되게 하고, quickstart·app boot는 실 Keycloak
# 접근이 필요해 install-net에서 실행돼야 하므로 어차피 런타임 진입점이 필요하다. 로컬 레지스트리
# 디렉터리 자체도 이미지에 굽지 않고 docker run -v로 마운트한다.
#
# rust:1.88-alpine을 최종 런타임 이미지로도 그대로 쓴다 — node의 "npm install"에 대응하는 rust의
# "설치"는 곧 오프라인 컴파일이므로 컨테이너 안에 cargo/rustc가 있어야 한다(consume 단계에서도 빌드가
# 발생하는 유일한 언어 — 다른 언어는 사전 컴파일된 아티팩트를 받기만 한다). apk 패키지는
# harness/apps/rust/Dockerfile과 동일(이미 빌드 검증된 조합)로 맞춘다.
FROM rust:1.88-alpine AS app
RUN apk add --no-cache build-base musl-dev openssl-dev pkgconfig perl make ca-certificates
WORKDIR /app

# quickstart — rust/examples/quickstart.rs(SDK 배포 아티팩트가 아닌 예제, 무변경 재사용) + 이 하네스
# 전용 Cargo.toml(keycloak-sdk="0.1.0" 직접 기입 — cargo add #10926 회피, harness/install/quickstart/
# rust/Cargo.toml 참고).
COPY rust/examples/quickstart.rs /app/quickstart/quickstart.rs
COPY harness/install/quickstart/rust/Cargo.toml /app/quickstart/Cargo.toml

# app — harness/apps/rust(무변경 재사용, src/만 COPY). Cargo.toml은 원본을 .orig로 보존해 두고
# run.sh가 path 의존성(/src/rust)을 registry 의존성(keycloak-sdk = "0.1.0")으로 sed 치환한 사본을
# 만든다(harness/apps/rust/Cargo.toml 자체는 이 리포에서 무변경 — 빌드 컨텍스트 COPY 사본만 수정).
COPY harness/apps/rust/src /app/app/src
COPY harness/apps/rust/Cargo.toml /app/app/Cargo.toml.orig

# 소스 치환 템플릿 — run.sh가 /app/.cargo/config.toml로 배치한다(Cargo가 현재 디렉터리부터 상위로
# .cargo/config.toml을 탐색하므로 /app에 두면 /app/quickstart·/app/app 양쪽 빌드에 공통 적용됨).
COPY harness/install/registries/rust-cargo-config.toml /app/cargo-config.toml.template

COPY harness/install/consume/rust-run.sh /app/run.sh

EXPOSE 8090
# 런타임 엔트리포인트: source-replace 설정 배치 → cargo build --offline(quickstart+app, 오프라인이지만
# 컴파일 자체는 발생) → quickstart 스모크 → app boot. 전부 install-net에서 실행되어야 실 Keycloak에
# 접근 가능(cargo build 자체는 로컬 레지스트리 볼륨만 읽으므로 install-net이 없어도 되지만, 컨테이너
# 하나가 순차 실행하는 단일 진입점이라 어차피 install-net에 붙여 기동한다).
CMD ["sh", "/app/run.sh"]
