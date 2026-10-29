import { createHash, randomBytes } from 'node:crypto'
import * as oidc from 'openid-client'
import type { KeycloakConfig } from './config.js'
import { KeycloakAuthError, KeycloakTransportError } from './errors.js'
import { JwtValidator } from './jwt.js'
import { mask } from './masking.js'
import { oidcEndpoints, type OidcEndpoints } from './oidc-metadata.js'
import { fetchTokenEndpointBounded, responseTooLarge } from './token-response-cap.js'
import { isTransportError } from './transport.js'
import {
  tokenSetFromResponse,
  type IntrospectionResult,
  type TokenSet,
  type ValidatedToken,
} from './tokens.js'

/**
 * The bundle of values needed to start a PKCE authorization-code flow.
 * The caller (session) keeps `codeVerifier` until it is passed to `exchangeCode` — the SDK is stateless.
 * `state`/`nonce` are random values that defend against CSRF/replay attacks; the caller must compare them in the
 * callback.
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
 * 실패 메시지의 꼬리. 응답 본문이 상한을 넘었으면 그렇게 말한다 — openid-client 는 fetch 가 던진 상한 신호를
 * `ClientError('something went wrong')` 로 감싸므로 그 겉 메시지는 거짓에 가깝다(`token-response-cap.ts`).
 */
function reasonOf(e: unknown): string {
  return responseTooLarge(e)?.message ?? (e as Error).message
}

/**
 * Authentication (OIDC/OAuth2) facade. It wraps openid-client v6's functional API without exposing the underlying
 * types in the public API — every failure is converted to {@link KeycloakAuthError} at the boundary (§4 contract).
 *
 * Being a network boundary, it is excluded from the coverage gate (vitest exclude); the mapping/PKCE/exception
 * conversion logic is verified by `auth.test.ts` with openid-client mocked, and the real calls by the integration
 * tests (Task 10).
 *
 * The `Configuration` (the discovery result) is assembled once, on the first token operation, and cached. When
 * `serverUrl` is `http://` (local/test) `allowInsecureRequests` is applied; otherwise (`https://`) TLS is enforced
 * — keeping the secure default and relaxing only an explicit http setting.
 */
export class AuthClient {
  #configuration?: oidc.Configuration
  #discovering?: Promise<oidc.Configuration>
  readonly #cfg: KeycloakConfig
  readonly #endpoints: OidcEndpoints
  readonly #validator: JwtValidator
  /** id_token 용 — `#validator` 에서 audience 만 clientId 로 바꿔 파생한다(키 소스 공유). */
  #idTokenValidator?: JwtValidator

