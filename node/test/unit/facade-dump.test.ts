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
 * 바닥 경로도 `#private` 을 찍지 않으므로 그 필드가 바닥으로 새는 길은 없다. 비밀 이름인 `#private` 필드 선언은 `node/src` 를 훑어
 * (`privateFieldDeclarations`) 그 흐름을 재는 시험이 적힌 표(`PRIVATE_SECRET_FIELDS`)와 양쪽으로 대조한다. (2) 카나리아는 뿌리를 만드는
 * 호출이 흘려 넣은 비밀뿐이다 — 새 타입이 이 뿌리들이 안 밟는 경로로 비밀을 받으면 그 경로를 뿌리에 더한다.
 * (3) 선언 파생은 정규식이다 — 놓치지 않는지는 배럴의 클래스 export 전부가 파생 집합에 드는지로 대조한다.
 * (4) 공개되지 않은 클래스(`MaskedAuthorizationRequest`)는 이름으로만 식별한다 — 같은 이름의 남의 클래스는
 * 구분하지 못한다. 공개된 클래스는 배럴의 생성자와 **동일성**으로 식별한다.
 *
 * ⚠️ SDK 클래스 인스턴스의 비밀 이름 프로퍼티(`secretWords` · `SECRET_WORDS`)가 닿은 인스턴스마다 빈 값이면 실패한다 — 그
 * 렌더링은 아무것도 증명하지 않는다(등록부 facade-dump-reached-empty-secret-field, 면제 `EMPTY_SECRET_EXEMPT`). 프로퍼티는 가장
 * 가까운 SDK 클래스의 것으로 센다(런타임에는 어느 생성자가 달았는지 모른다). 남은 빈틈(구현하지 않는다): 비밀 이름 필드가 빈 값
 * 아닌 자리표시자만 쥐는 것 · 평범한 이름의 필드에 든 비밀(예: `ClientCredentialsTokenProvider` 의 `#cached`) · 인코딩된(base64 등) 비밀.
 */
import { describe, it, expect, beforeAll, afterAll } from 'vitest'
import {
  KeycloakAdminError,
  KeycloakAuthError,
  KeycloakConfigError,
  KeycloakConflictError,
  KeycloakForbiddenError,
  KeycloakNotFoundError,
  KeycloakTokenValidationError,
  KeycloakTransportError,
} from '../../src/index.js'
import {
  ACCESS,
  BARREL,
  declaredClasses,
  dumpRoots,
  isClass,
  newWalk,
  privateFieldDeclarations,
  REFRESH,
  visit,
  type Declared,
  type FakeIdp,
  type Walk,
} from './facade-walk.js'

/** 걷기에 안 닿아도 되는 클래스와 그 이유. ⚠️ 이유 없는 면제는 넣지 않는다. */
const EXEMPT: Readonly<Record<string, string>> = {
  ResponseUnusableError:
    '내부 신호(token-response-cap.ts) — 상한 fetch 가 끝까지 온 토큰 · introspection 응답을 쓸 수 없으면(짝 없는 ' +
    '서로게이트 · 풀 수 없는 content-coding — ResponseNotUtf8Error 의 부모) 던지고 openid-client 가 ClientError 로 ' +
    '감싸며, auth.ts 가 KeycloakAuthError 로 바꾼다. 인스턴스는 공개 API 로 나오지 않는다(auth-token-response-residue.test.ts)',
  ResponseNotUtf8Error:
    '내부 신호(token-response-cap.ts) — 상한 fetch 가 2xx 토큰 · introspection 본문이 UTF-8 이 아니면 던지고 ' +
    'openid-client 가 ClientError 로 감싸며, auth.ts 가 KeycloakAuthError 로 바꾼다. KeycloakError 생성자가 cause 를 ' +
    '평범한 Error 사본으로 바꾸므로 인스턴스는 공개 API 로 나오지 않는다(auth-token-response-utf8.test.ts)',
  ResponseTooLargeError:
    '내부 신호(token-response-cap.ts) — 상한 fetch 가 던지고 openid-client 가 ClientError 로 감싸며, auth.ts 가 ' +
    'KeycloakAuthError 로 바꾼다. KeycloakError 생성자가 cause 를 평범한 Error 사본으로 바꾸므로 인스턴스는 공개 ' +
    'API 로 나오지 않는다(token-response-cap.test.ts 의 「원인 사슬」 시험이 잰다)',
}

