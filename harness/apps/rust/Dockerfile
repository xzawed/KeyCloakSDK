# build context = repo root (docker-compose.yml의 context: ..)
# ⚠️ 빌드가 느리다(크레이트 fetch + ring/rustls 컴파일 포함 약 15~25분) — 인내심을 갖고 넉넉한 타임아웃 사용.
FROM rust:alpine AS build
# build-base/musl-dev: musl 네이티브 컴파일 툴체인(ring 등). openssl-dev/pkgconfig/perl/make:
# 일부 전이의존(openssl-sys 등)의 빌드 스크립트가 요구.
RUN apk add --no-cache build-base musl-dev openssl-dev pkgconfig perl make
WORKDIR /src/rust
COPY rust/ /src/rust/
WORKDIR /app
COPY harness/apps/rust/Cargo.toml /app/Cargo.toml
COPY harness/apps/rust/src /app/src
RUN cargo build --release && strip target/release/app-rust

FROM alpine:3.20
RUN apk add --no-cache ca-certificates && adduser -D -u 10001 app
COPY --from=build /app/target/release/app-rust /usr/local/bin/app-rust
USER app
EXPOSE 8090
ENTRYPOINT ["/usr/local/bin/app-rust"]
