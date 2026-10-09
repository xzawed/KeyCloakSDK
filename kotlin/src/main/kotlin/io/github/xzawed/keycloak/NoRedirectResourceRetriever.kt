package io.github.xzawed.keycloak

import com.nimbusds.jose.jwk.JWKSet
import com.nimbusds.jose.jwk.source.JWKSourceBuilder
import com.nimbusds.jose.util.DefaultResourceRetriever
import com.nimbusds.jose.util.Resource
import org.apache.http.client.methods.HttpGet
import java.io.IOException
import java.net.URI
import java.net.URL
import java.nio.charset.StandardCharsets
import java.util.Objects
import java.util.concurrent.ExecutionException
import java.util.concurrent.FutureTask
import javax.net.ssl.HttpsURLConnection

/**
 * JWKS 조회 전용 [DefaultResourceRetriever] — 3xx를 따라가지 않고, 응답의 틀과 본문에 한도를 건다.
 *
 * Nimbus의 기본 리트리버는 `HttpURLConnection`의 기본 동작(리다이렉트 추종)을 그대로 쓴다.
 * 즉 JWKS 엔드포인트가 예상 밖 3xx를 반환하면 SDK가 공격자가 고른 URL을 가져와 **그 응답을
 * 서명 검증용 키 집합으로 사용한다**. 타임아웃만 주입하고 이 플래그를 두면 SSRF 표면이 남는다.
 * 그래서 조회([fetch])는 [BoundedTransport] 로 직접 하고 리다이렉트를 따르는 길을 두지 않는다 — 3xx 는 조회 실패로
 * 표면화되고, 상위 `JWKSourceBuilder`가 그것을 조회 실패로 처리한다 — 조용히 엉뚱한 키를 쓰는 것보다 낫다. Java 자매 SDK와 동형.
 *
 * ⚠️ SDK가 스스로 보내는 요청에 대한 것이다. authorization-code의 `redirect_uri`는 브라우저
 * front-channel 개념이라 무관하다.
 *
 * ⚠️ **응답 크기 상한(3번째 인자)을 반드시 넘긴다.** 이것을 빼면 `DefaultResourceRetriever(int,int)`가
 * sizeLimit 을 **0(무제한)** 으로 넣는다(바이트코드 실측: 2-arg 생성자가 `iconst_0` 을 밀어
 * 3-arg 를 호출한다). 그런데 우리가 리트리버를 주입하지 않았다면 `JWKSourceBuilder` 는 자기
 * 리트리버를 `(500, 500, 51200)` 으로 만든다 — 즉 **하드닝을 주입하는 행위 자체가 Nimbus 의
 * 51200 바이트 상한을 지운다.** 그 상태에서는 JWKS 엔드포인트(또는 그 자리를 차지한 무엇)가
 * 무제한 응답을 흘려 메모리를 채울 수 있다. 상한은 Nimbus 의 `BoundedInputStream` 과 같은 셈으로 집행한다([fetch]).
 *
 * 값은 하드코딩하지 않고 `JWKSourceBuilder.DEFAULT_HTTP_SIZE_LIMIT` 을 참조한다 — 우리가 잃은
 * 바로 그 값이고, 두 번째 정의 자리를 만들지 않는다.
 *
 * ⚠️ 운송이 HttpURLConnection 이던 때는 본문 상한을 넘은 청크 응답을 닫으며 쌓인 바이트를 풀었고 짧은 본문 뒤 트레일러를 한도 없이
 * 담았다(한 줄 1 MiB 에 9 초 — 실측 `ResponseFramingBoundsTest`). 그 둘은 이제 [BoundedTransport] 가 끊고 묶는다. TLS 근원은
 * HttpURLConnection 의 전역 기본값(`HttpsURLConnection.getDefaultSSLSocketFactory()`·검증기 — 조회 때마다 읽는다)으로 Nimbus 의 기본
 * 리트리버가 쓰던 그대로다.
 */
