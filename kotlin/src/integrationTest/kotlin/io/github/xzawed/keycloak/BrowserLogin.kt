package io.github.xzawed.keycloak

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.net.URI
import java.net.URLDecoder
import java.net.URLEncoder
import java.net.http.HttpClient
import java.net.http.HttpRequest
import java.net.http.HttpResponse
import java.nio.charset.StandardCharsets
import java.time.Duration
import kotlin.test.fail

// 브라우저 없는 로그인 — 실제 Keycloak 로그인 폼을 HTTP 로 채워 인가 코드를 받는다. python 파일럿
// (`python/tests/integration/browser_login.py`)의 세 걸음을 그대로 옮긴다:
//
// 1. SDK 가 만든 인가 URL 을 GET 한다(로그인 페이지 + 인증 세션 쿠키 — 쿠키는 2 에서 직접 되싣는다).
// 2. `<form id="kc-form-login">` 의 `action` 에 사용자명·비밀번호를 POST 하되 **리다이렉트는 따라가지
//    않는다** — redirect_uri 에는 아무것도 떠 있지 않다. 302 의 `Location` 이 곧 콜백이다.
// 3. `Location` 에서 `code`·`state` 를 꺼내고, `state` 가 SDK 가 발급한 값인지 확인한다.
//
// 폼을 못 찾거나 상태 코드가 틀리면 받은 HTML 앞부분을 실어 실패한다 — 테마가 바뀌었을 때 원인이
// 바로 보이게. 블로킹 `HttpClient.send` 는 `Dispatchers.IO` 에서 돈다(SDK 의 네트워크 메서드는 전부 suspend).

internal const val LOGIN_FORM_ID = "kc-form-login"

// `<form …>` 시작 태그 — 따옴표 안의 `>` 에 끊기지 않게 속성 값을 통째로 건너뛴다.
private val FORM_TAG = Regex("""<form\b(?:[^>"']|"[^"]*"|'[^']*')*>""", RegexOption.IGNORE_CASE)
private val ATTRIBUTE = Regex("""([^\s=/>"']+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>"']+))""")
private val CHARACTER_REFERENCE = Regex("""&(#[0-9]+|#[xX][0-9a-fA-F]+|amp|quot|apos|lt|gt);""")

/** `<form id="kc-form-login">` 의 action(문자 참조 `&amp;` 등을 푼 값) — 없으면 null. */
internal fun loginFormAction(html: String): String? =
    FORM_TAG.findAll(html).firstNotNullOfOrNull { tag ->
        val attributes =
            ATTRIBUTE.findAll(tag.value).associate { m ->
                val (name, double, single, bare) = m.destructured
                name.lowercase() to unescapeHtml(double.ifEmpty { single.ifEmpty { bare } })
            }
        if (attributes["id"] == LOGIN_FORM_ID) attributes["action"] else null
    }

private fun unescapeHtml(value: String): String =
    CHARACTER_REFERENCE.replace(value) { m ->
        when (val ref = m.groupValues[1]) {
            "amp" -> "&"
            "quot" -> "\""
            "apos" -> "'"
            "lt" -> "<"
            "gt" -> ">"
            else ->
                if (ref[1] == 'x' || ref[1] == 'X') {
                    String(Character.toChars(ref.substring(2).toInt(16)))
                } else {
                    String(Character.toChars(ref.substring(1).toInt()))
                }
        }
    }

private fun snippet(response: HttpResponse<String>): String =
    "HTTP ${response.statusCode()} ${response.uri()}\n${response.body().take(1500)}"

private fun formEncode(vararg fields: Pair<String, String>): String =
    fields.joinToString("&") { (k, v) ->
        "${URLEncoder.encode(k, StandardCharsets.UTF_8)}=${URLEncoder.encode(v, StandardCharsets.UTF_8)}"
    }

/** 쿼리 문자열 → 이름별 값 목록(같은 이름이 둘이면 둘 다 남긴다 — 「코드가 정확히 하나」를 재려고). */
internal fun parseQuery(rawQuery: String?): Map<String, List<String>> =
    rawQuery
        .orEmpty()
        .split('&')
        .filter { it.isNotEmpty() }
        .groupBy(
            { URLDecoder.decode(it.substringBefore('='), StandardCharsets.UTF_8) },
            { URLDecoder.decode(it.substringAfter('=', ""), StandardCharsets.UTF_8) },
        )

/** [request](SDK 의 `createAuthorizationRequest` 결과)로 로그인해 인가 코드를 돌려준다. */
internal suspend fun browserLogin(
    request: AuthorizationRequest,
    redirectUri: String,
    username: String,
    password: String,
): String =
    withContext(Dispatchers.IO) {
        // 쿠키 핸들러를 달지 않는다 — 아래에서 직접 되싣는다. `HttpClient.close()` 는 JDK 21 부터라
        // (`-Xjdk-release=17`) 부르지 않는다.
        val browser =
            HttpClient
                .newBuilder()
                .followRedirects(HttpClient.Redirect.NEVER)
                .connectTimeout(Duration.ofSeconds(30))
                .build()
        val page =
            browser.send(
                HttpRequest
                    .newBuilder(URI.create(request.authorizationUrl))
                    .timeout(Duration.ofSeconds(30))
                    .GET()
                    .build(),
                HttpResponse.BodyHandlers.ofString(),
            )
        if (page.statusCode() != 200) fail("login page did not render:\n${snippet(page)}")
        val action =
            loginFormAction(page.body())
                ?: fail("no <form id=\"$LOGIN_FORM_ID\"> in the login page:\n${snippet(page)}")
        // ⚠️ 쿠키 저장소에 맡기지 말고 **직접 되싣는다.** Keycloak 26 은 http 에서도 로그인 쿠키에
        // `Secure` 를 단다. 브라우저는 localhost 를 안전한 출처로 봐서 보내지만, RFC 6265 대로 사는
        // 저장소(`java.net.CookieManager` 등)는 http 요청에 싣지 않아 POST 가 400 "Restart login cookie
        // not found" 로 끝난다(python 파일럿 실측).
        val cookie = page.headers().allValues("set-cookie").joinToString("; ") { it.substringBefore(';').trim() }
        val answer =
            browser.send(
                HttpRequest
                    .newBuilder(URI.create(action))
                    .timeout(Duration.ofSeconds(30))
                    .header("Content-Type", "application/x-www-form-urlencoded")
                    .header("Cookie", cookie)
                    .POST(HttpRequest.BodyPublishers.ofString(formEncode("username" to username, "password" to password)))
                    .build(),
                HttpResponse.BodyHandlers.ofString(),
            )
        if (answer.statusCode() != 302) fail("login POST did not redirect:\n${snippet(answer)}")
        val location =
            answer.headers().firstValue("location").orElse(null)
                ?: fail("login POST redirected without a Location:\n${snippet(answer)}")
        val callback = URI.create(location)
        if ("${callback.scheme}://${callback.rawAuthority}${callback.rawPath}" != redirectUri) {
            fail("login redirected somewhere else: $location")
        }
        val query = parseQuery(callback.rawQuery)
        // state 는 SDK 가 인가 URL 에 실은 CSRF 값이다 — 서버가 그대로 되돌려야 한다.
        if (query["state"] != listOf(request.state)) {
            fail("state mismatch: sent ${request.state}, got ${query["state"]}")
        }
        val codes = query["code"]
        if (codes == null || codes.size != 1 || codes[0].isEmpty()) {
            fail("no single authorization code in the callback: $location")
        }
        codes[0]
    }
