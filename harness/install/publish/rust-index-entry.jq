# cargo local-registry(디렉터리) 인덱스 엔트리 생성기 — `cargo metadata --no-deps --format-version 1`의
# 출력(패키지 자신의 [dependencies]는 있는 그대로, req/features/kind는 Cargo.toml을 cargo 스스로
# 파싱한 결과)을 실 레지스트리 index JSON Lines 포맷(v2)으로 변환한다.
#
# 별도 파일로 둔 이유: Dockerfile의 RUN(shell form)에 여러 줄 인라인 jq 프로그램을 넣으면 각 줄 끝에
# `\`(Dockerfile 라인 연속)이 없는 한 도커 파서가 다음 줄을 "새 인스트럭션"으로 오인해 파싱 에러가
# 난다(실측 확인) — `jq -c -f <이 파일> --arg cksum "$CKSUM" /tmp/meta.json`로 호출해 이 문제를 피한다.
#
# kind==null(=normal 의존성)만 포함한다 — keycloak-sdk 자신의 [dev-dependencies](wiremock 등, JWKS
# 공격 프로브 픽스처 전용)는 하류 소비자의 빌드 그래프에 절대 활성화되지 않으므로(레지스트리 의존성의
# dev-dependencies는 그 크레이트를 직접 `cargo test`하지 않는 한 cargo가 resolve하지 않음) 제외해도
# 안전하고, 제외해야 로컬 레지스트리에 rsa/rand/base64/wiremock/testcontainers까지 불필요하게
# 미러링하지 않아도 된다.
.packages[0] as $p
| {
    name: $p.name,
    vers: $p.version,
    deps: [
      $p.dependencies[]
      | select(.kind == null)
      | {
          name: .name,
          req: .req,
          features: .features,
          optional: .optional,
          default_features: .uses_default_features,
          target: .target,
          kind: "normal",
          registry: .registry,
          package: (.rename // null)
        }
    ],
    cksum: $cksum,
    features: {},
    yanked: false,
    links: null,
    v: 2
  }
