import { KeycloakConfigError } from './errors.js'

/**
 * The redirect URI of the authorization-code flow, in the one form both of its requests send. `createAuthorizationRequest`
 * puts its `href` in the authorization URL and `exchangeCode` hands it to openid-client, which builds the token request's
 * `redirect_uri` by serializing it with the query and fragment removed. Keycloak compares the two strings exactly
 * (`Incorrect redirect_uri` otherwise), so a URI that differs from its own serialization — a bare origin without the
 * trailing slash, an upper-case host, a default port, `..`, a space — is normalized here, and a query or a fragment,
 * which the token request would drop, is refused.
 *
 * A value that does not parse as a URL, or carries a query or a fragment, is a `KeycloakConfigError`
 * (`invalid redirect_uri: <reason>`) before any request — the same class as Rust's `redirect_url` and Kotlin's
 * `redirectUri`. It used to escape the SDK's error hierarchy as `new URL`'s `TypeError` (§4). So is a serialization
 * Keycloak's parser (`java.net.URI`) refuses although WHATWG accepts it — a character outside RFC 3986 §2 that the
 * serialization keeps, an unpaired surrogate in the value, nothing after the scheme or after its `//`, or a `[` or `]`
 * outside one bracketed host (`invalid redirect_uri: not a valid URI (RFC 3986 §2)`).
 *
 * It lives outside `auth.ts` on purpose: `auth.ts` is a network boundary excluded from unit coverage, and the
 * integration run never takes these failure branches, so there they hid from both gates.
 */
export function redirectUrl(value: string): URL {
  let url: URL
  try {
    url = new URL(value)
  } catch (e) {
    throw new KeycloakConfigError(`invalid redirect_uri: ${(e as Error).message}`, { cause: e })
  }
  // 빈 `?` · `#` 는 값이 아니라 표기라 아래에서 지운다(`search` · `hash` 가 빈 문자열이다). 값이 있는 것만 거부한다 —
  // fragment 는 RFC 6749 §3.1.2 가 금하고, 쿼리는 openid-client 6 이 토큰 요청에서 떼어 내(`stripParams`) 교환이 맞을 수 없다.
  if (url.hash !== '') {
    throw new KeycloakConfigError(
      'invalid redirect_uri: a fragment is not allowed (RFC 6749 §3.1.2)',
    )
  }
  if (url.search !== '') {
    throw new KeycloakConfigError(
      'invalid redirect_uri: a query is not supported (the code exchange sends the redirect URI without it)',
    )
  }
  url.search = ''
  url.hash = ''
  if (!passesR3(value, url.href) || !passesR4(url.href)) {
    throw new KeycloakConfigError('invalid redirect_uri: not a valid URI (RFC 3986 §2)')
  }
  return url
}

// RFC 3986 §2 밖의 ASCII 문장부호 중 Keycloak 의 java.net.URI.create 가 던지는 아홉(다른 언어의 R3 와 같은 열).
const R3_PUNCTUATION = '"<>\\^`{|}'

// R3 — 다른 언어가 R3 로 거부하는 값이 아닌가: 호출자의 값이 올바른 UTF-16 이고(홀로 선 서로게이트는 `new URL` 이 U+FFFD 로
// 바꿔 `href` 에서는 안 보인다 — 그래서 입력을 본다), 보내는 `href` 에 U+0000–U+0020 · U+007F–U+00A0 · 유니코드 공백
// 구분자(U+1680 · U+2000–U+200A · U+2028 · U+2029 · U+202F · U+205F · U+3000) · R3_PUNCTUATION 의 문자도, 16진 두 자리가 따르지
// 않는 `%` 도 없는가. WHATWG 는 이 문자 일부를 인코딩하지 않고 둔다(실측 node v22.18.0 · v22.23.5 · v24.22.3 · v26.13.1) — 불투명 경로의
// 아홉과 공백, 계층 경로의 `|`(비특수 scheme 은 `\` 도, node 22 는 `^` 도), 호스트의 `"` · `` ` `` · `{` · `}`, 그리고 깨진
// `%`(경로 · 사용자 정보 · 비특수 호스트). 나머지 자리의 같은 문자는 인코딩되어 받는다. `%` 는 zone id 안에서도 본다 —
// `[fe80::1%eth0]` 는 java.net.URI 가 받지만 다른 언어처럼 거부한다(RFC 6874 §2 는 URI 안에서 그 `%` 를 `%25` 로 쓰라고 한다).
export function passesR3(value: string, href: string): boolean {
  if (!value.isWellFormed()) return false
  for (const char of href) {
    if (isR3Char(char)) return false
  }
  return !/%(?![0-9A-Fa-f]{2})/.test(href)
}

function isR3Char(char: string): boolean {
  const n = char.codePointAt(0)!
  return (
    n <= 0x20 ||
    (n >= 0x7f && n <= 0xa0) ||
    n === 0x1680 ||
    (n >= 0x2000 && n <= 0x200a) ||
    n === 0x2028 ||
    n === 0x2029 ||
    n === 0x202f ||
    n === 0x205f ||
    n === 0x3000 ||
    R3_PUNCTUATION.includes(char)
  )
}

