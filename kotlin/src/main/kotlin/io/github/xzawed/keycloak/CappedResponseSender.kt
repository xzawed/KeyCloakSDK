package io.github.xzawed.keycloak

import com.nimbusds.oauth2.sdk.http.HTTPRequest
import com.nimbusds.oauth2.sdk.http.HTTPRequestSender
import com.nimbusds.oauth2.sdk.http.HTTPResponse
import com.nimbusds.oauth2.sdk.http.ReadOnlyHTTPRequest
import com.nimbusds.oauth2.sdk.http.ReadOnlyHTTPResponse
import org.apache.http.HttpResponse
import org.apache.http.client.methods.HttpRequestBase
import org.apache.http.client.methods.RequestBuilder
import org.apache.http.entity.ByteArrayEntity
import java.io.BufferedReader
import java.io.ByteArrayInputStream
import java.io.IOException
import java.io.InputStream
import java.io.InputStreamReader
import java.net.URI
import java.nio.ByteBuffer
import java.nio.CharBuffer
import java.nio.charset.Charset
import java.nio.charset.CoderResult
import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets

/**
 * 토큰 엔드포인트(세 그랜트 — auth 레인과 admin 레인의 자기 토큰 부여)·introspection·logout 응답 본문의 크기 상한(바이트).
 *
 * ⚠️ 아홉 언어가 함께 움직이는 값이고 교차언어 가드가 이 리터럴을 읽는다 — 식(`1 shl 20`)이 아니라 맨 십진 리터럴로 두고 여기
 * 한 곳에만 선언한다(auth 레인의 [CappedResponseSender] 와 admin 레인의 `TokenResponseGuard` 가 함께 쓰고, admin 엔진이 자원 응답의
 * 오류 본문 상한으로 빌린다 — 성공 본문에는 걸지 않는다). Keycloak 26.6 기본
 * 설정(start-dev 로 실측)이 받아들이는 가장 긴 Bearer(65,459 바이트 — 한 바이트 더 길면 HTTP 431)의 16 배라 서버가 받아들이는
 * 토큰을 거부하지 않는다. JWKS 응답 상한(51,200)을 빌리지 말 것 — 큰 배포의 쓸 수 있는 토큰을 거부했다.
 */
internal const val TOKEN_RESPONSE_MAX_BYTES: Int = 1_048_576

/**
 * 응답의 **틀**에서 한 줄의 최대 바이트 — 상태 줄 · 헤더 줄 · 청크 크기 줄(확장 포함) · 트레일러 줄. auth 레인(토큰·introspection·logout·
 * JWKS — [BoundedTransport])과 admin 레인(RESTEasy 의 HttpCore — `AdminClient.buildTimeoutClient`)이 함께 건다. 넘으면 그 호출은 전송 실패다.
 *
 * 왜: 본문 상한은 본문만 센다. 짧은 청크 본문 뒤의 트레일러를 JDK 는 한도 없이 담았고(4 MiB 줄 → 호출 하나 51.5 MB, 한 줄 512 KiB →
 * 4.3 GB · 1.5 초 — 등록부 `jvm-chunked-trailers-unbounded` 의 kotlin 실측), HttpCore 는 줄·헤더 수의 기본 한도가 없다(-1) — 실측
 * `ResponseFramingBoundsTest`·`AdminResponseFramingTest`. Java `ResponseLimits.MAX_LINE_LENGTH` 와 같은 값이다(Kotlin 은 한 모듈이라
 * 공개 상수가 아니라 여기 한 번 둔다). Keycloak 26.6.4 의 가장 긴 응답 헤더 줄은 85 바이트였다(Java 실측).
 */
internal const val RESPONSE_MAX_LINE_LENGTH: Int = 8192

/** 응답 헤더 하나의 절(머리 또는 트레일러)에 들 수 있는 최대 필드 수 — [RESPONSE_MAX_LINE_LENGTH] 와 함께 건다(Java `ResponseLimits.MAX_HEADER_COUNT`). */
internal const val RESPONSE_MAX_HEADER_COUNT: Int = 100