/**
 * 알려진 누출 — `"뿌리|카나리아"` 와 사유. ⚠️ 고쳐져 더 안 새면 **여기서 지워야 통과한다**(낡은 항목 검사).
 *
 * 지금은 비어 있다. 이 걷기가 처음 찾은 `malformed id_token error`(openid-client 가 `cause` 에 싣은 id_token
 * 원문을 `KeycloakAuthError` 가 그대로 달았다)는 `KeycloakError` 생성자의 cause 정화로 닫혔다 — 그 뿌리는
 * 남아 「더 안 샌다」를 잰다.
 */
const KNOWN_LEAKS: Readonly<Record<string, string>> = {}

/**
 * 비밀 이름 필드가 빈 값으로만 닿아도 되는 `클래스.프로퍼티` 와 그 이유(등록부 facade-dump-reached-empty-secret-field).
 * ⚠️ 이유 없는 면제는 넣지 않는다. 더는 「닿았고 빈 값뿐」이 아니면(채워졌거나 · 안 닿거나 · 선언이 없어지면) 낡은 면제로 실패한다.
 */
const EMPTY_SECRET_EXEMPT: Readonly<Record<string, string>> = {}

/**
 * 비밀 이름인 ES `#private` 필드(`파일:#이름`)와 그 이유 — 걷기가 못 보는 자리라, 그 필드의 흐름을 재는 시험을 적는다.
 * `privateFieldDeclarations()` 의 선언 파생과 양쪽으로 대조한다(표에 없는 선언 · 선언이 없는 표 항목 둘 다 실패).
 */
const PRIVATE_SECRET_FIELDS: Readonly<Record<string, string>> = {
  'auth.ts:#idTokenValidator':
    'AuthClient 가 지연 파생해 쥐는 id_token 검증기(JwtValidator — 비밀 값이 아니다, 이름의 token 은 id_token 의 것)다. 걷기가 못 ' +
    '보는 ES #private 이라, 그 흐름(공개 validateIdToken 과 nonce 를 받는 exchangeCode 가 함께 쓰는 #validateIdToken)은 ' +
    "auth.test.ts 의 'validateIdToken — 공개 id_token 검증' 과 auth-id-token-signature.test.ts 의 exchangeCode 시험이 잰다",
}

/** 비밀 낱말 — 낱말 단위로만 맞춘다(`keycloak` 은 `key` 가 아니다). 아홉 언어가 같은 집합이다. */
const SECRET_WORDS: ReadonlySet<string> = new Set([
  'secret',
  'password',
  'passwd',
  'passphrase',
  'token',
  'credential',
  'verifier',
  'private',
  'key',
  'bearer',
])

/**
 * 필드 이름 → 낱말: camel·Pascal 경계(대문자 연속은 다음 대문자 낱말 앞에서 끝난다 — `IDToken` → id · token) · `_ - $ .` ·
 * 앞의 `@`·`#`. .NET `<X>k__BackingField` → X · Kotlin `x$delegate` → x. 낱말마다 소문자로 바꾸고 끝의 s 하나를 뗀다.
 */
function secretWords(field: string): string[] {
  let n = /^<(.+)>k__BackingField$/.exec(field)?.[1] ?? field
  if (n.endsWith('$delegate')) n = n.slice(0, -'$delegate'.length)
  if (n.startsWith('@') || n.startsWith('#')) n = n.slice(1)
  return n
    .split(/[_$.-]+/)
    .flatMap((part) => part.split(/(?<=[a-z0-9])(?=[A-Z])|(?<=[A-Z])(?=[A-Z][a-z])/))
    .filter((w) => w.length > 0)
    .map((w) => {
      const lower = w.toLowerCase()
      return lower.endsWith('s') ? lower.slice(0, -1) : lower
    })
}

function isSecretNamed(field: string): boolean {
  return secretWords(field).some((w) => SECRET_WORDS.has(w))
}

let idp: FakeIdp | undefined
let walk: Walk
let declared: Declared

type ErrorRoots = Awaited<ReturnType<typeof dumpRoots>>['errors']

