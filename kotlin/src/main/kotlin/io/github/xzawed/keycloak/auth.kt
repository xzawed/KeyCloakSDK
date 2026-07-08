package io.github.xzawed.keycloak

import com.nimbusds.common.contenttype.ContentType
import com.nimbusds.oauth2.sdk.AuthorizationCode
import com.nimbusds.oauth2.sdk.AuthorizationCodeGrant
import com.nimbusds.oauth2.sdk.ClientCredentialsGrant
import com.nimbusds.oauth2.sdk.ParseException
import com.nimbusds.oauth2.sdk.RefreshTokenGrant
import com.nimbusds.oauth2.sdk.ResponseType
import com.nimbusds.oauth2.sdk.Scope
import com.nimbusds.oauth2.sdk.TokenIntrospectionRequest
import com.nimbusds.oauth2.sdk.TokenIntrospectionResponse
import com.nimbusds.oauth2.sdk.TokenRequest
import com.nimbusds.oauth2.sdk.TokenResponse
import com.nimbusds.oauth2.sdk.auth.ClientAuthentication
import com.nimbusds.oauth2.sdk.auth.ClientSecretBasic
import com.nimbusds.oauth2.sdk.auth.Secret
import com.nimbusds.oauth2.sdk.http.HTTPRequest
import com.nimbusds.oauth2.sdk.id.ClientID
import com.nimbusds.oauth2.sdk.id.State
import com.nimbusds.oauth2.sdk.pkce.CodeChallengeMethod
import com.nimbusds.oauth2.sdk.pkce.CodeVerifier
import com.nimbusds.oauth2.sdk.token.RefreshToken
import com.nimbusds.oauth2.sdk.token.Tokens
import com.nimbusds.oauth2.sdk.token.TypelessAccessToken
import com.nimbusds.oauth2.sdk.util.URLUtils
import com.nimbusds.openid.connect.sdk.AuthenticationRequest
import com.nimbusds.openid.connect.sdk.Nonce
import com.nimbusds.openid.connect.sdk.OIDCTokenResponseParser
import com.nimbusds.openid.connect.sdk.token.OIDCTokens
import kotlinx.coroutines.CancellationException
import java.io.IOException
import java.net.URI
import java.time.Instant