/**
 * SDK 가 스스로 읽는 응답을 요청을 보낸 때부터 읽기 타임아웃 안에 다 읽지 못했다 — 그 실패([java.net.SocketTimeoutException], 읽기
 * 타임아웃과 같은 타입)의 메시지 머리. 뒤에 마감의 길이만 붙는다(응답을 인용하지 않는다). auth 레인([BoundedTransport])과 admin 레인
 * (`AdminEngine`)이 함께 쓴다 — Java 의 같은 메시지와 같다.
 */
internal const val RESPONSE_LATE: String = "Read timed out: the response was not fully read within "

/** 상한을 넘는 응답 — 메시지는 무엇이 상한을 넘었는지만 말한다(응답을 인용하지 않는다). */
internal class ResponseTooLargeException(
    what: String,
) : IOException("$what exceeds $TOKEN_RESPONSE_MAX_BYTES bytes")

/**
 * 끝까지 왔으나 2xx 본문이 UTF-8 이 아닌 응답([CappedResponseSender] 의 strict) — 전송 실패가 아니다(그 레인의 인증 오류다, 등록부
 * token-response-class-divergent). 메시지는 무엇이 UTF-8 이 아닌지만 말한다(응답을 인용하지 않는다). Java `CappedResponseSender.NotUtf8` 동형.
 */
internal class ResponseNotUtf8Exception(
    what: String,
) : IOException("$what is not valid UTF-8")

/**
 * 엄격한 UTF-8 인가 — 잘못된 바이트(끝에서 잘린 열 · 겹침 꼴 · 서로게이트 포함)를 대체하지 않고 보고하는 디코더로 잰다. 입력의 끝을 알리고
 * 디코딩하므로 잘린 마지막 열도 여기서 보고된다(UTF-8 디코더는 비울 상태가 없다). 디코딩한 글자는 버린다(고정 4 KiB 버퍼 — 본문만 한 글자
 * 배열을 따로 잡지 않는다). BOM 은 UTF-8 의 유효한 바이트다(지금처럼 파서가 판정한다). Java `CappedResponseSender.isUtf8` 동형.
 */
internal fun isUtf8(body: ByteArray): Boolean {
    val decoder =
        StandardCharsets.UTF_8
            .newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
    val input = ByteBuffer.wrap(body)
    val out = CharBuffer.allocate(4096)
    var result: CoderResult
    do {
        out.clear() // 넘침 — 디코딩한 글자는 쓰지 않는다
        result = decoder.decode(input, out, true)
    } while (result.isOverflow)
    return !result.isError
}

/**
 * [input] 을 상한까지만 읽는다 — 넘침을 알아챌 한 바이트까지(상한+1) 읽어 넘치면 null, 아니면 읽은 바이트. `readNBytes(int)` 는
 * 남은 길이 너머를 요청하지 않고 JDK 기본 조각(17: 8 KiB · 21: 16 KiB)으로 **읽은 만큼만** 할당한다 — 작은 본문은 작은 배열이고,
 * 넘치는 본문도 상한의 약 두 배(읽은 조각 + 그것을 이은 배열)다. 상한만 한 버퍼를 미리 잡지 않는다(그러면 요청 하나하나가 상한을
 * 할당한다).
 */
internal fun readWithinCap(input: InputStream): ByteArray? {
    val body = input.readNBytes(TOKEN_RESPONSE_MAX_BYTES + 1)
    return if (body.size > TOKEN_RESPONSE_MAX_BYTES) null else body
}

