# publish/rust.Dockerfile — cargo-local-registry 빌더(rust 참조 구현).
#
# node(Verdaccio, 상시 구동 HTTP 레지스트리)와 달리 rust에는 서비스가 없다 — 소스 치환
# ([source.local] local-registry = "…")이 가리키는 **디렉터리**가 곧 레지스트리다(리서치 부록
# docs/superpowers/specs/2026-07-07-install-recipes-research.md §rust). 이 Dockerfile은 그 디렉터리
# (/opt/local-registry)를 만드는 일회성 빌더이고, publish/rust.sh가 docker build 후 docker
# create+cp로 산출물만 호스트로 뽑아낸다(런타임 이미지가 아님 — consume는 별도 rust.Dockerfile).
#
# 빌드 컨텍스트 = 리포지토리 루트(harness/apps/rust/Cargo.toml·rust/ 양쪽을 COPY해야 하므로).
#
# ⚠️ crates.io 접근이 필요한 단계들(cargo-local-registry 설치·cargo package의 verify 빌드·
# cargo local-registry sync)이 있어 기본 브리지 네트워크(인터넷 있음)로 빌드한다 — install-net
# (소비자 격리망)과는 무관하다. rust:1.88-alpine(musl) 베이스라 Windows Docker Desktop의 glibc-DNS
# 게차도 없다.
#
# ⚠️ 소요시간: cargo package --locked의 verify 빌드가 SDK 전체(keycloak/openidconnect/jsonwebtoken/
# reqwest/tokio 등, ring·rustls 네이티브 컴파일 포함)를 컴파일한다 — harness/apps/rust/Dockerfile의
# 게차 코멘트와 동일 이유로 첫 빌드는 15~25분 안팎. 이후 rust/ 소스가 바뀌지 않는 한 Docker 레이어
# 캐시로 재실행은 즉시 끝난다.
FROM rust:1.88-alpine AS registry-builder

RUN apk add --no-cache build-base openssl-dev openssl-libs-static perl cmake pkgconfig git jq
ENV OPENSSL_STATIC=1

# cargo-local-registry(플러그인) — 소비자 쪽엔 불요(cargo core가 local-registry 소스 종류를 이미
# 네이티브 이해). 여기 빌더에서만 트랜지티브 클로저를 미러링하는 데 쓴다.
#
# ⚠️ 리서치 부록(§rust)이 지목한 0.2.12는 이 Dockerfile에서 **실측 검증 결과 rustc 1.88과 비호환**
# 이다 — 0.2.12는 내부적으로 `cargo` 크레이트 0.95.0을 끌어오는데 그 MSRV가 rustc 1.92라 `cargo
# install --locked`가 "rustc 1.88.0 is not supported" 에러로 즉시 실패한다(cargo-local-registry
# 자신은 rust_version을 선언하지 않지만, 내부 `cargo`-as-library 의존성의 MSRV가 실질 MSRV를
# 정한다 — cargo-local-registry는 6주 주기 rustc 릴리스에 맞춰 빠르게 버전을 올리는 프로젝트라
# 최신 버전이 항상 우리 고정 rustc 1.88과 맞물린다는 보장이 없다). rustc 1.88 안정화일(2025-06-26)
# 바로 다음날 게시된 **0.2.8**(2025-06-27)로 고정하면 동시대 `cargo` 내부 버전(0.89.0)과 맞물려
# 정상 컴파일된다(실측 확인 — 컨테이너에서 `cargo install cargo-local-registry --version 0.2.8
# --locked` 성공, `cargo v0.89.0` 컴파일까지 진행). rust:1.88-alpine 자체를 올리지 않는 한(SDK의
# MSRV=1.88 고정과 충돌) 0.2.8을 유지할 것 — 향후 SDK가 rust-version을 올릴 경우에만 같이 재검증.
RUN cargo install cargo-local-registry --version 0.2.8 --locked

WORKDIR /work
COPY rust/ /work/rust/