// 괄호 안에 올 수 있는 것 — RFC 3986 §3.2.2 의 IPv6address 에 Java 의 dec-octet(앞자리 0 을 받는다: `01` · `0001` ·
// `00000000255`)을 넣은 것. `[zz]` · IPvFuture `[v1.x]` 는 URI.create 가 거부한다.
const H16 = '[0-9A-Fa-f]{1,4}'
const DEC = '0*(?:25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])'
const LS32 = `(?:${H16}:${H16}|${DEC}[.]${DEC}[.]${DEC}[.]${DEC})`
const IPV6 = [
  `(?:${H16}:){6}${LS32}`,
  `::(?:${H16}:){5}${LS32}`,
  `(?:${H16})?::(?:${H16}:){4}${LS32}`,
  `(?:(?:${H16}:){0,1}${H16})?::(?:${H16}:){3}${LS32}`,
  `(?:(?:${H16}:){0,2}${H16})?::(?:${H16}:){2}${LS32}`,
  `(?:(?:${H16}:){0,3}${H16})?::${H16}:${LS32}`,
  `(?:(?:${H16}:){0,4}${H16})?::${LS32}`,
  `(?:(?:${H16}:){0,5}${H16})?::${H16}`,
  `(?:(?:${H16}:){0,6}${H16})?::`,
].join('|')

// 괄호 호스트 하나의 authority — 사용자 정보 · 포트(숫자만, 비어도 된다)는 있어도 되고, 괄호 안은 IPv6 리터럴과 zone id(Java 의
// scope_id — 영숫자 · `_` · `.`, `%` 뒤가 비면 아니다)다. 포트의 크기는 따로 잰다(R4e).
const BRACKETED_AUTHORITY = new RegExp(
  `^(?:[^@[\\]/]*@)?\\[(?:${IPV6})(?:%[A-Za-z0-9_.]+)?\\](?::([0-9]*))?$`,
)

// R4 — WHATWG 는 받지만 Keycloak 의 `java.net.URI.create`(RedirectUtils.toUri)는 거부하는 직렬화(실측 JDK 21.0.8: 「Expected
// scheme-specific part」 · 「Expected authority」 · 「Illegal character in path」 · 「Malformed IPv6 address」 · 「Malformed port
// number」). (R4a) scheme 의 `:` 뒤가 비면(`myapp:`) 아니다. `:` 뒤가 `/` 로 시작하면 `?` 앞을 본다 — `//` 로 시작하면 (R4c)
// `:` 뒤가 `//` 뿐일 때(`myapp://`) 아니고, 다음 `/` 까지(없으면 끝까지)가 authority 이며 거기 `[` · `]` 는 (R4d) 괄호 호스트
// 하나(BRACKETED_AUTHORITY)로만 올 수 있고 (R4e) 그 포트는 수로 2147483647(Java 의 int) 이하다 — 앞의 0 은 떼고 재며, 남은
// 자리가 열을 넘으면 아니다. (R4b) 그 밖(경로)의 `[` · `]` 는 아니다. 불투명한 값(`myapp:c[b` · `urn:x[y]`)과 쿼리는 괄호를
// 가져도 된다. 다른 언어의 R4 와 같은 판정이고, 그 언어들이 보내는 문자열 대신 node 가 보내는 `href` 를 본다. WHATWG 의 `href` 는
// 호스트 밖의 `[` · `]` 를 이미 퍼센트 인코딩하고 잘못된 IPv6 · zone id · 65535 를 넘는 포트는 `new URL` 이 먼저 거부하므로
// R4d · R4e 의 거부는 `redirectUrl` 로는 닿지 않는다(R4c 는 닿는다 — `new URL('myapp://').href` 가 `myapp://` 다) — 판정 전체는
// 시험이 이 함수로 직접 잰다. zone id 의 맨 `%`(`[fe80::1%eth0]`)는 R4 가 Java 처럼 받는다 — 그것을 일부러 거부하는 것은
// R3(passesR3)이고, node 에서는 그 전에 `new URL` 이 zone id 를 아예 받지 않는다.
export function passesR4(href: string): boolean {
  const rest = href.slice(href.indexOf(':') + 1)
  if (rest === '') return false
  if (!rest.startsWith('/')) return true
  const beforeQuery = rest.split('?', 1)[0]!
  let path = beforeQuery
  if (beforeQuery.startsWith('//')) {
    if (rest === '//') return false
    const slash = beforeQuery.indexOf('/', 2)
    const authority = slash === -1 ? beforeQuery.slice(2) : beforeQuery.slice(2, slash)
    if (/[[\]]/.test(authority) && !isBracketedAuthority(authority)) return false
    path = slash === -1 ? '' : beforeQuery.slice(slash)
  }
  return !/[[\]]/.test(path)
}

// R4d · R4e — authority 가 괄호 호스트 하나이고, 포트는 앞의 0 을 떼면 열 자리 이하 · 2147483647 이하인가(빈 포트는 0).
function isBracketedAuthority(authority: string): boolean {
  const match = BRACKETED_AUTHORITY.exec(authority)
  if (match === null) return false
  const port = (match[1] ?? '').replace(/^0+/, '')
  return port.length <= 10 && Number(port) <= 2147483647
}