/**
 * Nimbus `HTTPRequest.send()` 와 같은 일을 하되 응답 본문을 [TOKEN_RESPONSE_MAX_BYTES] 까지만 읽는 송신기 — auth 레인의 토큰
 * (세 그랜트)·introspection·logout 요청이 `HTTPRequest.send(HTTPRequestSender)` 로 이것을 부른다.
 *
 * 왜: Nimbus 의 `send()` 는 본문을 readLine 고리로 끝까지 담는다(크기 설정이 없다) — 쓸 수 있는 토큰 뒤에 JSON 공백 32 MiB 를 붙인
 * 응답을 다섯 레인이 받아들였고 호출 하나가 약 230 MiB 를 할당했다(실측 — `TokenResponseCapTest`). 오류 상태의 본문도 같은 고리였다.
 *
 * 운송은 [BoundedTransport] 다 — JDK 의 HttpURLConnection 은 트레일러에 한도가 없었고 상한을 넘은 청크 본문을 닫으며 쌓인 바이트를
 * 제곱 비용으로 풀었다(그 객체 설명). 요청은 Nimbus 가 이 요청으로 HttpURLConnection 에 실었을 그대로 만든다([toApache]): 메서드·URL·
 * 헤더 표(제한 헤더는 HttpURLConnection 처럼 버린다)·POST/PUT 의 Content-Type 과 본문(플랫폼 기본 문자셋 — Nimbus 의
 * `OutputStreamWriter` 와 같다)·연결/읽기 타임아웃. ⚠️ `send(sender)` 가 넘기는 것은 그 요청 자신이다 — `ReadOnlyHTTPRequest` 인터페이스에는
 * TLS 설정이 없어 요청으로 되돌려 읽는다. TLS 근원은 이 요청의 소켓 팩토리와 검증기이고, 없으면 Nimbus 의 기본값이다
 * (`HTTPRequest.getDefaultSSLSocketFactory()` — Nimbus 가 클래스 초기화 때 잡아 둔 값, 오늘 그대로). ⚠️ 리다이렉트는 요청의 플래그와
 * 무관하게 따르지 않는다 — 모든 호출부가 [AuthClient.applyTimeouts] 로 끄는 값이고(SSRF 하드닝), 이 송신은 그것을 따르는 길을 아예 두지
 * 않는다. 요청의 프록시(`HTTPRequest.setProxy`)는 보지 않는다 — SDK 가 설정하지 않는 값이고, 시스템 프록시(`http(s).proxyHost`)는 따른다.
 *
 * 상한 안의 본문은 Nimbus 와 같은 문자열로 만든다(아래 `asNimbusReadsIt`) — 파서가 받는 입력이 지금과 같다. 그 본문은 EOF 까지 읽으므로
 * 연결은 운송의 풀로 돌아가 다음 호출이 다시 쓴다(HttpURLConnection 의 keep-alive 처럼). 상한을 넘으면 나머지를 읽지 않고 **그 연결을 끊은
 * 뒤**(풀에 돌려주지 않는다 — 평문은 그 자리에서 끝나고, HTTPS 는 JSSE 가 닫으며 이미 도착한 바이트를 버린다) [ResponseTooLargeException] 을
 * 던지고, 호출부가 그 레인의 KeycloakTransportException 으로 바꾼다. SDK 가 요청하고 쥐는 것은 상한+1 바이트까지다([readWithinCap]).
 * 운송은 내용 코딩을 요청하지도 풀지도 않으므로 센 바이트가 받은 바이트다. 그 본문을 읽는 동안 연결에서 받는 틀(청크 머리·트레일러
 * 포함)은 상한의 8 배까지다(`BoundedTransport.wireBounded`).
 *
 * [strict] 이면 **2xx 본문은 UTF-8 이어야 한다** — 아니면 [ResponseNotUtf8Exception](끝까지 온 응답을 쓸 수 없다 — 호출부가 그 레인의 인증
 * 오류로 바꾼다). 토큰(세 그랜트)·introspection 이 그렇다 — 그 2xx 본문은 JSON 이고 RFC 8259 §8.1 은 UTF-8 이다. ⚠️ Nimbus 와 같은
 * 디코딩(`asNimbusReadsIt`)은 잘못된 바이트를 U+FFFD 로 바꿔 **받아들였다** — IdP 가 내지 않은 토큰·바뀐 클레임이 성공으로 나갔다(실측 —
 * `TokenResponseClassTest`). 오류 상태의 본문은 보지 않는다(판정은 상태가 한다). 선언된 charset 도 보지 않는다(RFC 8259 §11). logout 은
 * 본문을 쓰지 않으므로 strict 가 아니다. 유효한 UTF-8 은 지금과 같은 문자열이다.
 */