# 1) keycloak-sdk 본체 패키징 — cargo publish와 동일 tarball(target/package/keycloak-sdk-0.1.0.crate).
#    ⚠️ rust/Cargo.lock은 라이브러리라 rust/.gitignore가 커밋에서 제외한다 — 신선한 CI 체크아웃에는
#    lockfile이 없으므로 패키징 직전에 새로 생성한다(--locked는 쓰지 않음: 패키징 자체는 lockfile 일치를
#    요구하지 않고, 없는 lockfile을 --locked로 요구하면 이 단계가 즉시 실패한다). verify 빌드가 포함돼
#    시간이 오래 걸리는 단계.
WORKDIR /work/rust
RUN cargo generate-lockfile
RUN cargo package

# 2) 트랜지티브 클로저 매니페스트 — harness/apps/rust/Cargo.toml(axum 등 앱 전용 의존성이 추가된
#    실제 소비 매니페스트)을 그대로 재사용하되 path 의존성만 이 빌드 레이아웃(/work/rust)에 맞게
#    재기입한다. rust/examples/quickstart.rs가 필요로 하는 의존성(keycloak-sdk·keycloak·tokio)은
#    이 클로저의 부분집합이므로 quickstart 전용 매니페스트를 따로 lock할 필요가 없다.
COPY harness/apps/rust/Cargo.toml /work/closure/Cargo.toml
RUN mkdir -p /work/closure/src \
    && printf 'fn main() {}\n' > /work/closure/src/main.rs \
    && sed -i 's#path = "/src/rust"#path = "/work/rust"#' /work/closure/Cargo.toml

WORKDIR /work/closure
RUN cargo generate-lockfile

# 3) 트랜지티브 클로저를 로컬 레지스트리로 미러링. keycloak-sdk 자신은 path 소스라 sync가 자동으로
#    건너뛴다(cargo-local-registry는 registry+ 소스만 미러링) — 4)에서 수동 주입.
RUN mkdir -p /opt/local-registry \
    && cargo local-registry --sync Cargo.lock --no-delete /opt/local-registry

# 4) keycloak-sdk 수동 주입 — cargo-local-registry는 crates.io에서만 fetch하므로(로컬 .crate 직접
#    주입 불가, cargo #10926과 별개의 근본 제약) .crate 파일 복사 + index 엔트리를 손수 만든다.
#    index 엔트리(v2 JSON 한 줄)는 손으로 deps 배열을 베끼는 대신 `cargo metadata`로 실제 의존성
#    그래프(req/features/kind)를 뽑아 정확히 재현한다(rust-index-entry.jq) — req 문자열은 cargo
#    자신이 Cargo.toml을 파싱해 만든 것이라 수기 입력보다 index 포맷과 어긋날 위험이 낮다.
#    ⚠️ jq 필터는 별도 파일(rust-index-entry.jq)로 둔다 — Dockerfile RUN(shell form)에 여러 줄
#    인라인 jq 프로그램을 넣으면 각 줄 끝에 `\`가 없는 한 도커 파서가 다음 줄들을 "새 인스트럭션"으로
#    오인해 파싱 에러가 난다(실측 확인 — "Unknown instruction: NAME:" 등).
#    샤딩 경로 규칙(4자 이상 이름): index/<첫2자>/<다음2자>/<name> → "keycloak-sdk" ⇒ index/ke/yc/keycloak-sdk.
COPY harness/install/publish/rust-index-entry.jq /work/rust-index-entry.jq
WORKDIR /work/rust
RUN CKSUM="$(sha256sum /work/rust/target/package/keycloak-sdk-0.1.0.crate | awk '{print $1}')" \
    && cp /work/rust/target/package/keycloak-sdk-0.1.0.crate /opt/local-registry/keycloak-sdk-0.1.0.crate \
    && cargo metadata --no-deps --format-version 1 > /tmp/meta.json \
    && mkdir -p /opt/local-registry/index/ke/yc \
    && jq -c -f /work/rust-index-entry.jq --arg cksum "$CKSUM" /tmp/meta.json > /opt/local-registry/index/ke/yc/keycloak-sdk

# 산출물 확인(빌드 실패를 조기에 드러냄) — publish/rust.sh가 이후 docker create+cp로 통째로 추출한다.
RUN test -s /opt/local-registry/keycloak-sdk-0.1.0.crate \
    && test -s /opt/local-registry/index/ke/yc/keycloak-sdk
