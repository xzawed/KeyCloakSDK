/**
 * 적대 경로 행렬 — 분류표를 세우고, 적대 변형을 **메서드 손 목록이 아니라 계급에** 붙인다
 * (등록부 `guard-detection-surface-hand-narrowed`). 참조 구현은 go 파일럿 `go/hostile_path_matrix_test.go` 다.
 *
 * nonce·콜드캐시 백오프·토큰응답 타입검증 축은 `scripts/test/test-security-defaults.sh` 가 손으로 고른 자리에
 * 앵커를 건다. 그래서 **새 공개 교환 경로**가 생기면 세 축 모두 그것을 모른다. 여기서는 경로를 파생한다:
 *
 *   - 선언 집합: `facade-walk.ts` 의 뿌리(`dumpRoots`)·걷기(`visit`)가 닿는 SDK 클래스와 배럴이 내보내는
 *     클래스마다 공개 멤버 전부(프로토타입의 메서드·접근자 · 생성자의 정적 메서드 · 인스턴스의 함수 값 필드) ∪
 *     배럴이 내보내는 함수 ∪ **소스에 선언된 공개 멤버**(TypeScript 컴파일러 API 로 읽는다). 오버로드는 서명마다
 *     한 행이다. 소스가 `private`·`protected`·`@internal` 로 적은 멤버는 뺀다 — 리플렉션은 TS `private` 을
 *     못 가른다(런타임엔 평범한 프로퍼티다). ES `#private` 은 리플렉션도 소비자도 못 본다.
 *   - 호출: 행마다 **새** 수신자(아래 빌더)를 기록하는 가짜 IdP 의 **새 realm** 위에 만들어 부른다(서버는 하나 —
 *     `startServer`). 인자는 소스 서명의 타입으로 합성한다. 걷기가 닿지만 어느 빌더도 안 닿는 타입은 영값
 *     수신자(`Object.create(prototype)`)다. 함수를 돌려주는 접근자는 그 함수까지 부른다.
 *   - 분류: 그 호출이 IdP 에 실제로 보낸 요청으로 가른다(`classify`). grant_type 은 폼·JSON 본문 어느 쪽이든,
 *     어느 경로로 가든 읽는다.
 *
 * 단언은 go 와 같다: (1) UNDETERMINED 없음(면제는 이유와 함께 · 낡은 면제는 실패) · (2) CODE_EXCHANGE·TOKEN_GRANT·
 * JWKS_FETCH 가 각각 비어 있지 않다 · (W1) 손으로 고른 테스트의 대상이 전부 행이고 기대 계급이다 · (W3a·b·c)
 * 계급별 적대 변형. 실패한 칸은 `KNOWN_GAPS` 에 이유와 함께 있으면 GAP 이고, 관측되지 않는 항목은 낡아 실패한다.
 * node 가 더한 단언: (1b) 비공개로 뺀 멤버라도 부르면 IdP 에 닿는 것은 이유가 있어야 한다 · (2b) 캐시가 부여 경로를
 * 가리지 않는다 · (2c) 호출이 돌아온 뒤 나간 요청이 없다 · W3a 의 `[nonce]` 판 · W3b 의 alg 두 칸 — 전부 Grok 레그가
 * 지목하고 실측이 SILENT 로 확인한 자리다(커밋 본문에 전후 판정).
 *
 * ⚠️ go 설계가 node 에 그대로 맞지 않은 자리(실측으로 갈랐다):
 *   - **discovery 는 분류에서 뺀다**(표에는 찍는다). openid-client 는 모든 토큰 연산 앞에서
 *     `/.well-known/openid-configuration` 를 GET 한다 — 세면 인자 합성이 틀려 토큰 요청 **전에** 실패한 교환
 *     메서드가 OTHER 로 조용히 읽힌다(빼면 UNDETERMINED 로 운다). go 는 엔드포인트를 규약으로 조립해 이 요청이 없다.
 *   - **URL 이름의 문자열 인자는 절대 URL 이다.** `exchangeCode` 는 `new URL(redirectUri)` 로 파싱하므로 JWS 를
 *     넣으면 토큰 요청 전에 TypeError 다. 타입이 둘 다 `string` 이라 이름(`…Uri`·`…Url`)으로 가른다. 다른 이름의
 *     URL 파라미터를 받는 새 교환 메서드는 위 규칙 덕에 OTHER 가 아니라 UNDETERMINED 로 드러난다.
 *   - **W3b 의 nonce 변형은 JWKS 에 안 닿는다.** nonce 대조는 openid-client 가 SDK 검증기 **앞에서** 한다
 *     (`expectedNonce`). 그래서 「JWKS 에 닿아야 한다」는 대조 칸과 다른 키로 서명한 두 칸에만 건다 — 대조와 다른
 *     것이 서명뿐이라 그 거부는 검증기에서만 날 수 있다.
 *   - **패닉은 없다** — 「크래시」는 `Error` 가 아닌 값이 던져진 것이다. SDK 오류는 `errors.ts` 가 선언한 클래스다.
 *
 * ⚠️ 잴 때 함정(go 와 같다): 문자열 인자는 가짜 IdP 키로 **서명한 JWS** 다(평문이면 `validate` 가 요청 전에 실패해
 * JWKS_FETCH 가 빈다). 토큰 응답의 `expires_in` 은 skew(30s)보다 짧다(길면 provider 캐시가 부여 경로를 가려 admin
 * 자원 메서드가 OTHER 로 읽힌다).
 *
 * ⚠️ 한계: 요청도 오류도 없이 끝나는 경로는 NONE 이다(합성 인자가 요청 앞에서 갈라 세우는 것 · 이 IdP 가 아닌 호스트로
 * 나가 오류를 버리는 것). 기다리지 않는 비동기 요청은 (2c) 가 **도착하면** 잡는다 — 테스트가 끝난 뒤 도착하면 못 본다.
 * 배럴이 내보내지 않는 모듈 함수는 공개 API 가 아니라 행이 아니다. 오버로드 서명의 인자는 서명별로 합성하지만 부르는
 * 구현은 하나다. W3b 는 nonce 이름의 파라미터로 대상을 고른다(다른 이름이면 NONCE_DROP_EXEMPT 가 운다).
 */
