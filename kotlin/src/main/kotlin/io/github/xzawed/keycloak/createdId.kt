package io.github.xzawed.keycloak

import jakarta.ws.rs.core.HttpHeaders
import jakarta.ws.rs.core.Response
import org.keycloak.admin.client.CreatedResponseUtil
import java.net.URI
import java.net.URISyntaxException

// createdId.kt — admin create 의 답이 이름하는 id(등록부 admin-create-relative-location — 아홉 SDK 가 같은 규칙, Java `CreatedIds`
// 동형). admin 패키지는 Kover 가 통째로 빼는 경계라, 응답 하나만 보는 이 판정은 단위 게이트가 재는 이 자리에 둔다.
// admin-client 의 CreatedResponseUtil.getCreatedId 는 `Location` 의 디코딩된 경로에서 마지막 `/` 뒤를 그대로 돌려줬다 — 상대 값은 풀지
// 않았고, 다른 컬렉션의 id 도 받았고, 끝 `/` 에는 빈 id, `%20` 은 풀린 채였으며, `Location` 이 없으면 null 이 non-null `String` 으로
// 새어 날 NullPointerException 이 SDK 오류 계층 밖으로 나갔다(§4).

/** id 없음의 keycloakError — 답은 201 이지만 쓸 수 있는 id 가 없다(.NET 의 같은 자리 문구). */
internal const val NO_CREATED_ID = "resource created but no id returned in Location header"

/**
 * `Location` 값(앞뒤 SP · HTAB 를 뗀)을 [sentTo] — create 를 보낸 URL — 에 대해 풀고(RFC 9110 §10.2.2 — 상대 값도), 풀린 경로(디코딩하지
 * 않고 · 끝 `/` 하나는 무시)의 마지막 조각을 id 로 돌려준다 — 그 앞 조각은 보낸 컬렉션이어야 한다. 쿼리 · 조각은 id 가 아니다. 없거나
 * 비었거나 풀리지 않는 값, 그 컬렉션의 id 를 이름하지 않는 경로(다른 컬렉션의 id 도)는 id 없음 — [KeycloakAdminException.Other]
 * (500, [NO_CREATED_ID]). 201 이 아닌 답은 admin-client 처럼 실패한다.
 */
internal fun createdId(
    response: Response,
    sentTo: URI,
): String {
    if (response.statusInfo != Response.Status.CREATED) {
        return CreatedResponseUtil.getCreatedId(response) // 201 이 아니면 던진다 — 예전 그대로
    }
    val value = response.getHeaderString(HttpHeaders.LOCATION).orEmpty().trim(' ', '\t')
    val resolved =
        try {
            if (value.isEmpty()) null else sentTo.resolve(URI(value))
        } catch (unparsable: URISyntaxException) {
            null
        }
    val (collection, id) = lastSegments(resolved?.rawPath.orEmpty()) // 불투명 URI(`mailto:x`)의 경로는 null 이다
    if (resolved == null || id.isEmpty() || collection != lastSegments(sentTo.rawPath).second) {
        throw KeycloakAdminException.Other(500, NO_CREATED_ID)
    }
    return id
}

/** URI 경로의 마지막 두 조각(끝 `/` 하나는 무시) — 조각이 하나뿐이면 앞의 것은 null. */
private fun lastSegments(path: String): Pair<String?, String> {
    val segments = path.removeSuffix("/").split('/')
    return (if (segments.size < 2) null else segments[segments.size - 2]) to segments.last()
}
