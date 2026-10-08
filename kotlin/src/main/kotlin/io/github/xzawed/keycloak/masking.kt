package io.github.xzawed.keycloak

import com.nimbusds.oauth2.sdk.ErrorObject
import java.net.URLEncoder
import java.nio.charset.StandardCharsets

// masking.kt — internal, 접두 노출 없음
internal fun mask(v: CharArray?) = if (v == null || v.isEmpty()) "" else "***"

internal fun mask(v: String?) = if (v.isNullOrEmpty()) "" else "***"

// IdP 가 쓴 문구(error_description)에서 SDK 가 **그 요청에 실어 보낸** 비밀을 가린다 — 값을 되울리는 IdP·프록시
// 앞에서 SDK 메시지가 호출자의 refresh 토큰·시크릿을 찍었다(`AuthMalformedResponseTest`). 긴 값부터 가려 한 비밀이
// 다른 비밀을 품어도 조각이 남지 않는다. 보낸 적 없는 값은 사유 문구와 구별할 수 없어 가리지 못한다.
// ⚠️ 보낸 값 그대로만 찾으면 되울린 사본을 놓친다 — 이 문구는 Nimbus `ErrorObject` 가 RFC 6749 §5.2 밖의 글자(제어 문자·
// 비 ASCII·`"`·`\`)를 **지운 뒤**의 것이고, 짝 없는 서로게이트는 UTF-8 이 `?` 로 바꿔 보냈다. 그래서 LF·NUL·U+0100 을 담은
// 토큰이 「…rtLFNULWIDE…」 로 메시지에 실렸다(헤더 경우 탐침 — `AuthEchoedValueMaskingTest`). 값마다 [echoForms] 를 가리고,
// 퍼센트 인코딩을 풀면 그 값이 되는 구간도 가린다([maskDecoded]).
internal fun maskSent(
    text: String?,
    sent: List<String?>,
): String? =
    text?.let { t ->
        val forms =
            sent
                .filterNotNull()
                .flatMap(::echoForms)
                .filter { it.isNotEmpty() }
                .distinct()
                .sortedByDescending { it.length }
        // 푼 바이트로 먼저 가린다 — 그대로의 꼴을 먼저 가리면 인코딩된 되울림의 아스키 부분만 사라지고 나머지(`&#233;`)가 남는다.
        forms.fold(maskDecoded(t, forms)) { acc, s -> acc.replace(s, "***") }
    }

// 퍼센트 인코딩을 푼 사본에서 보낸 값을 찾아 원문의 그 구간을 가린다. ⚠️ 꼴을 늘어놓는 것으로는 끝나지 않는다 — 인코더마다
// 그대로 두는 글자·공백의 꼴·16진의 대소문자·문자 집합이 다르고(Grok 레그 1: Go `url.QueryEscape` → 「sec+ret%2F%2B%3D~0005%C3%A9」
// · Python `quote` → 「sec%20ret/%2B%3D~0005%C3%A9」 · JS `encodeURI` · ISO-8859-1 폼 → 「…%E9」), 한 겹 더 인코딩되거나 공백과 `+` 가
// 뒤섞이기도 한다(레그 2: 이미 `quote_plus` 된 값을 다시 인코딩한 「sec%2Bret%252F…」 · 공백을 %2B 로 쓴 게이트웨이 · %uXXXX · 비 ASCII
// 를 JSON 유니코드 이스케이프·&#233;·ISO-8859-1 로 읽은 깨진 글자로 쓴 뒤 URL 인코딩한 것 — 아스키만 가려지고 é 가 남았다) — 전부
// [echoForms] 의 꼴과 달라 그대로 찍혔다(`AuthEchoedSecretFormsTest`). 그래서 꼴이 아니라 **푼 바이트**를 맞춘다: 이스케이프
// ([unescapeAt])를 **두 겹까지** 풀고, 공백과 `+` 는 같은 글자로 본다(폼 인코딩에서 둘은 서로의 꼴이다). 바늘은 그대로 가릴 꼴(forms)
// 마다 그 UTF-8 바이트 · ISO-8859-1 로 쓸 수 있으면 그 바이트 · UTF-8 바이트를 ISO-8859-1 글자로 읽어 다시 UTF-8 로 쓴 깨진 꼴의
// 바이트다. 보낸 값과 같은 바이트가 되는 구간만 가린다 — 산문은 건드리지 않는다. Java `AuthClient.maskDecoded` 와 같은 일을 한다.
private fun maskDecoded(
    text: String,
    forms: List<String>,
): String {
    val needles = decodedNeedles(forms)
    if (needles.isEmpty()) return text
    val hit = BooleanArray(text.length)
    // 이스케이프 하나는 제 길이보다 적은 바이트를 낸다 — 사본은 원문보다 길어지지 않는다
    val from = IntArray(text.length)
    val to = IntArray(text.length)
    val once = unescape(text, null, null, from, to)
    mark(once, from, to, needles, hit)
    val from2 = IntArray(once.length)
    val to2 = IntArray(once.length)
    mark(unescape(once, from, to, from2, to2), from2, to2, needles, hit)
    return starred(text, hit)
}