import { describe, it, expect, beforeAll, afterAll } from 'vitest'
import { createServer, type IncomingMessage, type ServerResponse } from 'node:http'
import type { AddressInfo } from 'node:net'
import { existsSync, readdirSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { format, inspect } from 'node:util'
import ts from 'typescript'
import { exportJWK, generateKeyPair, SignJWT, UnsecuredJWT, type CryptoKey, type JWK } from 'jose'
import {
  AuthClient,
  ClientCredentialsTokenProvider,
  defineConfig,
  JwtValidator,
  KeycloakClient,
  type JwtValidatorOptions,
  type KeycloakConfigInput,
} from '../../src/index.js'
import {
  BARREL,
  declaredClasses,
  dumpRoots,
  isClass,
  newWalk,
  SRC,
  visit,
  type ClassCtor,
} from './facade-walk.js'
import { MALFORMED_TOKEN_RESPONSES, NON_STRING_ACCESS_TOKENS } from './token-responses.js'

const CODE_EXCHANGE = 'CODE_EXCHANGE'
const TOKEN_GRANT = 'TOKEN_GRANT'
const JWKS_FETCH = 'JWKS_FETCH'
const OTHER = 'OTHER'
const NONE = 'NONE'
const UNDETERMINED = 'UNDETERMINED'
const CLASSES = [CODE_EXCHANGE, TOKEN_GRANT, JWKS_FETCH, OTHER, NONE, UNDETERMINED] as const

/**
 * UNDETERMINED 여도 되는 행과 그 이유. **이유 없는 면제는 넣지 않는다.** 선언 집합에 없거나 더는
 * UNDETERMINED 가 아닌 항목은 낡은 면제로 실패한다.
 */
const UNDETERMINED_EXEMPT: Readonly<Record<string, string>> = {
  'tokenSetFromResponse()':
    '순수 매퍼(tokens.ts) — I/O 가 없다. 합성 인자 `{}` 를 거절하는 것이 곧 토큰 타입 축의 계약이고 ' +
    '(tokens.test.ts), 토큰 부여 행 전부가 이 함수를 거쳐 W3a 변형을 받는다',
}

/**
 * 소스가 비공개(TS `private`·`protected`·`@internal`)로 적었지만 런타임엔 부를 수 있고, 부르면 IdP 에 닿는 멤버와
 * 그 이유. 선언 집합(공개 API)이 아니라 W3 는 안 붙지만, **숨긴 교환 경로**는 이유 없이 두지 않는다(Grok 레그 —
 * `@internal` 교환 메서드를 심으니 SILENT 였다). 이유 없는 항목은 넣지 않고, 낡은 항목은 실패한다.
 */
const HIDDEN_REACH_EXEMPT: Readonly<Record<string, string>> = {
  'JwtValidator#keys':
    'TS private 키 소스(jose 원격 JWKS + 콜드 캐시 백오프, jwt.ts) — 생성자 파라미터 프로퍼티라 런타임엔 보이지만 ' +
    '방출 .d.ts 에 없다. 공개 경로는 JwtValidator#validate·AuthClient#validate 둘뿐이고 둘 다 JWKS_FETCH 행으로 W3c 를 받는다',
}

/**
 * W3b 에서 빠져도 되는 CODE_EXCHANGE 행과 그 이유. **이유 없는 면제는 넣지 않는다.** nonce 파라미터의 이름으로
 * 대상을 파생하므로, nonce 를 다른 이름으로 받는 새 교환 메서드는 이 표가 없으면 조용히 빠진다(go 와 같다).
 */
const NONCE_DROP_EXEMPT: Readonly<Record<string, string>> = {}

/**
 * 현재 main 에서 실패하는 칸 — 키는 `W3<축> 행/변형`, 값은 `<등록부 id>: 한 줄 이유`. SDK 를 고치지 않고
 * 드러내 둔다. 관측되지 않는(이제 통과하거나 칸이 없는) 항목은 낡은 것이라 실패한다.
 */
const KNOWN_GAPS: Readonly<Record<string, string>> = {}

const TEST_DIR = fileURLToPath(new URL('./', import.meta.url))
const NODE_ROOT = fileURLToPath(new URL('../../', import.meta.url))
const SCRIPT = join(NODE_ROOT, '..', 'scripts', 'test', 'test-security-defaults.sh')

// 분류는 realm 과 무관하게 **꼬리**로 본다 — 인자로 받은 realm 의 엔드포인트도 교환이다(go 와 같다).
const OIDC = '/protocol/openid-connect'
const TOKEN_SUFFIX = `${OIDC}/token`
const CERTS_SUFFIX = `${OIDC}/certs`
const INTROSPECT_SUFFIX = `${OIDC}/token/introspect`
const LOGOUT_SUFFIX = `${OIDC}/logout`
const DISCOVERY_SUFFIX = '/.well-known/openid-configuration'
const URL_ARG = 'https://app.example/cb'
const CLIENT_ID = 'c'

// ---- 기록하는 가짜 IdP ----

interface Req {
  readonly method: string
  readonly path: string
  /** POST 본문(폼·JSON)의 grant_type — 경로와 무관하게 읽는다(아니면 빈 문자열) */
  readonly grant: string
  /** 이 IdP 가 발급한 액세스 토큰(`ISSUED_AT`)을 Bearer 로 실었는가 — 캐시가 부여를 가렸는지 본다 */
  readonly bearer: boolean
}

/** 정상 토큰 응답의 access_token — 인자로 넘긴 보편 인자와 달라, 요청에 실리면 SDK 가 발급받아 쥔 것이다. */
const ISSUED_AT = 'hp-access'

interface HostileResp {
  readonly status: number
  readonly body: string
}

interface Keys {
  readonly priv: CryptoKey
  /** JWKS 에 없는 키 — W3b 의 위조 서명 */
  readonly other: CryptoKey
  readonly jwk: JWK
}

function sign(
  key: CryptoKey,
  kid: string,
  iss: string,
  claims: Record<string, unknown>,
): Promise<string> {
  return new SignJWT(claims)
    .setProtectedHeader({ alg: 'RS256', kid, typ: 'JWT' })
    .setIssuer(iss)
    .setSubject('u1')
    .setAudience(CLIENT_ID)
    .setIssuedAt()
    .setExpirationTime('5m')
    .sign(key)
}

interface HpIdp {
  readonly origin: string
  /** 이 칸의 realm — 칸마다 달라, 한 서버 위에서도 요청이 칸을 넘나들지 않는다 */
  readonly realm: string
  readonly iss: string
  /**
   * 모든 문자열 인자에 넣는 값. ⚠️ 평문이면 토큰을 받는 메서드(`validate` 둘)가 JWS 파싱에서 요청 없이 실패해
   * JWKS_FETCH 가 빈다 — 그래서 이 IdP 키로 서명한 **유효한 JWS** 다(URL·폼에 안전한 문자만 쓴다).
   */
  readonly universal: string
  /** 정상 토큰 응답의 id_token — nonce 가 `universal` 이라 `exchangeCode` 의 nonce·서명 검증까지 통과한다 */
  readonly idToken: string
  readonly reqs: Req[]
  /** 있으면 토큰 엔드포인트가 정상 응답 대신 이것을 낸다(W3 — 수신자를 정상 응답으로 만든 **뒤에** 건다). */
  tokenResp: HostileResp | undefined
  /** 참이면 JWKS 가 503 이다(W3c). */
  certsDown: boolean
  input(): KeycloakConfigInput
  validatorOpts(): JwtValidatorOptions
  certsUri(): string
  close(): Promise<void>
}

interface OpenCell extends HpIdp {
  readonly label: string
  closed: boolean
}

/**
 * 기록하는 가짜 IdP — **서버는 하나**이고 칸(행 × 변형)마다 realm 을 새로 연다(`r1`, `r2`, …). 클라이언트는 여전히
 * 칸마다 새것이라 SDK 캐시(discovery·JWKS·provider)는 칸을 넘지 않는다.
 * ⚠️ 칸마다 서버를 새로 띄우면 한 번에 포트를 천 단위로 쓰고, 연달아 돌리면 Windows 의 동적 포트(16k)가 TIME_WAIT 로
 * 차 `connect EADDRINUSE` 로 칸이 거짓 실패한다(실측: TIME_WAIT 10k 에서 났다).
 *
 * 요청은 경로의 realm → 경로의 보편 인자 → 지금 열린 칸 순으로 칸에 붙는다. **닫힌** 칸에 붙는 요청은 호출이
 * 돌아온 **뒤에** 나간 것이라 `late` 에 모인다(기다리지 않는 비동기 요청 — Grok 레그 지목). 어디에도 안 붙으면
 * `orphans` 다. 기록은 라우팅 **앞**에서 하므로 라우트가 없는 경로(admin 404 포함)도 남는다.
 */
interface IdpServer {
  readonly late: Array<{ readonly label: string; readonly req: Req }>
  readonly orphans: Req[]
  open(label: string): Promise<HpIdp>
  close(): Promise<void>
}

/** 32 바이트 넘게 — W3b 의 `alg=HS256` id_token 을 이 비밀로 서명한다(openid-client 의 client_secret 과 같다). */
const CLIENT_SECRET = 'hp-client-secret-0123456789abcdefghij'

/** Keycloak 이 discovery 에 광고하는 id_token 서명 알고리즘(HMAC 포함). */
const KEYCLOAK_ID_TOKEN_ALGS = [
  'PS384',
  'RS384',
  'EdDSA',
  'ES384',
  'HS256',
  'HS512',
  'ES256',
  'RS256',
  'HS384',
  'ES512',
  'PS256',
  'PS512',
  'RS512',
]

/**
 * 요청 본문의 grant_type — 폼이든 JSON 이든 읽는다. ⚠️ 폼만 읽으면 JSON 본문으로 보낸 코드 교환이 grant 없는
 * 토큰 POST 가 되어 TOKEN_GRANT 로 읽히고 W3b(nonce·서명)가 안 붙는다(Grok 레그 지목, 실측 SILENT).
 */
function grantOf(body: string): string {
  const text = body.trim()
  if (text.startsWith('{')) {
    try {
      const g: unknown = (JSON.parse(text) as Record<string, unknown>)['grant_type']
      return typeof g === 'string' ? g : ''
    } catch {
      return ''
    }
  }
  return new URLSearchParams(text).get('grant_type') ?? ''
}

async function startServer(keys: Keys): Promise<IdpServer> {
  const cells = new Map<string, OpenCell>()
  const byUniversal = new Map<string, OpenCell>()
  const late: Array<{ label: string; req: Req }> = []
  const orphans: Req[] = []
  let active: OpenCell | undefined
  let next = 0
  const find = (path: string): OpenCell | undefined => {
    const m = /\/realms\/(r\d+)(?=\/|$)/.exec(path)
    const byRealm = m === null ? undefined : cells.get(m[1] as string)
    if (byRealm !== undefined) return byRealm
    for (const [u, c] of byUniversal) if (path.includes(u)) return c
    return active
  }
  const send = (res: ServerResponse, status: number, body: string): void => {
    res.writeHead(status, { 'content-type': 'application/json' })
    res.end(body)
  }
  const route = (
    res: ServerResponse,
    method: string,
    path: string,
    grant: string,
    cell: OpenCell | undefined,
  ): void => {
    if (path.endsWith(DISCOVERY_SUFFIX)) {
      const issuer = origin + path.slice(0, -DISCOVERY_SUFFIX.length)
      const base = `${issuer}${OIDC}`
      return send(
        res,
        200,
        JSON.stringify({
          issuer,
          authorization_endpoint: `${base}/auth`,
          token_endpoint: `${base}/token`,
          introspection_endpoint: `${base}/token/introspect`,
          end_session_endpoint: `${base}/logout`,
          jwks_uri: `${base}/certs`,
          response_types_supported: ['code'],
          grant_types_supported: ['client_credentials', 'authorization_code', 'refresh_token'],
          // Keycloak 처럼 HMAC 도 광고한다 — openid-client 는 토큰 엔드포인트 id_token 의 alg 를 이 목록으로만
          // 거르므로, RS256 만 적으면 HS256 id_token 을 라이브러리가 먼저 거절해 SDK 검증기의 alg 핀이 안 재진다
          // (W3b 의 `alg=HS256` 칸 — Grok 레그 지목, 실측 SILENT).
          id_token_signing_alg_values_supported: KEYCLOAK_ID_TOKEN_ALGS,
        }),
      )
    }
    // grant_type 을 실은 POST 는 경로가 무엇이든 토큰 요청으로 답한다 — 적대 응답이 그 경로에도 닿게.
    if (method === 'POST' && (path.endsWith(TOKEN_SUFFIX) || grant !== '')) {
      const override = cell?.tokenResp
      if (override !== undefined) return send(res, override.status, override.body)
      // expires_in 을 기본 skew(30s)보다 짧게 준다 — provider 캐시가 늘 식어 있어, 부여에 **닿을 수 있는**
      // 메서드는 실제로 닿는다(admin 자원 메서드가 생성 때 데운 토큰에 가려 OTHER 로 읽히지 않게).
      // ⚠️ 300 으로 올리면 TOKEN_GRANT 30 → 5 이고 W3a 가 403 → 78 칸으로 **조용히** 준다(실측) — (2b) 의 캐시
      // 단언이 그것을 잡는다.
      return send(
        res,
        200,
        JSON.stringify({
          access_token: ISSUED_AT,
          token_type: 'Bearer',
          expires_in: 1,
          refresh_token: 'hp-refresh',
          id_token: cell?.idToken,
          scope: 'openid',
        }),
      )
    }
    if (path.endsWith(INTROSPECT_SUFFIX)) {
      return send(res, 200, '{"active":true,"username":"svc","client_id":"c","sub":"u1"}')
    }
    if (method === 'GET' && path.endsWith(CERTS_SUFFIX)) {
      if (cell?.certsDown === true) return send(res, 503, '{"error":"unavailable"}')
      return send(res, 200, JSON.stringify({ keys: [keys.jwk] }))
    }
    if (path.endsWith(LOGOUT_SUFFIX)) {
      res.writeHead(204)
      return void res.end()
    }
    send(res, 404, '{"error":"not_found"}')
  }
  const server = createServer((req: IncomingMessage, res: ServerResponse) => {
    const chunks: Buffer[] = []
    req.on('data', (c: Buffer) => chunks.push(c))
    // 본문을 다 받은 뒤 기록하고 답한다 — grant_type 은 본문에 있다.
    req.on('end', () => {
      const method = req.method ?? ''
      const path = new URL(req.url ?? '/', 'http://idp').pathname
      const grant = method === 'POST' ? grantOf(Buffer.concat(chunks).toString('utf8')) : ''
      const bearer = req.headers.authorization === `Bearer ${ISSUED_AT}`
      const r: Req = { method, path, grant, bearer }
      const cell = find(path)
      if (cell === undefined) orphans.push(r)
      else if (cell.closed) late.push({ label: cell.label, req: r })
      else cell.reqs.push(r)
      route(res, method, path, grant, cell)
    })
  })
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve))
  const origin = `http://127.0.0.1:${(server.address() as AddressInfo).port}`
  return {
    late,
    orphans,
    async open(label: string): Promise<HpIdp> {
      next += 1
      const realm = `r${next}`
      const iss = `${origin}/realms/${realm}`
      const universal = await sign(keys.priv, 'k1', iss, {})
      const cell: OpenCell = {
        label,
        closed: false,
        origin,
        realm,
        iss,
        universal,
        idToken: await sign(keys.priv, 'k1', iss, { nonce: universal }),
        reqs: [],
        tokenResp: undefined,
        certsDown: false,
        input: () => ({
          serverUrl: origin,
          realm,
          clientId: CLIENT_ID,
          clientSecret: CLIENT_SECRET,
        }),
        validatorOpts: () => ({
          issuer: iss,
          audience: CLIENT_ID,
          allowedAlgs: ['RS256'],
          clockSkewSeconds: 30,
          jwksMinRefetchSeconds: 30,
        }),
        certsUri: () => `${iss}${CERTS_SUFFIX}`,
        close: async () => {
          cell.closed = true
          if (active === cell) active = undefined
        },
      }
      cells.set(realm, cell)
      byUniversal.set(universal, cell)
      active = cell
      return cell
    },
    close: () =>
      new Promise<void>((resolve) => {
        server.closeAllConnections()
        server.close(() => resolve())
      }),
  }
}

// ---- 소스 서명(TypeScript 컴파일러 API) ----

type ParamKind = 'string' | 'number' | 'boolean' | 'object'

interface Param {
  readonly name: string
  readonly kind: ParamKind
  /** 타입 참조 이름(`KeycloakConfig` 등) — SDK 타입이면 그 값을 만든다 */
  readonly ref?: string
}

interface SrcMember {
  /** `Class#m` · `Class.m`(정적) · `fn()`(모듈 함수) */
  readonly label: string
  readonly owner: string
  readonly name: string
  /** 공개가 아니면 그 이유 — ES `#private` · TS `private`·`protected` · `@internal` */
  readonly hidden: string | undefined
  /** 함수가 아닌 필드(생성자 파라미터 프로퍼티 포함) — 런타임 값이 함수일 때만 행이 된다 */
  readonly field: boolean
  /** 오버로드 서명마다 하나(없으면 구현 서명 하나) */
  readonly signatures: ReadonlyArray<ReadonlyArray<Param>>
  readonly body: ts.Node | undefined
  readonly file: string
}

interface Source {
  readonly members: Map<string, SrcMember>
  /** 최상위 `export function` — 배럴이 내보내는 것만 공개 API 다 */
  readonly functions: Map<string, SrcMember>
}

