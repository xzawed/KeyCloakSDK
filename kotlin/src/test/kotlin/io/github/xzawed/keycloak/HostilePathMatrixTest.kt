package io.github.xzawed.keycloak

import com.github.tomakehurst.wiremock.WireMockServer
import com.github.tomakehurst.wiremock.client.ResponseDefinitionBuilder
import com.github.tomakehurst.wiremock.client.WireMock.aResponse
import com.github.tomakehurst.wiremock.client.WireMock.any
import com.github.tomakehurst.wiremock.client.WireMock.anyUrl
import com.github.tomakehurst.wiremock.client.WireMock.get
import com.github.tomakehurst.wiremock.client.WireMock.post
import com.github.tomakehurst.wiremock.client.WireMock.urlPathMatching
import com.github.tomakehurst.wiremock.core.WireMockConfiguration.wireMockConfig
import com.nimbusds.jose.JWSAlgorithm
import com.nimbusds.jose.JWSHeader
import com.nimbusds.jose.crypto.RSASSASigner
import com.nimbusds.jose.jwk.JWKSet
import com.nimbusds.jose.jwk.RSAKey
import com.nimbusds.jose.jwk.gen.RSAKeyGenerator
import com.nimbusds.jwt.JWTClaimsSet
import com.nimbusds.jwt.PlainJWT
import com.nimbusds.jwt.SignedJWT
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import java.lang.reflect.InvocationTargetException
import java.lang.reflect.Modifier
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.net.URLDecoder
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.Paths
import java.time.Clock
import java.time.Duration
import java.time.Instant
import java.util.Base64
import java.util.Date
import kotlin.reflect.KCallable
import kotlin.reflect.KClass
import kotlin.reflect.KMutableProperty
import kotlin.reflect.KParameter
import kotlin.reflect.KType
import kotlin.reflect.KVisibility
import kotlin.reflect.full.callSuspendBy
import kotlin.reflect.full.companionObject
import kotlin.reflect.full.declaredMemberExtensionFunctions
import kotlin.reflect.full.declaredMemberExtensionProperties
import kotlin.reflect.full.declaredMemberFunctions
import kotlin.reflect.full.declaredMemberProperties
import kotlin.reflect.full.isSubclassOf
import kotlin.reflect.jvm.jvmErasure
import kotlin.reflect.jvm.kotlinFunction
import kotlin.test.Test
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.seconds

// 적대 경로 행렬 — 분류표를 세우고, 적대 변형을 **메서드 손 목록이 아니라 계급에** 붙인다(등록부
// `guard-detection-surface-hand-narrowed`). Go 파일럿 `go/hostile_path_matrix_test.go` 의 Kotlin 이식이다.
//
// nonce·토큰응답 타입검증·빈 JWKS 축은 `scripts/test/test-security-defaults.sh` 가 손으로 고른 자리에 앵커를 건다. 그래서
// **새 공개 교환 경로**가 생기면 그 축들은 그것을 모른다. 여기서는 경로를 손 목록이 아니라 파생한다:
//
//   - 선언 집합: `FacadeDumpTest` 의 뿌리(dumpRoots)·걷기(DumpWalker)가 닿는 공개 SDK 타입마다 공개 멤버 전부 — 함수·
//     프로퍼티 접근자·멤버 확장·**공개 생성자**. kotlin-reflect 로 읽는다: `internal` 은 바이트코드에서 public 이라 Java
//     리플렉션으로는 못 가르고, `$default` 합성은 여기 안 나온다. 오버로드는 따로 센다. 걷기는 정적 필드를 안 걸으므로 닿은
//     타입의 **companion** 을 한 걸음 더 따라가고, 파일 수준(top-level) 공개 함수를 더한다 — 멤버가 아니라 타입 걷기로는
//     영영 안 보인다(Kotlin 에서 새 교환 경로가 선언 집합을 빠져나갈 가장 쉬운 길이다).
//   - 호출: 행마다 **새** 클라이언트를 기록하는 가짜 IdP(WireMock — 단위 스위트의 목 서버) 위에서 만들어 kotlin-reflect
//     `callSuspendBy` 로 부른다(suspend 포함). 인자는 타입만 보고 합성한다.
//   - 분류: 그 호출이 IdP 에 실제로 보낸 요청으로 가른다(hpClassify). 엔드포인트는 정규화한 경로의 **꼬리**로 보고,
//     grant_type 을 실은 POST 는 경로와 무관하게 토큰 POST 다. 분류 실행은 저널이 조용해질 때까지 기다린다(비동기 요청).
//
// 단언:
//   (1) UNDETERMINED 가 없다(면제 표에 이유와 함께 있으면 통과, 낡은 면제는 실패).
//   (2) CODE_EXCHANGE·TOKEN_GRANT·JWKS_FETCH 가 각각 비어 있지 않다.
//   (W1) 손으로 고른 Kotlin 테스트가 겨누는 멤버(HP_HAND_TARGETS)가 전부 행이고, 기대 계급이고, 그 축의 파생 대상에 있다.
//        표 자신도 손 목록이라 썩지 않게 셋과 대조한다 — 앵커 함수가 정말 그 이름을 부르는가(소스를 읽는다), 형식이 틀린
//        토큰 응답 손 테스트의 `invoke` 가 부르는 공개 이름이 전부 표에 있는가, 보안 기본값 가드의 kotlin 행위 앵커가 전부
//        표의 앵커인가.
//   (W3a) TOKEN_GRANT·CODE_EXCHANGE 행마다 형식이 틀린 토큰 응답 변형. 변형은 새로 만들지 않고 기존 테스트에서 가져온다
//        (hpTokenVariants). 칸마다: 크래시 없음 · 오류 · 그 오류가 SDK 오류 타입 · 카나리아가 오류 렌더링 어디에도 없음 ·
//        토큰 엔드포인트에 닿음 · 대조보다 토큰 요청이 많지 않음 · 적대 토큰 응답 **뒤로** 요청 없음. nonce 파라미터는 비운다
//        (아래 공허 함정). 행마다 정상 응답 대조를 먼저 돈다 — admin 자원 멤버는 정상 응답에도 404 로 실패하므로 그 행에서
//        「오류다」는 공허하고, 무게는 「토큰 뒤로 안 나아갔다」가 진다. 대조가 둘 다 못 가르면 행이 실패한다.
//   (W3b) CODE_EXCHANGE 행 중 **서명에 nonce 이름 파라미터가 있는** 것(kotlin-reflect 파라미터 이름으로 파생)마다 nonce 가
//        다른 id_token · 다른 키(같은 kid·다른 kid) · id_token 없음 · nonce 클레임 없음, 그리고 iss·aud·exp(지남·없음)·
//        alg=none 이 틀린 id_token. 대조(맞는 id_token)는 성공하고 JWKS 에 닿아야 한다. nonce 파라미터가 없어 빠지는
//        CODE_EXCHANGE 행은 HP_NONCE_DROP_EXEMPT 에 이유가 있어야 한다.
//   (W3c) 분류 실행에서 /certs 를 조회한 행마다 콜드 캐시 + /certs 503 에서 k 회 호출 — 전부 실패하고
//        1 ≤ /certs 요청 ≤ k−1. 시간이 아니라 요청 수만 잰다.
// 실패한 칸은 HP_KNOWN_GAPS 에 이유와 함께 있으면 GAP 으로 찍히고, 관측되지 않는 항목은 낡은 것이라 실패한다.
//
// ⚠️ Go 와 다른 자리(Kotlin 이 강제한 것):
//   - 보편 인자(서명한 JWS)만으로는 **로컬 검증**에 막힌다 — Nimbus `CodeVerifier` 는 43–128 자만 받아 JWS(수백 자)를
//     요청 전에 거부한다(→ 요청 없이 실패 = UNDETERMINED). 그래서 UNDETERMINED 인 행만 문자열 자리 **하나씩**을 대안
//     후보(PKCE 형 문자열 V · 절대 URL L)로 바꿔 다시 부르고, 처음 분류되는 벡터를 그 행의 인자로 삼는다. 이름이 아니라
//     자리·타입으로 찾으므로 손 목록이 아니다. 고른 벡터는 표에 찍히고 W3 칸이 그대로 쓴다(nonce 자리는 늘 보편 인자).
//   - 영값 수신자가 없다 — 빌더(공개 API 뿌리)에 안 닿는 타입은 object 싱글턴 → 추상 타입이면 구체 SDK 하위 타입 → 공개
//     생성자(인자 합성) 순서로 만든다. 그래도 없으면 UNDETERMINED 다.
//   - 문자열이 아닌 선택 파라미터는 SDK 기본값을 쓴다(`isExpired(clock, skew)`·`forRealm(allowedAlgs)` 류) — 문자열은 기본값이
//     있어도 늘 합성한다(`exchangeCode(expectedNonce = null)` 이 nonce 경로를 끄지 않게).
//
// ⚠️ 독립 레그(Grok, 2026-09-27)가 「새 공개 교환 멤버가 빠져나갈 길」로 짚은 것 가운데 변이로 SILENT 를 재현하고 닫은 것:
//   - 공개 **생성자**가 교환한다 → 생성자도 행이다(`Type.<init>`, Go 는 New 를 뺐다).
//   - 파일 수준 공개 **프로퍼티**의 접근자가 교환한다 → kotlin-reflect 는 파일 파사드의 프로퍼티 가시성을 못 읽으므로 부르지
//     않고 UNDETERMINED 로 세운다(오늘 파일 수준 프로퍼티는 0 이다).
//   - 반환 **뒤에** 비동기로 요청한다 → 분류 실행은 저널이 HP_SETTLE_QUIET_MS 동안 조용해질 때까지 기다린다.
//   - 토큰 경로를 비튼다(꼬리 `/` 등) → 경로를 정규화하고, grant_type 을 실은 POST 는 경로와 무관하게 토큰 POST 로 본다.
//   - JSON 본문으로 authorization_code 를 보낸다 → TOKEN_GRANT 로 빠져 W3b 를 피했다. grant_type 을 JSON·쿼리에서도 읽는다.
//   - id_token 의 서명·nonce 만 보고 iss·aud·exp·alg 를 안 본다 → W3b 에 그 변형을 더했다.
// ⚠️ 남은 한계(전부 NONE 이나 OTHER 로 읽히거나 보이지 않는다): 기록된 요청도 오류도 없이 끝나는 교환 경로(합성 인자가
// 요청 앞에서 갈라 세우는 것, 이 IdP 가 아닌 호스트로 나가 오류를 버리는 것), 정착 창보다 늦게 나가는 비동기 요청(다음 행에
// 잘못 붙는다), 측정만 하는 변형(at:missing — 200 인데 access_token 이 없는 응답을 받아들여도 이 행렬은 실패하지 않는다:
// 이 행렬이 단언을 끌어오는 테스트에 그 거부가 없다 — admin 레인만 admin/AdminTokenResponseTest 가 따로 단언한다).

private const val HP_CODE_EXCHANGE = "CODE_EXCHANGE"
private const val HP_TOKEN_GRANT = "TOKEN_GRANT"
private const val HP_JWKS_FETCH = "JWKS_FETCH"
private const val HP_OTHER = "OTHER"
private const val HP_NONE = "NONE"
private const val HP_UNDETERMINED = "UNDETERMINED"

private const val HP_PKG = "io.github.xzawed.keycloak."
private const val HP_BASE = "/realms/r/protocol/openid-connect"

