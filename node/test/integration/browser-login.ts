import type { AuthorizationRequest } from '../../src/index.js'

/**
 * 브라우저 없는 로그인 — 실제 Keycloak 로그인 폼을 HTTP 로 채워 인가 코드를 받는다.
 * python 파일럿(`python/tests/integration/browser_login.py`)의 세 걸음을 그대로 옮긴다:
 *
 * 1. SDK 가 만든 인가 URL 을 GET 한다(로그인 페이지 + 인증 세션 쿠키 — 쿠키는 2 에서 직접 되싣는다).
 * 2. `<form id="kc-form-login">` 의 `action` 에 사용자명·비밀번호를 POST 하되 **리다이렉트는 따라가지
 *    않는다**(`redirect: 'manual'`) — redirect_uri 에는 아무것도 떠 있지 않다. 302 의 `Location` 이 곧
 *    콜백이다.
 * 3. `Location` 에서 `code`·`state` 를 꺼내고, `state` 가 SDK 가 발급한 값인지 확인한다.
 *
 * 폼을 못 찾거나 상태 코드가 틀리면 받은 HTML 앞부분을 실어 실패한다 — 테마가 바뀌었을 때 원인이
 * 바로 보이게. 새 의존성은 없다 — 폼 하나의 시작 태그만 읽으면 되므로 HTML 파서를 들이지 않는다.
 */

const LOGIN_FORM_ID = 'kc-form-login'

const ENTITIES: Readonly<Record<string, string>> = {
  amp: '&',
  quot: '"',
  apos: "'",
  lt: '<',
  gt: '>',
}

/** 속성 값의 문자 참조를 푼다 — Keycloak 은 action 쿼리의 `&` 를 `&amp;` 로 쓴다. */
function decodeEntities(value: string): string {
  return value.replace(/&(#x[0-9a-f]+|#[0-9]+|[a-z]+);/gi, (whole, ref: string) => {
    if (ref.startsWith('#x') || ref.startsWith('#X'))
      return String.fromCodePoint(parseInt(ref.slice(2), 16))
    if (ref.startsWith('#')) return String.fromCodePoint(parseInt(ref.slice(1), 10))
    return ENTITIES[ref.toLowerCase()] ?? whole
  })
}

/** `<form id="kc-form-login">` 의 action 만 집는다. 없으면 undefined. */
function loginFormAction(html: string): string | undefined {
  for (const tag of html.matchAll(/<form\b[^>]*>/gi)) {
    const attributes = new Map<string, string>()
    for (const m of tag[0].matchAll(
      /([^\s"'<>/=]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))/g,
    )) {
      const name = (m[1] as string).toLowerCase()
      attributes.set(name, decodeEntities(m[2] ?? m[3] ?? m[4] ?? ''))
    }
    if (attributes.get('id') === LOGIN_FORM_ID) return attributes.get('action')
  }
  return undefined
}

async function snippet(response: Response, url: string): Promise<string> {
  return `HTTP ${String(response.status)} ${url}\n${(await response.text()).slice(0, 1500)}`
}

/**
 * `request`(SDK 의 `createAuthorizationRequest` 결과)로 로그인해 인가 코드를 돌려준다.
 * 실패는 전부 던진다 — 테스트가 이 헬퍼의 실패를 교환의 실패로 오인하지 않게.
 */
export async function browserLogin(
  request: AuthorizationRequest,
  redirectUri: string,
  username: string,
  password: string,
): Promise<string> {
  const page = await fetch(request.url, { redirect: 'manual' })
  if (page.status !== 200) {
    throw new Error(`login page did not render:\n${await snippet(page, request.url)}`)
  }
  const html = await page.text()
  const action = loginFormAction(html)
  if (action === undefined || action === '') {
    throw new Error(
      `no <form id="${LOGIN_FORM_ID}"> in the login page:\n` +
        `HTTP ${String(page.status)} ${request.url}\n${html.slice(0, 1500)}`,
    )
  }
  // ⚠️ 쿠키 저장소에 맡기지 말고 **직접 되싣는다.** Keycloak 26 은 http 에서도 로그인 쿠키에 `Secure` 를
  // 단다. 브라우저는 localhost 를 안전한 출처로 봐서 보내지만, RFC 6265 대로 사는 저장소는 http 요청에
  // 싣지 않아 POST 가 400 "Restart login cookie not found" 로 끝난다(python 파일럿 실측). fetch 는 쿠키
  // 저장소가 없으니 여기서는 `Set-Cookie` 의 `name=value` 만 떼어 `Cookie` 헤더로 보낸다.
  const cookie = page.headers
    .getSetCookie()
    .map((header) => header.split(';', 1)[0] as string)
    .join('; ')
  const answer = await fetch(new URL(action, request.url), {
    method: 'POST',
    redirect: 'manual',
    headers: { cookie, 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ username, password }),
  })
  if (answer.status !== 302) {
    throw new Error(`login POST did not redirect:\n${await snippet(answer, action)}`)
  }
  const location = answer.headers.get('location')
  if (location === null) {
    throw new Error(`login POST redirected without a Location:\n${await snippet(answer, action)}`)
  }
  const callback = new URL(location)
  if (`${callback.origin}${callback.pathname}` !== redirectUri) {
    throw new Error(`login redirected somewhere else: ${location}`)
  }
  // state 는 SDK 가 인가 URL 에 실은 CSRF 값이다 — 서버가 그대로 되돌려야 한다.
  const states = callback.searchParams.getAll('state')
  if (states.length !== 1 || states[0] !== request.state) {
    throw new Error(`state mismatch: sent ${request.state}, got ${JSON.stringify(states)}`)
  }
  const codes = callback.searchParams.getAll('code')
  if (codes.length !== 1 || !codes[0]) {
    throw new Error(`no single authorization code in the callback: ${location}`)
  }
  return codes[0]
}

/**
 * 인가 URL 에서 `nonce` 만 뺀다 — 서버가 nonce 클레임 **없는** id_token 을 서명하게 한다.
 * 나머지 값(verifier·state·nonce)은 그대로다 — 교환 쪽이 기대 nonce 를 계속 넘길 수 있게.
 */
export function stripNonce(request: AuthorizationRequest): AuthorizationRequest {
  const url = new URL(request.url)
  url.searchParams.delete('nonce')
  return {
    url: url.href,
    codeVerifier: request.codeVerifier,
    state: request.state,
    nonce: request.nonce,
  }
}