function kindOf(
  t: ts.TypeNode | undefined,
  init: ts.Expression | undefined,
  sf: ts.SourceFile,
): Pick<Param, 'kind' | 'ref'> {
  if (t === undefined) {
    // 타입 표기가 없으면 기본값에서 추론한다(`first = 0`).
    if (init === undefined) return { kind: 'object' }
    if (ts.isNumericLiteral(init)) return { kind: 'number' }
    if (ts.isStringLiteral(init) || ts.isNoSubstitutionTemplateLiteral(init))
      return { kind: 'string' }
    if (init.kind === ts.SyntaxKind.TrueKeyword || init.kind === ts.SyntaxKind.FalseKeyword)
      return { kind: 'boolean' }
    return { kind: 'object' }
  }
  if (ts.isParenthesizedTypeNode(t)) return kindOf(t.type, undefined, sf)
  if (ts.isUnionTypeNode(t)) {
    const kinds = t.types.map((x) => kindOf(x, undefined, sf))
    for (const k of ['string', 'number', 'boolean'] as const) {
      if (kinds.some((x) => x.kind === k)) return { kind: k }
    }
    return kinds.find((x) => x.ref !== undefined) ?? { kind: 'object' }
  }
  if (t.kind === ts.SyntaxKind.StringKeyword) return { kind: 'string' }
  if (t.kind === ts.SyntaxKind.NumberKeyword) return { kind: 'number' }
  if (t.kind === ts.SyntaxKind.BooleanKeyword) return { kind: 'boolean' }
  if (ts.isLiteralTypeNode(t)) {
    if (ts.isStringLiteral(t.literal)) return { kind: 'string' }
    if (ts.isNumericLiteral(t.literal)) return { kind: 'number' }
    return { kind: 'boolean' }
  }
  if (ts.isTypeReferenceNode(t)) return { kind: 'object', ref: t.typeName.getText(sf) }
  return { kind: 'object' }
}

function paramsOf(
  ps: ts.NodeArray<ts.ParameterDeclaration>,
  sf: ts.SourceFile,
): ReadonlyArray<Param> {
  return ps.map((p) => ({
    name: ts.isIdentifier(p.name) ? p.name.text : p.name.getText(sf),
    ...kindOf(p.type, p.initializer, sf),
  }))
}

/** 계산된 이름의 심볼을 리플렉션의 `description` 과 같은 모양으로 — `[Symbol.asyncDispose]`·`[INSPECT]`. */
function symbolDesc(expr: ts.Expression, sf: ts.SourceFile): string {
  if (
    ts.isPropertyAccessExpression(expr) &&
    ts.isIdentifier(expr.expression) &&
    expr.expression.text === 'Symbol'
  )
    return `Symbol.${expr.name.text}`
  if (ts.isIdentifier(expr)) {
    let found: string | undefined
    const find = (n: ts.Node): void => {
      if (
        ts.isVariableDeclaration(n) &&
        ts.isIdentifier(n.name) &&
        n.name.text === expr.text &&
        n.initializer !== undefined &&
        ts.isCallExpression(n.initializer)
      ) {
        const arg = n.initializer.arguments[0]
        if (arg !== undefined && ts.isStringLiteral(arg)) found = arg.text
      }
      ts.forEachChild(n, find)
    }
    find(sf)
    if (found !== undefined) return found
  }
  return expr.getText(sf)
}

