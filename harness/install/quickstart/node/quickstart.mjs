// Install-smoke(b1) — node/examples/quickstart.ts의 .mjs 등가물.
//
// consume/node.Dockerfile이 Verdaccio에서 설치한 `@xzawed/keycloak-sdk@0.1.0`(소스 트리 접근 없음)를
// 실 Keycloak에 대해 최소 흐름(client-credentials 발급 → 자체 강화 validate)으로 구동해 "설치 후
// 첫 프로그램이 실제로 동작한다"를 증명한다. 소비 이미지는 TypeScript 툴체인을 두지 않으므로(클린 설치
// 원칙) node/examples/quickstart.ts를 그대로 실행하는 대신 이 순수 .mjs로 축약했다 — SDK 소스 트리가
// 아니라 harness/install/ 아래 하네스 전용 파일이다(node/ 패키지 배포 아티팩트에는 포함되지 않는다).
//
// consume/node.Dockerfile의 RUN 단계에서 `docker build --network install-net`로 실행되어야
// KC_SERVER_URL(http://keycloak:8080)을 install-net의 도커 DNS로 해석할 수 있다.
import { KeycloakClient } from '@xzawed/keycloak-sdk'

const env = (k, d) => process.env[k] || d

async function main() {
  const client = KeycloakClient.create({
    serverUrl: env('KC_SERVER_URL', 'http://localhost:8080'),
    realm: env('KC_REALM', 'it-realm'),
    clientId: env('KC_CLIENT_ID', 'it-client'),
    clientSecret: env('KC_CLIENT_SECRET', 'it-secret'),
  })

  try {
    // 1) client-credentials 토큰 발급.
    const token = await client.auth.clientCredentialsToken()
    if (!token.accessToken) throw new Error('quickstart-smoke: no access token issued')

    // 2) 발급받은 토큰을 자체 강화 검증(alg 핀·iss 정확일치·aud 포함검사·클록 스큐).
    const validated = await client.auth.validate(token.accessToken)
    if (!validated.subject) throw new Error('quickstart-smoke: validate produced no subject')

    console.log(
      `quickstart-smoke OK: tokenType=${token.tokenType} subject=${validated.subject} ` +
        `audience=${validated.audience.join(',')}`,
    )
  } finally {
    await client.close()
  }
}

main().catch((err) => {
  console.error('quickstart-smoke FAILED:', err)
  process.exitCode = 1
})
