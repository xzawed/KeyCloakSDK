# build context = repo root (docker-compose.yml의 context: ..)
# ⚠️ 빌드가 느리다(크레이트 fetch + ring/rustls 컴파일 포함 약 15~25분) — 인내심을 갖고 넉넉한 타임아웃 사용.
# ⚠️ 태그를 버전으로 핀한다 — `rust:alpine`은 감사한 rustc 와 빌드한 rustc 가 갈라진다.
# 값은 SDK 의 MSRV(`rust/Cargo.toml` 의 rust-version)이고 install 경로 둘과 같다.
# `check-versions.mjs` 가 넷을 함께 대조한다.
FROM rust:1.88-alpine AS build
# build-base/musl-dev: musl 네이티브 컴파일 툴체인(ring 등). openssl-dev/pkgconfig/perl/make:
# 일부 전이의존(openssl-sys 등)의 빌드 스크립트가 요구.
RUN apk add --no-cache build-base musl-dev openssl-dev pkgconfig perl make
WORKDIR /src/rust
COPY rust/ /src/rust/
WORKDIR /app
COPY harness/apps/rust/Cargo.toml /app/Cargo.toml
COPY harness/apps/rust/src /app/src
# ⚠️ 락을 **반드시** 복사해 `--locked` 로 빌드한다 — `security-audit.yml` 이 `cargo audit -f` 로
# 감사하는 것이 바로 이 락이다. 빠뜨릴 때 컨테이너가 다른 그래프를 빌드하고도 감사는 초록이 된다.
COPY harness/apps/rust/Cargo.lock /app/Cargo.lock
RUN cargo build --locked --release && strip target/release/app-rust

FROM alpine:3.20
RUN apk add --no-cache ca-certificates && adduser -D -u 10001 app
COPY --from=build /app/target/release/app-rust /usr/local/bin/app-rust
USER app
EXPOSE 8090
ENTRYPOINT ["/usr/local/bin/app-rust"]
