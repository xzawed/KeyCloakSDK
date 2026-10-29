import { KeycloakAuthError } from './errors.js'
import type { TokenSet } from './tokens.js'

/** RFC 6750 §2.1 `b64token` — ASCII 영숫자와 `-._~+/`, `=` 는 끝의 덧대기로만. */
const B64TOKEN = /^[A-Za-z0-9\-._~+/]+=*$/

/** 앞뒤에서 떼는 넷 — SP·HTAB·CR·LF. `trim()` 은 유니코드 공백·VT·FF 까지 떼므로 쓰지 않는다. */
function isEdge(code: number): boolean {
  return code === 0x20 || code === 0x09 || code === 0x0d || code === 0x0a
}

/**
 * admin 이 Bearer 로 보낼 값 — 아홉 언어가 같은 규칙이다(등록부 `bearer-token-grammar-divergent`). 앞뒤의
 * SP·HTAB·CR·LF 만 떼고(파일에서 읽은 토큰의 끝 개행), 남은 값이 비지 않은 `b64token` 이면 **뗀 값**을 돌려주고,
 * 아니면 토큰을 담지 않은 {@link KeycloakAuthError} 를 원인 없이 던진다 — 그 요청은 나가지 않는다. 보내는 자리(파사드
 * `admin/http.ts` · `raw()` 에 등록한 공급자 · 생성 때의 토큰 확보)와 캐시하는 자리({@link ClientCredentialsTokenProvider})가
 * 이 함수 하나를 쓴다. 떼기는 선형 스캔이다(`config.ts` 의 `stripTrailingSlashes` 와 같은 이유). 길이는 보지 않는다 —
 * 요청 헤더 한도는 서버가 정한다(Keycloak 26.6 은 65,459 바이트 Bearer 를 받는다).
 */
export function sendableBearer(token: string): string {
  const text = String(token)
  let start = 0
  let end = text.length
  while (start < end && isEdge(text.charCodeAt(start))) start += 1
  while (end > start && isEdge(text.charCodeAt(end - 1))) end -= 1
  const trimmed = text.slice(start, end)
  if (!B64TOKEN.test(trimmed)) {
    throw new KeycloakAuthError(
      'admin access token cannot be sent: it is not an RFC 6750 bearer token (b64token)',
    )
  }
  return trimmed
}

/** admin이 소비하는 액세스 토큰의 공급 인터페이스(auth와 admin을 잇는 유일한 접착제). */
export interface TokenProvider {
  getAccessToken(): Promise<string>
}

/** client-credentials 토큰을 발급할 수 있는 소스(AuthClient가 구현). */
export interface TokenSource {
  clientCredentialsToken(): Promise<TokenSet>
}

/**
 * client-credentials로 토큰을 자동 획득·캐시·갱신하는 기본 TokenProvider.
 * 만료 전이면 캐시를 재사용하고, 동시 요청은 단일 발급(single-flight)으로 합친다.
 * 캐시하는 것은 {@link sendableBearer} 가 돌려준 값이다 — 그 검사를 못 지나는 토큰은 캐시하지 않고
 * `KeycloakAuthError` 로 실패하므로 다음 호출이 소스에 다시 묻는다.
 */
export class ClientCredentialsTokenProvider implements TokenProvider {
  #cached?: { token: string; expiresAt: number }
  #inflight?: Promise<string>

  constructor(
    private readonly source: TokenSource,
    private readonly skewSeconds = 30,
  ) {}

  async getAccessToken(): Promise<string> {
    const cached = this.#cached
    if (cached && Date.now() < cached.expiresAt) return cached.token
    if (this.#inflight) return this.#inflight
    this.#inflight = this.#fetch()
    try {
      return await this.#inflight
    } finally {
      this.#inflight = undefined
    }
  }

  async #fetch(): Promise<string> {
    const ts = await this.source.clientCredentialsToken()
    // 캐시하기 **전에** 거른다 — 던지면 `#cached` 는 그대로라 거부한 토큰이 캐시에 남지 않는다.
    const token = sendableBearer(ts.accessToken)
    this.#cached = {
      token,
      expiresAt: Date.now() + Math.max(0, ts.expiresIn - this.skewSeconds) * 1000,
    }
    return token
  }
}
