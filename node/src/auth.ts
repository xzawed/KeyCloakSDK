import { createHash, randomBytes } from 'node:crypto'
import * as oidc from 'openid-client'
import type { KeycloakConfig } from './config.js'
import { KeycloakAuthError, KeycloakTransportError } from './errors.js'
import { JwtValidator } from './jwt.js'
import { mask } from './masking.js'
import { oidcEndpoints, type OidcEndpoints } from './oidc-metadata.js'
import { isTransportError } from './transport.js'
import {
  tokenSetFromResponse,
  type IntrospectionResult,
  type TokenSet,
  type ValidatedToken,
} from './tokens.js'

/**
 * PKCE 인가 코드 흐름을 시작하는 데 필요한 값 묶음.
 * `codeVerifier`는 `exchangeCode`에 전달할 때까지 호출자(세션)가 보관한다 — SDK는 무상태다.
 * `state`/`nonce`는 CSRF/재생 공격 방어용 난수로, 콜백에서 호출자가 대조해야 한다.
 */
export interface AuthorizationRequest {
  readonly url: string
  readonly codeVerifier: string
  readonly state: string
  readonly nonce: string
}

const AR_INSPECT = Symbol.for('nodejs.util.inspect.custom')

/**
 * `AuthorizationRequest`의 런타임 구현. **공개 타입은 위 인터페이스 그대로**이고(호출자가 만든
 * 객체 리터럴도 계속 그 타입을 만족한다) 이 클래스는 내보내지 않는다 — 바뀌는 것은 SDK가
 * 돌려주는 값이 마스킹 훅 셋을 갖는다는 점뿐이다.
 *
 * 평범한 객체 리터럴을 돌려주면 `console.log`(util.inspect)와 `JSON.stringify`가 PKCE
 * `codeVerifier`를 원문으로 찍는다. 그것은 코드 교환의 소유 증명 비밀이라, 코드를 훔친 공격자가
 * 로그에서 verifier를 얻으면 흐름을 완성한다. 같은 패키지의 `TokenSet`은 이미 세 경로를 막는다.
 * `url`/`state`/`nonce`는 그대로 둔다 — Rust의 Debug impl과 동형이다(거기서도 code_verifier만 가린다).
 */
class MaskedAuthorizationRequest implements AuthorizationRequest {
  constructor(
    readonly url: string,
    readonly codeVerifier: string,
    readonly state: string,
    readonly nonce: string,
  ) {}
  #masked(): string {
    return (
      `AuthorizationRequest { url: ${this.url}, state: ${this.state}, ` +
      `nonce: ${this.nonce}, codeVerifier: ${mask(this.codeVerifier)} }`
    )
  }
  toString(): string {
    return this.#masked()
  }
  toJSON(): Record<string, unknown> {
    return {
      url: this.url,
      state: this.state,
      nonce: this.nonce,
      codeVerifier: mask(this.codeVerifier),
    }
  }
  [AR_INSPECT](): string {
    return this.#masked()
  }
}

/** openid-client 그랜트 함수의 토큰 응답 형태(snake_case). */
type GrantResponse = Awaited<ReturnType<typeof oidc.clientCredentialsGrant>>

function base64url(buffer: Buffer): string {
  return buffer.toString('base64url')
}

/**
 * 인증(OIDC/OAuth2) 파사드. openid-client v6의 함수형 API를 감싸며 하위 타입을 공개 API에
 * 노출하지 않는다 — 모든 실패는 경계에서 {@link KeycloakAuthError}로 변환된다(§4 계약).
 *
 * 네트워크 경계라 커버리지 게이트에서 제외된다(vitest exclude); 매핑/PKCE/예외변환 로직은
 * `auth.test.ts`가 openid-client 목킹으로, 실호출은 통합테스트(Task 10)가 검증한다.
 *
 * `Configuration`(discovery 결과)은 첫 토큰 연산 시 한 번 조립해 캐시한다. `serverUrl`이
 * `http://`면(로컬/테스트) `allowInsecureRequests`를 적용하고, 그 외(`https://`)는 TLS를
 * 강제한다 — 보안 기본값을 유지하면서 명시적 http 설정만 완화한다.
 */
export class AuthClient {
  #configuration?: oidc.Configuration
  #discovering?: Promise<oidc.Configuration>
  readonly #cfg: KeycloakConfig
  readonly #endpoints: OidcEndpoints
  readonly #validator: JwtValidator