// [maskDecoded] 의 바늘 — 한 바이트를 한 글자(0–255)로, 공백은 `+` 로([unescape] 와 같이).
private fun decodedNeedles(forms: List<String>): List<String> {
    val latin1 = StandardCharsets.ISO_8859_1.newEncoder()
    return forms
        .flatMap { f ->
            val bytes = String(f.toByteArray(StandardCharsets.UTF_8), StandardCharsets.ISO_8859_1)
            val mojibake = String(bytes.toByteArray(StandardCharsets.UTF_8), StandardCharsets.ISO_8859_1) // UTF-8 을 ISO-8859-1 로 읽은 깨진 꼴
            // ISO-8859-1 의 바이트는 그 글자 값과 같다
            if (latin1.canEncode(f)) listOf(bytes, mojibake, f) else listOf(bytes, mojibake)
        }.map { it.replace(' ', '+') }
        .filter { it.isNotEmpty() }
        .distinct()
}

// src 의 이스케이프([unescapeAt])를 한 겹 푼 사본 — 한 바이트를 한 글자(0–255)로, 공백은 `+` 로 적는다. 사본의 글자 j 는 원문의 구간
// [from[j], to[j]) 에서 왔다 — srcFrom 이 있으면 src 자체가 사본이고, 구간을 그 원문으로 옮긴다. ⚠️ 상태를 쥔 객체를 만들지 않는다 —
// 되울린 비밀을 품은 사본이 어디에도 남지 않는다(`FacadeDumpTest`).
private fun unescape(
    src: String,
    srcFrom: IntArray?,
    srcTo: IntArray?,
    from: IntArray,
    to: IntArray,
): String {
    val out = StringBuilder(src.length)
    var i = 0
    while (i < src.length) {
        val k = out.length
        var end = unescapeAt(src, i, out)
        if (end < 0) {
            out.append(src[i]) // 0–255 밖의 글자는 바늘(0–255)과 맞을 수 없다
            end = i + 1
        }
        for (j in k until out.length) {
            if (out[j] == ' ') out.setCharAt(j, '+')
            from[j] = srcFrom?.get(i) ?: i
            to[j] = srcTo?.get(end - 1) ?: end
        }
        i = end
    }
    return out.toString()
}

// 바늘이 사본 view 에 나오는 곳마다 그 원문 구간을 hit 에 표시한다.
private fun mark(
    view: String,
    from: IntArray,
    to: IntArray,
    needles: List<String>,
    hit: BooleanArray,
) {
    for (needle in needles) {
        var at = view.indexOf(needle)
        while (at >= 0) {
            hit.fill(true, from[at], to[at + needle.length - 1])
            at = view.indexOf(needle, at + 1)
        }
    }
}

// src 의 i 에서 시작하는 이스케이프를 풀어 그 바이트를 out 에 한 글자(0–255)씩 덧붙이고 끝 위치를 돌려준다 — 이스케이프가 아니면
// -1(덧붙이지 않는다). %XX 는 그 바이트, %uXXXX·\uXXXX(서로게이트 쌍이면 둘을 이어)와 HTML 숫자 참조 &#NNN;·&#xHH; 는 그 글자의 UTF-8
// 바이트. ⚠️ \u 는 퍼센트 인코딩 **안**에서만 나온다 — 날 `\` 는 Nimbus 가 이미 지웠다. 이름 참조(&eacute;)는 풀지 않는다.
private fun unescapeAt(
    src: String,
    i: Int,
    out: StringBuilder,
): Int {
    val c = src[i]
    if (c == '&') return entityAt(src, i, out)
    if (c != '%' && c != '\\') return -1
    val b = if (c == '%' && i + 2 < src.length) hexByte(src[i + 1], src[i + 2]) else -1
    if (b >= 0) {
        out.append(b.toChar())
        return i + 3
    }
    val unit = unitAt(src, i)
    if (unit < 0) return -1
    val low = if (Character.isHighSurrogate(unit.toChar())) unitAt(src, i + 6) else -1
    val ch = if (low >= 0 && Character.isLowSurrogate(low.toChar())) "${unit.toChar()}${low.toChar()}" else unit.toChar().toString()
    appendUtf8(out, ch)
    return i + 6 * ch.length
}

// %uXXXX·\uXXXX 의 16 비트 값, 아니면 -1.
private fun unitAt(
    src: String,
    i: Int,
): Int {
    if (i + 5 >= src.length || (src[i] != '%' && src[i] != '\\') || src[i + 1].lowercaseChar() != 'u') return -1
    var v = 0
    for (k in i + 2 until i + 6) {
        val d = hexDigit(src[k])
        if (d < 0) return -1
        v = v * 16 + d
    }
    return v
}