// 분류는 realm 과 무관하게 **꼬리**로 본다 — 인자로 받은 realm 의 엔드포인트도 교환이다(Go 레그 실측).
private const val HP_TOKEN_SUFFIX = "/protocol/openid-connect/token"
private const val HP_CERTS_SUFFIX = "/protocol/openid-connect/certs"

private const val HP_CLIENT_SECRET = "HPSECRET-client-secret-0001"

// 대안 문자열 후보 — 보편 인자가 로컬 검증에 막힐 때만 쓴다. V 는 RFC 7636 verifier 모양(43–128 자, unreserved)이라 코드·
// refresh 토큰 자리에도 유효하고, L 은 절대 URL 이다.
private const val HP_VERIFIER = "hp-verifier-vvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvv"
private const val HP_URL = "https://app.example/cb"
private val HP_ALTERNATIVES = listOf("V" to HP_VERIFIER, "L" to HP_URL)

// 콜드 캐시 JWKS 칸의 호출 수 — 상한 k−1 이 물러섬, 하한 1 이 콜드 경로 도달의 증명이다.
private const val HP_COLD_K = 5

// 분류 실행의 정착 창 — 반환 뒤 저널이 이만큼 조용하면 그 행의 요청이 다 왔다고 본다(비동기 요청을 행에 붙인다). 시간을
// 단언하지 않는다 — 요청 수가 멈춘 것을 볼 뿐이고, 상한에 닿으면 그때까지 온 것으로 가른다.
private const val HP_SETTLE_QUIET_MS = 100L
private const val HP_SETTLE_POLL_MS = 20L
private const val HP_SETTLE_MAX_MS = 2_000L

// at:* 변형(토큰 타입 축)의 refresh_token 카나리아 — 쓸 수 없는 토큰 응답이 오류 렌더링에 실리지 않는지 본다.
private const val HP_AT_RT = "HPATRTLEAK-refresh-0001"

/**
 * UNDETERMINED 여도 되는 행과 그 이유. **이유 없는 면제는 넣지 않는다.** 선언 집합에 없거나 더는 UNDETERMINED 가 아닌
 * 항목은 낡은 면제로 실패한다.
 */
private val HP_UNDETERMINED_EXEMPT: Map<String, String> =
    mapOf(
        "ClientCredentialsTokenProvider.<init>" to
            "fetch 는 소비자가 주는 suspend 부여 함수라 타입으로 합성하지 않는다 — 생성자는 받아 저장만 하고(tokenprovider.kt), " +
            "그 함수를 부르는 부여는 accessToken 행(TOKEN_GRANT, 빌더가 auth.clientCredentialsToken 으로 배선)이 잰다",
    )

/**
 * W3b 에서 빠져도 되는 CODE_EXCHANGE 행과 그 이유. nonce 파라미터를 **이름**으로 파생하므로 nonce 를 다른 이름(`expected`
 * 등)으로 받는 새 교환 멤버는 이 표가 없으면 조용히 빠진다(Go 레그가 지목한 부류). **이유 없는 면제는 넣지 않는다.** 오늘은
 * 비어 있다.
 */
private val HP_NONCE_DROP_EXEMPT: Map<String, String> = emptyMap()

/**
 * 현재 `main` 에서 실패하는 칸 — 키는 [HpCell.key](`W3<축> 행/변형`), 값은 `등록부 id: 한 줄 이유`. SDK 를 여기서 고치지
 * 않고 드러내 둔다. 관측되지 않는(이제 통과하거나 칸이 없는) 항목은 낡은 것이라 실패한다. **이유 없는 항목은 넣지 않는다.**
 * 키는 칸 하나하나다(와일드카드 없음). 오늘은 비어 있다.
 */
private val HP_KNOWN_GAPS: Map<String, String> = emptyMap()

internal class HostilePathMatrixTest {
    @Test
    fun `public exchange paths are derived, classified, and get hostile variants by class`(): Unit =
        runBlocking {
            val key = RSAKeyGenerator(2048).keyID("k1").generate()
            val own =
                checkNotNull(
                    KeycloakConfig::class.java.protectionDomain
                        ?.codeSource
                        ?.location,
                ) { "SDK 코드 출처가 없다" }
            val harness =
                checkNotNull(
                    HostilePathMatrixTest::class.java.protectionDomain
                        ?.codeSource
                        ?.location,
                ) { "테스트 코드 출처가 없다" }
            val derivation = hpDerive(own, harness)
            val server = WireMockServer(wireMockConfig().dynamicPort())
            server.start()
            try {
                val idp = HpIdP(server, key)
                hpCheckJournalOrder(idp)
                val env = HpEnv(idp, own.toString(), harness.toString(), derivation.publicTypes)
                env.builderOf = hpProbeBuilders(env)
                hpMatrix(env, derivation)
            } finally {
                server.stop()
            }
        }
}

private suspend fun hpMatrix(
    env: HpEnv,
    derivation: HpDerivation,
) {
    val rows = mutableListOf<HpRow>()
    val byLabel = linkedMapOf<String, HpRow>()
    val methods = linkedMapOf<String, HpMethod>()
    for (m in derivation.methods) {
        val r = hpRun(m, env)
        rows += r
        byLabel[r.label] = r
        methods[r.label] = m
    }
    val called = rows.size
    for ((label, why) in derivation.sourceOnly) {
        val r = HpRow(label, HP_UNDETERMINED, "-", "없음", "-", " · $why", emptyList(), emptyMap())
        rows += r
        byLabel[label] = r
    }
    val counts = hpLogTable(rows, called, derivation)

    val problems = mutableListOf<String>()
    // (1) UNDETERMINED 없음 — 면제는 이유와 함께, 낡은 면제는 실패.
    for (r in rows) {
        if (r.cls == HP_UNDETERMINED && r.label !in HP_UNDETERMINED_EXEMPT) {
            problems += "${r.label}: 분류하지 못했다(UNDETERMINED) — 인자 합성·수신자를 고치거나 이유와 함께 면제하라${r.note}"
        }
    }
    for ((label, reason) in HP_UNDETERMINED_EXEMPT) {
        if (byLabel[label]?.cls != HP_UNDETERMINED) problems += "$label: 낡은 면제다 — 선언 집합에 없거나 더는 UNDETERMINED 가 아니다($reason)"
    }
    // (2) 세 교환 계급이 각각 비어 있지 않다 — 비면 분류기·가짜 IdP·인자 합성 중 하나가 공허해진 것이다.
    for (c in listOf(HP_CODE_EXCHANGE, HP_TOKEN_GRANT, HP_JWKS_FETCH)) {
        if ((counts[c] ?: 0) == 0) problems += "$c 계급이 비었다 — 교환 경로를 하나도 못 찾았다"
    }

    // W3 — 대상은 전부 파생이다: (a) 계급 · (b) 계급 ∩ 서명 · (c) 분류 실행이 보낸 요청.
    val tgt: Map<String, MutableList<String>> = listOf("a", "b", "c").associateWith { mutableListOf() }
    val late = mutableListOf<String>()
    for (r in rows) {
        val m = methods[r.label] ?: continue
        if (r.cls == HP_TOKEN_GRANT || r.cls == HP_CODE_EXCHANGE) tgt.getValue("a") += r.label
        if (r.cls == HP_CODE_EXCHANGE) {
            when {
                hpNonceParams(m).isNotEmpty() -> tgt.getValue("b") += r.label
                r.label in HP_NONCE_DROP_EXEMPT ->
                    println("(b) nonce 파라미터가 없어 빠진 CODE_EXCHANGE 행: ${r.label} — ${HP_NONCE_DROP_EXEMPT[r.label]}")
                else ->
                    late +=
                        "W3b ${r.label}: CODE_EXCHANGE 인데 이름에 nonce 가 든 파라미터가 없어 W3b 가 붙지 않는다 — " +
                        "nonce 를 그 이름으로 받게 하거나, 정말 nonce 없는 흐름이면 이유와 함께 HP_NONCE_DROP_EXEMPT 에 적어라"
            }
        }
        if (r.sent.any(::hpIsCertsGet)) tgt.getValue("c") += r.label
    }
    for ((label, reason) in HP_NONCE_DROP_EXEMPT) {
        val r = byLabel[label]
        val m = methods[label]
        if (r == null || m == null || r.cls != HP_CODE_EXCHANGE || hpNonceParams(m).isNotEmpty()) {
            late += "HP_NONCE_DROP_EXEMPT[$label]: 낡은 면제다 — nonce 파라미터 없는 CODE_EXCHANGE 행이 아니다($reason)"
        }
    }
    val other = RSAKeyGenerator(2048).keyID("k1").generate()
    val cells = mutableListOf<HpCell>()
    cells += hpRunVariantsA(env, methods, byLabel, tgt.getValue("a"), other)
    cells += hpRunNonceB(env, methods, byLabel, tgt.getValue("b"), other)
    cells += hpRunColdJwksC(env, methods, byLabel, tgt.getValue("c"))
    val (fails, summaries) = hpJudge(cells)
    problems += fails

    // W1 — 손 목록 포함. 표의 실패 사유는 판정표 뒤에 모아 찍는다(변이 프로브는 출력 꼬리만 보여 준다).
    problems += late
    problems += hpCheckHand(byLabel, methods, tgt)

    for (p in problems) println("HP-FAIL $p")
    // 요약은 실패 줄 **뒤에** 찍는다.
    summaries.forEach(::println)
    assertTrue(problems.isEmpty(), "적대 경로 행렬 실패 ${problems.size}건:\n" + problems.joinToString("\n"))
}

// ---- 가짜 IdP ----

private data class HpReq(
    val method: String,
    val path: String,
    val grant: String?,
    // 보낸 Authorization 헤더 — 적대 토큰 응답 **뒤로** 나아간 요청이 무엇을 Bearer 로 실었는지 실패 사유에 찍는다.
    val authorization: String? = null,
)

/** 토큰 엔드포인트가 낼 응답 하나. */
private data class HpResp(
    val status: Int,
    val body: String,
    val contentType: String = "application/json",
)