// auth.kt — AuthClient: Java SDK의 io.github.xzawed.keycloak.auth.AuthClient와 동형인 흐름(client-credentials·
// PKCE authorization-code·introspect·logout·refresh·validate)을 Nimbus oauth2-oidc-sdk 위에 코루틴으로
// 재구현한다. 모든 네트워크 메서드는 suspend + onIo(jwt.kt의 runInterruptible 래퍼 재사용)로 감싼다.
// 하위 Nimbus 타입은 공개 API에 노출하지 않는다 — OAuth 에러응답은 KeycloakAuthException, send()의
// IOException은 KeycloakTransportException으로 경계 변환한다(§4 계약). 네트워크 경계라 Kover 게이트에서
// 제외된다(build.gradle.kts) — 이 파일의 매핑/PKCE/경계변환 로직은 AuthClientTest가 WireMock으로 검증한다.
public class AuthClient internal constructor(
    private val config: KeycloakConfig,
    private val endpoints: OidcEndpoints,
    injectedValidator: JwtValidator?,
) : AutoCloseable {
    /** 운영 진입점 — realm의 OIDC 엔드포인트 규약으로 endpoints를 조립한다(네트워크 없음). */
    public constructor(config: KeycloakConfig) : this(config, OidcEndpoints.forRealm(config), null)

    // validate()/exchangeCode()의 nonce 검증이 공유하는 지연 생성 JwtValidator. Java AuthClient와 동형인
    // double-checked locking — forRealm()이 non-suspend(JWKS는 첫 validate 호출까지 지연 조회)이므로
    // 이 synchronized 블록 안에는 suspension point가 없다(§코루틴 래핑 핵심 계약 위반 아님).
    @Volatile
    private var jwtValidator: JwtValidator? = injectedValidator
    private val validatorLock = Any()

    /**
     * PKCE(S256) 인가 코드 흐름의 시작 URL을 만든다(non-suspend·네트워크 없음). S256 code_challenge 계산은
     * Nimbus `AuthenticationRequest.Builder.codeChallenge(CodeVerifier, S256)`에 위임한다(Java `AuthClient`
     * 동형 — 직접 SHA-256 계산 불필요). `config.scopes`가 비어 있으면 Java와 동일하게 `openid`로 대체한다.
     */
    public fun createAuthorizationRequest(redirectUri: String): AuthorizationRequest {
        val codeVerifier = CodeVerifier()
        val state = State()
        val nonce = Nonce()
        var scope = Scope(*config.scopes.toTypedArray())
        if (scope.isEmpty()) {
            scope = Scope("openid")
        }
        val request =
            AuthenticationRequest
                .Builder(ResponseType(ResponseType.Value.CODE), scope, ClientID(config.clientId), URI(redirectUri))
                .endpointURI(URI(endpoints.authorization))
                .state(state)
                .nonce(nonce)
                .codeChallenge(codeVerifier, CodeChallengeMethod.S256)
                .build()
        return AuthorizationRequest(request.toURI().toString(), codeVerifier.value, state.value, nonce.value)
    }

    /** `client_credentials` 그랜트로 서비스계정 토큰을 발급한다. `config.scopes`를 명시 전달한다(부록 §auth exactConfig). */
    public suspend fun clientCredentialsToken(): TokenSet {
        val issuedAt = Instant.now().epochSecond
        val tr =
            TokenRequest
                .Builder(URI(endpoints.token), clientAuth(), ClientCredentialsGrant())
                .scope(Scope(*config.scopes.toTypedArray()))
                .build()
        return mapTokenResponse(authSend(tr.toHTTPRequest()), issuedAt, "Client credentials failed")
    }

    /**
     * 인가 코드 + PKCE verifier를 토큰으로 교환한다(`authorization_code` 그랜트). 기밀 클라이언트
     * (clientSecret 설정됨)는 ClientSecretBasic, 퍼블릭 클라이언트는 client_id만 본문에 포함한다(Java 동형).
     *
     * `createAuthorizationRequest`가 돌려준 `nonce`를 [expectedNonce]로 넘기면, 응답 id_token을 realm
     * JWKS로 서명·iss·aud·exp까지 강화 검증한 뒤(§jwt 재사용) nonce 클레임까지 대조한다 — Node SDK가 겪은
     * HIGH 결함(nonce를 threading하지 않으면 id_token이 사실상 무검증으로 통과)을 원천 차단한다.
     * `expectedNonce`를 생략하면(커스텀 무-nonce 흐름) id_token 검증을 건너뛴다.
     */
    public suspend fun exchangeCode(
        code: String,
        codeVerifier: String,
        redirectUri: String,
        expectedNonce: String? = null,
    ): TokenSet {
        val issuedAt = Instant.now().epochSecond
        val grant = AuthorizationCodeGrant(AuthorizationCode(code), URI(redirectUri), CodeVerifier(codeVerifier))
        val builder =
            if (config.clientSecret != null) {
                TokenRequest.Builder(URI(endpoints.token), clientAuth(), grant)
            } else {
                TokenRequest.Builder(URI(endpoints.token), ClientID(config.clientId), grant)
            }
        // oidc=true: id_token을 실제로 담아 오는 유일한 그랜트라 OIDC 인지 파서로 파싱해야 id_token이 보존된다
        // (플레인 TokenResponse.parse는 Tokens만 만들고 OIDCTokens/id_token을 인지하지 못한다).
        val tokenSet =
            mapTokenResponse(
                authSend(builder.build().toHTTPRequest(), oidc = true),
                issuedAt,
                "Authorization code exchange failed",
            )
        if (expectedNonce != null) {
            requireValidNonce(tokenSet.idToken, expectedNonce)
        }
        return tokenSet
    }

    /** `refresh_token` 그랜트로 액세스 토큰을 갱신한다. */
    public suspend fun refresh(refreshToken: String): TokenSet {
        val issuedAt = Instant.now().epochSecond
        val tr =
            TokenRequest
                .Builder(URI(endpoints.token), clientAuth(), RefreshTokenGrant(RefreshToken(refreshToken)))
                .build()
        return mapTokenResponse(authSend(tr.toHTTPRequest()), issuedAt, "Token refresh failed")
    }

    /** RFC 7662 토큰 introspection. 비활성 토큰은 active 외 클레임이 생략될 수 있다. */
    public suspend fun introspect(token: String): IntrospectionResult {
        val req = TokenIntrospectionRequest(URI(endpoints.introspection), clientAuth(), TypelessAccessToken(token))
        val resp =
            try {
                onIo { TokenIntrospectionResponse.parse(applyTimeouts(req.toHTTPRequest()).send()) }
            } catch (e: CancellationException) {
                throw e
            } catch (e: IOException) {
                throw KeycloakTransportException("Introspection request failed", e)
            } catch (e: ParseException) {
                throw KeycloakAuthException("Malformed introspection response", c = e)
            }
        if (!resp.indicatesSuccess()) {
            val err = resp.toErrorResponse().errorObject
            throw KeycloakAuthException("Introspection failed: ${err.description}", err.code)
        }
        val success = resp.toSuccessResponse()
        return IntrospectionResult(success.isActive, success.username, success.clientID?.value)
    }

    /** 세션을 무효화한다(백채널 로그아웃 — refresh_token revoke). */
    public suspend fun logout(refreshToken: String) {
        val resp =
            try {
                onIo { applyTimeouts(buildLogoutRequest(refreshToken)).send() }
            } catch (e: CancellationException) {
                throw e
            } catch (e: IOException) {
                throw KeycloakTransportException("Logout request failed", e)
            }
        if (!resp.indicatesSuccess()) {
            throw KeycloakAuthException("Logout failed (HTTP ${resp.statusCode})")
        }
    }

    /** realm JWKS로 서명을 검증하고 issuer/audience/exp/nbf를 강제한다(강화 [JwtValidator], §jwt 재사용). */
    public suspend fun validate(accessToken: String): ValidatedToken = ensureValidator().validate(accessToken)

    /**
     * auth 자원을 정리한다. Nimbus `HTTPRequest.send()`는 호출마다 ephemeral `HttpURLConnection`을 열 뿐
     * AuthClient가 소유하는 커넥션 풀이 없어 no-op이지만, [KeycloakClient] close 프로토콜과의 대칭을 위해
     * `AutoCloseable`을 구현한다(Node `AuthClient.close()` 동형).
     */
    override fun close() {
        // 의도적 no-op: 소유하는 커넥션 풀/자원이 없다(위 KDoc 참조). AutoCloseable만 대칭을 위해 구현.
    }

    private fun ensureValidator(): JwtValidator {
        jwtValidator?.let { return it }
        synchronized(validatorLock) {
            jwtValidator?.let { return it }
            val created = JwtValidator.forRealm(endpoints, config, config.clientId)
            jwtValidator = created
            return created
        }
    }

    // id_token의 nonce 클레임을 대조하기 전에 realm JWKS로 서명·iss·aud·exp까지 강화 검증한다(ensureValidator
    // 재사용 — 액세스 토큰과 id_token 모두 aud=config.clientId이므로 검증기를 공유해도 안전하다).
    private suspend fun requireValidNonce(
        idToken: String?,
        expectedNonce: String,
    ) {
        if (idToken == null) {
            throw KeycloakAuthException("Authorization code exchange failed: missing id_token for nonce validation")
        }
        val claims =
            try {
                ensureValidator().validate(idToken)
            } catch (e: CancellationException) {
                throw e
            } catch (e: TokenValidationException) {
                throw KeycloakAuthException("Authorization code exchange failed: invalid id_token", c = e)
            }
        if (claims.claims["nonce"] as? String != expectedNonce) {
            throw KeycloakAuthException("Authorization code exchange failed: unexpected nonce")
        }
    }

    // 토큰 엔드포인트 send() + 경계변환 공용 헬퍼(부록 §auth exactConfig의 clientCredentialsToken 인라인
    // 로직을 세 그랜트(client-credentials/refresh/exchangeCode)가 공유하도록 factoring). oidc=true일 때만
    // OIDCTokenResponseParser로 파싱해 id_token을 보존한다(exchangeCode 전용 — 나머지 그랜트는 id_token이
    // 없어도 플레인 파서로 충분하다).
    private suspend fun authSend(
        req: HTTPRequest,
        oidc: Boolean = false,
    ): TokenResponse =
        try {
            onIo {
                val httpResponse = applyTimeouts(req).send()
                if (oidc) OIDCTokenResponseParser.parse(httpResponse) else TokenResponse.parse(httpResponse)
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: IOException) {
            throw KeycloakTransportException("Auth request failed", e)
        } catch (e: ParseException) {
            throw KeycloakAuthException("Malformed auth response", c = e)
        }

    private fun mapTokenResponse(
        resp: TokenResponse,
        issuedAt: Long,
        failureMessage: String,
    ): TokenSet {
        if (!resp.indicatesSuccess()) {
            val err = resp.toErrorResponse().errorObject
            throw KeycloakAuthException("$failureMessage: ${err.description}", err.code)
        }
        return toTokenSet(resp.toSuccessResponse().tokens, issuedAt)
    }

    // Nimbus Tokens → SDK 소유 TokenSet 매핑(Java toTokenSet 동형). tokens가 OIDCTokens(=id_token 포함
    // 가능)이면 id_token도 실어 나른다 — Java는 id_token을 아예 캡처하지 않지만, TokenSet.idToken 필드가
    // 이미 존재하므로(tokens.kt) exchangeCode의 nonce 검증을 위해 값을 채운다.
    private fun toTokenSet(
        tokens: Tokens,
        issuedAtEpoch: Long,
    ): TokenSet {
        val at = tokens.accessToken
        val expiresAt = Instant.ofEpochSecond(issuedAtEpoch + at.lifetime)
        val refresh = tokens.refreshToken?.value
        val idToken = (tokens as? OIDCTokens)?.getIDToken()?.serialize()
        return TokenSet(at.value, refresh, idToken, "Bearer", at.scope?.toString(), expiresAt)
    }

    // Nimbus HTTPRequest에 KeycloakConfig 타임아웃을 적용한다(부록 §코루틴 래핑 핵심 계약 exactConfig).
    private fun applyTimeouts(req: HTTPRequest): HTTPRequest =
        req.apply {
            connectTimeout = config.connectTimeout.toMillis().toInt()
            readTimeout = config.readTimeout.toMillis().toInt()
        }

    // 기밀 클라이언트(clientSecret 설정됨)를 요구하는 그랜트(client-credentials/refresh/introspect/logout)의
    // 공용 클라이언트 인증. Java의 암묵적 NPE(시크릿 없이 new String((char[]) null)) 대신 명시적으로
    // KeycloakAuthException을 던진다 — 같은 실패 조건을 더 나은 진단으로 대체할 뿐 동작은 동형이다.
    private fun clientAuth(): ClientAuthentication {
        val secret =
            config.clientSecret
                ?: throw KeycloakAuthException("Confidential client required: clientSecret is not configured")
        return ClientSecretBasic(ClientID(config.clientId), Secret(String(secret)))
    }

    private fun buildLogoutRequest(refreshToken: String): HTTPRequest {
        val req = HTTPRequest(HTTPRequest.Method.POST, URI(endpoints.logout))
        req.setEntityContentType(ContentType.APPLICATION_URLENCODED)
        clientAuth().applyTo(req)
        val params = linkedMapOf("refresh_token" to listOf(refreshToken))
        req.setBody(URLUtils.serializeParameters(params))
        return req
    }
}