// HTML 숫자 참조 &#NNN;·&#xHH;(일곱 자리까지) — 그 글자의 UTF-8 바이트를 덧붙이고 끝 위치를, 아니면 -1.
private fun entityAt(
    src: String,
    i: Int,
    out: StringBuilder,
): Int {
    val n = src.length
    if (i + 3 >= n || src[i + 1] != '#') return -1
    val radix = if (src[i + 2].lowercaseChar() == 'x') 16 else 10
    val start = if (radix == 16) i + 3 else i + 2
    var k = start
    var cp = 0
    while (k < n && k - start < 7 && digit(src[k], radix) >= 0) {
        cp = cp * radix + digit(src[k], radix)
        k++
    }
    if (k == start || k >= n || src[k] != ';' || cp > Character.MAX_CODE_POINT) return -1
    appendUtf8(out, String(Character.toChars(cp)))
    return k + 1
}

// s 의 UTF-8 바이트를 한 글자(0–255)씩.
private fun appendUtf8(
    out: StringBuilder,
    s: String,
) {
    for (b in s.toByteArray(StandardCharsets.UTF_8)) out.append((b.toInt() and 0xFF).toChar())
}

// ASCII 숫자 하나의 값(radix 16 이면 16진), 아니면 -1.
private fun digit(
    c: Char,
    radix: Int,
): Int {
    val d = hexDigit(c)
    return if (d >= radix) -1 else d
}

// 표시된 구간마다 *** 하나로.
private fun starred(
    text: String,
    hit: BooleanArray,
): String =
    buildString(text.length) {
        var i = 0
        while (i < text.length) {
            if (hit[i]) {
                append("***")
                while (i < text.length && hit[i]) i++
            } else {
                append(text[i++])
            }
        }
    }

// % 뒤 두 글자가 ASCII 16진이면 그 바이트, 아니면 -1.
private fun hexByte(
    hi: Char,
    lo: Char,
): Int {
    val h = hexDigit(hi)
    val l = hexDigit(lo)
    return if (h < 0 || l < 0) -1 else h * 16 + l
}

private fun hexDigit(c: Char): Int =
    when (c) {
        in '0'..'9' -> c - '0'
        in 'a'..'f' -> c - 'a' + 10
        in 'A'..'F' -> c - 'A' + 10
        else -> -1
    }

// 보낸 값이 문구로 되돌아올 수 있는 꼴 — 그대로 · IdP 가 받은 꼴(UTF-8 이 짝 없는 서로게이트를 `?` 로 바꾼다) · 그 둘에서 §5.2
// 밖의 글자를 지운 꼴(Nimbus 가 error_description 에 한 일 — 같은 함수로 지워 어긋나지 않게 한다) · 폼 인코딩된 꼴 · RFC 3986
// 퍼센트 인코딩된 꼴 · 두 인코딩의 소문자 16진 꼴.
// ⚠️ 폼 인코딩된 꼴은 **어느 값이든** 더한다 — SDK 는 grant 값을 본문에, 클라이언트 시크릿을 Basic 의 비밀번호 칸에 이 꼴로
// 싣는다(RFC 6749 §2.3.1 — Nimbus `URLUtils`·`ClientSecretBasic` 이 같은 `URLEncoder` 를 쓴다). 한때 호출부가 grant 값에만 이
// 꼴을 더해, 폼 디코딩 없이 되울리는 IdP 앞에서 시크릿이 「Bad BASIC: sec+ret%2F… (rejected)」 로 찍혔다
// (`AuthEchoedValueMaskingTest`). 이 꼴은 §5.2 안의 글자뿐이라 지울 것이 없다.
// ⚠️ 폼 꼴만으로는 다시 인코딩하는 IdP·프록시를 놓친다 — RFC 3986 꼴(공백 %20 · `~` 그대로 · `*` 는 %2A)과 소문자 16진 꼴의
// 시크릿이 「Bad credentials: sec%20ret%2F%2B%3D~0005%C3%A9」 로 찍혔다(`AuthEchoedSecretFormsTest`). Java `echoForms` 와 같은 꼴이다.
private fun echoForms(value: String): List<String> {
    val received = String(value.toByteArray(StandardCharsets.UTF_8), StandardCharsets.UTF_8)
    val form = URLEncoder.encode(value, StandardCharsets.UTF_8)
    // URLEncoder 는 공백만 `+` 로 쓰고(`+` 자체는 %2B), `~` 를 %7E 로, `*` 를 그대로 쓴다 — RFC 3986 의 unreserved 로 고친다.
    val pct = form.replace("+", "%20").replace("*", "%2A").replace("%7E", "~")
    return listOf(
        value,
        received,
        ErrorObject.removeIllegalChars(value),
        ErrorObject.removeIllegalChars(received),
        form,
        pct,
        lowerHex(form),
        lowerHex(pct),
    )
}

// %XX 의 16진만 소문자로 — 값 자체의 대문자는 그대로 둔다.
private fun lowerHex(encoded: String): String {
    val c = encoded.toCharArray()
    var i = 0
    while (i + 2 < c.size) {
        if (c[i] == '%') {
            c[i + 1] = c[i + 1].lowercaseChar()
            c[i + 2] = c[i + 2].lowercaseChar()
            i += 3
        } else {
            i++
        }
    }
    return String(c)
}