// 기록하는 가짜 IdP — WireMock 저널이 모든 요청(맞은 스텁이 없는 것까지)을 남긴다. 분류는 SDK 가 무엇을 **시도했나**를 본다.
// 서버는 하나를 다시 쓰고 칸마다 스텁·저널을 비운다 — 새로 만드는 것은 **클라이언트**다(캐시가 옆 칸으로 새지 않게).
private class HpIdP(
    val server: WireMockServer,
    val key: RSAKey,
) {
    val iss: String = "${server.baseUrl()}/realms/r"

    // 모든 문자열 인자에 넣는 값이다. ⚠️ 평문이면 토큰을 받는 멤버(validate 둘)가 JWS 파싱에서 요청 없이 실패해
    // UNDETERMINED 가 되고 JWKS_FETCH 가 빈다 — 그래서 이 IdP 키로 서명한 **유효한 JWS** 다(URL·폼에 안전한 글자뿐).
    val universal: String = hpSign(key, key.keyID, iss, emptyMap())

    // 토큰 응답의 id_token — nonce 가 보편 인자라 exchangeCode 의 nonce 검증까지 통과한다.
    val idToken: String = hpSign(key, key.keyID, iss, mapOf("nonce" to universal))

    fun config(): KeycloakConfig =
        KeycloakConfig(
            server.baseUrl(),
            "r",
            "c",
            HP_CLIENT_SECRET.toCharArray(),
            connectTimeout = Duration.ofSeconds(2),
            readTimeout = Duration.ofSeconds(10),
        )

    // expires_in 을 기본 skew(30s) 보다 짧게 준다 — 캐시가 늘 식어 있어 부여에 **닿을 수 있는** 멤버는 실제로 닿는다.
    fun normalToken(): HpResp =
        HpResp(
            200,
            """{"access_token":"hp-access","token_type":"Bearer","expires_in":1,"refresh_token":"hp-refresh",""" +
                """"id_token":"$idToken","scope":"openid"}""",
        )

    /** 스텁을 새로 건다(저널도 비운다). [token] 이 null 이면 정상 응답, [certsDown] 이면 JWKS 가 503 이다. */
    fun serve(
        token: HpResp? = null,
        certsDown: Boolean = false,
    ) {
        server.resetAll()
        val t = token ?: normalToken()
        val oidc = "/realms/[^/]+/protocol/openid-connect"
        server.stubFor(any(anyUrl()).atPriority(10).willReturn(hpJson(404, """{"error":"hp-not-routed"}""")))
        server.stubFor(
            post(urlPathMatching("$oidc/token"))
                .willReturn(aResponse().withStatus(t.status).withHeader("Content-Type", t.contentType).withBody(t.body)),
        )
        server.stubFor(
            post(urlPathMatching("$oidc/token/introspect"))
                .willReturn(hpJson(200, """{"active":true,"username":"svc","client_id":"c","sub":"u1"}""")),
        )
        server.stubFor(
            get(urlPathMatching("$oidc/certs")).willReturn(
                if (certsDown) aResponse().withStatus(503) else hpJson(200, JWKSet(key.toPublicJWK()).toString()),
            ),
        )
        server.stubFor(post(urlPathMatching("$oidc/logout")).willReturn(aResponse().withStatus(204)))
    }

    fun clearJournal() = server.resetRequests()

    // WireMock 저널은 최신이 앞이다 — 시간순으로 뒤집는다(hpCheckJournalOrder 가 이 전제를 잰다).
    fun snapshot(): List<HpReq> =
        server.allServeEvents.reversed().map { e ->
            val method = e.request.method.value()
            val grant = if (method == "POST") hpGrant(e.request.bodyAsString, e.request.url) else null
            HpReq(method, e.request.url.substringBefore('?'), grant, e.request.getHeader("Authorization"))
        }
}

private fun hpJson(
    status: Int,
    body: String,
): ResponseDefinitionBuilder = aResponse().withStatus(status).withHeader("Content-Type", "application/json").withBody(body)

private fun hpFormValue(
    body: String?,
    name: String,
): String? =
    body
        ?.split('&')
        ?.firstOrNull { it.substringBefore('=') == name }
        ?.substringAfter('=', "")
        ?.let { URLDecoder.decode(it, StandardCharsets.UTF_8) }

