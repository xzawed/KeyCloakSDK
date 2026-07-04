/**
 * QuickStart — `@xzawed/keycloak-sdk`(Node/TypeScript) 최소 사용 예제.
 *
 * 실제 Keycloak 서버가 필요하므로 이 파일은 배포 아티팩트(`dist`)에 포함되지 않고, 참조용
 * 예제다. 실행하려면 아래 환경변수를 실제 값으로 설정하고 SDK를 로컬 링크/빌드한 뒤
 * (예: `npm run build` 후 소비 프로젝트에서 참조), tsx/ts 런타임으로 실행한다:
 *
 *   KEYCLOAK_URL=https://kc.example.com KEYCLOAK_REALM=my-realm \
 *   KEYCLOAK_CLIENT_ID=my-client KEYCLOAK_CLIENT_SECRET=*** \
 *   node --experimental-strip-types examples/quickstart.ts
 */
import { KeycloakClient } from '@xzawed/keycloak-sdk'

async function main(): Promise<void> {
  // KeycloakClient.create()는 auth(AuthClient)를 즉시 조립한다. admin은 최초 admin() 호출 시
  // 지연 생성된다(client-credentials grant — clientSecret 필요).
  const client = KeycloakClient.create({
    serverUrl: process.env['KEYCLOAK_URL'] ?? 'https://kc.example.com',
    realm: process.env['KEYCLOAK_REALM'] ?? 'my-realm',
    clientId: process.env['KEYCLOAK_CLIENT_ID'] ?? 'my-client',
    // 실제 값은 환경변수/시크릿 매니저에서 로드할 것. config는 로깅 시 자동 마스킹된다.
    clientSecret: process.env['KEYCLOAK_CLIENT_SECRET'] ?? 'changeme',
  })

  try {
    // 1) client-credentials 토큰 발급 — TokenSet의 문자열 표현은 자동 마스킹된다(accessToken=***).
    const token = await client.auth.clientCredentialsToken()
    console.log(`token=${token.toString()}`)

    // 2) 발급받은 토큰을 자체 강화 검증(alg 핀·iss 정확일치·aud 포함검사·클록 스큐).
    const validated = await client.auth.validate(token.accessToken)
    console.log(`subject=${validated.subject} aud=${validated.audience.join(',')}`)

    // 3) 관리 API — admin은 이 시점에 지연 생성된다. 사용자 목록 조회(최대 10명).
    const admin = await client.admin()
    const users = await admin.users.search(undefined, 0, 10)
    console.log(`users=${users.map((u) => u.username).join(', ')}`)
  } finally {
    // close()는 admin + auth 자원을 정리한다.
    // `await using client = KeycloakClient.create(...)`로 스코프 이탈 시 자동 정리도 가능하다.
    await client.close()
  }
}

main().catch((err: unknown) => {
  console.error(err)
  process.exitCode = 1
})