  /** `validator`는 테스트 주입용(미지정 시 realm JWKS로 강화 검증기를 생성). */
  constructor(cfg: KeycloakConfig, validator?: JwtValidator) {
    this.#cfg = cfg
    this.#endpoints = oidcEndpoints(cfg)
    this.#validator =
      validator ??
      JwtValidator.forJwksUri(this.#endpoints.jwks, {
        issuer: this.#endpoints.issuer,
        // expectedAudience가 설정되면 그 값을, 아니면 clientId를 기대한다(기존 동작).
        audience: cfg.expectedAudience ?? cfg.clientId,
        allowedAlgs: [...cfg.signatureAlgorithms],
        clockSkewSeconds: cfg.clockSkewSeconds,
        jwksMinRefetchSeconds: cfg.jwksMinRefetchSeconds,
      })
  }

  /**
   * PKCE(S256) 인가 코드 흐름의 시작 URL을 만든다(동기·네트워크 없음). PKCE 챌린지는
   * `node:crypto`로 직접 계산해 openid-client의 비동기 헬퍼에 의존하지 않는다(Python SDK와 동형).
   */
  createAuthorizationRequest(redirectUri: string): AuthorizationRequest {
    const codeVerifier = base64url(randomBytes(32))
    const codeChallenge = base64url(createHash('sha256').update(codeVerifier).digest())
    const state = base64url(randomBytes(16))
    const nonce = base64url(randomBytes(16))
    const scope = this.#cfg.scopes.length > 0 ? this.#cfg.scopes.join(' ') : 'openid'
    const url = new URL(this.#endpoints.authorization)
    url.searchParams.set('response_type', 'code')
    url.searchParams.set('client_id', this.#cfg.clientId)
    url.searchParams.set('redirect_uri', redirectUri)
    url.searchParams.set('scope', scope)
    url.searchParams.set('state', state)
    url.searchParams.set('nonce', nonce)
    url.searchParams.set('code_challenge', codeChallenge)
    url.searchParams.set('code_challenge_method', 'S256')
    return new MaskedAuthorizationRequest(url.href, codeVerifier, state, nonce)
  }

  /** `client_credentials` grant로 서비스 계정 토큰을 발급한다. 설정된 scopes를 명시 전달한다. */
  async clientCredentialsToken(): Promise<TokenSet> {
    const config = await this.#discover()
    return this.#grant(
      () =>
        oidc.clientCredentialsGrant(
          config,
          this.#cfg.scopes.length > 0 ? { scope: this.#cfg.scopes.join(' ') } : undefined,
        ),
      'Client credentials grant failed',
    )
  }

  /**
   * 인가 코드 + PKCE verifier를 토큰으로 교환한다(`authorization_code` grant).
   * openid-client는 콜백 URL에서 code를 추출하므로 `redirectUri`에 code(+iss)를 붙여 넘긴다.
   *
   * `createAuthorizationRequest`는 항상 `nonce`를 인가 URL에 실으므로 Keycloak은 발급 id_token에
   * 그 nonce를 담아 돌려준다. openid-client v6는 id_token의 nonce를 자동 검증하며, 기대 nonce를
   * 주지 않으면 "unexpected nonce"로 **거부**한다 — 따라서 `createAuthorizationRequest`가 돌려준
   * `nonce`를 여기로 넘겨야 한다(재생 공격 방어이자 정상 흐름의 필수 조건). nonce 없이 시작한
   * 커스텀 흐름을 위해 인자는 선택적이다.
   */
  async exchangeCode(
    code: string,
    redirectUri: string,
    codeVerifier: string,
    nonce?: string,
  ): Promise<TokenSet> {
    const config = await this.#discover()
    const currentUrl = new URL(redirectUri)
    currentUrl.searchParams.set('code', code)
    // RFC 9207: Keycloak은 인가 응답에 iss를 포함하며 openid-client가 이를 검증한다.
    currentUrl.searchParams.set('iss', this.#endpoints.issuer)
    const checks: oidc.AuthorizationCodeGrantChecks = { pkceCodeVerifier: codeVerifier }
    if (nonce !== undefined) {
      checks.expectedNonce = nonce
    }
    return this.#grant(
      () => oidc.authorizationCodeGrant(config, currentUrl, checks),
      'Authorization code exchange failed',
    )
  }

  /** `refresh_token` grant로 액세스 토큰을 갱신한다. */
  async refresh(refreshToken: string): Promise<TokenSet> {
    const config = await this.#discover()
    return this.#grant(() => oidc.refreshTokenGrant(config, refreshToken), 'Token refresh failed')
  }

  /** RFC 7662 토큰 introspection. 비활성 토큰은 `active` 외 클레임이 생략될 수 있다. */
  async introspect(token: string): Promise<IntrospectionResult> {
    const config = await this.#discover()
    try {
      const response = await oidc.tokenIntrospection(config, token)
      return {
        active: response.active === true,
        username: typeof response.username === 'string' ? response.username : undefined,
        clientId: typeof response.client_id === 'string' ? response.client_id : undefined,
        claims: response as Record<string, unknown>,
      }
    } catch (e) {
      throw new KeycloakAuthError(`Token introspection failed: ${(e as Error).message}`, {
        cause: e,
      })
    }
  }

  /**
   * 세션을 무효화한다(백채널 로그아웃 — refresh_token revoke). Keycloak logout 엔드포인트에
   * client 인증과 함께 refresh_token을 POST한다(front-channel redirect 로그아웃과 구분).
   */
  async logout(refreshToken: string): Promise<void> {
    const body = new URLSearchParams({
      client_id: this.#cfg.clientId,
      refresh_token: refreshToken,
    })
    if (this.#cfg.clientSecret !== undefined) {
      body.set('client_secret', this.#cfg.clientSecret)
    }
    let response: Response
    try {
      response = await globalThis.fetch(this.#endpoints.endSession, {
        method: 'POST',
        headers: { 'content-type': 'application/x-www-form-urlencoded' },
        body,
        signal: AbortSignal.timeout(this.#cfg.readTimeoutMs),
        // SSRF 하드닝: back-channel 요청은 3xx를 따라가지 않는다. fetch 기본값은 'follow'이고
        // undici는 same-host 리다이렉트에서 자격증명을 재전송한다. 여기가 특히 위험한 이유는
        // 실패 모드다 — 302를 따라가 무관한 200을 받으면 `response.ok`가 참이라 **logout이 성공을
        // 반환**하고, 호출자는 세션이 폐기됐다고 믿지만 살아 있다(실측 확인).
        // ⚠️ 'error'가 아니라 'manual'을 쓴다: 'error'는 `TypeError: fetch failed`로 뭉개져
        // 네트워크 장애와 구분되지 않는다. 'manual'은 3xx를 그대로 표면화해 아래 `!response.ok`가
        // 정상적으로 실패로 처리한다 — Go의 `ErrUseLastResponse`와 같은 의미론이다.
        redirect: 'manual',
      })
    } catch (e) {
      throw new KeycloakAuthError(`Logout request error: ${(e as Error).message}`, { cause: e })
    }
    if (!response.ok) {
      throw new KeycloakAuthError(`Logout failed (HTTP ${response.status})`)
    }
  }

  /** realm JWKS로 서명을 검증하고 issuer/audience/exp/nbf를 강제한다(강화 {@link JwtValidator}). */
  async validate(accessToken: string): Promise<ValidatedToken> {
    return this.#validator.validate(accessToken)
  }

  /**
   * auth 자원을 정리한다. openid-client 함수형 API는 전역 `fetch` 기반이라 보유 연결이 없어
   * 현재는 no-op이지만, {@link KeycloakClient} close 프로토콜과 대칭을 이루기 위해 유지한다.
   */
  async close(): Promise<void> {
    return undefined
  }

  /**
   * discovery로 `Configuration`을 한 번 조립해 캐시한다. read 타임아웃(초)을 주입한다.
   * single-flight: 동시 최초 호출이 discovery를 중복 요청하지 않도록 진행중 Promise를 공유하고,
   * 실패는 캐시하지 않는다(재시도 가능) — `ClientCredentialsTokenProvider`와 동일 패턴.
   */
  async #discover(): Promise<oidc.Configuration> {
    if (this.#configuration !== undefined) {
      return this.#configuration
    }
    if (this.#discovering !== undefined) {
      return this.#discovering
    }
    this.#discovering = this.#runDiscovery()
    try {
      return await this.#discovering
    } finally {
      this.#discovering = undefined
    }
  }

  async #runDiscovery(): Promise<oidc.Configuration> {
    const execute: Array<(config: oidc.Configuration) => void> = this.#cfg.serverUrl.startsWith(
      'http://',
    )
      ? [oidc.allowInsecureRequests]
      : []
    // read 타임아웃(초)을 discovery 옵션으로 주입한다. openid-client는 이 값을 최초 `.well-known`
    // 페치와, resolve된 Configuration(이후 모든 HTTP 요청)에 함께 적용한다 — 옵션 미전달 시 최초
    // 페치는 openid-client 기본 30초를 쓰고 readTimeoutMs를 무시했다(이후 요청만 적용되던 결함).
    const timeout = Math.max(1, Math.round(this.#cfg.readTimeoutMs / 1000))
    // openid-client `discovery`는 `{issuer}/.well-known/openid-configuration`를 네트워크 페치하므로
    // 서버 다운(undici `TypeError: fetch failed` + cause)·타임아웃(AbortError)·불량 메타데이터
    // (openid-client 자체 오류)를 던진다. 이들이 §4 계약을 뚫고 원시 하위 오류로 누출되지 않도록
    // 경계에서 SDK 예외로 변환한다(전송 실패는 KeycloakTransportError, 그 외는 KeycloakAuthError).
    let config: oidc.Configuration
    try {
      config = await oidc.discovery(
        new URL(this.#endpoints.issuer),
        this.#cfg.clientId,
        this.#cfg.clientSecret,
        undefined,
        { execute, timeout },
      )
    } catch (e) {
      if (isTransportError(e)) {
        throw new KeycloakTransportError('OIDC discovery transport failure', { cause: e })
      }
      throw new KeycloakAuthError(`OIDC discovery failed: ${(e as Error).message}`, { cause: e })
    }
    this.#configuration = config
    return config
  }

  /** 그랜트 함수를 실행하고 응답을 TokenSet으로 매핑하며, 실패를 KeycloakAuthError로 변환한다. */
  async #grant(fn: () => Promise<GrantResponse>, message: string): Promise<TokenSet> {
    try {
      const response = await fn()
      return tokenSetFromResponse(response as unknown as Record<string, unknown>)
    } catch (e) {
      throw new KeycloakAuthError(`${message}: ${(e as Error).message}`, { cause: e })
    }
  }
}