beforeAll(async () => {
  // 뿌리·걷기는 `facade-walk.ts` 가 소유한다 — 선언 집합을 파생하는 적대 경로 행렬과 같은 걷기다.
  const d = await dumpRoots()
  idp = d.idp
  const { ts, ar, ir, vt, idToken, providerToken, errors } = d

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
  const expected: Record<keyof ErrorRoots, abstract new (...args: never[]) => Error> = {
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
    'introspect transport error': KeycloakTransportError,
    'logout transport error': KeycloakTransportError,
    'config error': KeycloakConfigError,
  }
  for (const [name, err] of Object.entries(errors)) {
    expect(err, name).toBeInstanceOf(expected[name as keyof ErrorRoots])
  }

  declared = declaredClasses()
  walk = newWalk(new Set(declared.names.keys()), d.canaries, KNOWN_LEAKS)
  for (const [name, value] of d.roots) visit(value, name, name, walk)
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

  it('비밀 이름 필드가 닿은 인스턴스마다 빈 값이지 않다 — 빈 렌더링은 아무것도 증명하지 않는다', () => {
    const fieldOf = (key: string): string => key.slice(key.indexOf('.') + 1)
    // 기록이 공허하지 않은가 — 카나리아로 채운 필드가 비밀 이름 필드로 잡혀야 한다.
    expect([...walk.ownFields.keys()].filter((k) => isSecretNamed(fieldOf(k)))).toContain(
      'TokenSet.accessToken',
    )
    const problems: string[] = []
    for (const [key, anyNonEmpty] of walk.ownFields) {
      if (anyNonEmpty || key in EMPTY_SECRET_EXEMPT || !isSecretNamed(fieldOf(key))) continue
      problems.push(
        `${key}: secret-named but every reached instance holds an empty value — fill it from a root with a canary, or exempt it with a reason`,
      )
    }
    for (const [key, reason] of Object.entries(EMPTY_SECRET_EXEMPT)) {
      if (walk.ownFields.get(key) !== false)
        problems.push(
          `${key}: 면제 표에 있지만 더는 「닿았고 빈 값뿐」이 아니다(채워졌거나 · 안 닿거나 · 선언이 없다) — 낡은 면제다(${reason})`,
        )
    }
    expect(problems, problems.join('\n')).toEqual([])
  })

  it('비밀 이름인 ES #private 필드 선언 전부가 이유와 함께 표에 있다 — 걷기가 못 보는 자리', () => {
    const all = privateFieldDeclarations()
    expect(all.length, '#private 필드 선언을 하나도 못 찾았다 — 파생이 공허하다').toBeGreaterThan(0)
    const secret = all.filter((d) => isSecretNamed(d.slice(d.indexOf(':') + 1)))
    const problems: string[] = []
    for (const d of secret) {
      if (!(d in PRIVATE_SECRET_FIELDS))
        problems.push(
          `${d}: 비밀 이름인 #private 필드다 — 걷기가 못 본다. 그 흐름을 재는 시험을 이유와 함께 PRIVATE_SECRET_FIELDS 에 적어라`,
        )
    }
    for (const k of Object.keys(PRIVATE_SECRET_FIELDS)) {
      if (!secret.includes(k))
        problems.push(`${k}: 표에 있지만 비밀 이름인 #private 필드 선언이 없다 — 낡은 항목이다`)
    }
    expect(problems, problems.join('\n')).toEqual([])
  })

  it('비밀 이름 판정은 낱말 단위다 — keycloak 은 key 가 아니다', () => {
    expect(secretWords('IDToken')).toEqual(['id', 'token'])
    expect(secretWords('<ClientSecret>k__BackingField')).toEqual(['client', 'secret'])
    expect(secretWords('refreshToken$delegate')).toEqual(['refresh', 'token'])
    const yes =
      'clientSecret accessToken IDToken password passwd passphrase credentials codeVerifier privateKey keys'
    for (const n of `${yes} bearer api_secret x-token a.token @token #token SECRETS`.split(' '))
      expect(isSecretNamed(n), n).toBe(true)
    for (const n of 'keycloak keycloakUrl monkey tokenizer secretary keystore scope expiresAt this$0'.split(
      ' ',
    ))
      expect(isSecretNamed(n), n).toBe(false)
  })
})