function memberKey(
  name: ts.PropertyName,
  sf: ts.SourceFile,
): { key: string; privateName: boolean } {
  if (ts.isPrivateIdentifier(name)) return { key: name.text, privateName: true }
  if (ts.isComputedPropertyName(name))
    return { key: `[${symbolDesc(name.expression, sf)}]`, privateName: false }
  return { key: name.getText(sf).replace(/^['"]|['"]$/g, ''), privateName: false }
}

function hiddenReason(m: ts.Declaration, privateName: boolean): string | undefined {
  if (privateName) return 'ES #private'
  const flags = ts.getCombinedModifierFlags(m)
  if (flags & ts.ModifierFlags.Private) return 'TS private'
  if (flags & ts.ModifierFlags.Protected) return 'TS protected'
  if (ts.getJSDocTags(m).some((t) => t.tagName.text === 'internal')) return '@internal'
  return undefined
}

function isStatic(m: ts.Declaration): boolean {
  return (ts.getCombinedModifierFlags(m) & ts.ModifierFlags.Static) !== 0
}

function parseSource(): Source {
  const members = new Map<string, SrcMember>()
  const functions = new Map<string, SrcMember>()
  // 오버로드 — 몸체 없는 선언은 서명으로 모은다.
  const overloads = new Map<string, Param[][]>()
  const put = (map: Map<string, SrcMember>, m: SrcMember, bodyless: boolean): void => {
    if (bodyless) {
      overloads.set(m.label, [
        ...(overloads.get(m.label) ?? []),
        ...m.signatures.map((s) => [...s]),
      ])
      if (!map.has(m.label)) map.set(m.label, m)
      return
    }
    const sigs = overloads.get(m.label)
    map.set(m.label, sigs === undefined ? m : { ...m, signatures: sigs })
  }
  for (const rel of readdirSync(SRC, { recursive: true, encoding: 'utf8' }).sort()) {
    if (!rel.endsWith('.ts') || rel.endsWith('.d.ts')) continue
    const file = rel.replace(/\\/g, '/')
    const sf = ts.createSourceFile(
      file,
      readFileSync(join(SRC, rel), 'utf8'),
      ts.ScriptTarget.Latest,
      true,
      ts.ScriptKind.TS,
    )
    const classMembers = (owner: string, c: ts.ClassLikeDeclaration): void => {
      for (const m of c.members) {
        if (ts.isConstructorDeclaration(m)) {
          // 파라미터 프로퍼티(`private readonly keys: …`)도 필드다 — 런타임 값이 함수면 리플렉션이 행으로 본다.
          for (const p of m.parameters) {
            if (!ts.isParameterPropertyDeclaration(p, m) || !ts.isIdentifier(p.name)) continue
            const label = `${owner}#${p.name.text}`
            put(
              members,
              {
                label,
                owner,
                name: p.name.text,
                hidden: hiddenReason(p, false),
                field: true,
                signatures: [],
                body: undefined,
                file,
              },
              false,
            )
          }
          continue
        }
        if (
          !ts.isMethodDeclaration(m) &&
          !ts.isGetAccessorDeclaration(m) &&
          !ts.isPropertyDeclaration(m)
        )
          continue
        const { key, privateName } = memberKey(m.name, sf)
        const label = `${owner}${isStatic(m) ? '.' : '#'}${key}`
        const fnInit =
          ts.isPropertyDeclaration(m) &&
          m.initializer !== undefined &&
          (ts.isArrowFunction(m.initializer) || ts.isFunctionExpression(m.initializer))
            ? m.initializer
            : undefined
        // 함수를 돌려주는 접근자는 그 함수의 서명을 쓴다 — 부를 때 돌려받은 함수까지 부른다(invoke).
        const getterFn =
          ts.isGetAccessorDeclaration(m) && m.type !== undefined && ts.isFunctionTypeNode(m.type)
            ? m.type
            : undefined
        const params = ts.isMethodDeclaration(m)
          ? paramsOf(m.parameters, sf)
          : fnInit !== undefined
            ? paramsOf(fnInit.parameters, sf)
            : getterFn !== undefined
              ? paramsOf(getterFn.parameters, sf)
              : []
        put(
          members,
          {
            label,
            owner,
            name: key,
            hidden: hiddenReason(m, privateName),
            field: ts.isPropertyDeclaration(m) && fnInit === undefined,
            signatures: [params],
            body: ts.isPropertyDeclaration(m) ? fnInit : m.body,
            file,
          },
          ts.isMethodDeclaration(m) && m.body === undefined,
        )
      }
    }
    const visitNode = (n: ts.Node): void => {
      if (ts.isClassDeclaration(n) || ts.isClassExpression(n)) {
        const owner =
          n.name?.text ??
          (ts.isVariableDeclaration(n.parent) && ts.isIdentifier(n.parent.name)
            ? n.parent.name.text
            : undefined)
        if (owner !== undefined) classMembers(owner, n)
      }
      if (
        ts.isFunctionDeclaration(n) &&
        n.parent === sf &&
        n.name !== undefined &&
        (ts.getCombinedModifierFlags(n) & ts.ModifierFlags.Export) !== 0
      ) {
        put(
          functions,
          {
            label: `${n.name.text}()`,
            owner: '',
            name: n.name.text,
            hidden: hiddenReason(n, false),
            field: false,
            signatures: [paramsOf(n.parameters, sf)],
            body: n.body,
            file,
          },
          n.body === undefined,
        )
      }
      ts.forEachChild(n, visitNode)
    }
    visitNode(sf)
  }
  return { members, functions }
}

/** `node` 본문이 부르는 이름 전부(`x.name(` · `name(` · `this.#name(`). */
function callsIn(node: ts.Node | undefined): Array<{ name: string; onThis: boolean }> {
  const out: Array<{ name: string; onThis: boolean }> = []
  const walk = (n: ts.Node): void => {
    if (ts.isCallExpression(n)) {
      const e = n.expression
      if (ts.isIdentifier(e)) out.push({ name: e.text, onThis: false })
      else if (ts.isPropertyAccessExpression(e))
        out.push({ name: e.name.text, onThis: e.expression.kind === ts.SyntaxKind.ThisKeyword })
    }
    ts.forEachChild(n, walk)
  }
  if (node !== undefined) walk(node)
  return out
}

/** 공개 입구가 (같은 클래스의 비공개 멤버를 따라) 부르는 이름 전부. */
function entryCalls(src: Source, owner: string, name: string): Set<string> {
  const out = new Set<string>()
  const seen = new Set<string>()
  const follow = (member: string): void => {
    if (seen.has(member)) return
    seen.add(member)
    const m = src.members.get(`${owner}#${member}`) ?? src.members.get(`${owner}.${member}`)
    for (const c of callsIn(m?.body)) {
      out.add(c.name)
      if (c.onThis) follow(c.name)
    }
  }
  follow(name)
  return out
}

// ---- 선언 집합 ----

type RowKind = 'method' | 'get' | 'function'

interface Row {
  readonly label: string
  readonly owner: string
  readonly name: string
  readonly kind: RowKind
  /** 정적 멤버·모듈 함수는 수신자가 없다(생성자·함수 자신을 부른다) */
  readonly isStatic: boolean
  readonly key: string | symbol
  readonly params: ReadonlyArray<Param> | undefined
  readonly ctor: ClassCtor | undefined
  readonly fn: unknown
  /** 소스에만 있고 리플렉션이 못 닿은 행 — 부를 수 없다 */
  readonly unreached?: boolean
}

/**
 * 잘 알려진 심볼은 이름으로 적는다 — ⚠️ node 22 의 `Symbol.asyncDispose` 는 description 이 `nodejs.asyncDispose`
 * 라(실측) 소스의 `[Symbol.asyncDispose]` 와 description 으로는 안 맞는다.
 */
const WELL_KNOWN = new Map<symbol, string>(
  Object.getOwnPropertyNames(Symbol).flatMap((n) => {
    const v: unknown = Reflect.get(Symbol, n)
    return typeof v === 'symbol' ? [[v, `Symbol.${n}`] as const] : []
  }),
)

function keyLabel(k: string | symbol): string {
  if (typeof k === 'string') return k
  return `[${WELL_KNOWN.get(k) ?? k.description ?? ''}]`
}

interface Declared {
  readonly rows: Row[]
  /** 리플렉션에 보였지만 소스가 비공개로 적어 뺀 멤버 */
  readonly excluded: string[]
  /**
   * 그 멤버들도 런타임엔 부를 수 있다(TS `private`·`@internal` 은 타입에서만 숨는다). 선언 집합에는 넣지 않되
   * 따로 분류해 IdP 에 닿는 것은 이유를 요구한다(`HIDDEN_REACH_EXEMPT`) — 숨긴 교환 경로가 조용히 빠지지 않게.
   */
  readonly hidden: Row[]
}

async function deriveDeclared(src: Source): Promise<Declared> {
  // 뿌리·걷기는 facade-dump.test.ts 와 **같은 것**이다(facade-walk.ts).
  const d = await dumpRoots()
  const w = newWalk(new Set(declaredClasses().names.keys()))
  try {
    for (const [name, value] of d.roots) visit(value, name, name, w)
  } finally {
    await d.idp.close()
  }
  const types = new Map<string, { ctor: ClassCtor; value: object | undefined }>()
  for (const [name, f] of w.found) types.set(name, { ctor: f.ctor, value: f.value })
  for (const [name, v] of Object.entries(BARREL)) {
    if (isClass(v) && !types.has(name)) types.set(name, { ctor: v as ClassCtor, value: undefined })
  }
  const rows: Row[] = []
  const excluded: string[] = []
  const hidden: Row[] = []
  const emit = (base: Omit<Row, 'label' | 'params'>, label: string, fnLength: number): void => {
    const m = src.members.get(label) ?? src.functions.get(label)
    const sigs = m?.signatures ?? []
    // 소스에 없는 멤버(런타임에만 붙은 것)는 인자 수만 안다 — 전부 보편 인자다.
    const lengthOnly = Array.from({ length: fnLength }, (_, i): Param => ({
      name: `arg${i}`,
      kind: 'string',
    }))
    if (m?.hidden !== undefined) {
      excluded.push(`${label} (${m.hidden})`)
      hidden.push({ ...base, label, params: sigs[0] ?? lengthOnly })
      return
    }
    if (sigs.length <= 1) {
      rows.push({ ...base, label, params: sigs[0] ?? lengthOnly })
      return
    }
    // 오버로드는 서명마다 한 행이다.
    sigs.forEach((params, i) => rows.push({ ...base, label: `${label}/${i + 1}`, params }))
  }
  for (const [owner, { ctor, value }] of types) {
    const proto = (ctor as unknown as { prototype: object }).prototype
    for (const key of Reflect.ownKeys(proto)) {
      if (key === 'constructor') continue
      const desc = Object.getOwnPropertyDescriptor(proto, key)
      if (desc === undefined) continue
      const kind: RowKind | undefined =
        typeof desc.value === 'function' ? 'method' : desc.get !== undefined ? 'get' : undefined
      if (kind === undefined) continue
      const fnLen = typeof desc.value === 'function' ? (desc.value as () => void).length : 0
      emit(
        { owner, name: keyLabel(key), kind, isStatic: false, key, ctor, fn: undefined },
        `${owner}#${keyLabel(key)}`,
        fnLen,
      )
    }
    for (const key of Reflect.ownKeys(ctor)) {
      if (key === 'length' || key === 'name' || key === 'prototype') continue
      const desc = Object.getOwnPropertyDescriptor(ctor, key)
      if (desc === undefined) continue
      const kind: RowKind | undefined =
        typeof desc.value === 'function' ? 'method' : desc.get !== undefined ? 'get' : undefined
      if (kind === undefined) continue
      const fnLen = typeof desc.value === 'function' ? (desc.value as () => void).length : 0
      emit(
        { owner, name: keyLabel(key), kind, isStatic: true, key, ctor, fn: undefined },
        `${owner}.${keyLabel(key)}`,
        fnLen,
      )
    }
    // 인스턴스의 함수 값 필드(`readonly exchange = async () => …`) — 프로토타입에 없어 따로 본다.
    if (value !== undefined) {
      for (const key of Reflect.ownKeys(value)) {
        const desc = Object.getOwnPropertyDescriptor(value, key)
        if (desc === undefined || typeof desc.value !== 'function') continue
        emit(
          { owner, name: keyLabel(key), kind: 'method', isStatic: false, key, ctor, fn: undefined },
          `${owner}#${keyLabel(key)}`,
          (desc.value as () => void).length,
        )
      }
    }
  }
  for (const [name, v] of Object.entries(BARREL)) {
    if (typeof v !== 'function' || isClass(v)) continue
    emit(
      { owner: '', name, kind: 'function', isStatic: true, key: name, ctor: undefined, fn: v },
      `${name}()`,
      (v as () => void).length,
    )
  }
  // 소스에 선언된 공개 멤버 중 리플렉션이 못 닿은 것 — 부를 수 없으니 UNDETERMINED 행이다.
  const seen = new Set(rows.map((r) => r.label.replace(/\/\d+$/, '')))
  for (const m of src.members.values()) {
    if (m.hidden !== undefined || m.field || seen.has(m.label)) continue
    rows.push({
      label: m.label,
      owner: m.owner,
      name: m.name,
      kind: 'method',
      isStatic: m.label.includes('.'),
      key: m.name,
      params: m.signatures[0],
      ctor: undefined,
      fn: undefined,
      unreached: true,
    })
  }
  rows.sort((a, b) => (a.label < b.label ? -1 : a.label > b.label ? 1 : 0))
  hidden.sort((a, b) => (a.label < b.label ? -1 : a.label > b.label ? 1 : 0))
  return { rows, excluded: excluded.sort(), hidden }
}

// ---- 수신자 ----

/**
 * 수신자를 얻는 공개 API 뿌리 — **덜 데운 것부터**. 타입은 자기를 처음 닿게 하는 빌더의 새 인스턴스에서
 * 불린다(`KeycloakClient#admin` 은 admin 이 아직 없는 `create` 에서). 어느 빌더에도 안 닿는 타입은 영값
 * 수신자다 — 상태가 필요한 새 타입이면 그 호출이 요청 없이 실패해 UNDETERMINED 로 드러난다.
 */
const BUILDERS: ReadonlyArray<{ name: string; build: (idp: HpIdp) => Promise<unknown> }> = [
  { name: 'create', build: async (idp) => KeycloakClient.create(idp.input()) },
  {
    name: 'create+admin()',
    build: async (idp) => {
      const kc = KeycloakClient.create(idp.input())
      return { kc, admin: await kc.admin() }
    },
  },
  {
    name: 'forJwksUri',
    build: async (idp) => JwtValidator.forJwksUri(idp.certsUri(), idp.validatorOpts()),
  },
  {
    name: 'new provider',
    build: async (idp) =>
      new ClientCredentialsTokenProvider(new AuthClient(defineConfig(idp.input()))),
  },
  {
    name: 'auth values',
    build: async (idp) => {
      const kc = KeycloakClient.create(idp.input())
      return {
        ts: await kc.auth.clientCredentialsToken(),
        ar: kc.auth.createAuthorizationRequest(URL_ARG),
      }
    },
  },
]

function walkFound(root: unknown, name: string): Map<string, { value: object }> {
  const w = newWalk(new Set(declaredClasses().names.keys()))
  visit(root, name, name, w)
  return w.found
}

async function probeBuilders(): Promise<Map<string, number>> {
  const builderOf = new Map<string, number>()
  for (const [i, b] of BUILDERS.entries()) {
    const idp = await srv.open(`probe:${b.name}`)
    try {
      for (const name of walkFound(await b.build(idp), b.name).keys()) {
        if (!builderOf.has(name)) builderOf.set(name, i)
      }
    } finally {
      await idp.close()
    }
  }
  return builderOf
}

/** 이 IdP 위에 새로 만든 뿌리에서 수신자를 꺼낸다. 정적 멤버는 생성자, 모듈 함수는 수신자가 없다. */
async function receiver(
  row: Row,
  idp: HpIdp,
  builderOf: Map<string, number>,
): Promise<{ recv: unknown; src: string }> {
  if (row.kind === 'function') return { recv: undefined, src: 'module' }
  if (row.isStatic) return { recv: row.ctor, src: 'static' }
  const i = builderOf.get(row.owner)
  if (i === undefined) {
    const proto = (row.ctor as unknown as { prototype: object }).prototype
    return { recv: Object.create(proto) as unknown, src: 'zero' }
  }
  const b = BUILDERS[i] as (typeof BUILDERS)[number]
  const v = walkFound(await b.build(idp), b.name).get(row.owner)
  if (v === undefined)
    throw new Error(`${row.label}: 빌더 ${b.name} 가 탐침 때는 닿았는데 지금은 안 닿는다`)
  return { recv: v.value, src: b.name }
}

// ---- 인자 합성 · 호출 ----

/**
 * SDK 타입 파라미터 — 그 타입의 값을 이 IdP 위에 새로 만든다. 표에 없는 타입은 `{}` 다(go 의 영값) — 그 값으로
 * 요청 앞에서 실패하는 새 메서드는 UNDETERMINED 로 드러난다.
 */
const SDK_ARGS: Readonly<Record<string, (idp: HpIdp) => unknown>> = {
  KeycloakConfigInput: (idp) => idp.input(),
  KeycloakConfig: (idp) => defineConfig(idp.input()),
  TokenSource: (idp) => new AuthClient(defineConfig(idp.input())),
  TokenProvider: (idp) =>
    new ClientCredentialsTokenProvider(new AuthClient(defineConfig(idp.input()))),
  JwtValidatorOptions: (idp) => idp.validatorOpts(),
}

function argFor(p: Param, idp: HpIdp): unknown {
  switch (p.kind) {
    case 'string':
      return /(?:uri|url)$/i.test(p.name) ? URL_ARG : idp.universal
    case 'number':
      return 1
    case 'boolean':
      return false
  }
  const make = p.ref === undefined ? undefined : SDK_ARGS[p.ref]
  return make === undefined ? {} : make(idp)
}

interface Outcome {
  readonly threw: boolean
  readonly err: unknown
}

/** `blank` 에 든 위치(0 부터)는 `undefined` 다 — W3a 가 nonce 파라미터를 비워 id_token 검증을 끈다. */
async function invoke(
  row: Row,
  recv: unknown,
  idp: HpIdp,
  blank: ReadonlySet<number> = new Set(),
): Promise<Outcome> {
  try {
    const args = (row.params ?? []).map((p, i) => (blank.has(i) ? undefined : argFor(p, idp)))
    let r: unknown
    if (row.kind === 'function') {
      r = Reflect.apply(row.fn as (...a: unknown[]) => unknown, undefined, args)
    } else if (row.kind === 'get') {
      r = Reflect.get(recv as object, row.key)
      // 함수를 돌려주는 접근자는 그 함수까지 부른다 — 읽기만 하면 그 안의 교환이 NONE 으로 읽힌다(Grok 레그 지목,
      // 실측 SILENT). 소스 서명이 없으면 인자 수만큼 보편 인자다.
      if (typeof r === 'function') {
        const f = r as (...a: unknown[]) => unknown
        const ps =
          row.params !== undefined && row.params.length > 0
            ? row.params
            : Array.from({ length: f.length }, (_, i): Param => ({
                name: `arg${i}`,
                kind: 'string',
              }))
        r = Reflect.apply(
          f,
          recv,
          ps.map((p, i) => (blank.has(i) ? undefined : argFor(p, idp))),
        )
      }
    } else {
      const f: unknown = Reflect.get(recv as object, row.key)
      if (typeof f !== 'function') throw new TypeError(`${row.label} 는 함수가 아니다`)
      r = Reflect.apply(f as (...a: unknown[]) => unknown, recv, args)
    }
    if (r instanceof Promise) await r
    return { threw: false, err: undefined }
  } catch (e) {
    return { threw: true, err: e }
  }
}

// ---- 분류 ----

const isDiscovery = (r: Req): boolean => r.method === 'GET' && r.path.endsWith(DISCOVERY_SUFFIX)
/**
 * 토큰 요청 — 토큰 엔드포인트(꼬리)로 간 POST, 또는 **경로가 무엇이든** grant_type 을 실은 POST. ⚠️ 꼬리만 보면
 * 다른 경로로 보낸 교환이 OTHER 로 읽혀 W3 가 안 붙는다(Grok 레그 지목, 실측 SILENT).
 */
const isTokenPost = (r: Req): boolean =>
  r.method === 'POST' && (r.path.endsWith(TOKEN_SUFFIX) || r.grant !== '')
const isCertsGet = (r: Req): boolean => r.method === 'GET' && r.path.endsWith(CERTS_SUFFIX)
const count = (reqs: readonly Req[], pred: (r: Req) => boolean): number => reqs.filter(pred).length

/**
 * 요청으로 가른다. 앞 줄이 이긴다: 코드 교환 > 토큰 부여 > JWKS 조회 > 그 밖의 요청 > 요청 없음.
 * 토큰 요청은 grant_type 이 무엇이든 TOKEN_GRANT 다(새 grant 가 OTHER 로 새지 않게).
 * ⚠️ discovery GET 은 세지 않는다 — 머리 주석.
 */
function classify(reqs: readonly Req[], failed: boolean): string {
  const counted = reqs.filter((r) => !isDiscovery(r))
  if (counted.some((r) => r.method === 'POST' && r.grant === 'authorization_code'))
    return CODE_EXCHANGE
  if (counted.some(isTokenPost)) return TOKEN_GRANT
  if (counted.some(isCertsGet)) return JWKS_FETCH
  if (counted.length > 0) return OTHER
  return failed ? UNDETERMINED : NONE
}

function formatReqs(reqs: readonly Req[], universal: string): string {
  if (reqs.length === 0) return '-'
  const order: string[] = []
  const n = new Map<string, number>()
  for (const r of reqs) {
    let p = r.path
      .replace(/\/realms\/r\d+(?=\/|$)/, '/realms/r')
      .replace(/^\/realms\/r(?=\/)/, '')
      .replace(OIDC, '')
    if (universal !== '') p = p.split(universal).join('{U}')
    const k = `${r.method} ${p}${r.grant !== '' ? `[${r.grant}]` : ''}`
    if (!n.has(k)) order.push(k)
    n.set(k, (n.get(k) ?? 0) + 1)
  }
  return order.map((k) => ((n.get(k) ?? 0) > 1 ? `${k} ×${n.get(k)}` : k)).join(', ')
}

interface ClassRow {
  readonly row: Row
  readonly cls: string
  readonly reqs: string
  readonly recv: string
  readonly outcome: string
  readonly note: string
  readonly sent: readonly Req[]
}

function errName(e: unknown): string {
  if (e instanceof Error) return `${e.name}: ${e.message}`
  return `non-Error ${typeof e}`
}

async function classifyRow(row: Row, builderOf: Map<string, number>): Promise<ClassRow> {
  if (row.unreached === true) {
    return {
      row,
      cls: UNDETERMINED,
      reqs: '-',
      recv: '없음',
      outcome: '-',
      note: ' · 걷기·배럴이 닿지 않는 멤버라 수신자가 없다(facade-walk.ts 의 뿌리에 닿게 하거나 이유와 함께 면제하라)',
      sent: [],
    }
  }
  const idp = await srv.open(row.label)
  try {
    const { recv, src } = await receiver(row, idp, builderOf)
    idp.reqs.length = 0 // 뿌리를 만들며 나간 요청(admin 로그인 등)은 이 메서드의 몫이 아니다
    const out = await invoke(row, recv, idp)
    const sent = [...idp.reqs]
    const cls = classify(sent, out.threw)
    return {
      row,
      cls,
      reqs: formatReqs(sent, idp.universal),
      recv: src,
      outcome: out.threw ? 'err' : 'ok',
      // 사유는 분류를 못 한 행에만 — 요청을 낸 행의 오류(admin 404 등)는 분류와 무관하다.
      note: cls === UNDETERMINED ? ` · ${errName(out.err)}` : '',
      sent,
    }
  } finally {
    await idp.close()
  }
}

// ---- SDK 오류 · 렌더링 ----

/** `errors.ts` 가 선언한 클래스 — SDK 오류 계급을 손으로 적지 않는다. */
function sdkErrorCtors(): ReadonlyArray<ClassCtor> {
  const out: ClassCtor[] = []
  for (const [name, file] of declaredClasses().names) {
    const v = BARREL[name]
    if (file === 'errors.ts' && isClass(v)) out.push(v as ClassCtor)
  }
  if (out.length === 0) throw new Error('errors.ts 에서 SDK 오류 클래스를 하나도 못 읽었다')
  return out
}

function safe(fn: () => string | undefined): string {
  try {
    return fn() ?? 'undefined'
  } catch (e) {
    return `<throws ${e instanceof Error ? e.message : 'non-error'}>`
  }
}

/** 오류의 문자열·디버그 렌더링과 원인 사슬의 각 고리 — 카나리아가 어디에도 없어야 한다. */
function renderings(err: unknown): Array<readonly [string, string]> {
  const out: Array<readonly [string, string]> = [
    ['String', safe(() => String(err))],
    ['util.inspect', inspect(err)],
    ['util.inspect(depth∞·hidden)', inspect(err, { depth: Infinity, showHidden: true })],
    ["util.format('%o')", format('%o', err)],
    ['JSON.stringify', safe(() => JSON.stringify(err))],
  ]
  let link: unknown = err
  for (let i = 0; link instanceof Error && i < 16; i += 1) {
    out.push([`cause[${i}].message`, link.message], [`cause[${i}].stack`, link.stack ?? ''])
    link = link.cause
  }
  return out
}

// ---- W3 ----

interface Variant {
  readonly code: string
  /** 이 변형을 단언하는 기존 테스트(`파일|선언`) — 비면 측정만 한다 */
  readonly from: string
  readonly canaries: readonly string[]
  readonly resp: HostileResp
}

const RT_CANARY = 'LEAK-HP-RT'
const MALFORMED_ANCHOR =
  'auth-malformed-token-response.test.ts|%s — 기본·깊은 inspect 어디에도 토큰이 없다'
const NON_STRING_ANCHOR = 'tokens.test.ts|access_token 이 비문자열·빈 문자열이면 throw'
const MISSING_ANCHOR = "tokens.test.ts|it('access_token 없으면 throw'"

/**
 * 변형 집합을 새로 만들지 않고 기존 테스트에서 가져온다(`token-responses.ts` — 단언하는 테스트가 같은 표를 쓴다).
 *   - `MALFORMED_TOKEN_RESPONSES` 다섯 — `auth-malformed-token-response.test.ts` 가 단언한다.
 *   - `NON_STRING_ACCESS_TOKENS` 여섯 + 키 없음 — `tokens.test.ts` 가 매퍼에서 단언한다. go 의 `ccAccessTokenCases`
 *     처럼 refresh_token 카나리아를 더한다(누출 검사가 공허하지 않게).
 *
 * ⚠️ 공허 함정(go 와 같다): 이 본문들엔 쓸 수 있는 id_token 이 없다. nonce 를 준 `exchangeCode` 는 정상 토큰
 * 응답이어도 「missing id_token」으로 실패하므로 적대 응답이 안 닿아도 통과한다 — 그래서 W3a 는 nonce 파라미터를
 * 비워 id_token 검증을 끄고 **토큰 응답 형식만** 잰다. nonce 는 W3b 가 따로 잰다.
 */
function tokenVariants(): Variant[] {
  const out: Variant[] = []
  for (const [name, v] of Object.entries(MALFORMED_TOKEN_RESPONSES)) {
    const values = typeof v === 'string' ? [v] : Object.values(v)
    out.push({
      // 열 이름 — 본문이 JSON 이 아니면 `non-json`, 아니면 틀린 필드 이름(표 제목의 첫 낱말).
      code: typeof v === 'string' ? 'mt:non-json' : `mt:${name.split(' ')[0] ?? name}`,
      from: MALFORMED_ANCHOR,
      canaries: values.filter((x): x is string => typeof x === 'string' && x.startsWith('LEAK')),
      resp: { status: 200, body: typeof v === 'string' ? v : JSON.stringify(v) },
    })
  }
  for (const [label, value] of NON_STRING_ACCESS_TOKENS) {
    out.push({
      code: `at:${label.replace(/ /g, '_')}`,
      from: NON_STRING_ANCHOR,
      canaries: [RT_CANARY],
      resp: {
        status: 200,
        body: JSON.stringify({
          access_token: value,
          token_type: 'Bearer',
          expires_in: 300,
          refresh_token: RT_CANARY,
        }),
      },
    })
  }
  out.push({
    code: 'at:missing',
    from: MISSING_ANCHOR,
    canaries: [RT_CANARY],
    resp: {
      status: 200,
      body: JSON.stringify({ token_type: 'Bearer', expires_in: 300, refresh_token: RT_CANARY }),
    },
  })
  return out
}

/** W3a 대조 — 변형들과 같은 모양(id_token 없음)의 쓸 수 있는 토큰 응답이다. */
const WELL_FORMED: HostileResp = {
  status: 200,
  body: '{"access_token":"hp-access","token_type":"Bearer","expires_in":300,"refresh_token":"hp-refresh"}',
}

interface Cell {
  readonly axis: 'a' | 'b' | 'c'
  readonly label: string
  readonly variant: string
  readonly why: string[]
  readonly measure: boolean
  note: string
}

const cellKey = (c: Pick<Cell, 'axis' | 'label' | 'variant'>): string =>
  `W3${c.axis} ${c.label}/${c.variant}`

interface CellRun {
  readonly sent: readonly Req[]
  readonly out: Outcome
}

/** 수신자를 정상 응답으로 만든 **뒤에** 토큰 응답을 바꾸고(undefined 면 정상 그대로) 한 번 부른다. */
async function runCell(
  row: Row,
  builderOf: Map<string, number>,
  blank: ReadonlySet<number>,
  resp: (idp: HpIdp) => Promise<HostileResp | undefined>,
): Promise<CellRun> {
  const idp = await srv.open(row.label)
  try {
    const { recv } = await receiver(row, idp, builderOf)
    idp.reqs.length = 0
    idp.tokenResp = await resp(idp)
    const out = await invoke(row, recv, idp, blank)
    return { sent: [...idp.reqs], out }
  } finally {
    await idp.close()
  }
}

/** 토큰 요청 수와, 첫 토큰 요청 **뒤에** 나간 토큰 아닌 요청. */
function afterToken(reqs: readonly Req[]): { hits: number; after: Req[] } {
  let hits = 0
  const after: Req[] = []
  for (const r of reqs) {
    if (isTokenPost(r)) hits += 1
    else if (hits > 0) after.push(r)
  }
  return { hits, after }
}

function isSdkError(e: unknown, sdk: ReadonlyArray<ClassCtor>): boolean {
  return sdk.some((c) => e instanceof c)
}

/** 적대 토큰 응답 한 칸의 실패 사유 — 비면 통과. `ctlHits` 는 같은 행의 대조가 낸 토큰 요청 수다. */
function hostileWhy(
  run: CellRun,
  canaries: readonly string[],
  sdk: ReadonlyArray<ClassCtor>,
  ctlHits: number,
  withIdToken: boolean,
): string[] {
  const why: string[] = []
  const { out } = run
  if (!out.threw) why.push('오류 없이 성공했다')
  else if (!(out.err instanceof Error))
    why.push(`크래시: 오류가 아닌 값이 던져졌다(${typeof out.err})`)
  else {
    if (!isSdkError(out.err, sdk)) why.push(`SDK 오류 타입이 아니다: ${errName(out.err)}`)
    for (const [how, text] of renderings(out.err)) {
      for (const cn of canaries) {
        if (text.includes(cn)) why.push(`카나리아 ${cn} 가 ${how} 에 찍혔다`)
      }
    }
  }
  const { hits, after } = afterToken(run.sent)
  if (hits === 0) why.push('토큰 엔드포인트에 한 번도 안 닿았다 — 변형이 공허하다')
  // 하한만 두면 틀린 응답마다 재시도하는 새 메서드가 통과한다. 상한은 손 상수가 아니라 같은 행의 대조다.
  if (hits > ctlHits)
    why.push(
      `토큰 요청 ${hits} 건 — 정상 응답 대조(${ctlHits} 건)보다 많다: 틀린 응답이 재시도를 부른다`,
    )
  // `[nonce]` 판의 JWKS 조회는 끼운 id_token 을 **검증**하는 것이지 응답을 믿고 나아간 것이 아니다 — 서명을 먼저 보고
  // 형식을 나중에 보는 구현도 안전하다. 성공 여부는 위에서 따로 본다.
  const onward = after.filter((r) => !(withIdToken && isCertsGet(r)))
  if (onward.length > 0) why.push(`적대 토큰 응답 뒤로 나아갔다: ${formatReqs(onward, '')}`)
  return why
}

/**
 * JSON 객체 본문에 id_token 이 없으면 이 칸의 맞는 id_token(nonce = 보편 인자)을 끼운다 — W3a 의 nonce 판에서 변형이
 * 「id_token 없음」이 아니라 **자기 형식 때문에** 실패하게. id_token 을 이미 든 변형과 JSON 이 아닌 본문은 그대로다.
 */
function withIdToken(resp: HostileResp, idp: HpIdp): HostileResp {
  let body: unknown
  try {
    body = JSON.parse(resp.body)
  } catch {
    return resp
  }
  if (body === null || typeof body !== 'object' || Array.isArray(body) || 'id_token' in body)
    return resp
  return { ...resp, body: JSON.stringify({ ...body, id_token: idp.idToken }) }
}

async function runVariantsA(
  rows: readonly Row[],
  builderOf: Map<string, number>,
  nonceParams: Map<string, number[]>,
  sdk: ReadonlyArray<ClassCtor>,
): Promise<Cell[]> {
  const variants = tokenVariants()
  const cells: Cell[] = []
  for (const row of rows) {
    const nonce = nonceParams.get(row.label) ?? []
    // 첫 판은 nonce 파라미터를 비운다(위 공허 함정). nonce 파라미터가 있는 행은 둘째 판(`[nonce]`)을 더 돈다 —
    // nonce 를 채우고 변형마다 맞는 id_token 을 끼운다. 첫 판만으로는 **nonce 가 있을 때만** 도는 분기가 토큰 응답
    // 형식을 안 봐도 통과한다(Grok 레그 지목, 실측 SILENT).
    const passes = [{ label: row.label, blank: new Set(nonce), withId: false }]
    if (nonce.length > 0)
      passes.push({ label: `${row.label}[nonce]`, blank: new Set<number>(), withId: true })
    for (const pass of passes) {
      const shape = (resp: HostileResp, idp: HpIdp): HostileResp =>
        pass.withId ? withIdToken(resp, idp) : resp
      // 대조 — 변형과 **같은 모양의** 정상 응답. 성공하면 「오류다」가, 토큰 뒤로 나아가면(admin 자원 → 404)
      // 「뒤로 안 나아갔다」가 무게를 진다. 둘 다 아니면 행 전체가 공허하다.
      const ctlRun = await runCell(row, builderOf, pass.blank, async (idp) =>
        shape(WELL_FORMED, idp),
      )
      const { hits, after } = afterToken(ctlRun.sent)
      const ctl: Cell = {
        axis: 'a',
        label: pass.label,
        variant: '대조',
        why: [],
        measure: false,
        note: '',
      }
      if (ctlRun.out.threw && !(ctlRun.out.err instanceof Error))
        ctl.why.push('정상 응답에 크래시(오류가 아닌 값)')
      else if (hits === 0)
        ctl.why.push('정상 응답에서 토큰 엔드포인트에 안 닿았다 — 이 행의 변형은 공허하다')
      else if (ctlRun.out.threw && after.length === 0)
        ctl.why.push(
          `정상 응답에 실패했고 토큰 뒤로 나아가지도 않았다 — 변형이 무엇을 바꿨는지 가를 수 없다: ${errName(ctlRun.out.err)}`,
        )
      ctl.note = ctlRun.out.threw ? `↓${after.length}` : 'ok'
      cells.push(ctl)
      for (const v of variants) {
        const run = await runCell(row, builderOf, pass.blank, async (idp) => shape(v.resp, idp))
        const c: Cell = {
          axis: 'a',
          label: pass.label,
          variant: v.code,
          why: hostileWhy(run, v.canaries, sdk, hits, pass.withId),
          measure: v.from === '',
          note: '',
        }
        if (c.measure) c.note = run.out.threw ? (errName(run.out.err).split(':')[0] ?? '') : 'ok'
        cells.push(c)
      }
    }
  }
  return cells
}

/**
 * W3b 의 변형 — 대조(맞는 id_token)와 다섯. 다른 키로 서명할 때 kid 가 k1 이면 캐시된 키로 서명 검증이 실패하고,
 * k2 면 키를 못 찾는다. `reachJwks` 는 그 칸이 JWKS 에 닿아야 하는가다(머리 주석 — nonce 대조는 openid-client 가
 * 검증기 앞에서 한다).
 */
const NONCE_VARIANTS: ReadonlyArray<{
  code: string
  kid: string
  otherKey: boolean
  /** undefined 면 `{ nonce: 보편 인자 }`(= 호출에 넘긴 nonce) */
  claims: Record<string, unknown> | undefined
  noIdToken: boolean
  want: 'ok' | 'reject'
  reachJwks: boolean
  alg?: 'HS256' | 'none'
}> = [
  {
    code: '대조',
    kid: 'k1',
    otherKey: false,
    claims: undefined,
    noIdToken: false,
    want: 'ok',
    reachJwks: true,
  },
  {
    code: 'nonce≠',
    kid: 'k1',
    otherKey: false,
    claims: { nonce: 'hp-other-nonce' },
    noIdToken: false,
    want: 'reject',
    reachJwks: false,
  },
  {
    code: 'key≠·kid=k1',
    kid: 'k1',
    otherKey: true,
    claims: undefined,
    noIdToken: false,
    want: 'reject',
    reachJwks: true,
  },
  {
    code: 'key≠·kid=k2',
    kid: 'k2',
    otherKey: true,
    claims: undefined,
    noIdToken: false,
    want: 'reject',
    reachJwks: true,
  },
  {
    code: 'id_token없음',
    kid: '',
    otherKey: false,
    claims: undefined,
    noIdToken: true,
    want: 'reject',
    reachJwks: false,
  },
  {
    code: 'nonce클레임없음',
    kid: 'k1',
    otherKey: false,
    claims: {},
    noIdToken: false,
    want: 'reject',
    reachJwks: false,
  },
  // 알고리즘 — 위 칸은 전부 RS256 이라, RS256 일 때만 서명을 보는 교환이 통과한다(Grok 레그 지목, 실측 SILENT).
  // HS256 은 client_secret 으로 서명한다(Keycloak 이 광고하는 알고리즘이라 openid-client 는 통과시킨다 — 거절은
  // SDK 검증기의 alg 핀 몫이다). 둘 다 alg 핀에서 키 조회 **전에** 거절되므로 JWKS 에 닿지 않는다.
  {
    code: 'alg=HS256',
    kid: '',
    otherKey: false,
    claims: undefined,
    noIdToken: false,
    want: 'reject',
    reachJwks: false,
    alg: 'HS256',
  },
  {
    code: 'alg=none',
    kid: '',
    otherKey: false,
    claims: undefined,
    noIdToken: false,
    want: 'reject',
    reachJwks: false,
    alg: 'none',
  },
]

/** W3b 의 id_token — `alg` 가 있으면 RS256 대신 그 알고리즘이다(HS256 은 client_secret, none 은 서명 없음). */
function nonceIdToken(
  nv: (typeof NONCE_VARIANTS)[number],
  idp: HpIdp,
  signer: CryptoKey,
): Promise<string> {
  const claims = nv.claims ?? { nonce: idp.universal }
  if (nv.alg === 'none') {
    return Promise.resolve(
      new UnsecuredJWT(claims)
        .setIssuer(idp.iss)
        .setSubject('u1')
        .setAudience(CLIENT_ID)
        .setIssuedAt()
        .setExpirationTime('5m')
        .encode(),
    )
  }
  if (nv.alg === 'HS256') {
    return new SignJWT(claims)
      .setProtectedHeader({ alg: 'HS256', typ: 'JWT' })
      .setIssuer(idp.iss)
      .setSubject('u1')
      .setAudience(CLIENT_ID)
      .setIssuedAt()
      .setExpirationTime('5m')
      .sign(new TextEncoder().encode(CLIENT_SECRET))
  }
  return sign(signer, nv.kid, idp.iss, claims)
}

async function runNonceB(
  rows: readonly Row[],
  keys: Keys,
  builderOf: Map<string, number>,
  sdk: ReadonlyArray<ClassCtor>,
): Promise<Cell[]> {
  const cells: Cell[] = []
  for (const row of rows) {
    for (const nv of NONCE_VARIANTS) {
      const run = await runCell(row, builderOf, new Set(), async (idp) => {
        const body: Record<string, unknown> = {
          access_token: 'hp-access',
          token_type: 'Bearer',
          expires_in: 300,
          refresh_token: 'hp-refresh',
        }
        if (!nv.noIdToken) {
          body['id_token'] = await nonceIdToken(nv, idp, nv.otherKey ? keys.other : keys.priv)
        }
        return { status: 200, body: JSON.stringify(body) }
      })
      const certs = count(run.sent, isCertsGet)
      const c: Cell = {
        axis: 'b',
        label: row.label,
        variant: nv.code,
        why: [],
        measure: false,
        note: `certs ${certs}`,
      }
      const { out } = run
      if (out.threw && !(out.err instanceof Error))
        c.why.push(`크래시: 오류가 아닌 값(${typeof out.err})`)
      if (count(run.sent, isTokenPost) === 0)
        c.why.push('토큰 엔드포인트에 안 닿았다 — 변형이 공허하다')
      if (nv.reachJwks && certs === 0)
        c.why.push('JWKS 를 조회하지 않았다 — id_token 이 서명 검증기에 닿지 않았다')
      if (nv.want === 'ok' && out.threw)
        c.why.push(
          `맞는 id_token 에 실패했다 — 아래 변형의 실패가 아무것도 증명하지 않는다: ${errName(out.err)}`,
        )
      if (nv.want === 'reject' && !out.threw) c.why.push('틀린 id_token 을 받아들였다')
      if (
        nv.want === 'reject' &&
        out.threw &&
        out.err instanceof Error &&
        !isSdkError(out.err, sdk)
      )
        c.why.push(`SDK 오류 타입이 아니다: ${errName(out.err)}`)
      cells.push(c)
    }
  }
  return cells
}

/** 콜드 캐시 JWKS 칸의 호출 수 — 상한 k−1 이 백오프, 하한 1 이 콜드 경로 도달의 증명이다. */
const COLD_K = 5

async function runColdC(
  rows: readonly Row[],
  builderOf: Map<string, number>,
  sdk: ReadonlyArray<ClassCtor>,
): Promise<Cell[]> {
  const cells: Cell[] = []
  for (const row of rows) {
    const idp = await srv.open(row.label)
    const c: Cell = {
      axis: 'c',
      label: row.label,
      variant: `503×${COLD_K}`,
      why: [],
      measure: false,
      note: '',
    }
    try {
      const { recv } = await receiver(row, idp, builderOf) // 새 수신자 — 캐시가 비어 있다
      idp.reqs.length = 0
      idp.certsDown = true
      for (let i = 1; i <= COLD_K; i += 1) {
        const out = await invoke(row, recv, idp)
        if (!out.threw) c.why.push(`${i}번째 호출이 JWKS 503 인데 성공했다`)
        else if (!(out.err instanceof Error)) c.why.push(`${i}번째 호출이 크래시(오류가 아닌 값)`)
        else if (!isSdkError(out.err, sdk))
          c.why.push(`${i}번째 호출의 오류가 SDK 오류 타입이 아니다: ${errName(out.err)}`)
      }
      const hits = count(idp.reqs, isCertsGet)
      c.note = `certs ${hits}`
      if (hits < 1) c.why.push(`/certs 요청 ${hits} — 콜드 경로에 닿지 않았다(하한 1)`)
      if (hits > COLD_K - 1)
        c.why.push(`/certs 요청 ${hits} — 실패한 조회가 물러서지 않았다(상한 ${COLD_K - 1})`)
    } finally {
      await idp.close()
    }
    cells.push(c)
  }
  return cells
}

/** 칸마다 통과·GAP·FAIL 을 정하고 판정표·요약을 찍는다. 반환값은 실패 사유(낡은 GAP 포함). */
function judge(axis: Cell['axis'], cells: readonly Cell[]): string[] {
  const fails: string[] = []
  const verdict = new Map<string, string>()
  const observed = new Set<string>()
  for (const c of cells) {
    let v = 'pass'
    if (c.measure) v = c.why.length === 0 ? 'm:rej' : 'm:ACC'
    else if (c.why.length > 0) {
      if (cellKey(c) in KNOWN_GAPS) {
        v = 'GAP'
        observed.add(cellKey(c))
      } else {
        v = 'FAIL'
        fails.push(`${cellKey(c)}: ${c.why.join(' · ')}`)
      }
    }
    if (c.note !== '' && (axis !== 'a' || c.variant === '대조' || c.measure)) v += `(${c.note})`
    verdict.set(cellKey(c), v)
  }
  const labels = [...new Set(cells.map((c) => c.label))]
  const cols = [...new Set(cells.map((c) => c.variant))]
  if (labels.length === 0) {
    console.log(`[hp] W3${axis} 판정표: 대상 행이 없다`)
  } else {
    const width = cols.map((col) =>
      Math.max(
        col.length,
        ...labels.map((l) => (verdict.get(cellKey({ axis, label: l, variant: col })) ?? '').length),
      ),
    )
    const line = (first: string, vals: (i: number) => string): string =>
      [first.padEnd(44), ...cols.map((_, i) => vals(i).padEnd(width[i] ?? 0))].join(' ').trimEnd()
    console.log(
      `[hp] W3${axis} 판정표 — ${labels.length}행 × ${cols.length}열 (pass · GAP=알려진 틈 · FAIL · m:rej/m:ACC=측정만: 거부/받아들임)`,
    )
    console.log(`[hp] ${line('행 \\ 변형', (i) => cols[i] ?? '')}`)
    for (const l of labels) {
      console.log(
        `[hp] ${line(l, (i) => verdict.get(cellKey({ axis, label: l, variant: cols[i] ?? '' })) ?? '')}`,
      )
    }
  }
  for (const [key, reason] of Object.entries(KNOWN_GAPS)) {
    if (key.startsWith(`W3${axis} `) && !observed.has(key))
      fails.push(`KNOWN_GAPS[${key}]: 더는 관측되지 않는다 — 낡은 항목을 지워라(${reason})`)
  }
  const n = new Map<string, number>()
  const failedBy = new Map<string, number>()
  for (const c of cells) {
    const v = (verdict.get(cellKey(c)) ?? '').split('(')[0] ?? ''
    n.set(v, (n.get(v) ?? 0) + 1)
    if (v === 'FAIL') failedBy.set(c.variant, (failedBy.get(c.variant) ?? 0) + 1)
  }
  const get = (k: string): number => n.get(k) ?? 0
  console.log(
    `[hp] W3${axis} 요약: pass ${get('pass')} · GAP ${get('GAP')} · FAIL ${get('FAIL')} · ` +
      `측정 ${get('m:rej') + get('m:ACC')}(m:rej ${get('m:rej')} · m:ACC ${get('m:ACC')}) · ` +
      `FAIL 열 [${[...failedBy].map(([v, k]) => `${v}×${k}`).join(' ')}]`,
  )
  return fails
}

// ---- W1: 손 목록 포함 ----

/**
 * 손으로 고른 node 테스트가 겨누는 메서드 — 파생 집합이 이것 밑으로 **조용히** 줄지 않게 한다. `anchor` 는 그 손
 * 테스트(`파일|선언` — 보안 기본값 가드와 같은 모양), `call` 은 그 테스트 블록이 (파일 안 도우미를 따라) 실제로
 * 부르는 이름이다. `call` 이 행의 이름과 다르면 공개 입구의 소스가 (같은 클래스의 비공개 멤버를 따라) 그것을
 * 부르는지 대조한다. axis: a·b·c = 그 W3 축의 파생 대상에 있어야 한다 · row = 행이고 계급이 맞기만 하면 된다.
 */
const HAND: ReadonlyArray<{
  label: string
  cls: string
  axis: 'a' | 'b' | 'c' | 'row'
  anchor: string
  call: string
}> = [
  // #603 — 형식이 틀린 토큰 응답의 원인 사슬 누출(go 의 causeRun 자리).
  {
    label: 'AuthClient#clientCredentialsToken',
    cls: TOKEN_GRANT,
    axis: 'a',
    anchor: MALFORMED_ANCHOR,
    call: 'clientCredentialsToken',
  },
  {
    label: 'KeycloakClient.create',
    cls: NONE,
    axis: 'row',
    anchor: MALFORMED_ANCHOR,
    call: 'create',
  },
  // 보안 기본값 가드(scripts/test/test-security-defaults.sh)의 node 행위 앵커 — 토큰 타입 · nonce · 백오프.
  {
    label: 'AuthClient#clientCredentialsToken',
    cls: TOKEN_GRANT,
    axis: 'a',
    anchor: NON_STRING_ANCHOR,
    call: 'tokenSetFromResponse',
  },
  {
    label: 'AuthClient#exchangeCode',
    cls: CODE_EXCHANGE,
    axis: 'b',
    anchor:
      "auth.test.ts|it('nonce를 넘기면 expectedNonce로 전달하고 id_token을 SDK 검증기에 태운다'",
    call: 'exchangeCode',
  },
  {
    label: 'AuthClient#exchangeCode',
    cls: CODE_EXCHANGE,
    axis: 'b',
    anchor: "auth-id-token-signature.test.ts|it('대조군: nonce 가 틀리면 거부한다",
    call: 'exchangeCode',
  },
  {
    label: 'AuthClient#exchangeCode',
    cls: CODE_EXCHANGE,
    axis: 'b',
    anchor:
      "auth-id-token-signature.test.ts|it('JWKS 밖 키로 서명된 RS256 id_token 은 nonce 가 맞아도 SDK 검증기에서 거부한다'",
    call: 'exchangeCode',
  },
  {
    label: 'JwtValidator#validate',
    cls: JWKS_FETCH,
    axis: 'c',
    anchor: "jwt-jwks.test.ts|it('20회 검증이 IdP 요청 1건으로 접힌다'",
    call: 'validate',
  },
  {
    label: 'JwtValidator#validate',
    cls: JWKS_FETCH,
    axis: 'c',
    anchor: "jwt-jwks.test.ts|it('대조군 — 백오프 창이 지나면 다시 IdP 로 나간다'",
    call: 'validate',
  },
  {
    label: 'JwtValidator#validate',
    cls: JWKS_FETCH,
    axis: 'c',
    anchor:
      "jwt-jwks.test.ts|it('대조군 — 성공하면 카운터가 돌아간다: 회복 뒤 다시 낡아 실패하면 창은 처음(0.2 초)부터다'",
    call: 'validate',
  },
]

/** 보안 기본값 가드가 node 행위 앵커를 적는 모양(`node/test/unit/<파일>|<선언>`, 한 따옴표 안). */
const SCRIPT_ANCHOR_RE =
  /"(?:canary\|)?node\/test\/unit\/([^"|]+)\|([^"]*)"|'(?:canary\|)?node\/test\/unit\/([^'|]+)\|([^']*)'/g

/**
 * `파일|선언` 이 가리키는 테스트 블록(`it`·`test`·`it.each(…)`) 하나와, 그 블록이 (파일 안 함수를 따라) 부르는
 * 이름 전부. 선언이 `it('제목'` 이면 제목과 같아야 하고, `it('제목` 이면 접두, 그 밖엔 부분 문자열로 찾는다.
 */
function resolveAnchor(anchor: string): { calls: Set<string> } | string {
  const bar = anchor.indexOf('|')
  const file = anchor.slice(0, bar)
  const decl = anchor.slice(bar + 1)
  const path = join(TEST_DIR, file)
  if (!existsSync(path)) return `앵커 파일이 없다: ${file}`
  const sf = ts.createSourceFile(file, readFileSync(path, 'utf8'), ts.ScriptTarget.Latest, true)
  let match: (title: string) => boolean
  if (decl.startsWith("it('")) {
    const frag = decl.slice(4)
    match = frag.endsWith("'") ? (t) => t === frag.slice(0, -1) : (t) => t.startsWith(frag)
  } else match = (t) => t.includes(decl)
  const locals = new Map<string, ts.Node>()
  const blocks: ts.Node[] = []
  const isTestFn = (e: ts.Expression): boolean =>
    (ts.isIdentifier(e) && (e.text === 'it' || e.text === 'test')) ||
    (ts.isPropertyAccessExpression(e) && isTestFn(e.expression))
  const scan = (n: ts.Node): void => {
    if (ts.isFunctionDeclaration(n) && n.name !== undefined && n.body !== undefined)
      locals.set(n.name.text, n.body)
    if (
      ts.isVariableDeclaration(n) &&
      ts.isIdentifier(n.name) &&
      n.initializer !== undefined &&
      (ts.isArrowFunction(n.initializer) || ts.isFunctionExpression(n.initializer))
    )
      locals.set(n.name.text, n.initializer.body)
    if (ts.isCallExpression(n)) {
      const callee = n.expression
      const each = ts.isCallExpression(callee) && isTestFn(callee.expression)
      const title = n.arguments[0]
      const fn = n.arguments[n.arguments.length - 1]
      if (
        (isTestFn(callee) || each) &&
        title !== undefined &&
        (ts.isStringLiteral(title) || ts.isNoSubstitutionTemplateLiteral(title)) &&
        match(title.text) &&
        fn !== undefined &&
        (ts.isArrowFunction(fn) || ts.isFunctionExpression(fn))
      )
        blocks.push(fn.body)
    }
    ts.forEachChild(n, scan)
  }
  scan(sf)
  if (blocks.length !== 1)
    return `앵커 ${anchor} 가 테스트 블록 ${blocks.length} 개에 걸린다(정확히 1 이어야 한다)`
  const calls = new Set<string>()
  const seen = new Set<string>()
  const follow = (node: ts.Node): void => {
    for (const c of callsIn(node)) {
      calls.add(c.name)
      const local = locals.get(c.name)
      if (local !== undefined && !c.onThis && !seen.has(c.name)) {
        seen.add(c.name)
        follow(local)
      }
    }
  }
  follow(blocks[0] as ts.Node)
  return { calls }
}

function checkHand(
  src: Source,
  byLabel: Map<string, ClassRow>,
  tgt: Record<'a' | 'b' | 'c', string[]>,
  publicNames: ReadonlySet<string>,
): string[] {
  const why: string[] = []
  const anchors = new Set(HAND.map((h) => h.anchor))
  for (const h of HAND) {
    const r = byLabel.get(h.label)
    if (r === undefined)
      why.push(`W1 ${h.label}: 손 테스트(${h.anchor})가 겨누는데 파생 집합에 행이 없다`)
    else if (r.cls !== h.cls)
      why.push(
        `W1 ${h.label}: 손 테스트(${h.anchor})가 겨누는 계급은 ${h.cls} 인데 파생은 ${r.cls} 다`,
      )
    else if (h.axis !== 'row' && !tgt[h.axis].includes(h.label))
      why.push(`W1 ${h.label}: 손 테스트(${h.anchor})가 겨누는데 W3${h.axis} 의 파생 대상에 없다`)
    const res = resolveAnchor(h.anchor)
    if (typeof res === 'string') {
      why.push(`W1 ${res} — 손 테스트가 옮겨졌으면 표를 따라 고쳐라`)
      continue
    }
    if (!res.calls.has(h.call))
      why.push(`W1 ${h.anchor}: 앵커가 ${h.call}( 를 부르지 않는다 — 손 테스트의 대상이 바뀌었다`)
    const sep = h.label.includes('#') ? '#' : '.'
    const [owner, name] = h.label.split(sep) as [string, string]
    if (name !== h.call && !entryCalls(src, owner, name).has(h.call))
      why.push(
        `W1 ${h.label}: 공개 입구가 ${h.call} 를 부르지 않는다 — 앵커(${h.anchor})의 대상과 이어지지 않는다`,
      )
  }
  // #603 테스트가 부르는 공개 이름은 전부 표에 있다 — 그 테스트에 대상이 늘면 여기가 먼저 운다.
  const cause = resolveAnchor(MALFORMED_ANCHOR)
  const handCalls = new Set(HAND.filter((h) => h.anchor === MALFORMED_ANCHOR).map((h) => h.call))
  const causePublic =
    typeof cause === 'string' ? [] : [...cause.calls].filter((c) => publicNames.has(c))
  if (causePublic.length === 0)
    why.push('W1 #603 테스트에서 공개 호출을 하나도 못 읽었다 — 대조가 공허하다')
  for (const c of causePublic) {
    if (!handCalls.has(c)) why.push(`W1 #603 테스트가 ${c} 를 부르는데 HAND 에 없다`)
  }
  // 보안 기본값 가드의 node 행위 앵커는 전부 표의 앵커다 — 그 가드에 node 앵커가 늘면 여기가 운다.
  if (existsSync(SCRIPT)) {
    const found = [...readFileSync(SCRIPT, 'utf8').matchAll(SCRIPT_ANCHOR_RE)].map(
      (m) => `${m[1] ?? m[3]}|${m[2] ?? m[4]}`,
    )
    console.log(
      `[hp] W1 손 목록 ${HAND.length} 항목 · 앵커 ${anchors.size} — #603 공개 호출 ${causePublic.length} · ` +
        `보안 기본값 가드의 node 행위 앵커 ${found.length} 와 대조`,
    )
    if (found.length === 0)
      why.push(
        'W1 test-security-defaults.sh 에서 node 행위 앵커를 하나도 못 읽었다 — 적는 모양이 바뀌었나?',
      )
    for (const a of found) {
      if (!anchors.has(a)) why.push(`W1 보안 기본값 가드의 node 앵커 ${a} 가 HAND 에 없다`)
    }
  } else if (existsSync(join(NODE_ROOT, '..', '.git'))) {
    why.push(`W1 저장소 체크아웃인데 보안 기본값 가드를 못 읽었다: ${SCRIPT}`)
  } else {
    console.log('[hp] W1: 저장소 밖에서 돌아 보안 기본값 가드 대조는 건너뛴다')
  }
  return why
}

// ---- 테스트 ----

let keys: Keys
let srv: IdpServer
let src: Source
let builderOf: Map<string, number>
let rows: ClassRow[]
let hiddenRows: ClassRow[]
const byLabel = new Map<string, ClassRow>()
let sdk: ReadonlyArray<ClassCtor>
let nonceParams: Map<string, number[]>
const tgt: Record<'a' | 'b' | 'c', string[]> = { a: [], b: [], c: [] }
const late: string[] = [] // W3 대상 파생에서 난 실패 — W1 과 함께 단언한다

beforeAll(async () => {
  const pair = await generateKeyPair('RS256')
  keys = {
    priv: pair.privateKey,
    other: (await generateKeyPair('RS256')).privateKey,
    jwk: { ...(await exportJWK(pair.publicKey)), kid: 'k1', alg: 'RS256', use: 'sig' },
  }
  srv = await startServer(keys)
  src = parseSource()
  sdk = sdkErrorCtors()
  const declared = await deriveDeclared(src)
  builderOf = await probeBuilders()
  rows = []
  for (const row of declared.rows) {
    const r = await classifyRow(row, builderOf)
    rows.push(r)
    byLabel.set(r.row.label, r)
  }
  const called = rows.filter((r) => r.row.unreached !== true).length
  console.log(
    `[hp] 선언 집합 ${rows.length} 행(리플렉션으로 부른 것 ${called} + 소스에만 있는 것 ${rows.length - called}) — ` +
      `경로의 /realms/r·${OIDC} 는 생략, {U} 는 보편 인자(서명된 JWS), discovery 는 찍되 세지 않는다`,
  )
  console.log(`[hp] 소스가 비공개로 적어 뺀 멤버: ${declared.excluded.join(', ')}`)
  hiddenRows = []
  for (const row of declared.hidden) hiddenRows.push(await classifyRow(row, builderOf))
  console.log(
    `[hp] 그 멤버의 분류(선언 집합 밖): ${hiddenRows.map((r) => `${r.row.label} → ${r.cls}`).join(' · ')}`,
  )
  const counts = new Map<string, number>()
  for (const r of rows) {
    counts.set(r.cls, (counts.get(r.cls) ?? 0) + 1)
    console.log(
      `[hp] ${r.row.label.padEnd(44)} → ${r.cls.padEnd(13)} · ${r.reqs}  [수신자 ${r.recv} · ${r.outcome}]${r.note}`,
    )
  }
  console.log(`[hp] 계급별: ${CLASSES.map((c) => `${c} ${counts.get(c) ?? 0}`).join(' · ')}`)

  // W3 대상 — 전부 파생이다: (a) 계급 · (b) 계급 ∩ 서명 · (c) 분류 실행이 보낸 요청.
  nonceParams = new Map()
  for (const r of rows) {
    const idx = (r.row.params ?? []).flatMap((p, i) => (/nonce/i.test(p.name) ? [i] : []))
    if (idx.length > 0) nonceParams.set(r.row.label, idx)
  }
  for (const r of rows) {
    if (r.row.unreached === true) continue
    if (r.cls === TOKEN_GRANT || r.cls === CODE_EXCHANGE) tgt.a.push(r.row.label)
    // nonce 파라미터가 있는 토큰 요청 행은 계급이 무엇이든 (b) 다 — grant 를 못 읽어 TOKEN_GRANT 로 읽힌 교환이
    // nonce 검사 없이 빠지지 않게(Grok 레그 지목).
    if (nonceParams.has(r.row.label) && (r.cls === TOKEN_GRANT || r.cls === CODE_EXCHANGE))
      tgt.b.push(r.row.label)
    if (r.cls === CODE_EXCHANGE && !nonceParams.has(r.row.label)) {
      const reason = NONCE_DROP_EXEMPT[r.row.label]
      if (reason !== undefined)
        console.log(
          `[hp] (b) nonce 파라미터가 없어 빠진 CODE_EXCHANGE 행: ${r.row.label} — ${reason}`,
        )
      else
        late.push(
          `W3b ${r.row.label}: CODE_EXCHANGE 인데 이름에 nonce 가 든 파라미터가 없어 W3b 가 붙지 않는다 — ` +
            'nonce 를 그 이름으로 받게 하거나, 정말 nonce 없는 흐름이면 이유와 함께 NONCE_DROP_EXEMPT 에 적어라',
        )
    }
    if (count(r.sent, isCertsGet) > 0) tgt.c.push(r.row.label)
  }
  for (const [label, reason] of Object.entries(NONCE_DROP_EXEMPT)) {
    const r = byLabel.get(label)
    if (r === undefined || r.cls !== CODE_EXCHANGE || nonceParams.has(label))
      late.push(
        `NONCE_DROP_EXEMPT[${label}]: 낡은 면제다 — nonce 파라미터 없는 CODE_EXCHANGE 행이 아니다(${reason})`,
      )
  }
  console.log(
    `[hp] W3 대상 — (a) ${tgt.a.length} · (b) ${tgt.b.map((l) => `${l}${JSON.stringify(nonceParams.get(l))}`).join(', ')} · (c) ${tgt.c.join(', ')}`,
  )
}, 120_000)

afterAll(async () => {
  await srv?.close()
})

describe('적대 경로 행렬 — 공개 호출 경로를 파생해 요청으로 가른다', () => {
  it('(1) UNDETERMINED 가 없다 — 면제는 이유와 함께, 낡은 면제는 실패', () => {
    const problems: string[] = []
    for (const r of rows) {
      if (r.cls === UNDETERMINED && !(r.row.label in UNDETERMINED_EXEMPT))
        problems.push(
          `${r.row.label}: 분류하지 못했다 — 인자 합성·수신자를 고치거나 이유와 함께 면제하라${r.note}`,
        )
    }
    for (const [label, reason] of Object.entries(UNDETERMINED_EXEMPT)) {
      if (byLabel.get(label)?.cls !== UNDETERMINED)
        problems.push(
          `${label}: 낡은 면제다 — 선언 집합에 없거나 더는 UNDETERMINED 가 아니다(${reason})`,
        )
    }
    expect(problems, problems.join('\n')).toEqual([])
  })

  it('(1b) 비공개로 적은 멤버가 IdP 에 닿으면 이유가 있다 — 낡은 이유는 실패', () => {
    const reaching = new Set([CODE_EXCHANGE, TOKEN_GRANT, JWKS_FETCH, OTHER])
    const problems: string[] = []
    for (const r of hiddenRows) {
      if (reaching.has(r.cls) && !(r.row.label in HIDDEN_REACH_EXEMPT))
        problems.push(
          `${r.row.label}: 비공개로 적었지만 부르면 IdP 에 닿는다(${r.cls} · ${r.reqs}) — 공개 API 가 아니라는 ` +
            '이유를 HIDDEN_REACH_EXEMPT 에 적거나, 공개로 돌려 행렬에 들여라',
        )
    }
    for (const [label, reason] of Object.entries(HIDDEN_REACH_EXEMPT)) {
      const r = hiddenRows.find((h) => h.row.label === label)
      if (r === undefined || !reaching.has(r.cls))
        problems.push(
          `${label}: 낡은 이유다 — 비공개 멤버가 아니거나 더는 IdP 에 닿지 않는다(${reason})`,
        )
    }
    expect(problems, problems.join('\n')).toEqual([])
  })

  it('(2) 세 교환 계급이 각각 비어 있지 않다', () => {
    // 비면 분류기·가짜 IdP·인자 합성 중 하나가 공허해진 것이다.
    const empty = [CODE_EXCHANGE, TOKEN_GRANT, JWKS_FETCH].filter(
      (c) => !rows.some((r) => r.cls === c),
    )
    expect(empty, `빈 계급 — 교환 경로를 하나도 못 찾았다: ${empty.join(', ')}`).toEqual([])
  })

  it('(2b) 캐시가 부여 경로를 가리지 않는다 — 발급받은 토큰을 실은 요청 앞에는 같은 호출의 토큰 요청이 있다', () => {
    // 계급이 비지 않아도 **줄 수는** 있다 — provider 캐시가 데워져 있으면 admin 자원 메서드는 부여 없이 캐시된
    // 토큰으로 나가 OTHER 로 읽히고, W3a 가 그 행들을 조용히 잃는다(실측: expires_in 300 → TOKEN_GRANT 30 → 5).
    // 인자로 받은 토큰(보편 인자)이 아니라 **이 IdP 가 발급한** 토큰이 실렸다면 그것은 캐시에서 왔다.
    const hidden = rows.flatMap((r) => {
      const first = r.sent.findIndex((q) => q.bearer)
      return first >= 0 && !r.sent.slice(0, first).some(isTokenPost) ? [r.row.label] : []
    })
    expect(
      hidden,
      `캐시된 토큰이 부여를 가렸다(토큰 응답의 expires_in 이 skew 보다 짧은가?): ${hidden.join(', ')}`,
    ).toEqual([])
  })

  it('(W1) 손으로 고른 테스트의 대상이 전부 행이고 기대 계급이다', () => {
    const publicNames = new Set(rows.map((r) => r.row.name))
    const problems = [...late, ...checkHand(src, byLabel, tgt, publicNames)]
    // W3a 변형의 출처 테스트도 살아 있어야 한다 — 단언하는 테스트가 없으면 그 변형은 계약이 아니다.
    for (const v of tokenVariants()) {
      if (v.from === '') continue
      const res = resolveAnchor(v.from)
      if (typeof res === 'string') problems.push(`W3a 변형 ${v.code} 의 출처: ${res}`)
    }
    expect(problems, problems.join('\n')).toEqual([])
  })

  it('(W3a) 토큰 부여·코드 교환 행 × 형식이 틀린 토큰 응답', async () => {
    const labels = new Set(tgt.a)
    const cells = await runVariantsA(
      rows.filter((r) => labels.has(r.row.label)).map((r) => r.row),
      builderOf,
      nonceParams,
      sdk,
    )
    const fails = judge('a', cells)
    expect(fails, fails.join('\n')).toEqual([])
  }, 300_000)

  it('(W3b) nonce 파라미터가 있는 코드 교환 행 × id_token 변형', async () => {
    const labels = new Set(tgt.b)
    const cells = await runNonceB(
      rows.filter((r) => labels.has(r.row.label)).map((r) => r.row),
      keys,
      builderOf,
      sdk,
    )
    const fails = judge('b', cells)
    expect(fails, fails.join('\n')).toEqual([])
  }, 120_000)

  it('(W3c) JWKS 를 조회한 행 × 콜드 캐시 503', async () => {
    const labels = new Set(tgt.c)
    const cells = await runColdC(
      rows.filter((r) => labels.has(r.row.label)).map((r) => r.row),
      builderOf,
      sdk,
    )
    const fails = judge('c', cells)
    expect(fails, fails.join('\n')).toEqual([])
  }, 120_000)

  it('(2c) 호출이 돌아온 뒤 나간 요청도, 어느 칸에도 안 붙는 요청도 없다', async () => {
    // 기다리지 않는 비동기 요청은 분류표에 안 잡힌다(NONE 으로 읽힌다) — 그 요청은 칸이 닫힌 뒤에 도착해 여기
    // 모인다. 마지막 칸의 것이 도착할 틈만 준다(시간을 단언하지 않는다 — 늦게 오면 못 볼 뿐이다).
    await new Promise((resolve) => setTimeout(resolve, 100))
    const problems = [
      ...srv.late.map(
        ({ label, req }) => `${label}: 호출이 돌아온 뒤 나갔다 — ${formatReqs([req], '')}`,
      ),
      ...srv.orphans.map((req) => `어느 칸에도 안 붙는 요청 — ${formatReqs([req], '')}`),
    ]
    expect(problems, problems.join('\n')).toEqual([])
  })
})