private val HP_JSON_GRANT = Regex(""""grant_type"\s*:\s*"([^"]*)"""")

// grant_type — 폼 본문, JSON 본문, 쿼리 어디에 있든 읽는다. ⚠️ 폼만 읽으면 JSON 으로 보낸 authorization_code 가 TOKEN_GRANT
// 로 빠져 W3b(nonce·서명)를 피한다(Grok 레그 지목, 변이로 SILENT 재현).
private fun hpGrant(
    body: String?,
    url: String,
): String? =
    hpFormValue(body, "grant_type")
        ?: body?.let { HP_JSON_GRANT.find(it)?.groupValues?.get(1) }
        ?: hpFormValue(url.substringAfter('?', ""), "grant_type")

// 엔드포인트 비교용 경로 — 퍼센트 디코딩 · `;` 경로 파라미터 제거 · 겹친 `/` 접기 · 꼬리 `/` 제거 · 소문자. ⚠️ 꼬리 `/` 하나로
// 토큰 POST 가 OTHER 로 빠졌다(Grok 레그 지목, 변이로 SILENT 재현).
private fun hpNormPath(path: String): String =
    (runCatching { URLDecoder.decode(path.replace("+", "%2B"), StandardCharsets.UTF_8) }.getOrNull() ?: path)
        .replace(Regex(";[^/]*"), "")
        .replace(Regex("/{2,}"), "/")
        .trimEnd('/')
        .lowercase()

// 클레임 — 기본은 이 IdP 가 발급한 유효한 모양(aud=c · 5 분 뒤 만료). [expInMillis] 가 null 이면 exp 를 싣지 않는다.
private fun hpClaims(
    iss: String,
    extra: Map<String, Any>,
    aud: String = "c",
    expInMillis: Long? = 300_000,
): JWTClaimsSet {
    val claims =
        JWTClaimsSet
            .Builder()
            .issuer(iss)
            .subject("u1")
            .audience(aud)
            .issueTime(Date())
    if (expInMillis != null) claims.expirationTime(Date(System.currentTimeMillis() + expInMillis))
    extra.forEach { (k, v) -> claims.claim(k, v) }
    return claims.build()
}

private fun hpSign(
    key: RSAKey,
    kid: String,
    iss: String,
    extra: Map<String, Any>,
    aud: String = "c",
    expInMillis: Long? = 300_000,
): String {
    val jwt = SignedJWT(JWSHeader.Builder(JWSAlgorithm.RS256).keyID(kid).build(), hpClaims(iss, extra, aud, expInMillis))
    jwt.sign(RSASSASigner(key))
    return jwt.serialize()
}

// 계측기 대조 — 저널을 시간순으로 읽는다는 전제(「토큰 **뒤로** 나아갔다」가 여기에 기댄다)를 알려진 순서로 잰다.
private fun hpCheckJournalOrder(idp: HpIdP) {
    idp.serve()
    idp.clearJournal()
    for (p in listOf("/hp-order-1", "/hp-order-2", "/hp-order-3")) {
        val con = URI("${idp.server.baseUrl()}$p").toURL().openConnection() as HttpURLConnection
        con.responseCode
        con.disconnect()
    }
    val order = idp.snapshot().map { it.path }
    check(order == listOf("/hp-order-1", "/hp-order-2", "/hp-order-3")) { "WireMock 저널을 시간순으로 못 읽는다: $order" }
}

// ---- 분류 ----

// 토큰 POST — 경로 꼬리가 토큰 엔드포인트이거나, 경로와 무관하게 grant_type 을 실었다(OAuth 부여는 grant_type 이 정한다).
private fun hpIsTokenPost(r: HpReq): Boolean = r.method == "POST" && (hpNormPath(r.path).endsWith(HP_TOKEN_SUFFIX) || r.grant != null)

private fun hpIsCertsGet(r: HpReq): Boolean = r.method == "GET" && hpNormPath(r.path).endsWith(HP_CERTS_SUFFIX)

// 요청으로 가른다. 앞 줄이 이긴다: 코드 교환 > 토큰 부여 > JWKS 조회 > 그 밖의 요청 > 요청 없음.
// ⚠️ 토큰 엔드포인트 POST 는 grant_type 이 무엇이든 TOKEN_GRANT 다 — 새 grant(password·token-exchange…)가 OTHER 로 새지
// 않게. grant 는 표의 요청 열에 그대로 찍힌다.
private fun hpClassify(
    reqs: List<HpReq>,
    failed: Boolean,
): String =
    when {
        reqs.any { hpIsTokenPost(it) && it.grant == "authorization_code" } -> HP_CODE_EXCHANGE
        reqs.any(::hpIsTokenPost) -> HP_TOKEN_GRANT
        reqs.any(::hpIsCertsGet) -> HP_JWKS_FETCH
        reqs.isNotEmpty() -> HP_OTHER
        failed -> HP_UNDETERMINED
        else -> HP_NONE
    }

private fun hpFormat(
    reqs: List<HpReq>,
    idp: HpIdP,
): String {
    if (reqs.isEmpty()) return "-"
    val count = linkedMapOf<String, Int>()
    for (r in reqs) {
        val p =
            r.path
                .removePrefix(HP_BASE)
                .replace(idp.universal, "{U}")
                .replace(HP_VERIFIER, "{V}")
        val k = "${r.method} $p" + (r.grant?.let { "[$it]" } ?: "")
        count[k] = (count[k] ?: 0) + 1
    }
    return count.entries.joinToString(", ") { (k, n) -> if (n > 1) "$k ×$n" else k }
}

// ---- 선언 집합 ----

private class HpMethod(
    val owner: KClass<*>?,
    val fn: KCallable<*>,
    val label: String,
) {
    val hasInstance: Boolean get() = fn.parameters.any { it.kind == KParameter.Kind.INSTANCE }
    val valueParams: List<KParameter> get() = fn.parameters.filter { it.kind == KParameter.Kind.VALUE }
}

private class HpDerivation(
    val methods: List<HpMethod>,
    // 부르지 못하는 공개 멤버와 그 사유 — UNDETERMINED 행이 된다.
    val sourceOnly: List<Pair<String, String>>,
    val publicTypes: List<KClass<*>>,
    val walkTypes: Int,
    val companions: Int,
    val topLevel: Int,
)

private fun hpTypeLabel(k: KClass<*>): String =
    k.java.name
        .removePrefix(HP_PKG)
        .replace('$', '.')

private fun hpTypeName(t: KType): String = ((t.classifier as? KClass<*>)?.simpleName ?: t.toString()) + if (t.isMarkedNullable) "?" else ""

// 공개 타입 — 자기와 바깥 타입 전부가 Kotlin 가시성 PUBLIC 이다(`internal class` 는 바이트코드에서 public 이라 메타데이터로 가른다).
private fun hpIsPublic(k: KClass<*>): Boolean =
    generateSequence(k.java) { it.declaringClass }.all { c -> runCatching { c.kotlin.visibility }.getOrNull() == KVisibility.PUBLIC }

// 타입이 선언한 공개 멤버 — 함수·멤버 확장·프로퍼티 접근자·생성자. 상속만 한 멤버는 선언한 타입의 행이다(한 번만 센다).
// ⚠️ 생성자도 행이다 — 교환을 하는 생성자는 멤버가 없어도 공개 경로다(Grok 레그 지목, 변이로 SILENT 재현).
private fun hpMembers(k: KClass<*>): List<HpMethod> {
    val type = hpTypeLabel(k)
    val fns = (k.declaredMemberFunctions + k.declaredMemberExtensionFunctions).filter { it.visibility == KVisibility.PUBLIC }
    val overloaded =
        fns
            .groupingBy { it.name }
            .eachCount()
            .filterValues { it > 1 }
            .keys
    val out = mutableListOf<HpMethod>()
    for (f in fns) {
        val sig =
            if (f.name in overloaded) {
                f.parameters.filter { it.kind == KParameter.Kind.VALUE }.joinToString(",", "(", ")") { hpTypeName(it.type) }
            } else {
                ""
            }
        out += HpMethod(k, f, "$type.${f.name}$sig")
    }
    for (p in k.declaredMemberProperties + k.declaredMemberExtensionProperties) {
        if (p.visibility != KVisibility.PUBLIC) continue
        out += HpMethod(k, p.getter, "$type.<get-${p.name}>")
        val setter = (p as? KMutableProperty<*>)?.setter
        if (setter != null && setter.visibility == KVisibility.PUBLIC) out += HpMethod(k, setter, "$type.<set-${p.name}>")
    }
    val ctors = k.constructors.filter { it.visibility == KVisibility.PUBLIC }
    for (c in ctors) {
        val sig = if (ctors.size > 1) c.parameters.joinToString(",", "(", ")") { hpTypeName(it.type) } else ""
        out += HpMethod(k, c, "$type.<init>$sig")
    }
    return out
}

// 파일 수준 공개 함수 — Kotlin 메타데이터 kind 2(파일 파사드)·4(다중 파일 파사드)의 정적 메서드를 kotlin-reflect 로 읽는다.
// kotlin-reflect 가 함수로 못 읽는 정적 메서드(파일 수준 **프로퍼티** 접근자)는 가시성을 알 수 없어 부르지 않고 따로 돌려준다
// — UNDETERMINED 행이 된다(Grok 레그 지목: 접근자가 교환하면 조용히 빠졌다, 변이로 SILENT 재현). 오늘은 0 이다.
private fun hpTopLevel(
    own: URL,
    loader: ClassLoader,
): Pair<List<HpMethod>, List<Pair<String, String>>> {
    val dir = Paths.get(own.toURI())
    val files = Files.walk(dir).use { s -> s.filter { it.fileName.toString().endsWith(".class") }.toList() }
    val out = mutableListOf<HpMethod>()
    val unresolved = mutableListOf<Pair<String, String>>()
    for (f in files) {
        val c = Class.forName(dir.relativize(f).joinToString(".").removeSuffix(".class"), false, loader)
        if (c.getAnnotation(Metadata::class.java)?.kind !in setOf(2, 4)) continue
        for (jm in c.declaredMethods) {
            if (!Modifier.isPublic(jm.modifiers) || !Modifier.isStatic(jm.modifiers) || jm.isSynthetic) continue
            val kf = runCatching { jm.kotlinFunction }.getOrNull()
            if (kf == null) {
                unresolved += "${c.name.removePrefix(HP_PKG)}::${jm.name}" to
                    "파일 수준 정적 메서드인데 kotlin-reflect 가 함수로 못 읽는다(프로퍼티 접근자) — 가시성을 몰라 부르지 않는다. " +
                    "공개면 멤버로 옮기거나 이유와 함께 면제하라"
                continue
            }
            if (kf.visibility != KVisibility.PUBLIC) continue
            out += HpMethod(null, kf, "${c.name.removePrefix(HP_PKG)}::${kf.name}")
        }
    }
    return out to unresolved
}

private suspend fun hpDerive(
    own: URL,
    harness: URL,
): HpDerivation {
    val loader = checkNotNull(KeycloakConfig::class.java.classLoader)
    // 걷기 — FacadeDumpTest 의 뿌리를 그대로 만든다(카나리아 없이: 누출 단언은 그쪽 몫이다). 버리는 서버 위에서 돈다.
    val dumpServer = WireMockServer(wireMockConfig().dynamicPort())
    dumpServer.start()
    val closing = mutableListOf<AutoCloseable>()
    val reached: Set<String>
    try {
        val walker = DumpWalker(emptyMap(), own.toString(), harness.toString())
        dumpRoots(dumpServer, closing).roots.forEach { (name, obj) -> walker.walk(name, obj) }
        reached = walker.reached.toSet()
    } finally {
        hpClose(closing)
        dumpServer.stop()
    }
    val publicTypes = declaredTypes(own, loader).map { it.kotlin }.filter(::hpIsPublic)
    val walkTypes = reached.map { Class.forName(it, false, loader).kotlin }.filter(::hpIsPublic)
    val companions = walkTypes.mapNotNull { k -> k.companionObject?.takeIf(::hpIsPublic) }
    val callTypes = (walkTypes + companions).distinct()
    val (topLevel, topLevelUnresolved) = hpTopLevel(own, loader)
    val methods = (callTypes.flatMap(::hpMembers) + topLevel).sortedBy { it.label }
    val calledLabels = methods.map { it.label }.toSet()
    val unreached =
        publicTypes
            .filter { it !in callTypes }
            .flatMap(::hpMembers)
            .map { it.label }
            .filter { it !in calledLabels }
            .map { it to "걷기가 닿지 않는 타입이라 부르지 않는다(FacadeDumpTest 의 뿌리에 닿게 하거나 이유와 함께 면제하라)" }
    val sourceOnly = (unreached + topLevelUnresolved).sortedBy { it.first }
    return HpDerivation(methods, sourceOnly, publicTypes, walkTypes.size, companions.size, topLevel.size)
}

// ---- 수신자 ----

// 수신자를 얻는 공개 API 뿌리 — **덜 데운 것부터**. 타입은 자기를 처음 닿게 하는 빌더의 새 인스턴스에서 불린다(admin 은
// 아직 토큰을 받기 전의 것에서, JwtValidator 는 JWKS 를 한 번도 안 받은 것에서). 공급자의 fetch 람다는 하네스 객체라
// 걷기가 들어가지 않는다(FacadeDumpTest 의 위생 규칙).
private class HpBuilder(
    val name: String,
    val build: (HpIdP, MutableList<AutoCloseable>) -> Any,
)

private fun hpClient(
    idp: HpIdP,
    closing: MutableList<AutoCloseable>,
): KeycloakClient = KeycloakClient.create(idp.config()).also { closing += it }

private val HP_BUILDERS: List<HpBuilder> =
    listOf(
        HpBuilder("KeycloakClient.create") { p, c -> hpClient(p, c) },
        HpBuilder("KeycloakClient.create.admin") { p, c -> hpClient(p, c).admin },
        HpBuilder("admin.users()") { p, c -> hpClient(p, c).admin.users() },
        HpBuilder("admin.clients()") { p, c -> hpClient(p, c).admin.clients() },
        HpBuilder("admin.realms()") { p, c -> hpClient(p, c).admin.realms() },
        HpBuilder("admin.roles()") { p, c -> hpClient(p, c).admin.roles() },
        HpBuilder("admin.groups()") { p, c -> hpClient(p, c).admin.groups() },
        HpBuilder("JwtValidator.forRealm") { p, _ ->
            val cfg = p.config()
            JwtValidator.forRealm(OidcEndpoints.forRealm(cfg), cfg, cfg.clientId)
        },
        HpBuilder("ClientCredentialsTokenProvider(auth.clientCredentialsToken)") { p, c ->
            val kc = hpClient(p, c)
            ClientCredentialsTokenProvider(fetch = { kc.auth.clientCredentialsToken() })
        },
    )

private class HpEnv(
    val idp: HpIdP,
    val own: String,
    val harness: String,
    val publicTypes: List<KClass<*>>,
) {
    var builderOf: Map<String, Int> = emptyMap()
}

private fun hpClose(closing: List<AutoCloseable>) {
    for (c in closing.asReversed()) runCatching { c.close() }
}

// 타입마다 처음 닿게 하는 빌더 — 빌더마다 한 번씩 걸어 정한다.
private fun hpProbeBuilders(env: HpEnv): Map<String, Int> {
    val builderOf = linkedMapOf<String, Int>()
    env.idp.serve()
    HP_BUILDERS.forEachIndexed { i, b ->
        val closing = mutableListOf<AutoCloseable>()
        try {
            val w = DumpWalker(emptyMap(), env.own, env.harness)
            w.walk(b.name, b.build(env.idp, closing))
            for (name in w.found.keys) builderOf.putIfAbsent(name, i)
        } finally {
            hpClose(closing)
        }
    }
    return builderOf
}

private class HpNoReceiver(
    why: String,
) : Exception(why)

// 이 IdP 위에 새로 만든 뿌리에서 수신자를 꺼낸다. 순서: object 싱글턴 → 빌더 → (추상이면) 구체 SDK 하위 타입 → 공개 생성자.
private fun hpReceiver(
    k: KClass<*>,
    env: HpEnv,
    closing: MutableList<AutoCloseable>,
    depth: Int = 0,
): Pair<Any, String> {
    k.objectInstance?.let { return it to "object" }
    env.builderOf[k.java.name]?.let { i ->
        val b = HP_BUILDERS[i]
        val root = b.build(env.idp, closing)
        if (root.javaClass == k.java) return root to b.name
        val w = DumpWalker(emptyMap(), env.own, env.harness)
        w.walk(b.name, root)
        val found = w.found[k.java.name] ?: throw HpNoReceiver("빌더 ${b.name} 가 탐침 때는 닿았는데 지금은 안 닿는다")
        return found to b.name
    }
    if (k.isAbstract || k.isSealed || k.java.isInterface) {
        if (depth > 3) throw HpNoReceiver("하위 타입 탐색이 너무 깊다")
        val subs =
            env.publicTypes
                .filter { it != k && !it.isAbstract && !it.isSealed && !it.java.isInterface && it.isSubclassOf(k) }
                .sortedBy { it.java.name }
        for (sub in subs) {
            val got = runCatching { hpReceiver(sub, env, closing, depth + 1) }.getOrNull() ?: continue
            return got.first to "하위 ${hpTypeLabel(sub)} ← ${got.second}"
        }
        throw HpNoReceiver("구체 SDK 하위 타입이 없다")
    }
    // 공개 생성자 — Go 의 영값 수신자에 대응한다(빌더에 안 닿는 값 타입·오류 타입).
    val ctor =
        k.constructors.filter { it.visibility == KVisibility.PUBLIC }.minByOrNull { it.parameters.size }
            ?: throw HpNoReceiver("공개 생성자가 없다")
    val args = linkedMapOf<KParameter, Any?>()
    for (p in ctor.parameters) {
        if (p.type.jvmErasure == String::class) {
            args[p] = env.idp.universal
        } else if (!p.isOptional) {
            args[p] = hpValue(p.type, env, closing)
        }
    }
    val made =
        try {
            ctor.callBy(args)
        } catch (e: InvocationTargetException) {
            throw HpNoReceiver("생성자가 실패했다: ${e.targetException}")
        }
    (made as? AutoCloseable)?.let { closing += it }
    return made to "생성자"
}

// ---- 인자 합성 ----

private class HpCannotSynthesize(
    why: String,
) : Exception(why)

// 타입만 보고 값을 만든다. SDK 타입은 수신자와 같은 길로 만든다.
private fun hpValue(
    t: KType,
    env: HpEnv,
    closing: MutableList<AutoCloseable>,
): Any? {
    val k = t.jvmErasure
    return when {
        k == String::class -> env.idp.universal
        k == Int::class -> 1
        k == Long::class -> 1L
        k == Short::class -> 1.toShort()
        k == Byte::class -> 1.toByte()
        k == Double::class -> 1.0
        k == Float::class -> 1f
        k == Boolean::class -> false
        k == Char::class -> 'a'
        k == CharArray::class -> env.idp.universal.toCharArray()
        k == Duration::class -> Duration.ofSeconds(1)
        k == Instant::class -> Instant.now().plusSeconds(300)
        k == Clock::class -> Clock.systemUTC()
        k == KeycloakConfig::class -> env.idp.config()
        k.isSubclassOf(Set::class) -> emptySet<Any>()
        k.isSubclassOf(Map::class) -> emptyMap<Any, Any>()
        k.isSubclassOf(Iterable::class) ->
            if (t.arguments
                    .firstOrNull()
                    ?.type
                    ?.jvmErasure == String::class
            ) {
                listOf(env.idp.universal)
            } else {
                emptyList<Any>()
            }
        k.java.isEnum -> k.java.enumConstants.first()
        t.isMarkedNullable -> null
        k == Any::class -> Any()
        k.java.name.startsWith(HP_PKG) ->
            try {
                hpReceiver(k, env, closing).first
            } catch (e: HpNoReceiver) {
                throw HpCannotSynthesize("${hpTypeName(t)}: ${e.message}")
            }
        else ->
            k.java.constructors
                .firstOrNull { it.parameterCount == 0 && Modifier.isPublic(it.modifiers) }
                ?.newInstance()
                ?: throw HpCannotSynthesize("${hpTypeName(t)} 를 만들 수 없다")
    }
}

// 인자 — 문자열 자리는 [plan] 의 대안(없으면 보편 인자), [blank] 자리는 영값(nullable 은 null, 아니면 빈 문자열), 문자열이
// 아닌 선택 파라미터는 SDK 기본값(생략).
private fun hpArgs(
    m: HpMethod,
    receiver: Any?,
    env: HpEnv,
    plan: Map<Int, String>,
    blank: Set<Int>,
    closing: MutableList<AutoCloseable>,
): Map<KParameter, Any?> {
    val out = linkedMapOf<KParameter, Any?>()
    var vi = 0
    for (p in m.fn.parameters) {
        when (p.kind) {
            KParameter.Kind.INSTANCE -> out[p] = receiver
            KParameter.Kind.VALUE -> {
                val i = vi++
                val isString = p.type.jvmErasure == String::class
                when {
                    i in blank -> out[p] = if (p.type.isMarkedNullable) null else ""
                    isString -> out[p] = plan[i] ?: env.idp.universal
                    p.isOptional -> Unit
                    else -> out[p] = hpValue(p.type, env, closing)
                }
            }
            // 확장 수신자(와 실험 기능인 컨텍스트 파라미터)는 타입으로 합성한다 — SDK 타입이면 수신자와 같은 길이다.
            else -> out[p] = hpValue(p.type, env, closing)
        }
    }
    return out
}

private fun hpUnwrap(e: Throwable): Throwable {
    var t = e
    while (t is InvocationTargetException && t.targetException != null) t = t.targetException
    return t
}

private class HpCall(
    val sent: List<HpReq>,
    val error: Throwable?,
)

// 한 번 부른다. 결과가 닫을 수 있는 것이면 닫는다(`KeycloakClient.create` 의 반환값 등).
private suspend fun hpInvoke(
    fn: KCallable<*>,
    args: Map<KParameter, Any?>,
    closing: MutableList<AutoCloseable>,
): Throwable? =
    try {
        val result = withTimeout(60.seconds) { fn.callSuspendBy(args) }
        (result as? AutoCloseable)?.let { closing += it }
        null
    } catch (e: Throwable) {
        hpUnwrap(e)
    }

// ---- 분류 실행 ----

private class HpRow(
    val label: String,
    val cls: String,
    val reqs: String,
    val recv: String,
    val outcome: String,
    val note: String,
    // 분류 실행이 보낸 요청 그대로 — W3c 대상 파생에 쓴다.
    val sent: List<HpReq>,
    // 이 행을 분류한 문자열 자리 대안(자리 → 값) — W3 칸이 같은 인자로 부른다.
    val plan: Map<Int, String>,
)

private fun hpStringPositions(m: HpMethod): List<Int> =
    m.valueParams
        .withIndex()
        .filter { it.value.type.jvmErasure == String::class }
        .map { it.index }

private suspend fun hpRun(
    m: HpMethod,
    env: HpEnv,
): HpRow {
    val first = hpRunOnce(m, env, emptyMap())
    if (first.cls != HP_UNDETERMINED || first.recv == "없음") return first
    // 요청 없이 실패했다 — 문자열 자리 하나씩 대안으로 바꿔 처음 분류되는 벡터를 쓴다(머리 주석 「Go 와 다른 자리」).
    for (i in hpStringPositions(m)) {
        for ((_, alt) in HP_ALTERNATIVES) {
            val r = hpRunOnce(m, env, mapOf(i to alt))
            if (r.cls != HP_UNDETERMINED) return r
        }
    }
    return first
}

private suspend fun hpRunOnce(
    m: HpMethod,
    env: HpEnv,
    plan: Map<Int, String>,
): HpRow {
    env.idp.serve()
    val closing = mutableListOf<AutoCloseable>()
    try {
        val (recv, src) =
            if (m.hasInstance) {
                try {
                    hpReceiver(checkNotNull(m.owner), env, closing)
                } catch (e: HpNoReceiver) {
                    return HpRow(m.label, HP_UNDETERMINED, "-", "없음", "-", " · 수신자 없음: ${e.message}", emptyList(), plan)
                }
            } else {
                null to "정적"
            }
        val args =
            try {
                hpArgs(m, recv, env, plan, emptySet(), closing)
            } catch (e: HpCannotSynthesize) {
                return HpRow(m.label, HP_UNDETERMINED, "-", src, "-", " · 인자 합성 불가: ${e.message}", emptyList(), plan)
            }
        env.idp.clearJournal() // 뿌리를 만들며 나간 요청은 이 멤버의 몫이 아니다
        val err = hpInvoke(m.fn, args, closing)
        val sent = hpSettle(env.idp)
        val cls = hpClassify(sent, err != null)
        val outcome = if (err == null) "ok" else "err"
        // 사유는 분류를 못 한 행에만 — 요청을 낸 행의 오류(admin 404 등)는 분류와 무관하다.
        val note = if (cls == HP_UNDETERMINED) " · err: $err" else ""
        return HpRow(m.label, cls, hpFormat(sent, env.idp), src, outcome, note, sent, plan)
    } finally {
        hpClose(closing)
    }
}

// 반환 뒤에 비동기로 나가는 요청도 그 행의 몫이다 — 저널이 HP_SETTLE_QUIET_MS 동안 조용해질 때까지 기다린다(Grok 레그 지목:
// 반환 직후 찍으면 fire-and-forget 부여가 NONE 으로 읽혔다, 변이로 SILENT 재현). 시간은 단언하지 않는다.
private suspend fun hpSettle(idp: HpIdP): List<HpReq> {
    var last = idp.snapshot()
    var quietSince = System.nanoTime()
    val deadline = quietSince + HP_SETTLE_MAX_MS * 1_000_000
    while (true) {
        delay(HP_SETTLE_POLL_MS)
        val now = idp.snapshot()
        val t = System.nanoTime()
        if (now.size != last.size) {
            last = now
            quietSince = t
        } else if (t - quietSince >= HP_SETTLE_QUIET_MS * 1_000_000 || t >= deadline) {
            return now
        }
    }
}

private fun hpPlanNote(plan: Map<Int, String>): String =
    if (plan.isEmpty()) {
        ""
    } else {
        " · 인자 " + plan.entries.joinToString(",") { (i, v) -> "#$i=" + (HP_ALTERNATIVES.firstOrNull { it.second == v }?.first ?: v) }
    }

private fun hpLogTable(
    rows: List<HpRow>,
    called: Int,
    d: HpDerivation,
): Map<String, Int> {
    val counts = linkedMapOf<String, Int>()
    val width = rows.maxOf { it.label.length }
    println(
        "선언 집합 ${rows.size} 멤버(부른 것 $called + 소스에만 있는 것 ${rows.size - called}) — 걷기 타입 ${d.walkTypes} · " +
            "companion ${d.companions} · 파일 수준 함수 ${d.topLevel} · 경로의 $HP_BASE 는 생략, {U} 는 보편 인자(서명된 JWS)",
    )
    for (r in rows) {
        counts[r.cls] = (counts[r.cls] ?: 0) + 1
        println("${r.label.padEnd(width)} → ${r.cls.padEnd(13)} · ${r.reqs}  [수신자 ${r.recv} · ${r.outcome}${hpPlanNote(r.plan)}]${r.note}")
    }
    val classes = listOf(HP_CODE_EXCHANGE, HP_TOKEN_GRANT, HP_JWKS_FETCH, HP_OTHER, HP_NONE, HP_UNDETERMINED)
    println("계급별: " + classes.joinToString(" · ") { "$it ${counts[it] ?: 0}" })
    return counts
}

// ---- W3: 계급별 적대 변형 ----

// nonce 파라미터 — 이름에 "nonce" 가 든(대소문자 무시) 값 파라미터의 자리(0 부터, 수신자 제외). **이름 목록이 아니라
// 서명에서** 얻는다(kotlin-reflect 가 메타데이터의 파라미터 이름을 준다).
private fun hpNonceParams(m: HpMethod): Set<Int> =
    m.valueParams
        .withIndex()
        .filter {
            it.value.name
                ?.lowercase()
                ?.contains("nonce") == true
        }.map { it.index }
        .toSet()

// 반환 오류 **자체**가 SDK 오류 계급인가 — 봉인된 뿌리라 SDK 밖에서는 하위 타입을 못 만든다(하위 오류는 경계에서 변환된다, §4).
private fun hpIsSdkError(e: Throwable): Boolean = e is KeycloakException

private fun hpAfterToken(reqs: List<HpReq>): Pair<Int, List<HpReq>> {
    var hits = 0
    val after = mutableListOf<HpReq>()
    for (r in reqs) {
        when {
            hpIsTokenPost(r) -> hits++
            hits > 0 -> after += r
        }
    }
    return hits to after
}

// 토큰 엔드포인트가 내는 형식이 틀린 응답 하나. [from] 이 비면 **측정만** 한다 — 기존 테스트가 이 계급 전체에 단언하지
// 않는 변형에 새 계약을 만들지 않기 위해서다.
private class HpVariant(
    val code: String,
    val from: String,
    val canaries: List<String>,
    val resp: HpResp,
)

// 변형 집합을 새로 만들지 않고 기존 테스트에서 가져온다.
//   - AuthMalformedResponseTest 의 토큰 엔드포인트 변형: 토큰 호출 **전부**(ALL_TOKEN_CALLS — admin 내장 TokenManager 포함)에
//     단언된 것은 단언, 일부 호출에만 단언된 것은 측정만(Go 는 뺐다 — 여기서는 재 둔다). 카나리아는 그 파일이 설계로 면제한 것
//     (MAL_KNOWN_LEAKS — IdP 가 쓴 error_description)을 뺀다. id_token 변형은 W3b 의 몫이고, 카나리아가 그 호출이 보낸 입력인
//     변형은 호출 인자에 묶여 있어 뺀다.
//   - AuthClientTest 의 CC_NON_STRING_ACCESS_TOKENS — 교차언어 가드 토큰 타입 축(1c)의 kotlin 앵커가 단언하는 값이다. Go 가
//     ccAccessTokenCases 로 한 것처럼 계급 전체에 단언한다(그 축의 불변식이 부여 경로의 것이다).
//   - at:missing — 위 두 출처 어디에도 없다(admin 레인만 admin/AdminTokenResponseTest 가 따로 단언한다). 측정만.
//
// ⚠️ 공허 함정: 이 본문들엔 쓸 수 있는 id_token 이 없다. nonce 를 준 exchangeCode 는 정상 토큰 응답이어도 「missing id_token」
// 으로 실패하므로 적대 응답이 안 닿아도 통과한다 — 그래서 W3a 는 nonce 파라미터를 비워 id_token 검증을 끄고 **토큰 응답
// 형식만** 잰다. nonce 는 W3b 가 따로 잰다.
private fun hpTokenVariants(
    idp: HpIdP,
    foreign: RSAKey,
): Pair<List<HpVariant>, List<String>> {
    val out = mutableListOf<HpVariant>()
    val skipped = mutableListOf<String>()
    for (v in malTokenEndpointVariants(idp.iss, idp.key, foreign)) {
        val code = v.id.substringBefore(' ')
        when {
            "\"id_token\"" in v.body -> skipped += "$code(id_token 변형 — W3b 의 몫)"
            v.canaries.isEmpty() -> skipped += "$code(그 호출이 보낸 입력을 되울린다 — 카나리아가 호출 인자에 묶여 있다)"
            else -> {
                val from = if (v.assertedOnEveryTokenCall) "AuthMalformedResponseTest ${v.id}" else ""
                if (from.isEmpty()) skipped += "$code 는 측정만(단언 호출 ${v.assertedCalls.sorted()} — 토큰 호출 전부가 아니다)"
                val canaries =
                    v.canaries
                        .filterKeys { it !in v.knownLeakLabels }
                        .values
                        .toList()
                out += HpVariant(code, from, canaries, HpResp(v.status, v.body, v.contentType))
            }
        }
    }
    for (raw in CC_NON_STRING_ACCESS_TOKENS) {
        out +=
            HpVariant(
                "at:" + raw.replace('"', '\''),
                "AuthClientTest CC_NON_STRING_ACCESS_TOKENS $raw",
                listOf(HP_AT_RT),
                HpResp(200, """{"access_token":$raw,"token_type":"Bearer","expires_in":300,"refresh_token":"$HP_AT_RT"}"""),
            )
    }
    out +=
        HpVariant(
            "at:missing",
            "",
            listOf(HP_AT_RT),
            HpResp(200, """{"token_type":"Bearer","expires_in":300,"refresh_token":"$HP_AT_RT"}"""),
        )
    return out to skipped
}

// W3a 대조 — 변형들과 같은 모양(id_token 없음)의 쓸 수 있는 토큰 응답이다.
private val HP_WELL_FORMED =
    HpResp(200, """{"access_token":"hp-access","token_type":"Bearer","expires_in":300,"refresh_token":"hp-refresh"}""")

// 판정표의 한 칸. why 가 비면 통과, measure 면 단언하지 않고 결과만 찍는다.
private class HpCell(
    val axis: String,
    val label: String,
    val variant: String,
    val why: List<String>,
    val measure: Boolean = false,
    val note: String = "",
) {
    val key: String get() = "W3$axis $label/$variant"
}

// 수신자를 정상 응답으로 만든 **뒤에** 토큰 응답을 [resp] 로 바꾸고(null 이면 정상 그대로) 한 번 부른다.
private suspend fun hpCell0(
    m: HpMethod,
    env: HpEnv,
    plan: Map<Int, String>,
    blank: Set<Int>,
    resp: HpResp?,
): HpCall {
    env.idp.serve()
    val closing = mutableListOf<AutoCloseable>()
    try {
        val recv = if (m.hasInstance) hpReceiver(checkNotNull(m.owner), env, closing).first else null
        env.idp.serve(token = resp)
        val args = hpArgs(m, recv, env, plan, blank, closing)
        env.idp.clearJournal()
        val err = hpInvoke(m.fn, args, closing)
        return HpCall(env.idp.snapshot(), err)
    } finally {
        hpClose(closing)
    }
}

// 오류를 로거가 찍는 꼴 전부 — 문자열·스택(원인 사슬의 "Caused by:" 포함)·원인마다 메시지.
private fun hpRenderings(e: Throwable): Map<String, String> {
    val out = linkedMapOf("toString()" to e.toString(), "stackTraceToString()" to e.stackTraceToString())
    generateSequence(e) { it.cause }.take(16).forEachIndexed { i, c ->
        out["cause[$i].message"] = c.message.orEmpty()
        out["cause[$i].toString()"] = c.toString()
    }
    return out
}

// 적대 토큰 응답 한 칸의 실패 사유 — 비면 통과. [ctlHits] 는 같은 행의 대조가 낸 토큰 요청 수다.
private fun hpHostileWhy(
    call: HpCall,
    canaries: List<String>,
    ctlHits: Int,
    idp: HpIdP,
): List<String> {
    val why = mutableListOf<String>()
    val err = call.error
    when {
        err == null -> why += "오류 없이 성공했다"
        err is Error -> why += "크래시: $err"
        !hpIsSdkError(err) -> why += "SDK 오류 타입이 아니다: ${err.javaClass.name}"
    }
    if (err != null) {
        for ((how, out) in hpRenderings(err)) {
            for (cn in canaries) {
                val hit =
                    when {
                        cn in out -> "전체"
                        cn.length > MAL_PREFIX && cn.take(MAL_PREFIX) in out -> "앞 $MAL_PREFIX 자"
                        else -> null
                    }
                if (hit != null) why += "카나리아 ${cn.take(MAL_PREFIX)}… 가 $how 에 찍혔다($hit)"
            }
        }
    }
    val (hits, after) = hpAfterToken(call.sent)
    if (hits == 0) why += "토큰 엔드포인트에 한 번도 안 닿았다 — 변형이 공허하다"
    // 하한만 두면 틀린 응답마다 재시도하는 새 멤버가 통과한다(Go 레그 지목). 상한은 손 상수가 아니라 같은 행의 대조다.
    if (hits > ctlHits) why += "토큰 요청 $hits 건 — 정상 응답 대조($ctlHits 건)보다 많다: 틀린 응답이 재시도를 부른다"
    if (after.isNotEmpty()) {
        why += "적대 토큰 응답 뒤로 나아갔다: ${hpFormat(after, idp)} (Authorization: ${after.first().authorization?.take(24)})"
    }
    return why
}

private suspend fun hpRunVariantsA(
    env: HpEnv,
    methods: Map<String, HpMethod>,
    byLabel: Map<String, HpRow>,
    labels: List<String>,
    foreign: RSAKey,
): List<HpCell> {
    val (variants, skipped) = hpTokenVariants(env.idp, foreign)
    println(
        "(a) 토큰응답 형식 변형 ${variants.size}(측정만 ${variants.count { it.from.isEmpty() }} 포함) — 기존 테스트에서 파생 · " +
            "뺀 것·측정만: ${skipped.joinToString(", ")}",
    )
    val cells = mutableListOf<HpCell>()
    for (label in labels) {
        val m = methods.getValue(label)
        val plan = byLabel.getValue(label).plan
        val blank = hpNonceParams(m)
        // 호출자가 보낸 비밀도 카나리아다 — 클라이언트 시크릿·그 Basic 자격·이 행이 넘긴 문자열 인자.
        val inputs =
            listOf(HP_CLIENT_SECRET, Base64.getEncoder().encodeToString("c:$HP_CLIENT_SECRET".toByteArray()), env.idp.universal) +
                plan.values.filter { it == HP_VERIFIER }
        // 대조 — 변형과 **같은 모양의** 정상 응답(id_token 없음). 이 행에서 무엇이 적대 변형을 가르는지 정한다: 성공하면
        // 「오류다」가, 토큰 뒤로 나아가면(admin 자원 → 404) 「뒤로 안 나아갔다」가 무게를 진다. 둘 다 아니면 행 전체가 공허하다.
        val ctl = hpCell0(m, env, plan, blank, HP_WELL_FORMED)
        val (hits, after) = hpAfterToken(ctl.sent)
        val ctlWhy = mutableListOf<String>()
        when {
            ctl.error is Error -> ctlWhy += "정상 응답에 크래시: ${ctl.error}"
            hits == 0 -> ctlWhy += "정상 응답에서 토큰 엔드포인트에 안 닿았다 — 이 행의 변형은 공허하다"
            ctl.error != null && after.isEmpty() ->
                ctlWhy += "정상 응답에 실패했고 토큰 뒤로 나아가지도 않았다 — 변형이 무엇을 바꿨는지 가를 수 없다: ${ctl.error}"
        }
        cells += HpCell("a", label, "대조", ctlWhy, note = if (ctl.error == null) "ok" else "↓${after.size}")
        for (v in variants) {
            val call = hpCell0(m, env, plan, blank, v.resp)
            val why = hpHostileWhy(call, v.canaries + inputs, hits, env.idp)
            val measure = v.from.isEmpty()
            cells += HpCell("a", label, v.code, why, measure, if (measure) call.error?.javaClass?.simpleName ?: "성공" else "")
        }
    }
    return cells
}

// W3b 의 변형 — 대조(맞는 id_token)와 거부해야 할 것들. [idToken] 은 (이 IdP, 다른 키) → 토큰 응답에 실을 id_token(null 이면
// 싣지 않는다)이고, nonce 는 보편 인자(=호출에 넘긴 nonce)다. [touchesJwks] 면 검증기가 JWKS 까지 가야 한다(콜드 캐시).
//   - 다섯은 브리프의 것이다: 다른 키로 서명할 때 kid 가 k1 이면 캐시된 키로 서명 검증이 실패하고, k2 면 키를 못 찾는다.
//     「id_token 없음」과 「nonce 클레임 없음」은 requireValidNonce 의 두 거부 가지다(Go 는 같은 둘을 단언한다).
//   - iss·aud·exp·alg 넷은 Grok 레그(P2)가 짚었다 — 서명·nonce 만 보고 나머지 강화 검증을 건너뛰는 새 교환 멤버가 다섯을 다
//     통과했다(변이로 SILENT 재현). 계약은 새로 만든 것이 아니다: `.claude/rules/kotlin.md`「exchangeCode fully validates the
//     id_token (signature · iss · aud · exp)」· 루트 CLAUDE.md「JWT 검증 — none 거부 · iss 정확일치 · aud 포함 · exp 필수」·
//     AuthMalformedResponseTest a5(iss). ⚠️ aud 는 기본 설정(expectedAudience = clientId)에서의 계약이다(등록부
//     `id-token-audience-follows-access-audience` 는 사람 판정 대기).
private class HpNonceVariant(
    val code: String,
    // ok=성공해야 한다 · reject=거부해야 한다
    val want: String,
    val touchesJwks: Boolean = true,
    val idToken: (HpIdP, RSAKey) -> String?,
)

private val HP_NONCE_VARIANTS =
    listOf(
        HpNonceVariant("대조", "ok") { p, _ -> hpSign(p.key, "k1", p.iss, mapOf("nonce" to p.universal)) },
        HpNonceVariant("nonce≠", "reject") { p, _ -> hpSign(p.key, "k1", p.iss, mapOf("nonce" to "hp-other-nonce")) },
        HpNonceVariant("key≠·kid=k1", "reject") { p, o -> hpSign(o, "k1", p.iss, mapOf("nonce" to p.universal)) },
        HpNonceVariant("key≠·kid=k2", "reject") { p, o -> hpSign(o, "k2", p.iss, mapOf("nonce" to p.universal)) },
        HpNonceVariant("id_token없음", "reject", touchesJwks = false) { _, _ -> null },
        HpNonceVariant("nonce클레임없음", "reject") { p, _ -> hpSign(p.key, "k1", p.iss, emptyMap()) },
        HpNonceVariant("iss≠", "reject") { p, _ -> hpSign(p.key, "k1", "${p.iss}-other", mapOf("nonce" to p.universal)) },
        HpNonceVariant("aud≠", "reject") { p, _ -> hpSign(p.key, "k1", p.iss, mapOf("nonce" to p.universal), aud = "hp-other-client") },
        // 만료는 skew(30s)를 넉넉히 넘겨 지난 것이다.
        HpNonceVariant("exp지남", "reject") { p, _ ->
            hpSign(p.key, "k1", p.iss, mapOf("nonce" to p.universal), expInMillis = -600_000)
        },
        HpNonceVariant("exp없음", "reject") { p, _ -> hpSign(p.key, "k1", p.iss, mapOf("nonce" to p.universal), expInMillis = null) },
        // 서명 없는 JWT 는 키를 고르기 전에 거부된다 — JWKS 에 안 닿는 것이 맞다.
        HpNonceVariant("alg=none", "reject", touchesJwks = false) { p, _ ->
            PlainJWT(hpClaims(p.iss, mapOf("nonce" to p.universal))).serialize()
        },
    )

private suspend fun hpRunNonceB(
    env: HpEnv,
    methods: Map<String, HpMethod>,
    byLabel: Map<String, HpRow>,
    labels: List<String>,
    other: RSAKey,
): List<HpCell> {
    println(
        "(b) nonce 대상(서명에서 파생 — 파라미터 자리): " +
            labels.joinToString(", ") { "$it${hpNonceParams(methods.getValue(it)).sorted()}" },
    )
    val cells = mutableListOf<HpCell>()
    for (label in labels) {
        val m = methods.getValue(label)
        // nonce 자리는 늘 보편 인자다 — id_token 의 nonce 가 그것이다.
        val plan = byLabel.getValue(label).plan - hpNonceParams(m)
        for (nv in HP_NONCE_VARIANTS) {
            var body = """"access_token":"hp-access","token_type":"Bearer","expires_in":300,"refresh_token":"hp-refresh""""
            val idToken = nv.idToken(env.idp, other)
            if (idToken != null) body += ""","id_token":"$idToken""""
            val call = hpCell0(m, env, plan, emptySet(), HpResp(200, "{$body}"))
            val certs = call.sent.count(::hpIsCertsGet)
            val why = mutableListOf<String>()
            val err = call.error
            if (err is Error) why += "크래시: $err"
            if (call.sent.none(::hpIsTokenPost)) why += "토큰 엔드포인트에 안 닿았다 — 변형이 공허하다"
            // id_token 이 있는 변형은 검증기에 닿아야 한다(콜드 캐시라 JWKS 를 조회한다) — 아니면 다른 이유로 실패한 것이다.
            if (certs == 0 && nv.touchesJwks) why += "JWKS 를 조회하지 않았다 — id_token 이 검증기에 닿지 않았다"
            when {
                nv.want == "ok" && err != null ->
                    why += "맞는 id_token 에 실패했다 — 아래 변형의 실패가 아무것도 증명하지 않는다: $err"
                nv.want != "ok" && err == null -> why += "틀린 id_token 을 받아들였다"
                nv.want != "ok" && err != null && !hpIsSdkError(err) -> why += "SDK 오류 타입이 아니다: ${err.javaClass.name}"
            }
            cells += HpCell("b", label, nv.code, why, note = "certs $certs")
        }
    }
    return cells
}

private suspend fun hpRunColdJwksC(
    env: HpEnv,
    methods: Map<String, HpMethod>,
    byLabel: Map<String, HpRow>,
    labels: List<String>,
): List<HpCell> {
    println("(c) 콜드 캐시 JWKS 대상(분류 실행이 /certs 를 조회한 행): ${labels.joinToString(", ")}")
    val cells = mutableListOf<HpCell>()
    for (label in labels) {
        val m = methods.getValue(label)
        val plan = byLabel.getValue(label).plan
        env.idp.serve()
        val closing = mutableListOf<AutoCloseable>()
        val why = mutableListOf<String>()
        val certs: Int
        try {
            // 새 클라이언트 — 캐시가 비어 있다. 같은 수신자로 k 번 부른다.
            val recv = if (m.hasInstance) hpReceiver(checkNotNull(m.owner), env, closing).first else null
            env.idp.serve(certsDown = true)
            val args = hpArgs(m, recv, env, plan, emptySet(), closing)
            env.idp.clearJournal()
            for (i in 1..HP_COLD_K) {
                val err = hpInvoke(m.fn, args, closing)
                when {
                    err == null -> why += "${i}번째 호출이 JWKS 503 인데 성공했다"
                    err is Error -> why += "${i}번째 호출이 크래시: $err"
                    !hpIsSdkError(err) -> why += "${i}번째 호출의 오류가 SDK 오류 타입이 아니다: ${err.javaClass.name}"
                }
            }
            certs = env.idp.snapshot().count(::hpIsCertsGet)
        } finally {
            hpClose(closing)
        }
        if (certs < 1) why += "/certs 요청 $certs — 콜드 경로에 닿지 않았다(하한 1)"
        if (certs > HP_COLD_K - 1) why += "/certs 요청 $certs — 실패한 조회가 물러서지 않았다(상한 ${HP_COLD_K - 1})"
        cells += HpCell("c", label, "503×$HP_COLD_K", why, note = "certs $certs")
    }
    return cells
}

// 칸마다 통과·GAP·FAIL 을 정하고 판정표를 찍는다. 실패 사유와 요약을 돌려준다(요약은 실패 줄 뒤에 찍힌다).
private fun hpJudge(cells: List<HpCell>): Pair<List<String>, List<String>> {
    val verdict = linkedMapOf<String, String>()
    val fails = mutableListOf<String>()
    val observed = mutableSetOf<String>()
    for (c in cells) {
        var v =
            when {
                c.measure && c.why.isEmpty() -> "m:rej"
                c.measure -> "m:ACC"
                c.why.isEmpty() -> "pass"
                c.key in HP_KNOWN_GAPS -> {
                    observed += c.key
                    "GAP"
                }
                else -> {
                    fails += "${c.key}: ${c.why.joinToString(" · ")}"
                    "FAIL"
                }
            }
        if (c.note.isNotEmpty() && (c.axis != "a" || c.variant == "대조")) v += "(${c.note})"
        verdict[c.key] = v
    }
    for (axis in listOf("a", "b", "c")) hpLogVerdicts(axis, cells, verdict)
    // 측정 칸은 변형마다 한 줄로 모은다 — 받아들인 행만 이름과 사유를 적는다.
    val measured = linkedMapOf<String, Pair<MutableList<String>, MutableList<String>>>()
    for (c in cells.filter { it.measure }) {
        val (rej, acc) = measured.getOrPut("W3${c.axis} ${c.variant}") { mutableListOf<String>() to mutableListOf() }
        if (c.why.isEmpty()) rej += c.note else acc += "${c.label}(${c.why.joinToString(" · ")})"
    }
    for ((k, v) in measured) {
        println(
            "측정(단언 안 함) $k — 거부 ${v.first.size} · 받아들임 ${v.second.size} · 거부 오류 ${v.first.distinct().sorted()} · " +
                "받아들인 행 ${v.second}",
        )
    }
    for ((key, reason) in HP_KNOWN_GAPS) {
        if (key !in observed) fails += "HP_KNOWN_GAPS[$key]: 더는 관측되지 않는다 — 낡은 항목을 지워라($reason)"
    }
    val summaries = mutableListOf<String>()
    for (axis in listOf("a", "b", "c")) {
        val n = linkedMapOf<String, Int>()
        val failedBy = linkedMapOf<String, Int>()
        for (c in cells.filter { it.axis == axis }) {
            val v = checkNotNull(verdict[c.key]).substringBefore('(')
            n[v] = (n[v] ?: 0) + 1
            if (v == "FAIL") failedBy[c.variant] = (failedBy[c.variant] ?: 0) + 1
        }
        summaries +=
            "W3$axis 요약: pass ${n["pass"] ?: 0} · GAP ${n["GAP"] ?: 0} · FAIL ${n["FAIL"] ?: 0} · " +
            "측정 ${(n["m:rej"] ?: 0) + (n["m:ACC"] ?: 0)}(m:rej ${n["m:rej"] ?: 0} · m:ACC ${n["m:ACC"] ?: 0}) · " +
            "FAIL 열 ${failedBy.entries.map { "${it.key}×${it.value}" }}"
    }
    return fails to summaries
}

// 한 축의 판정표 — 행은 멤버, 열은 변형.
private fun hpLogVerdicts(
    axis: String,
    cells: List<HpCell>,
    verdict: Map<String, String>,
) {
    val mine = cells.filter { it.axis == axis }
    val labels = mine.map { it.label }.distinct()
    val cols = mine.map { it.variant }.distinct()
    if (labels.isEmpty()) {
        println("W3$axis 판정표: 대상 행이 없다")
        return
    }

    fun cell(
        l: String,
        col: String,
    ): String = verdict["W3$axis $l/$col"].orEmpty()
    val first = maxOf(labels.maxOf { it.length }, 10)
    val width = cols.map { col -> maxOf(col.length, labels.maxOf { cell(it, col).length }) }
    println("W3$axis 판정표 — ${labels.size}행 × ${cols.size}열 (pass · GAP=알려진 틈 · FAIL · m:rej/m:ACC=측정만: 거부/받아들임)")
    println(("행 \\ 변형".padEnd(first) + " " + cols.mapIndexed { i, c -> c.padEnd(width[i]) }.joinToString(" ")).trimEnd())
    for (l in labels) println((l.padEnd(first) + " " + cols.mapIndexed { i, c -> cell(l, c).padEnd(width[i]) }.joinToString(" ")).trimEnd())
}

// ---- W1: 손 목록 포함 ----

// 손으로 고른 Kotlin 테스트가 겨누는 멤버 — 파생 집합이 이것 밑으로 **조용히** 줄지 않게 한다. anchor 는 그 손 테스트
// (`파일|함수`), call 은 그 함수가 실제로 부르는 이름, uses 는 그 함수가 읽어야 하는 식별자(행렬이 같은 값을 쓴다는 결속)다.
// axis: a·b·c = 그 W3 축의 파생 대상에 있어야 한다 · row = 행이고 계급이 맞기만 하면 된다(교환 계급 밖).
private class HpHand(
    val label: String,
    val cls: String,
    val axis: String,
    val anchor: String,
    val call: String,
    val uses: String? = null,
)

private const val HP_MAL_INVOKE = "AuthMalformedResponseTest.kt|invoke"

private val HP_HAND_TARGETS =
    listOf(
        // 형식이 틀린 토큰 응답 손 테스트(#617–#624) — `invoke` 가 부르는 공개 호출 전부.
        HpHand("AuthClient.clientCredentialsToken", HP_TOKEN_GRANT, "a", HP_MAL_INVOKE, "clientCredentialsToken"),
        HpHand("AuthClient.refresh", HP_TOKEN_GRANT, "a", HP_MAL_INVOKE, "refresh"),
        HpHand("AuthClient.exchangeCode", HP_CODE_EXCHANGE, "a", HP_MAL_INVOKE, "exchangeCode"),
        HpHand("AuthClient.introspect", HP_OTHER, "row", HP_MAL_INVOKE, "introspect"),
        HpHand("admin.AdminClient.users", HP_NONE, "row", HP_MAL_INVOKE, "users"),
        HpHand("admin.UsersResource.get", HP_TOKEN_GRANT, "a", HP_MAL_INVOKE, "get"),
        // 보안 기본값 가드(scripts/test/test-security-defaults.sh)의 kotlin 행위 앵커 — nonce · 토큰 타입 · 빈 JWKS.
        HpHand(
            "AuthClient.exchangeCode",
            HP_CODE_EXCHANGE,
            "b",
            "AuthClientTest.kt|exchangeCode with mismatched nonce throws KeycloakAuthException",
            "exchangeCode",
        ),
        HpHand(
            "AuthClient.clientCredentialsToken",
            HP_TOKEN_GRANT,
            "a",
            "AuthClientTest.kt|clientCredentialsToken rejects non-string or empty access_token",
            "clientCredentialsToken",
            uses = "CC_NON_STRING_ACCESS_TOKENS",
        ),
        HpHand("JwtValidator.validate", HP_JWKS_FETCH, "c", "JwksEmptyKeysetTest.kt|empty200DoesNotPoisonGoodCache", "validate"),
        // 가드 밖의 손 테스트 — 콜드 캐시 JWKS(Nimbus 가 fetch 를 소유해 가드의 백오프 축에서 빠진 자리) · 위조 id_token.
        HpHand("JwtValidator.validate", HP_JWKS_FETCH, "c", "JwksColdCacheOutageTest.kt|run", "validate"),
        HpHand(
            "AuthClient.exchangeCode",
            HP_CODE_EXCHANGE,
            "b",
            "AuthClientTest.kt|exchangeCode refuses a forged RS256 id_token whose nonce matches",
            "exchangeCode",
        ),
    )

private const val HP_KT_TEST_PATH = "kotlin/src/test/kotlin/io/github/xzawed/keycloak/"

// 보안 기본값 가드가 kotlin 행위 앵커를 적는 두 모양 — `파일|fun 이름(`(nonce·토큰 타입)과 `"파일" "이름"`(빈 JWKS).
private val HP_SCRIPT_ANCHOR_RES =
    listOf(
        Regex("""${Regex.escape(HP_KT_TEST_PATH)}([A-Za-z0-9_/]+\.kt)\|fun (?:`([^`]+)`|([A-Za-z0-9_]+))\("""),
        Regex(""""${Regex.escape(HP_KT_TEST_PATH)}([A-Za-z0-9_/]+\.kt)"\s+"([^"]+)""""),
    )

private fun hpTestSourceDir(): Path =
    Paths.get(System.getProperty("user.dir"), "src", "test", "kotlin", "io", "github", "xzawed", "keycloak")

private fun hpCheckHand(
    byLabel: Map<String, HpRow>,
    methods: Map<String, HpMethod>,
    tgt: Map<String, List<String>>,
): List<String> {
    val why = mutableListOf<String>()
    val dir = hpTestSourceDir()
    if (!Files.isDirectory(dir)) return listOf("W1 테스트 소스 디렉터리가 없다($dir) — 앵커 대조가 공허하다")
    val anchors = HP_HAND_TARGETS.map { it.anchor }.toSet()
    for (h in HP_HAND_TARGETS) {
        val r = byLabel[h.label]
        when {
            r == null -> why += "W1 ${h.label}: 손 테스트(${h.anchor})가 겨누는데 파생 집합에 행이 없다"
            r.cls != h.cls -> why += "W1 ${h.label}: 손 테스트(${h.anchor})가 겨누는 계급은 ${h.cls} 인데 파생은 ${r.cls} 다"
            h.axis != "row" && h.label !in tgt.getValue(h.axis) ->
                why += "W1 ${h.label}: 손 테스트(${h.anchor})가 겨누는데 W3${h.axis} 의 파생 대상에 없다"
        }
        if (!h.label.substringBefore('(').endsWith(".${h.call}")) why += "W1 ${h.label}: 행 이름이 앵커가 부르는 ${h.call} 로 끝나지 않는다"
        val (file, fn) = h.anchor.split('|', limit = 2)
        val body = hpFunctionBody(dir.resolve(file), fn)
        if (body == null) {
            why += "W1 ${h.anchor}: 앵커 함수가 없다 — 손 테스트가 옮겨졌으면 표를 따라 고쳐라"
            continue
        }
        if (h.call !in hpCallsIn(body)) why += "W1 ${h.anchor}: 앵커가 .${h.call}( 를 부르지 않는다 — 손 테스트의 대상이 바뀌었다"
        if (h.uses != null && !Regex("""\b${h.uses}\b""").containsMatchIn(body)) {
            why += "W1 ${h.anchor}: 앵커가 ${h.uses} 를 읽지 않는다 — 행렬의 변형과 손 테스트의 값이 갈라졌다"
        }
    }
    // invoke 가 부르는 SDK 공개 이름은 전부 표에 있다 — 손 테스트에 대상이 늘면 여기가 먼저 운다.
    val sdkNames = methods.values.map { it.fn.name }.toSet()
    val invokeCalls = HP_HAND_TARGETS.filter { it.anchor == HP_MAL_INVOKE }.map { it.call }.toSet()
    val (mf, mfn) = HP_MAL_INVOKE.split('|', limit = 2)
    val sdkInInvoke = hpFunctionBody(dir.resolve(mf), mfn)?.let { hpCallsIn(it) intersect sdkNames }.orEmpty()
    if (sdkInInvoke.isEmpty()) why += "W1 $HP_MAL_INVOKE 에서 SDK 공개 호출을 하나도 못 읽었다 — 대조가 공허하다"
    for (name in sdkInInvoke - invokeCalls) why += "W1 $HP_MAL_INVOKE 이 $name 를 부르는데 HP_HAND_TARGETS 에 없다"
    // 보안 기본값 가드의 kotlin 행위 앵커는 전부 표의 앵커다 — 그 가드에 kotlin 앵커가 늘면 여기가 운다.
    val repo = Paths.get(System.getProperty("user.dir")).parent
    val script = repo.resolve("scripts/test/test-security-defaults.sh")
    when {
        Files.isRegularFile(script) -> {
            // 셸 주석 줄은 벗긴다 — 주석 속 사본이 앵커로 읽히지 않게(함정 (o)).
            val text = Files.readAllLines(script).filterNot { it.trimStart().startsWith("#") }.joinToString("\n")
            val found =
                HP_SCRIPT_ANCHOR_RES.flatMap { re ->
                    re.findAll(text).map { m -> "${m.groupValues[1]}|${m.groupValues.drop(2).first { it.isNotEmpty() }}" }.toList()
                }
            println(
                "W1 손 목록 ${HP_HAND_TARGETS.size} 항목 · 앵커 ${anchors.size} — invoke 의 SDK 공개 호출 ${sdkInInvoke.size} · " +
                    "보안 기본값 가드의 kotlin 행위 앵커 ${found.size} 와 대조",
            )
            if (found.isEmpty()) why += "W1 test-security-defaults.sh 에서 kotlin 행위 앵커를 하나도 못 읽었다 — 적는 모양이 바뀌었나?"
            for (a in found) if (a !in anchors) why += "W1 보안 기본값 가드의 kotlin 앵커 $a 가 HP_HAND_TARGETS 에 없다"
        }
        Files.exists(repo.resolve(".git")) -> why += "W1 저장소 체크아웃인데 보안 기본값 가드를 못 읽었다: $script"
        else -> println("W1: 저장소 밖에서 돌아 보안 기본값 가드 대조는 건너뛴다")
    }
    return why
}

// Kotlin 소스에서 코드만 남긴다 — 주석·문자열·문자 리터럴의 내용을 공백으로 바꾼다(길이·줄 보존). 백틱 식별자는 남긴다.
// 괄호 짝 맞추기와 호출 읽기가 문자열 속 `{`·`.x(` 에 속지 않게 한다(테스트 소스엔 `"""{"access_token":…}"""` 가 흔하다).
private fun hpCodeOnly(src: String): String {
    val out = StringBuilder(src)

    fun blank(
        from: Int,
        to: Int,
    ) {
        for (j in from until minOf(to, out.length)) if (out[j] != '\n') out.setCharAt(j, ' ')
    }

    fun skipChar(start: Int): Int {
        var j = start + 1
        if (j < src.length && src[j] == '\\') j++
        while (j < src.length && src[j] != '\'' && src[j] != '\n') j++
        return minOf(j + 1, src.length)
    }

    fun skipString(start: Int): Int {
        if (src.startsWith("\"\"\"", start)) {
            val end = src.indexOf("\"\"\"", start + 3)
            if (end < 0) return src.length
            var e = end + 3
            while (e < src.length && src[e] == '"') e++
            return e
        }
        var j = start + 1
        while (j < src.length) {
            when {
                src[j] == '\\' -> j += 2
                src[j] == '"' -> return j + 1
                src[j] == '\n' -> return j
                src.startsWith("\${", j) -> {
                    var depth = 1
                    j += 2
                    while (j < src.length && depth > 0) {
                        when (src[j]) {
                            '{' -> depth++
                            '}' -> depth--
                            '"' -> {
                                j = skipString(j) - 1
                            }
                        }
                        j++
                    }
                }
                else -> j++
            }
        }
        return src.length
    }
    var i = 0
    while (i < src.length) {
        when {
            src.startsWith("//", i) -> {
                val end = src.indexOf('\n', i).let { if (it < 0) src.length else it }
                blank(i, end)
                i = end
            }
            src.startsWith("/*", i) -> {
                var depth = 0
                var j = i
                while (j < src.length) {
                    if (src.startsWith("/*", j)) {
                        depth++
                        j += 2
                    } else if (src.startsWith("*/", j)) {
                        depth--
                        j += 2
                        if (depth == 0) break
                    } else {
                        j++
                    }
                }
                blank(i, j)
                i = j
            }
            src[i] == '"' -> {
                val end = skipString(i)
                blank(i, end)
                i = end
            }
            src[i] == '\'' -> {
                val end = skipChar(i)
                blank(i, end)
                i = end
            }
            src[i] == '`' -> {
                val end = src.indexOf('`', i + 1)
                i = if (end < 0) src.length else end + 1
            }
            else -> i++
        }
    }
    return out.toString()
}

// [file] 에서 이름이 [name] 인 함수의 본문(코드만) — 선언의 파라미터 목록 뒤 첫 `{` 부터 짝 맞는 `}` 까지다(식 본문
// `= runTest {` 도 그 람다가 본문이 된다). 없으면 null.
private fun hpFunctionBody(
    file: Path,
    name: String,
): String? {
    if (!Files.isRegularFile(file)) return null
    val code = hpCodeOnly(Files.readString(file))
    val ident = if (Regex("[A-Za-z_][A-Za-z0-9_]*").matches(name)) Regex.escape(name) else Regex.escape("`$name`")
    val decl = Regex("""\bfun\s+$ident\s*\(""").find(code) ?: return null
    var i = decl.range.last
    var depth = 0
    while (i < code.length) {
        if (code[i] == '(') depth++
        if (code[i] == ')' && --depth == 0) break
        i++
    }
    val open = code.indexOf('{', i)
    if (open < 0) return null
    depth = 0
    var j = open
    while (j < code.length) {
        if (code[j] == '{') depth++
        if (code[j] == '}' && --depth == 0) return code.substring(open + 1, j)
        j++
    }
    return null
}

// 본문이 `x.name(…)` 꼴로 부르는 이름 전부.
private fun hpCallsIn(body: String): Set<String> =
    Regex("""\.\s*([A-Za-z_][A-Za-z0-9_]*)\s*\(""")
        .findAll(body)
        .map { it.groupValues[1] }
        .toSet()