  /** `validator` is for test injection (when omitted, a hardened validator is built on the realm JWKS). */
  constructor(cfg: KeycloakConfig, validator?: JwtValidator) {
    this.#cfg = cfg
    this.#endpoints = oidcEndpoints(cfg)
    this.#validator =
      validator ??
      JwtValidator.forJwksUri(this.#endpoints.jwks, {
        issuer: this.#endpoints.issuer,
        // 액세스 토큰: expectedAudience가 설정되면 그 값을, 아니면 clientId를 기대한다(기존 동작).
        // id_token은 이 값을 쓰지 않는다 — `#verifyIdToken`이 clientId로 파생한다.
        audience: cfg.expectedAudience ?? cfg.clientId,
        allowedAlgs: [...cfg.signatureAlgorithms],
        clockSkewSeconds: cfg.clockSkewSeconds,
        jwksMinRefetchSeconds: cfg.jwksMinRefetchSeconds,
      })
  }

  /**
   * Builds the start URL of a PKCE (S256) authorization-code flow (synchronous, no network). The PKCE challenge is
   * computed directly with `node:crypto`, without relying on openid-client's async helpers (isomorphic with the
   * Python SDK).
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

  /** Issues a service-account token with the `client_credentials` grant. The configured scopes are passed explicitly. */
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
   * Exchanges an authorization code + PKCE verifier for tokens (`authorization_code` grant).
   * openid-client extracts the code from the callback URL, so the code (+iss) is appended to `redirectUri` and
   * passed.
   *
   * `createAuthorizationRequest` always puts a `nonce` in the authorization URL, so Keycloak returns that nonce
   * inside the id_token it issues. openid-client v6 verifies the id_token's nonce automatically and, when no
   * expected nonce is given, **rejects** it as "unexpected nonce" — so the `nonce` returned by
   * `createAuthorizationRequest` must be passed here (a defense against replay attacks and a requirement of the
   * normal flow). The argument is optional for custom flows started without a nonce.
   *
   * When a nonce is passed, the id_token is also verified with the hardened {@link JwtValidator} (signature ·
   * `signatureAlgorithms` pin · iss · aud · exp) — the same contract as the other eight languages. The id_token's
   * aud is checked against the **clientId**, not `expectedAudience` (OIDC Core §2·§3.1.3.7). A missing id_token is
   * rejected.
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
    const tokens = await this.#grant(
      () => oidc.authorizationCodeGrant(config, currentUrl, checks),
      'Authorization code exchange failed',
    )
    if (nonce !== undefined) {
      await this.#verifyIdToken(tokens.idToken)
    }
    return tokens
  }

  /**
   * ⚠️ openid-client v6는 토큰 엔드포인트가 준 id_token의 **서명을 보지 않는다** — OIDC Core §3.1.3.7이
   * 그 경우 TLS로 갈음하는 것을 허용하고, JWS 검사는 `enableNonRepudiationChecks`를 켤 때만 돈다. alg도
   * 서버 메타데이터(`id_token_signing_alg_values_supported`, Keycloak은 HS256 포함)로만 거른다. 그래서
   * JWKS 밖 키(HS256)나 위조 RS256 id_token도 nonce만 맞으면 통과했다(통합·단위 실측). SDK 검증기에 태워
   * 서명·alg 핀·iss·aud·exp를 강제한다.
   *
   * id_token의 aud는 **clientId**로 검사한다(OIDC Core §2·§3.1.3.7) — `expectedAudience`는 액세스 토큰의
   * 리소스 서버 제한이다. 검증기는 `#validator`에서 audience만 바꿔 파생하므로 키 소스(JWKS 캐시·재조회
   * 제한·백오프)는 하나다. 파생은 지연한다 — 주입된 검증기가 교환 경로에 닿기 전에는 부르지 않는다.
   */
  async #verifyIdToken(idToken: string | undefined): Promise<void> {
    if (idToken === undefined) {
      throw new KeycloakAuthError(
        'Authorization code exchange failed: missing id_token for nonce validation',
      )
    }
    try {
      this.#idTokenValidator ??= this.#validator.withAudience(this.#cfg.clientId)
      await this.#idTokenValidator.validate(idToken)
    } catch (e) {
      throw new KeycloakAuthError('Authorization code exchange failed: invalid id_token', {
        cause: e,
      })
    }
  }

  /** Renews the access token with the `refresh_token` grant. */
  async refresh(refreshToken: string): Promise<TokenSet> {
    const config = await this.#discover()
    return this.#grant(() => oidc.refreshTokenGrant(config, refreshToken), 'Token refresh failed')
  }

  /** RFC 7662 token introspection. For an inactive token, claims other than `active` may be omitted. */
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
      throw new KeycloakAuthError(`Token introspection failed: ${reasonOf(e)}`, { cause: e })
    }
  }

  /**
   * Invalidates the session (back-channel logout — refresh_token revoke). POSTs the refresh_token, with client
   * authentication, to the Keycloak logout endpoint (as distinct from a front-channel redirect logout).
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

  /** Verifies the signature against the realm JWKS and enforces issuer/audience/exp/nbf (hardened {@link JwtValidator}). */
  async validate(accessToken: string): Promise<ValidatedToken> {
    return this.#validator.validate(accessToken)
  }

  /**
   * Releases auth resources. openid-client's functional API is built on the global `fetch` and holds no
   * connections, so this is currently a no-op, but it is kept for symmetry with the {@link KeycloakClient} close
   * protocol.
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
    //
    // `[oidc.customFetch]` 는 응답 본문 상한이다(`token-response-cap.ts`). openid-client 가 이것을 Configuration 에
    // 복사하므로 discovery 와 이후 세 그랜트·introspection 이 전부 이 한 자리를 지난다. ⚠️ jose 의 `customFetch`
    // 심볼과 **다르다**(실측 `jose.customFetch === oidc.customFetch` → false) — 그것을 쓰면 조용히 무시된다.
    let config: oidc.Configuration
    try {
      config = await oidc.discovery(
        new URL(this.#endpoints.issuer),
        this.#cfg.clientId,
        this.#cfg.clientSecret,
        undefined,
        { execute, timeout, [oidc.customFetch]: fetchTokenEndpointBounded },
      )
    } catch (e) {
      if (isTransportError(e)) {
        throw new KeycloakTransportError('OIDC discovery transport failure', { cause: e })
      }
      throw new KeycloakAuthError(`OIDC discovery failed: ${reasonOf(e)}`, { cause: e })
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
      throw new KeycloakAuthError(`${message}: ${reasonOf(e)}`, { cause: e })
    }
  }
}
