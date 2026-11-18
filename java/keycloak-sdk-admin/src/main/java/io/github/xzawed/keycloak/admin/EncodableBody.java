package io.github.xzawed.keycloak.admin;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import io.github.xzawed.keycloak.core.exception.KeycloakTransportException;
import jakarta.ws.rs.core.MediaType;
import java.io.IOException;
import java.io.OutputStream;
import java.util.ArrayDeque;
import java.util.Deque;
import org.keycloak.admin.client.JacksonProvider;

/**
 * admin 쓰기 본문이 JSON 으로 그대로 실리는가 — 다섯 자원의 create · update 가 요청 전에 본다(등록부 admin-unencodable-body-residuals).
 * 아니면 {@link KeycloakTransportException} 이고 문구는 아홉 언어 공통이다({@link #UNENCODABLE}). 토큰도 admin 요청도 없다.
 *
 * <p>admin-client 의 Jackson 은 자유 형식 칸(Map&lt;String, Object&gt; · JsonNode — 사용자 프로필 메타데이터의 annotations ·
 * validators, realm 의 client profile · policy)의 NaN · ±Infinity 를 던지지 않고 문자열 {@code "NaN"} · {@code "Infinity"} 로
 * 썼다(QUOTE_NON_NUMERIC_NUMBERS — 수가 아닌 값으로 바뀐다, {@code AdminUnencodableBodyTest}). 그래서 본문을 그 작성기가 쓰는 매퍼 —
 * admin-client 의 {@link JacksonProvider} 가 돌려주는 것, 같은 설정(NON_NULL) — 로 먼저 보낼 때처럼 써 보고(아무 데도 아닌 곳에),
 * 트리로 바꿔(valueToTree) double · float 노드를 본다. 쓸 수 없는 표현(순환 · 깊이 1000 을 넘는 본문)도 같은 계약이다: 전에는 토큰을
 * 받은 뒤 본문을 쓰다 「admin transport failure」였다. 먼저 써 보는 까닭은 valueToTree 의 TokenBuffer 가 쓰기 깊이 한도
 * (StreamWriteConstraints)를 보지 않아 순환을 스택이 넘칠 때까지 따라가기 때문이다(실측 — 생성기는 깊이 1001 에서 멈춘다). 걷기는
 * 재귀가 아니다. 짝 없는 서로게이트는 보지 않는다 — Jackson 이 {@code \uD800} 이스케이프로 그대로 싣는다. 자체 ObjectMapper 를 만들지
 * 않는다(보안 불변식 — 상류 JacksonProvider 의 매퍼를 그대로 쓴다).
 */
final class EncodableBody {
  static final String UNENCODABLE = "admin request failed: the request body could not be encoded as JSON";

  /** admin-client 의 본문 작성기가 쓰는 매퍼 — 클래스를 처음 쓸 때 한 번 얻고, 그 뒤로는 읽기만 한다. */
  private static final ObjectMapper MAPPER =
      new JacksonProvider().locateMapper(Object.class, MediaType.APPLICATION_JSON_TYPE);

  private EncodableBody() {}

  /** {@code representation} 을 JSON 이 그대로 싣지 못하면 {@link KeycloakTransportException}. */
  static void require(Object representation) {
    JsonNode tree;
    try {
      MAPPER.writeValue(OutputStream.nullOutputStream(), representation);
      tree = MAPPER.valueToTree(representation);
    } catch (IOException | IllegalArgumentException e) {
      throw new KeycloakTransportException(UNENCODABLE, e);
    }
    Deque<JsonNode> pending = new ArrayDeque<>();
    pending.push(tree);
    while (!pending.isEmpty()) {
      JsonNode node = pending.pop();
      if ((node.isDouble() || node.isFloat()) && !Double.isFinite(node.doubleValue())) {
        throw new KeycloakTransportException(UNENCODABLE, null);
      }
      node.forEach(pending::push);
    }
  }
}
