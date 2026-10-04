package io.github.xzawed.keycloak

import com.nimbusds.oauth2.sdk.http.HTTPRequest
import com.nimbusds.oauth2.sdk.http.HTTPRequestSender
import com.nimbusds.oauth2.sdk.http.HTTPResponse
import com.nimbusds.oauth2.sdk.http.ReadOnlyHTTPRequest
import com.nimbusds.oauth2.sdk.http.ReadOnlyHTTPResponse
import java.io.BufferedReader
import java.io.ByteArrayInputStream
import java.io.Closeable
import java.io.IOException
import java.io.InputStream
import java.io.InputStreamReader
import java.io.OutputStream
import java.nio.charset.StandardCharsets

/**
 * 토큰 엔드포인트(세 그랜트 — auth 레인과 admin 레인의 자기 토큰 부여)·introspection·logout 응답 본문의 크기 상한(바이트).
 *
 * ⚠️ 아홉 언어가 함께 움직이는 값이고 교차언어 가드가 이 리터럴을 읽는다 — 식(`1 shl 20`)이 아니라 맨 십진 리터럴로 두고 여기
 * 한 곳에만 선언한다(auth 레인의 [CappedResponseSender] 와 admin 레인의 `TokenResponseGuard` 가 함께 쓴다). Keycloak 26.6 기본
 * 설정(start-dev 로 실측)이 받아들이는 가장 긴 Bearer(65,459 바이트 — 한 바이트 더 길면 HTTP 431)의 16 배라 서버가 받아들이는
 * 토큰을 거부하지 않는다. JWKS 응답 상한(51,200)을 빌리지 말 것 — 큰 배포의 쓸 수 있는 토큰을 거부했다.
 */
internal const val TOKEN_RESPONSE_MAX_BYTES: Int = 1_048_576

/** 상한을 넘는 응답 — 메시지는 무엇이 상한을 넘었는지만 말한다(응답을 인용하지 않는다). */
internal class ResponseTooLargeException(
    what: String,
) : IOException("$what exceeds $TOKEN_RESPONSE_MAX_BYTES bytes")

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
 * ⚠️ 연결은 `HTTPRequest.toHttpURLConnection()` 으로 연다 — `send(sender)` 가 넘기는 것은 그 요청 자신이다. `ReadOnlyHTTPRequest`
 * 로부터 연결을 새로 지으면 `followRedirects = false`(SSRF 하드닝 — [AuthClient.applyTimeouts])와 TLS 설정을 잃는다(그
 * 인터페이스에는 없다).
 *
 * 상한 안의 본문은 Nimbus 와 같은 문자열로 만든다(아래 `asNimbusReadsIt`). 상한을 넘으면 나머지를 읽지 않고 스트림을 닫은 뒤
 * [ResponseTooLargeException] 을 던진다 — 호출부가 그 레인의 KeycloakTransportException 으로 바꾼다. 닫기는 남은 본문을 비우지 않고
 * 연결을 끊는다(JDK 는 청크 본문과 512 KiB 보다 긴 길이 본문을 비우지 않는다 — 넘친 본문은 언제나 그보다 길다). SDK 는 상한+1
 * 바이트 너머를 요청하지 않는다 — 그 아래 JDK 의 소켓 버퍼(`BufferedInputStream` 8 KiB)가 그만큼 더 받아 둘 수 있을 뿐이고, 그것은
 * 고정 버퍼다.
 */
internal class CappedResponseSender(
    private val what: String,
) : HTTPRequestSender {
    override fun send(httpRequest: ReadOnlyHTTPRequest): ReadOnlyHTTPResponse {
        val conn = (httpRequest as HTTPRequest).toHttpURLConnection()
        var output: OutputStream? = null
        var input: InputStream? = null
        try {
            val status =
                try {
                    if (conn.doOutput) output = conn.outputStream
                    input = conn.inputStream
                    conn.responseCode
                } catch (e: IOException) {
                    // 4xx·5xx 면 getInputStream 이 던진다 — 상태가 있으면 본문은 오류 스트림에 있다(Nimbus `send()` 동형)
                    val code = conn.responseCode
                    if (code == -1) throw e
                    input = conn.errorStream
                    code
                }
            val body = if (input == null) ByteArray(0) else readWithinCap(input) ?: throw ResponseTooLargeException(what)
            val response = HTTPResponse(status)
            response.statusMessage = conn.responseMessage
            for ((name, values) in conn.headerFields) {
                if (name != null && !values.isNullOrEmpty() && values[0] != null) {
                    response.setHeader(name, *values.toTypedArray())
                }
            }
            val text = asNimbusReadsIt(body)
            if (text.isNotEmpty()) response.body = text
            return response
        } finally {
            closeQuietly(input)
            closeQuietly(output)
        }
    }

    private companion object {
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

        // Nimbus `closeStreams` 와 같이 닫기의 실패는 버린다 — 결과(응답이든 그 실패든)는 이미 정해졌다.
        fun closeQuietly(stream: Closeable?) {
            try {
                stream?.close()
            } catch (ignored: IOException) {
                // 버린다
            }
        }
    }
}
