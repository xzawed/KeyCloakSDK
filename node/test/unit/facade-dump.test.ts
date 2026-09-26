/**
 * 바닥 계약(기본 표현이 비밀을 찍지 않는다)을 **손으로 고른 값 타입이 아니라 도달 가능한 객체 전부**에
 * 건다. `masking.test.ts`·`tokens.test.ts`·`config.test.ts` 는 값 타입 셋(TokenSet·AuthorizationRequest·
 * config)을 손으로 골라 재는데, 자매 언어에서 실측(2026-09-26)으로 그 밖의 **파사드**가 새고 있었다
 * (go `facade_dump_test.go` · php `FacadeDumpTest.php`). 이 파일은 같은 모양을 node 로 옮긴다.
 *
 * ⚠️ **새 자리를 스스로 찾는 것이 요점이다**(등록부 `guard-detection-surface-hand-narrowed`). 검사 대상은
 * (1) 공개 API 로 만든 뿌리에서 리플렉션으로 **닿는 이 SDK 의 객체 전부**이고, (2) `node/src` 를 훑어 얻은
 * **클래스 선언 전수**가 그 걷기에 걸렸는지 대조한다 — 새 클래스는 걷기에 닿거나 아래 면제 표에 이유와
 * 함께 적혀야 통과한다.
 *
 * 바닥 경로 넷: `util.inspect(depth: Infinity)`(console.log 의 깊은 판) · `util.format('%o')`
 * (console.log('%o') — showHidden) · `String()` · `JSON.stringify()`.
 *
 * ⚠️ **닿은 객체는 SDK 타입이 아니어도 전부 찍는다**(내려가는 것은 SDK 타입과 그릇뿐). SDK 타입만 찍으면
 * 마스킹 훅을 가진 부모 아래의 평범한 객체·클래스 표현식 인스턴스가 소비자 손에 닿는데도(`ts.raw`) 재지
 * 않는다 — Grok 교차검토가 지목했고 변이 둘로 실측했다(`TokenSet` 에 `{ token }`·`const Holder = class`
 * 필드를 더해도 **SILENT** 였다). 같은 이유로 선언 파생은 `const X = class` 도 읽고, 이름을 추론할 수 없는
 * 익명 클래스 표현식은 대조 실패로 친다(걷기가 이름으로 식별할 수 없다).
 *
 * ⚠️ 한계 (1) ES `#private` 필드는 리플렉션이 못 본다 — 걷기가 그리로 내려가지 못하므로, 그런 자리에만
 * 사는 객체는 공개 API 뿌리로 따로 세운다(`JwtValidator.forJwksUri`·`new ClientCredentialsTokenProvider`).
 * 바닥 경로도 `#private` 을 찍지 않으므로 그 필드가 바닥으로 새는 길은 없다. (2) 카나리아는 뿌리를 만드는
 * 호출이 흘려 넣은 비밀뿐이다 — 새 타입이 이 뿌리들이 안 밟는 경로로 비밀을 받으면 그 경로를 뿌리에 더한다.
 * (3) 선언 파생은 정규식이다 — 놓치지 않는지는 배럴의 클래스 export 전부가 파생 집합에 드는지로 대조한다.
 * (4) 공개되지 않은 클래스(`MaskedAuthorizationRequest`)는 이름으로만 식별한다 — 같은 이름의 남의 클래스는
 * 구분하지 못한다. 공개된 클래스는 배럴의 생성자와 **동일성**으로 식별한다.
 */
