FROM rust:1.88-alpine AS build
WORKDIR /app
COPY harness/apps/rust/Cargo.toml /app/Cargo.toml
COPY harness/apps/rust/src /app/src
COPY harness/apps/rust/Cargo.lock /app/Cargo.lock
RUN cargo build --locked --release

FROM alpine:3.20