internal class NoRedirectResourceRetriever(
    connectTimeoutMs: Int,
    readTimeoutMs: Int,
) : DefaultResourceRetriever(connectTimeoutMs, readTimeoutMs, JWKSourceBuilder.DEFAULT_HTTP_SIZE_LIMIT) {
    // 200 + {"keys":[]} 를 조회 실패로 돌린다 — Nimbus 캐시는 파싱에 성공한 집합이면 빈 것도 올려
    // 좋은 키를 덮는다(JwksEmptyKeysetTest). 판정은 배열 길이가 아니라 Nimbus 가 **실제로 올릴
    // 집합**의 크기다(같은 파서). 파싱 자체가 실패하면 판정을 Nimbus 에 그대로 맡긴다.
    override fun retrieveResource(url: URL): Resource {
        val res = fetchToCompletion(url)
        val parsed =
            try {
                JWKSet.parse(res.content)
            } catch (_: java.text.ParseException) {
                return res
            }
        if (parsed.keys.isEmpty()) throw IOException("JWKS response contains no keys")
        return res
    }

    /**
     * 조회 하나 — Nimbus `DefaultResourceRetriever.retrieveResource` 가 HttpURLConnection 으로 하던 일을 [BoundedTransport] 로: GET · 이
     * 리트리버의 헤더(제한 헤더는 버린다) · 연결/읽기 타임아웃 · 2xx 가 아니면 실패 · 본문은 UTF-8 · Content-Type 은 마지막 값. 상한은
     * `BoundedInputStream` 과 같은 셈이다 — 읽은 바이트가 상한에 **닿으면** 넘침이다(정확히 51,200 바이트도 거부된다 — Nimbus 대조
     * `TransportParityTest`). 상한까지만 요청하고, 넘치면 나머지를 읽지 않고 끊는다. 비-2xx 의 메시지는 상태 코드만 싣는다(이유 문구는
     * 응답 바이트다). 끝까지 읽은 연결은 auth 레인과 같은 풀로 돌아간다 — Nimbus 의 기본 리트리버는 조회마다 연결을 끊었다
     * (`disconnectAfterUse`).
     */
    internal fun fetch(url: URL): Resource {
        val get = HttpGet(URI.create(url.toString()))
        BoundedTransport.addHeaders(get, Objects.requireNonNullElse(headers, emptyMap()))
        BoundedTransport.addJdkDefaults(get, url)
        val limit = sizeLimit
        return BoundedTransport.exchange(
            get,
            HttpsURLConnection.getDefaultSSLSocketFactory(),
            HttpsURLConnection.getDefaultHostnameVerifier(),
            connectTimeout,
            readTimeout,
            limit,
        ) { head, body ->
            val status = head.statusLine.statusCode
            if (status / 100 != 2) throw IOException("JWKS endpoint returned HTTP $status")
            val content = body.readNBytes(limit)
            if (content.size >= limit) throw IOException("Exceeded configured input limit of $limit bytes")
            Resource(String(content, StandardCharsets.UTF_8), head.getLastHeader("Content-Type")?.value)
        }
    }

    /**
     * 조회를 SDK 의 플랫폼 스레드에서 끝까지 돌리고, 호출자는 인터럽트와 무관하게 그 끝을 기다린 뒤 인터럽트 표시를 되살린다(Java
     * `NoRedirectResourceRetriever.fetchToCompletion` 과 같다).
     *
     * 왜: Nimbus `RateLimitedJWKSetSource` 는 강제 재조회를 하기로 정한 **뒤** 창의 크레딧을 쓰고 그다음 이 메서드를 부른다 — 되돌리지
     * 않는다. 검증은 [onIo] 의 `runInterruptible` 안에서 돌고 코루틴 취소는 그 스레드를 인터럽트한다. HttpURLConnection 의 읽기는 플랫폼
     * 스레드에서 인터럽트를 무시해 조회가 끝까지 갔다(등록부 `jwks-forced-refetch-window-burned` 「kotlin 은 해당 없음」). 이 운송에는
     * 인터럽트에 끝나는 자리가 하나 있다 — 경로의 연결이 모두 쓰이는 동안의 **풀의 기다림**. 그 자리에서 취소되면 크레딧은 썼는데 캐시는
     * 안 차서 창이 닫힐 때까지 회전한 진짜 키가 거부된다(실측 `ConnectionReuseTest` 의 강제 재조회 취소 사례). 그래서 조회는 인터럽트되지
     * 않는 스레드에서 돌고 그 결과 — 조회가 끝나고 캐시가 차며 인터럽트 표시는 남는다 — 를 호출자에게 준다. 캐시는 Nimbus 가 이 메서드를
     * 부른 호출자의 스택에서 채우므로 호출자는 끝을 기다려야 한다. 기다림은 이 리트리버의 연결·읽기 타임아웃(과 51,200 바이트 상한)이
     * 묶는다.
     *
     * ⚠️ 취소에서 크레딧을 되돌리는 것으로 고치지 않는다 — 위조 kid 검증을 취소할 때마다 IdP 요청 하나가 된다(Python 실측 10 대 1).
     * 실패한 조회(503 등)는 지금처럼 그대로 실패로 올라가 창을 쓴다(의도된 동작). 조회 스레드는 데몬이고 조회가 끝나면 끝난다.
     */
    private fun fetchToCompletion(url: URL): Resource {
        val fetch = FutureTask { fetch(url) }
        Thread(fetch, "keycloak-sdk-jwks-fetch").apply { isDaemon = true }.start()
        var interrupted = false
        try {
            while (true) {
                try {
                    return fetch.get()
                } catch (e: InterruptedException) {
                    interrupted = true // 창은 이미 썼다 — 조회가 끝날 때까지 기다린다
                } catch (e: ExecutionException) {
                    throw rethrow(e.cause)
                }
            }
        } finally {
            if (interrupted) Thread.currentThread().interrupt()
        }
    }

    internal companion object {
        /** 조회가 던진 것을 그대로 — 조회는 IOException 만 던지므로(Kotlin 은 선언하지 않는다) 그 밖의 검사 예외는 없다. */
        fun rethrow(cause: Throwable?): IOException =
            when (cause) {
                is RuntimeException -> throw cause
                is Error -> throw cause
                else -> cause as IOException
            }
    }
}
