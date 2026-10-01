/**
 * 공개 API 뿌리와 그 뿌리에서 닿는 SDK 객체를 걷는 걷기 — `facade-dump.test.ts` 가 누출을 재고
 * `hostile-path-matrix.test.ts` 가 선언 집합을 파생한다. **걷기는 하나다**(두 번째 걷기를 만들지 않는다 —
 * go 의 `dumpRoots`·`dumpWalker` 를 두 테스트가 함께 쓰는 것과 같은 모양). 이 파일은 `.test.ts` 가 아니라
 * 스위트로 돌지 않는다 — 테스트 파일을 import 하면 그 파일의 describe 가 가져온 쪽에서도 등록된다.
 *
 * 걷기의 계약·한계는 `facade-dump.test.ts` 머리 주석이 소유한다.
 */
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
  KeycloakClient,
  type KeycloakConfigInput,
} from '../../src/index.js'

export const SECRET = 'CANARY-DUMP-CLIENT-SECRET'
export const ACCESS = 'CANARY-DUMP-ACCESS-TOKEN'
export const REFRESH = 'CANARY-DUMP-REFRESH-TOKEN'
export const GARBAGE = 'CANARY-DUMP-GARBAGE-TOKEN'
export const PASSWORD = 'CANARY-DUMP-ADMIN-PASSWORD'
/**
 * JWT 가 아닌 id_token. ⚠️ 정상 경로의 id_token 은 서명한 JWT 여야 한다 — openid-client 가 토큰 응답의
 * id_token 클레임을 검증해, JWT 가 아니면 그랜트 전체를 거부한다(그 거부가 아래 `malformed id_token error`
 * 뿌리다).
 */
export const MALFORMED_ID = 'CANARY-DUMP-MALFORMED-ID-TOKEN'

export const SRC = fileURLToPath(new URL('../../src/', import.meta.url))

/** 걷기가 찍을 만한 값인가 — 원시값은 부모의 렌더가 이미 담는다. 함수의 클로저는 리플렉션이 못 본다. */
export function isObject(v: unknown): v is object {
  return typeof v === 'object' && v !== null
}

/** 남의 클래스가 아닌 **그릇**(배열·평범한 객체·Map·Set)인가 — 이것만은 SDK 타입이 아니어도 내려간다. */
export function isContainer(v: object): boolean {
  if (Array.isArray(v) || v instanceof Map || v instanceof Set) return true
  const proto: unknown = Object.getPrototypeOf(v)
  return proto === Object.prototype || proto === null
}

export interface Declared {
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
export function declaredClasses(): Declared {
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

export const BARREL = sdk as unknown as Readonly<Record<string, unknown>>

export function isClass(v: unknown): v is abstract new (...args: never[]) => unknown {
  return typeof v === 'function' && /^class\b/.test(Function.prototype.toString.call(v))
}

/** SDK 클래스의 생성자 — 인스턴스 메서드는 `prototype` 에, 정적 메서드는 생성자 자신에 있다. */
export type ClassCtor = abstract new (...args: never[]) => unknown

export interface Walk {
  readonly declared: ReadonlySet<string>
  readonly canaries: ReadonlyArray<readonly [name: string, value: string]>
  /** 알려진 누출(`"뿌리|카나리아"` → 사유) — 여기 있는 누출은 `leaks` 가 아니라 `knownSeen` 에 든다. */
  readonly known: Readonly<Record<string, string>>
  readonly seen: Set<object>
  readonly reached: Set<string>
  /** SDK 클래스 이름 → 처음 닿은 인스턴스와 그 생성자(선언 집합·수신자 파생이 쓴다). */
  readonly found: Map<string, { readonly value: object; readonly ctor: ClassCtor }>
  readonly rendered: string[]
  readonly leaks: string[]
  readonly knownSeen: Set<string>
}

export function newWalk(
  declared: ReadonlySet<string>,
  canaries: Walk['canaries'] = [],
  known: Walk['known'] = {},
): Walk {
  return {
    declared,
    canaries,
    known,
    seen: new Set(),
    reached: new Set(),
    found: new Map(),
    rendered: [],
    leaks: [],
    knownSeen: new Set(),
  }
}

/**
 * 프로토타입 사슬에서 이 SDK 가 선언한 클래스 전부(이름·생성자) — 오류 하위 클래스를 만나면
 * `KeycloakError` 도 닿은 것으로 센다(php 의 부모 클래스 순회와 동형).
 */
export function ownClasses(o: object, w: Walk): Array<readonly [string, ClassCtor]> {
  const out: Array<readonly [string, ClassCtor]> = []
  for (let p: unknown = Object.getPrototypeOf(o); isObject(p); p = Object.getPrototypeOf(p)) {
    const ctor: unknown = Object.getOwnPropertyDescriptor(p, 'constructor')?.value
    if (typeof ctor !== 'function' || !w.declared.has(ctor.name)) continue
    const exported = BARREL[ctor.name]
    // 배럴에 같은 이름이 있으면 동일성으로 판정한다 — 이름만 같은 남의 클래스를 SDK 타입으로 세지 않는다.
    if (exported !== undefined && exported !== ctor) continue
    out.push([ctor.name, ctor as ClassCtor])
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
  if (w.canaries.length === 0) return // 카나리아 없는 걷기(선언 파생)는 찍을 필요가 없다
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
      if (key in w.known) {
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
export function visit(v: unknown, path: string, root: string, w: Walk): void {
  if (!isObject(v) || w.seen.has(v)) return
  w.seen.add(v)
  const own = ownClasses(v, w)
  for (const [name, ctor] of own) {
    w.reached.add(name)
    if (!w.found.has(name)) w.found.set(name, { value: v, ctor })
  }
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

export interface FakeIdp {
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

/**
 * 공개 API 로 만든 뿌리 전부 — 정상 값·주입 경로·실패 호출의 오류. 가짜 IdP 를 띄우고 그 위에서 만든다
 * (닫는 것은 호출자 몫이다). 뿌리가 기대한 경로에서 났는지의 대조는 `facade-dump.test.ts` 가 한다.
 */
export async function dumpRoots() {
  const { publicKey, privateKey } = await generateKeyPair('RS256')
  const idp = await startIdp({
    ...(await exportJWK(publicKey)),
    kid: 'k1',
    alg: 'RS256',
    use: 'sig',
  })
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
  const canaries: Walk['canaries'] = [
    ['SECRET', SECRET],
    ['ACCESS', ACCESS],
    ['REFRESH', REFRESH],
    ['ID', idToken],
    ['MALFORMED_ID', MALFORMED_ID],
    ['GARBAGE', GARBAGE],
    ['PASSWORD', PASSWORD],
    ['VERIFIER', ar.codeVerifier],
    ['JWT', jwt],
  ]
  return { idp, roots, canaries, idToken, ts, ar, ir, vt, providerToken, errors }
}