import { describe, it, expect, beforeAll, afterAll } from 'vitest'
import { createServer, type IncomingMessage, type ServerResponse } from 'node:http'
import type { AddressInfo } from 'node:net'
import { readdirSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { format, inspect } from 'node:util'
import { exportJWK, generateKeyPair, SignJWT, type JWK } from 'jose'
import * as sdk from '../../src/index.js'
import {
  AdminClient,
  AuthClient,
  ClientCredentialsTokenProvider,
  defineConfig,
  JwtValidator,
  KeycloakAdminError,
  KeycloakAuthError,
  KeycloakClient,
  KeycloakConfigError,
  KeycloakConflictError,
  KeycloakForbiddenError,
  KeycloakNotFoundError,
  KeycloakTokenValidationError,
  KeycloakTransportError,
  type KeycloakConfigInput,
} from '../../src/index.js'

const SECRET = 'CANARY-DUMP-CLIENT-SECRET'
const ACCESS = 'CANARY-DUMP-ACCESS-TOKEN'
const REFRESH = 'CANARY-DUMP-REFRESH-TOKEN'
const GARBAGE = 'CANARY-DUMP-GARBAGE-TOKEN'
const PASSWORD = 'CANARY-DUMP-ADMIN-PASSWORD'
/**
 * JWT 가 아닌 id_token. ⚠️ 정상 경로의 id_token 은 서명한 JWT 여야 한다 — openid-client 가 토큰 응답의
 * id_token 클레임을 검증해, JWT 가 아니면 그랜트 전체를 거부한다(그 거부가 아래 `malformed id_token error`
 * 뿌리다).
 */
const MALFORMED_ID = 'CANARY-DUMP-MALFORMED-ID-TOKEN'

/** 걷기에 안 닿아도 되는 클래스와 그 이유. ⚠️ 이유 없는 면제는 넣지 않는다. */
const EXEMPT: Readonly<Record<string, string>> = {}

/**
 * 알려진 누출 — `"뿌리|카나리아"` 와 사유. ⚠️ 고쳐져 더 안 새면 **여기서 지워야 통과한다**(낡은 항목 검사).
 *
 * `malformed id_token error` — IdP 토큰 응답의 id_token 이 JWT 가 아니면 openid-client 가
 * `OperationProcessingError('Invalid JWT')` 의 `cause` 에 **id_token 원문**을 싣고, `AuthClient.#grant` 가 그
 * 오류를 `KeycloakAuthError` 의 `cause` 로 그대로 단다. `util.inspect`(기본 depth 2 의 `console.log(err)` 도)가
 * `[cause]` 사슬을 따라 원문을 찍는다. `String()`·`JSON.stringify` 는 깨끗하다(실측 2026-09-26).
 */
const KNOWN_LEAKS: Readonly<Record<string, string>> = {
  'malformed id_token error|MALFORMED_ID': 'UNTRIAGED — reported',
}

const SRC = fileURLToPath(new URL('../../src/', import.meta.url))

/** 걷기가 찍을 만한 값인가 — 원시값은 부모의 렌더가 이미 담는다. 함수의 클로저는 리플렉션이 못 본다. */
function isObject(v: unknown): v is object {
  return typeof v === 'object' && v !== null
}

/** 남의 클래스가 아닌 **그릇**(배열·평범한 객체·Map·Set)인가 — 이것만은 SDK 타입이 아니어도 내려간다. */
function isContainer(v: object): boolean {
  if (Array.isArray(v) || v instanceof Map || v instanceof Set) return true
  const proto: unknown = Object.getPrototypeOf(v)
  return proto === Object.prototype || proto === null
}

interface Declared {
  /** 이름 → 파일 */
  readonly names: Map<string, string>
  readonly duplicates: string[]
  /** 이름을 추론할 수 없는 클래스 표현식(`파일:줄`) */
  readonly anonymous: string[]
}

/**
 * `node/src` 의 클래스 전수 — 손 목록이 아니라 트리에서 파생한다. 선언(`class X`)·이름 있는 표현식
 * (`= class X`)·바인딩에서 이름을 추론하는 표현식(`const X = class`)을 읽는다. 주석은 먼저 지운다 —
 * 산문의 "class {@link …}" 가 선언으로 잡히지 않게.
 */
function declaredClasses(): Declared {
  const names = new Map<string, string>()
  const duplicates: string[] = []
  const anonymous: string[] = []
  const head = /\bclass\b(?:\s+(?!extends\b|implements\b)([A-Za-z_$][\w$]*))?[^{;=]*\{/g
  const binding = /(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*(?::[^=]*)?=\s*$/
  for (const rel of readdirSync(SRC, { recursive: true, encoding: 'utf8' })) {
    if (!rel.endsWith('.ts') || rel.endsWith('.d.ts')) continue
    // 주석은 지우되 줄바꿈은 남긴다 — 아래 보고가 원본 줄 번호를 가리키도록.
    const text = readFileSync(join(SRC, rel), 'utf8')
      .replace(/\/\*[\s\S]*?\*\//g, (c) => c.replace(/[^\n]/g, ''))
      .replace(/(^|[^:\\])\/\/[^\n]*/g, '$1')
    for (const m of text.matchAll(head)) {
      const before = text.slice(0, m.index)
      const name = m[1] ?? binding.exec(before)?.[1]
      if (name === undefined) {
        anonymous.push(`${rel}:${before.split('\n').length}`)
        continue
      }
      if (names.has(name)) duplicates.push(`${name} (${names.get(name)} · ${rel})`)
      names.set(name, rel)
    }
  }
  return { names, duplicates, anonymous }
}

const BARREL = sdk as unknown as Readonly<Record<string, unknown>>

function isClass(v: unknown): v is abstract new (...args: never[]) => unknown {
  return typeof v === 'function' && /^class\b/.test(Function.prototype.toString.call(v))
}

interface Walk {
  readonly declared: ReadonlySet<string>
  readonly canaries: ReadonlyArray<readonly [name: string, value: string]>
  readonly seen: Set<object>
  readonly reached: Set<string>
  readonly rendered: string[]
  readonly leaks: string[]
  readonly knownSeen: Set<string>
}

/**
 * 프로토타입 사슬에서 이 SDK 가 선언한 클래스 전부 — 오류 하위 클래스를 만나면 `KeycloakError` 도
 * 닿은 것으로 센다(php 의 부모 클래스 순회와 동형).
 */
function ownClasses(o: object, w: Walk): string[] {
  const out: string[] = []
  for (let p: unknown = Object.getPrototypeOf(o); isObject(p); p = Object.getPrototypeOf(p)) {
    const ctor: unknown = Object.getOwnPropertyDescriptor(p, 'constructor')?.value
    if (typeof ctor !== 'function' || !w.declared.has(ctor.name)) continue
    const exported = BARREL[ctor.name]
    // 배럴에 같은 이름이 있으면 동일성으로 판정한다 — 이름만 같은 남의 클래스를 SDK 타입으로 세지 않는다.
    if (exported !== undefined && exported !== ctor) continue
    out.push(ctor.name)
  }
  return out
}

function attempt(fn: () => string | undefined): string {
  try {
    return fn() ?? 'undefined'
  } catch (e) {
    // 순환 구조의 JSON.stringify 등 — 던진 메시지도 로거가 찍는 문자열이라 함께 잰다.
    return `<throws ${e instanceof Error ? e.message : 'non-error'}>`
  }
}

function render(o: object, path: string, root: string, w: Walk): void {
  w.rendered.push(path)
  const outs: ReadonlyArray<readonly [string, string]> = [
    ['util.inspect', inspect(o, { depth: Infinity })],
    ["util.format('%o')", format('%o', o)],
    ['String', attempt(() => String(o))],
    ['JSON.stringify', attempt(() => JSON.stringify(o))],
  ]
  for (const [how, out] of outs) {
    for (const [name, value] of w.canaries) {
      if (!out.includes(value)) continue
      const key = `${root}|${name}`
      if (key in KNOWN_LEAKS) {
        w.knownSeen.add(key)
        continue
      }
      const ctor: unknown = Object.getPrototypeOf(o)?.constructor
      const type = typeof ctor === 'function' ? ctor.name : 'null-prototype'
      w.leaks.push(`${path} [${type}] ${how}: 비밀 ${name} 가 원문으로 찍혔다`)
    }
  }
}

/**
 * 뿌리에서 닿는 객체를 걷는다. 닿은 객체는 **전부** 찍고, SDK 타입과 그릇으로만 내려간다 — 남의 객체로는
 * 내려가지 않는다(go·php 동형). 남의 객체를 잎으로라도 찍는 것은 마스킹 훅을 가진 부모가 그 필드를
 * 가려도 소비자는 필드를 직접 찍을 수 있기 때문이다.
 * 비공개 필드도 읽는다 — TS `private` 은 런타임에 평범한 프로퍼티라 `util.inspect` 가 바로 그것을 찍는다.
 * 접근자는 부르지 않는다(부작용).
 */
function visit(v: unknown, path: string, root: string, w: Walk): void {
  if (!isObject(v) || w.seen.has(v)) return
  w.seen.add(v)
  const own = ownClasses(v, w)
  for (const name of own) w.reached.add(name)
  render(v, path, root, w)
  if (own.length === 0 && !isContainer(v)) return
  for (const key of Reflect.ownKeys(v)) {
    const d = Object.getOwnPropertyDescriptor(v, key)
    if (d !== undefined && 'value' in d) visit(d.value, `${path}.${String(key)}`, root, w)
  }
  if (v instanceof Map) {
    for (const [k, x] of v) {
      visit(k, `${path}<key>`, root, w)
      visit(x, `${path}<value>`, root, w)
    }
  } else if (v instanceof Set) {
    for (const x of v) visit(x, `${path}<item>`, root, w)
  }
}

interface FakeIdp {
  readonly origin: string
  /** 토큰 엔드포인트의 응답 본문 — 카나리아가 여기서 SDK 로 흘러 들어간다. id_token 이 issuer 를 담아야
   * 해서 서버가 뜬 뒤 채운다. */
  tokenResponse: Record<string, unknown>
  /** admin 경로가 받은 `realm Authorization` — 기본 경로 admin 이 카나리아 토큰을 실었는지 대조한다. */
  readonly adminAuth: string[]
  close(): Promise<void>
}

/**
 * 가짜 IdP — 경로로 응답을 고른다(순서 큐가 아니라 호출 순서가 바뀌어도 안 깨진다).
 * realm `r` 정상 · `bad` 토큰 엔드포인트 401 · `badid` 토큰 응답의 id_token 이 JWT 가 아니다 · `down`
 * discovery 에서 소켓을 끊는다 · `drop` discovery 는 정상이고 그 뒤 모든 요청에서 소켓을 끊는다(비밀을 실은
 * 요청이 전송 실패하는 자리).
 */
async function startIdp(jwk: JWK): Promise<FakeIdp> {
  const json = (res: ServerResponse, status: number, body: unknown): void => {
    res.writeHead(status, { 'content-type': 'application/json' })
    res.end(JSON.stringify(body))
  }
  // 요청은 listen 뒤에만 오므로 아래 `idp` 는 route 가 불릴 때 이미 있다.
  const route = (req: IncomingMessage, res: ServerResponse): void => {
    const { origin, adminAuth } = idp
    const path = new URL(req.url ?? '/', origin).pathname
    const discovery = /^\/realms\/([^/]+)\/\.well-known\/openid-configuration$/.exec(path)
    if (discovery !== null) {
      const realm = discovery[1] as string
      if (realm === 'down') return void req.socket.destroy()
      const issuer = `${origin}/realms/${realm}`
      const base = `${issuer}/protocol/openid-connect`
      return json(res, 200, {
        issuer,
        token_endpoint: `${base}/token`,
        authorization_endpoint: `${base}/auth`,
        introspection_endpoint: `${base}/token/introspect`,
        end_session_endpoint: `${base}/logout`,
        jwks_uri: `${base}/certs`,
        response_types_supported: ['code'],
        grant_types_supported: ['client_credentials', 'authorization_code', 'refresh_token'],
      })
    }
    const oidc = /^\/realms\/([^/]+)\/protocol\/openid-connect\/(.+)$/.exec(path)
    if (oidc !== null) {
      const [, realm, endpoint] = oidc
      if (realm === 'drop') return void req.socket.destroy()
      if (endpoint === 'token') {
        if (realm === 'bad') return json(res, 401, { error: 'invalid_client' })
        if (realm === 'badid')
          return json(res, 200, { ...idp.tokenResponse, id_token: MALFORMED_ID })
        return json(res, 200, idp.tokenResponse)
      }
      if (endpoint === 'token/introspect') {
        return json(res, 200, { active: true, username: 'svc', client_id: 'c', sub: 'u1' })
      }
      if (endpoint === 'certs') return json(res, 200, { keys: [jwk] })
    }
    const admin = /^\/admin\/realms\/([^/]+)(\/.*)?$/.exec(path)
    if (admin !== null) {
      adminAuth.push(`${admin[1]} ${req.headers.authorization ?? ''}`)
      if (admin[1] === 'drop') return void req.socket.destroy()
      // admin-client 는 컬렉션 경로에 후행 슬래시를 붙인다(`POST /users/`).
      switch (`${req.method} ${(admin[2] ?? '').replace(/\/$/, '')}`) {
        case 'POST /users':
          return json(res, 409, { errorMessage: 'User exists with same username' })
        case 'GET /users':
          return json(res, 403, { error: 'unknown_error' })
        case 'GET /groups':
          return json(res, 500, { error: 'unknown_error' })
      }
    }
    json(res, 404, { error: 'not_found' })
  }
  const server = createServer((req, res) => {
    // 본문을 다 받은 뒤 답한다 — 비밀을 실은 POST 가 쓰는 도중 연결이 끊겨 다른 실패로 바뀌지 않게.
    req.on('end', () => route(req, res))
    req.resume()
  })
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve))
  const idp: FakeIdp = {
    origin: `http://127.0.0.1:${(server.address() as AddressInfo).port}`,
    tokenResponse: {},
    adminAuth: [],
    close: () =>
      new Promise<void>((resolve) => {
        server.closeAllConnections()
        server.close(() => resolve())
      }),
  }
  return idp
}

/** 실패 호출이 던진 오류 — 실패하지 않으면 뿌리를 못 만든 것이다. */
async function caught(fn: () => unknown): Promise<Error> {
  try {
    await fn()
  } catch (e) {
    if (e instanceof Error) return e
    throw new Error(`오류가 아닌 값이 던져졌다: ${typeof e}`)
  }
  throw new Error('실패 뿌리를 못 만들었다 — 가짜 IdP 가 실패를 안 냈다')
}

let idp: FakeIdp | undefined
let walk: Walk
let declared: Declared

beforeAll(async () => {
  const { publicKey, privateKey } = await generateKeyPair('RS256')
  idp = await startIdp({ ...(await exportJWK(publicKey)), kid: 'k1', alg: 'RS256', use: 'sig' })
  const { origin } = idp
  const input: KeycloakConfigInput = {
    serverUrl: origin,
    realm: 'r',
    clientId: 'c',
    clientSecret: SECRET,
  }
  const issuer = `${origin}/realms/r`
  const sign = (typ: string): Promise<string> =>
    new SignJWT({})
      .setProtectedHeader({ alg: 'RS256', kid: 'k1', typ })
      .setIssuer(issuer)
      .setSubject('u1')
      .setAudience('c')
      .setIssuedAt()
      .setExpirationTime('1m')
      .sign(privateKey)
  const idToken = await sign('JWT')
  const jwt = await sign('at+jwt')
  idp.tokenResponse = {
    access_token: ACCESS,
    token_type: 'Bearer',
    expires_in: 300,
    refresh_token: REFRESH,
    id_token: idToken,
  }

  const config = defineConfig(input)
  const kc = KeycloakClient.create(input)
  // 기본 경로의 admin — 내부 provider 가 토큰을 캐시한 뒤라야 그 상태가 걷기에 걸린다.
  const admin = await kc.admin()
  const ts = await kc.auth.clientCredentialsToken()
  const ar = kc.auth.createAuthorizationRequest('https://app.example/cb')
  const ir = await kc.auth.introspect(ACCESS)
  const vt = await kc.auth.validate(jwt)
  // `AuthClient` 의 검증기는 `#private` 에만 산다 — 공개 팩토리로 따로 세운다.
  const validator = JwtValidator.forJwksUri(`${issuer}/protocol/openid-connect/certs`, {
    issuer,
    audience: 'c',
    allowedAlgs: ['RS256'],
    clockSkewSeconds: 30,
    jwksMinRefetchSeconds: 30,
  })
  await validator.validate(jwt)

  // 주입 경로 — 소비자가 직접 만드는 provider 와 admin. provider 의 소스는 **SDK 의 AuthClient** 다 —
  // 테스트가 만든 객체를 소스로 주면 그 객체가 카나리아를 쥐고 provider 의 렌더에 섞인다(하네스 오염).
  const provider = new ClientCredentialsTokenProvider(new AuthClient(config))
  const providerToken = await provider.getAccessToken()
  // admin 호출은 소켓이 끊기는 realm 으로 간다 — 같은 객체가 전송 오류 뿌리도 낸다.
  const injected = await AdminClient.create(defineConfig({ ...input, realm: 'drop' }), provider)

  // 오류 뿌리 — 실제 실패 호출에서 얻는다(원인 사슬이 요청의 비밀을 쥘 수 있는 자리들이다).
  const errors = {
    'admin 404': await caught(() => admin.users.delete('missing')),
    'admin 409': await caught(() =>
      admin.users.create({
        username: 'dup',
        credentials: [{ type: 'password', value: PASSWORD, temporary: false }],
      }),
    ),
    'admin 403': await caught(() => admin.users.search('x')),
    'admin 500': await caught(() => admin.groups.list()),
    'admin transport error': await caught(() => injected.users.get('x')),
    'auth error': await caught(() =>
      KeycloakClient.create({ ...input, realm: 'bad' }).auth.clientCredentialsToken(),
    ),
    'malformed id_token error': await caught(() =>
      KeycloakClient.create({ ...input, realm: 'badid' }).auth.clientCredentialsToken(),
    ),
    'refresh error': await caught(() =>
      KeycloakClient.create({ ...input, realm: 'bad' }).auth.refresh(REFRESH),
    ),
    'exchangeCode error': await caught(() =>
      KeycloakClient.create({ ...input, realm: 'bad' }).auth.exchangeCode(
        'code',
        'https://app.example/cb',
        ar.codeVerifier,
        ar.nonce,
      ),
    ),
    'validation error': await caught(() => kc.auth.validate(GARBAGE)),
    'discovery transport error': await caught(() =>
      KeycloakClient.create({ ...input, realm: 'down' }).auth.introspect(ACCESS),
    ),
    'introspect transport error': await caught(() =>
      KeycloakClient.create({ ...input, realm: 'drop' }).auth.introspect(ACCESS),
    ),
    'logout transport error': await caught(() =>
      KeycloakClient.create({ ...input, realm: 'drop' }).auth.logout(REFRESH),
    ),
    'config error': await caught(() => defineConfig({ ...input, readTimeoutMs: -1 })),
  }

  // ⚠️ 카나리아가 실제로 흘러 들어갔는가 — 안 흘렀으면 아래 누출 검사는 없는 것을 찾으며 통과한다.
  expect([ts.accessToken, ts.refreshToken, ts.idToken]).toEqual([ACCESS, REFRESH, idToken])
  expect(providerToken).toBe(ACCESS)
  // 기본 경로 admin 의 캐시된 토큰은 `#private` 과 클로저 안에 있어 직접 못 읽는다 — 그 토큰이
  // 실제로 쓰였는지를 IdP 가 받은 헤더로 대조한다(realm `r` = 기본 경로, `drop` = 주입 경로).
  expect(idp.adminAuth).toContain(`r Bearer ${ACCESS}`)
  expect(idp.adminAuth).toContain(`drop Bearer ${ACCESS}`)
  expect(ar.codeVerifier).toMatch(/^[\w-]{43}$/)
  expect(vt.subject).toBe('u1')
  expect(ir.active).toBe(true)
  // 오류 뿌리가 기대한 SDK 경로에서 났는가 — 다른 실패로 바뀌면 재는 대상이 달라진다.
  const expected: Record<keyof typeof errors, abstract new (...args: never[]) => Error> = {
    'admin 404': KeycloakNotFoundError,
    'admin 409': KeycloakConflictError,
    'admin 403': KeycloakForbiddenError,
    'admin 500': KeycloakAdminError,
    'admin transport error': KeycloakTransportError,
    'auth error': KeycloakAuthError,
    'malformed id_token error': KeycloakAuthError,
    'refresh error': KeycloakAuthError,
    'exchangeCode error': KeycloakAuthError,
    'validation error': KeycloakTokenValidationError,
    'discovery transport error': KeycloakTransportError,
    'introspect transport error': KeycloakAuthError,
    'logout transport error': KeycloakAuthError,
    'config error': KeycloakConfigError,
  }
  for (const [name, err] of Object.entries(errors)) {
    expect(err, name).toBeInstanceOf(expected[name as keyof typeof errors])
  }

  const roots: ReadonlyArray<readonly [string, unknown]> = [
    ['defineConfig', config],
    ['KeycloakClient.create', kc],
    ['kc.admin()', admin],
    ['clientCredentialsToken', ts],
    ['createAuthorizationRequest', ar],
    ['introspect', ir],
    ['validate', vt],
    ['JwtValidator.forJwksUri', validator],
    ['ClientCredentialsTokenProvider', provider],
    ['AdminClient.create', injected],
    ...Object.entries(errors),
  ]
  declared = declaredClasses()
  walk = {
    declared: new Set(declared.names.keys()),
    canaries: [
      ['SECRET', SECRET],
      ['ACCESS', ACCESS],
      ['REFRESH', REFRESH],
      ['ID', idToken],
      ['MALFORMED_ID', MALFORMED_ID],
      ['GARBAGE', GARBAGE],
      ['PASSWORD', PASSWORD],
      ['VERIFIER', ar.codeVerifier],
      ['JWT', jwt],
    ],
    seen: new Set(),
    reached: new Set(),
    rendered: [],
    leaks: [],
    knownSeen: new Set(),
  }
  for (const [name, value] of roots) visit(value, name, name, walk)
}, 60_000)

afterAll(async () => {
  await idp?.close()
})

describe('도달 가능한 객체 전부의 기본 표현이 비밀을 찍지 않는다', () => {
  it('바닥 경로 넷이 어떤 카나리아도 원문으로 찍지 않는다', () => {
    expect(walk.rendered.length).toBeGreaterThan(0)
    expect(walk.leaks, `기본 표현이 비밀을 찍는다:\n${walk.leaks.join('\n')}`).toEqual([])
  })

  it('알려진 누출 표의 항목이 전부 아직 관측된다', () => {
    expect(
      Object.keys(KNOWN_LEAKS).filter((k) => !walk.knownSeen.has(k)),
      '알려진 누출이 더 안 난다 — 고쳐졌으면 KNOWN_LEAKS 와 등록부 항목을 함께 닫아라',
    ).toEqual([])
  })

  it('src 의 클래스 선언 전부가 걷기에 닿거나 이유와 함께 면제된다', () => {
    expect(declared.duplicates, '같은 이름의 클래스가 둘이다 — 이름 대조가 모호하다').toEqual([])
    expect(
      declared.anonymous,
      '이름을 추론할 수 없는 클래스 표현식이다 — 걷기가 이름으로 식별할 수 없으니 이름을 붙여라',
    ).toEqual([])
    // 파생이 공허하지 않은가 — 배럴이 내보내는 클래스는 전부 정규식 파생에 걸려야 한다.
    const exportedClasses = Object.entries(BARREL)
      .filter(([, v]) => isClass(v))
      .map(([k]) => k)
    expect(exportedClasses.length).toBeGreaterThan(0)
    expect(
      exportedClasses.filter((name) => !declared.names.has(name)),
      '배럴이 내보내는 클래스를 선언 파생이 놓쳤다 — 정규식이 새 문법을 못 읽는다',
    ).toEqual([])

    const problems: string[] = []
    for (const [name, file] of declared.names) {
      const reached = walk.reached.has(name)
      const reason = EXEMPT[name]
      if (reached && reason !== undefined) {
        problems.push(`${name}: 걷기에 닿는데 면제 표에도 있다 — 면제를 지워라(${reason})`)
      } else if (!reached && reason === undefined) {
        problems.push(
          `${name} (${file}): 공개 API 뿌리에서 닿지 않는 클래스다 — 만드는 경로를 뿌리에 더하거나, 이유와 함께 면제하라`,
        )
      }
    }
    for (const name of Object.keys(EXEMPT)) {
      if (!declared.names.has(name))
        problems.push(`${name}: 면제 표에 있지만 선언이 없다 — 낡은 면제다`)
    }
    expect(problems, problems.join('\n')).toEqual([])
  })
})