internal class CappedResponseSender(
    private val what: String,
    private val strict: Boolean = false,
) : HTTPRequestSender {
    override fun send(httpRequest: ReadOnlyHTTPRequest): ReadOnlyHTTPResponse {
        val request = httpRequest as HTTPRequest
        val tls = request.sslSocketFactory ?: HTTPRequest.getDefaultSSLSocketFactory()
        val verifier = request.hostnameVerifier ?: HTTPRequest.getDefaultHostnameVerifier()
        return BoundedTransport.exchange(
            toApache(request),
            tls,
            verifier,
            request.connectTimeout,
            request.readTimeout,
            TOKEN_RESPONSE_MAX_BYTES,
        ) { head, body -> toNimbus(head, body) }
    }

    private fun toNimbus(
        head: HttpResponse,
        body: InputStream,
    ): HTTPResponse {
        val bytes = readWithinCap(body) ?: throw ResponseTooLargeException(what)
        val status = head.statusLine.statusCode
        if (strict && status in 200..299 && !isUtf8(bytes)) throw ResponseNotUtf8Exception(what)
        val response = HTTPResponse(status)
        response.statusMessage = head.statusLine.reasonPhrase
        for ((name, values) in BoundedTransport.grouped(head)) response.setHeader(name, *values.toTypedArray())
        val text = asNimbusReadsIt(bytes)
        if (text.isNotEmpty()) response.body = text
        return response
    }

    private companion object {
        // Nimbus 가 본문을 쓰는 메서드(`toHttpURLConnection` 의 `setDoOutput(true)`) — 나머지는 본문 없이 보낸다.
        val WITH_BODY: Set<HTTPRequest.Method> = setOf(HTTPRequest.Method.POST, HTTPRequest.Method.PUT)

        // Nimbus `send()` 가 본문을 만드는 방식 그대로 — UTF-8 로 줄 단위로 읽어 줄마다 플랫폼 줄 구분자를 붙인다(마지막 줄 뒤에도).
        // 상한 안의 본문은 파서에 예전과 같은 문자열로 간다(`CappedResponseSenderTest` 가 Nimbus 의 `send()` 와 대조한다).
        fun asNimbusReadsIt(body: ByteArray): String {
            val reader = BufferedReader(InputStreamReader(ByteArrayInputStream(body), StandardCharsets.UTF_8))
            val separator = System.getProperty("line.separator")
            val text = StringBuilder()
            while (true) {
                val line = reader.readLine() ?: break
                text.append(line).append(separator)
            }
            return text.toString()
        }

        // Nimbus `toHttpURLConnection()` 이 HttpURLConnection 에 싣는 그대로의 요청. 본문을 싣는 메서드는 본문이 없어도 본문을 싣는 요청이다 —
        // HttpURLConnection 처럼 `Content-Length: 0`(빈 엔티티). ⚠️ 본문을 싣는 요청에 Content-Type 이 없을 때 HttpURLConnection 이 덧붙이는
        // `application/x-www-form-urlencoded` 는 따라하지 않는다 — SDK 의 요청은 모두 그것을 단다. HttpClient 의 RequestBuilder 가 그 클래스의
        // 요청(본문 있음·없음)을 만든다 — SDK 는 요청 하위 클래스를 따로 두지 않는다.
        fun toApache(request: HTTPRequest): HttpRequestBase {
            val withBody = request.method in WITH_BODY
            val builder = RequestBuilder.create(request.method.name).setUri(URI.create(request.url.toString()))
            if (withBody) builder.entity = ByteArrayEntity(request.body?.toByteArray(Charset.defaultCharset()) ?: ByteArray(0))
            val out = builder.build() as HttpRequestBase
            BoundedTransport.addHeaders(out, request.headerMap)
            if (withBody) {
                // Nimbus 의 setRequestProperty — 표의 값을 대신한다
                request.entityContentType?.let { out.setHeader("Content-Type", it.toString()) }
            }
            BoundedTransport.addJdkDefaults(out, request.url)
            return out
        }
    }
}
