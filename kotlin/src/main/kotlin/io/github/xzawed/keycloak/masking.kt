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
// 토큰이 「…rtLFNULWIDE…」 로 메시지에 실렸다(헤더 경우 탐침 — `AuthEchoedValueMaskingTest`). 값마다 [echoForms] 를 가린다.
internal fun maskSent(
    text: String?,
    sent: List<String?>,
): String? =
    text?.let { t ->
        sent
            .filterNotNull()
            .flatMap(::echoForms)
            .filter { it.isNotEmpty() }
            .distinct()
            .sortedByDescending { it.length }
            .fold(t) { acc, s -> acc.replace(s, "***") }
    }

// 보낸 값이 문구로 되돌아올 수 있는 꼴 — 그대로 · IdP 가 받은 꼴(UTF-8 이 짝 없는 서로게이트를 `?` 로 바꾼다) · 그 둘에서 §5.2
// 밖의 글자를 지운 꼴(Nimbus 가 error_description 에 한 일 — 같은 함수로 지워 어긋나지 않게 한다) · 폼 인코딩된 꼴.
// ⚠️ 폼 인코딩된 꼴은 **어느 값이든** 더한다 — SDK 는 grant 값을 본문에, 클라이언트 시크릿을 Basic 의 비밀번호 칸에 이 꼴로
// 싣는다(RFC 6749 §2.3.1 — Nimbus `URLUtils`·`ClientSecretBasic` 이 같은 `URLEncoder` 를 쓴다). 한때 호출부가 grant 값에만 이
// 꼴을 더해, 폼 디코딩 없이 되울리는 IdP 앞에서 시크릿이 「Bad BASIC: sec+ret%2F… (rejected)」 로 찍혔다
// (`AuthEchoedValueMaskingTest`). 이 꼴은 §5.2 안의 글자뿐이라 지울 것이 없다.
private fun echoForms(value: String): List<String> {
    val received = String(value.toByteArray(StandardCharsets.UTF_8), StandardCharsets.UTF_8)
    return listOf(
        value,
        received,
        ErrorObject.removeIllegalChars(value),
        ErrorObject.removeIllegalChars(received),
        URLEncoder.encode(value, StandardCharsets.UTF_8),
    )
}
