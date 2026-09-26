package io.github.xzawed.keycloak

// masking.kt — internal, 접두 노출 없음
internal fun mask(v: CharArray?) = if (v == null || v.isEmpty()) "" else "***"

internal fun mask(v: String?) = if (v.isNullOrEmpty()) "" else "***"

// IdP 가 쓴 문구(error_description)에서 SDK 가 **그 요청에 실어 보낸** 비밀을 가린다 — 값을 되울리는 IdP·프록시
// 앞에서 SDK 메시지가 호출자의 refresh 토큰·시크릿을 찍었다(`AuthMalformedResponseTest`). 긴 값부터 가려 한 비밀이
// 다른 비밀을 품어도 조각이 남지 않는다. 보낸 적 없는 값은 사유 문구와 구별할 수 없어 가리지 못한다.
internal fun maskSent(
    text: String?,
    sent: List<String?>,
): String? =
    text?.let { t ->
        sent
            .filterNotNull()
            .filter { it.isNotEmpty() }
            .sortedByDescending { it.length }
            .fold(t) { acc, s -> acc.replace(s, "***") }
    }
