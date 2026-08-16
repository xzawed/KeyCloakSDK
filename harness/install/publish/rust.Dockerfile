# publish/rust.Dockerfile — cargo-local-registry 빌더(rust 참조 구현).
#
# node(Verdaccio, 상시 구동 HTTP 레지스트리)와 달리 rust에는 서비스가 없다 — 소스 치환
# ([source.local] local-registry = "…")이 가리키는 **디렉터리**가 곧 레지스트리다(리서치 부록
# docs/superpowers/specs/2026-07-07-install-recipes-research.md §rust — 태그
# `archive/docs-history-2026-08`에 있다). 이 Dockerfile은 그 디렉터리
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
# ⚠️ 소요시간: `cargo package --no-verify`(아래 1단계)는 verify 빌드를 생략하므로 이 publish 이미지는
# 더 이상 SDK 전체(keycloak/openidconnect/jsonwebtoken/reqwest/tokio, ring·rustls 네이티브 포함)를
# 컴파일하지 않는다 — .crate tarball 생성 + 트랜지티브 클로저 다운로드(cargo local-registry sync)만
# 남아 수 분이면 끝난다(cargo-local-registry 설치 레이어는 항상 캐시). SDK의 실제 컴파일·검증은
# consume 단계(consume/rust-run.sh의 cargo build)가 어차피 수행하므로 여기서의 verify 빌드는
# 중복이었다 — rust가 install 경로에서 SDK를 두 번 컴파일하던 것을 한 번으로 줄인 최적화.
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

# 1) keycloak-sdk 본체 패키징 — cargo publish와 동일 tarball(target/package/keycloak-sdk-${PKG_VER}.crate).
#    ⚠️ rust/Cargo.lock은 라이브러리라 rust/.gitignore가 커밋에서 제외한다 — 신선한 CI 체크아웃에는
#    lockfile이 없으므로 패키징 직전에 새로 생성한다(--locked는 쓰지 않음: 패키징 자체는 lockfile 일치를
#    요구하지 않고, 없는 lockfile을 --locked로 요구하면 이 단계가 즉시 실패한다).
#    ⚠️ --no-verify: 패키징 후 verify 빌드(SDK 전체 재컴파일, 15~25분)를 생략한다. .crate tarball은
#    그대로 생성되고(4단계가 이 파일을 복사·주입), SDK의 실제 컴파일·검증은 consume 단계(cargo build
#    --offline)가 어차피 수행하므로 verify 빌드는 중복이었다 — install 경로의 이중 컴파일 제거.
WORKDIR /work/rust
RUN cargo generate-lockfile
RUN cargo package --no-verify

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

# 릴리스 버전(publish/rust.sh가 --build-arg로 넘긴다 — 기본값은 하네스 전체 기본과 같은 0.1.0).
# `cargo package`가 만드는 tarball 이름은 rust/Cargo.toml의 version이 정하므로 이 ARG는 "그 파일이
# 무슨 이름일지"에 대한 기대값이다 — 태그↔매니페스트가 어긋나면 아래 cp/test가 즉시 실패한다
# (조용히 엉뚱한 버전을 게시하는 것보다 낫다 — 그게 이 버전 스레딩의 요점이다).
# ⚠️ ARG를 FROM 직후가 아니라 여기(첫 사용 지점)에 두는 이유: ARG 값 변경은 그 지점 이후의 모든
# 레이어 캐시를 무효화한다. 위에 두면 버전을 바꿀 때마다 cargo-local-registry 설치와 트랜지티브
# 클로저 sync(수 분)까지 통째로 다시 돈다.
ARG PKG_VER=0.1.0
RUN CKSUM="$(sha256sum "/work/rust/target/package/keycloak-sdk-${PKG_VER}.crate" | awk '{print $1}')" \
    && cp "/work/rust/target/package/keycloak-sdk-${PKG_VER}.crate" "/opt/local-registry/keycloak-sdk-${PKG_VER}.crate" \
    && cargo metadata --no-deps --format-version 1 > /tmp/meta.json \
    && mkdir -p /opt/local-registry/index/ke/yc \
    && jq -c -f /work/rust-index-entry.jq --arg cksum "$CKSUM" /tmp/meta.json > /opt/local-registry/index/ke/yc/keycloak-sdk

# 산출물 확인(빌드 실패를 조기에 드러냄) — publish/rust.sh가 이후 docker create+cp로 통째로 추출한다.
RUN test -s "/opt/local-registry/keycloak-sdk-${PKG_VER}.crate" \
    && test -s /opt/local-registry/index/ke/yc/keycloak-sdk
