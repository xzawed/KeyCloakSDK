package io.github.xzawed.keycloak

import com.fasterxml.jackson.databind.JsonNode
import com.fasterxml.jackson.databind.ObjectMapper
import jakarta.ws.rs.core.MediaType
import org.keycloak.admin.client.JacksonProvider
import java.io.IOException
import java.io.OutputStream

// encodableBody.kt — admin 쓰기 본문이 JSON 으로 그대로 실리는가(등록부 admin-unencodable-body-residuals, Java EncodableBody 동형). 다섯
// 자원의 create · update 가 요청 전에 부른다 — admin 패키지는 통째로 Kover 게이트 밖이라 검사는 여기 산다. 아니면
// KeycloakTransportException 이고 문구는 아홉 언어 공통이다. 토큰도 admin 요청도 없다.
//
// admin-client 의 Jackson 은 자유 형식 칸(사용자 프로필 메타데이터의 annotations · validators, realm 의 client profile · policy
// JsonNode)의 NaN · ±Infinity 를 던지지 않고 문자열 "NaN" · "Infinity" 로 썼다(QUOTE_NON_NUMERIC_NUMBERS — 수가 아닌 값으로 바뀐다,
// `AdminUnencodableBodyTest`). 그래서 본문을 그 작성기가 쓰는 매퍼 — admin-client 의 JacksonProvider 가 돌려주는 것, 같은 설정(NON_NULL)
// — 로 먼저 보낼 때처럼 써 보고(아무 데도 아닌 곳에), 트리로 바꿔(valueToTree) double · float 노드를 본다. 쓸 수 없는 본문(순환 · 깊이
// 1000 초과)도 같은 계약이다: 전에는 토큰을 받은 뒤 본문을 쓰다 "Admin request failed" 였다. 먼저 써 보는 까닭은 valueToTree 의
// TokenBuffer 가 쓰기 깊이 한도(StreamWriteConstraints)를 보지 않아 순환을 스택이 넘칠 때까지 따라가기 때문이다(Java 에서 실측). 걷기는
// 재귀가 아니다. 짝 없는 서로게이트는 보지 않는다 — Jackson 이 `\uD800` 이스케이프로 그대로 싣는다. 자체 ObjectMapper 를 만들지 않는다
// (보안 불변식 — 상류 JacksonProvider 의 매퍼를 그대로 쓴다).

private const val UNENCODABLE_BODY = "admin request failed: the request body could not be encoded as JSON"

// admin-client 의 본문 작성기가 쓰는 매퍼 — 처음 쓸 때 한 번 얻고, 그 뒤로는 읽기만 한다.
private val ADMIN_BODY_MAPPER: ObjectMapper by lazy {
    JacksonProvider().locateMapper(Any::class.java, MediaType.APPLICATION_JSON_TYPE)
}

/** [representation] 을 JSON 이 그대로 싣지 못하면 [KeycloakTransportException]. */
internal fun requireEncodableBody(representation: Any?) {
    val tree: JsonNode =
        try {
            ADMIN_BODY_MAPPER.writeValue(OutputStream.nullOutputStream(), representation)
            ADMIN_BODY_MAPPER.valueToTree(representation)
        } catch (e: IOException) {
            throw KeycloakTransportException(UNENCODABLE_BODY, e)
        } catch (e: IllegalArgumentException) {
            // 먼저 쓴 것이 지나갔다면 같은 매퍼의 valueToTree 는 실패할 까닭이 없다 — 남겨 둔 방어선이다(Java 의 다중 catch 와 같은 집합)
            throw KeycloakTransportException(UNENCODABLE_BODY, e)
        }
    val pending = ArrayDeque<JsonNode>()
    pending.addLast(tree)
    while (pending.isNotEmpty()) {
        val node = pending.removeLast()
        if ((node.isDouble || node.isFloat) && !node.doubleValue().isFinite()) {
            throw KeycloakTransportException(UNENCODABLE_BODY)
        }
        node.forEach(pending::addLast)
    }
}
