import type { TokenSet } from './tokens.js'

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
    this.#cached = {
      token: ts.accessToken,
      expiresAt: Date.now() + Math.max(0, ts.expiresIn - this.skewSeconds) * 1000,
    }
    return ts.accessToken
  }
}
