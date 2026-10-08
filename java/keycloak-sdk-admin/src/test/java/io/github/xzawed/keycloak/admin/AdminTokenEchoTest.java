package io.github.xzawed.keycloak.admin;

import static org.junit.jupiter.api.Assertions.*;

import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;
import io.github.xzawed.keycloak.core.KeycloakConfig;
import io.github.xzawed.keycloak.core.exception.KeycloakTransportException;
import jakarta.ws.rs.WebApplicationException;
import jakarta.ws.rs.client.ResponseProcessingException;
import jakarta.ws.rs.core.Response;
import java.io.IOException;
import java.io.OutputStream;
import java.io.PrintWriter;
import java.io.StringWriter;
import java.lang.reflect.Method;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Base64;
import java.util.Collections;
import java.util.Deque;
import java.util.IdentityHashMap;
import java.util.List;
import java.util.Set;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

/**
 * admin 레인의 토큰 부여(keycloak-admin-client 내장 TokenManager)가 IdP 에서 오류를 받을 때 — 그 오류 본문이 이 요청의 Basic 시크릿을
 * 되울려도 SDK 오류의 어느 표현에도, 그리고 그 오류에서 닿는 어느 예외에도 본문이 남지 않는다.
 *
 * <p>⚠️ 메시지는 이미 깨끗했다(「admin transport failure」). 새던 것은 원인 사슬이다 — RESTEasy 는 오류 상태의 본문을 bufferEntity 한
 * {@code Response} 를 {@code NotAuthorizedException} 에 쥐여 BearerAuthFilter(요청 필터) 밖으로 {@code ProcessingException} 으로 감싸
 * 던지고, 그 {@code Response} 는 {@code close()} 뒤에도 {@code readEntity(String.class)} 가 본문을 돌려준다(버퍼된 엔티티는 닫힘
 * 검사를 건너뛴다 — 실측). 그래서 판정은 문자열이 아니라 <b>도달 가능성</b>이다: 사슬(원인·suppressed)의 어느 예외도
 * {@link WebApplicationException}·{@link ResponseProcessingException} 이 아니고, 어느 예외의 공개 메서드도 {@link Response} 를 돌려주지
 * 않는다 — {@code readEntity} 를 부를 대상이 없다. 진단은 남는다: 타입 이름(「jakarta.ws.rs.NotAuthorizedException (message withheld」)과
 * 분류(KeycloakTransportException · 「admin transport failure」). admin-client 의 Basic 은 시크릿을 폼 인코딩하지 않는다 — 꼴 다섯
 * (그대로·폼·RFC 3986·Basic 자격·userinfo)은 서버가 받은 자격에서 만든다. 네트워크는 루프백만.
 */
class AdminTokenEchoTest {
  private static final String SECRET = "sec ret/+=~0005é";
  private static final List<String> VARIANTS = List.of("raw", "form", "pct", "b64", "userinfo");

  private HttpServer server;
  private volatile String variant = "raw";
  /** 마지막으로 되울린 문자열(서버가 실제로 쓴 꼴). */
  private volatile String echoed = "";
  private final List<String> adminHits = Collections.synchronizedList(new ArrayList<>());

  @BeforeEach void start() throws IOException {
    server = HttpServer.create(new InetSocketAddress(InetAddress.getLoopbackAddress(), 0), 0);
    server.createContext("/", this::answer);
    server.start();
  }

  @AfterEach void stop() {
    server.stop(0);
  }

  private void answer(HttpExchange ex) throws IOException {
    ex.getRequestBody().readAllBytes();
    if (!ex.getRequestURI().getPath().endsWith("/protocol/openid-connect/token")) {
      adminHits.add(ex.getRequestMethod() + " " + ex.getRequestURI().getPath());
      send(ex, 200, "{\"id\":\"x\",\"username\":\"alice\"}");
      return;
    }
    String auth = ex.getRequestHeaders().getFirst("Authorization");
    String credential = auth == null ? "" : auth.substring(auth.indexOf(' ') + 1);
    String userinfo = new String(Base64.getDecoder().decode(credential), StandardCharsets.UTF_8);
    String password = userinfo.substring(userinfo.indexOf(':') + 1);
    String form = URLEncoder.encode(password, StandardCharsets.UTF_8);
    echoed = switch (variant) {
      case "raw" -> password;
      case "form" -> form;
      case "pct" -> form.replace("+", "%20").replace("*", "%2A").replace("%7E", "~");
      case "b64" -> credential;
      case "userinfo" -> userinfo;
      default -> throw new IllegalStateException(variant);
    };
    send(ex, 401, "{\"error\":\"invalid_client\",\"error_description\":\"Bad credentials: " + echoed + "\"}");
  }

  private static void send(HttpExchange ex, int status, String body) throws IOException {
    byte[] bytes = body.getBytes(StandardCharsets.UTF_8);
    ex.getResponseHeaders().add("Content-Type", "application/json");
    ex.sendResponseHeaders(status, bytes.length);
    try (OutputStream os = ex.getResponseBody()) {
      os.write(bytes);
    }
  }

  /** 원인·suppressed 를 따라 닿는 예외 전부(순환은 한 번만). */
  static List<Throwable> graph(Throwable root) {
    List<Throwable> out = new ArrayList<>();
    Set<Throwable> seen = Collections.newSetFromMap(new IdentityHashMap<>());
    Deque<Throwable> todo = new ArrayDeque<>();
    todo.push(root);
    while (!todo.isEmpty()) {
      Throwable t = todo.pop();
      if (!seen.add(t)) continue;
      out.add(t);
      if (t.getCause() != null) todo.push(t.getCause());
      for (Throwable s : t.getSuppressed()) todo.push(s);
    }
    return out;
  }

  /** 예외 하나가 {@link Response} 를 내줄 수 있는가 — 그 타입이거나, 공개 메서드 하나라도 그것을 돌려준다. */
  static String responseHandle(Throwable t) {
    if (t instanceof WebApplicationException || t instanceof ResponseProcessingException) return t.getClass().getName();
    for (Method m : t.getClass().getMethods()) {
      if (Response.class.isAssignableFrom(m.getReturnType())) return t.getClass().getName() + "." + m.getName() + "()";
    }
    return null;
  }

  @Test void tokenEndpointEcho_leavesNoReadableBody_inTheThrownGraph() {
    List<String> wrong = new ArrayList<>();
    List<String> table = new ArrayList<>();
    for (String v : VARIANTS) {
      variant = v;
      Throwable thrown;
      try (AdminClient admin = new AdminClient(KeycloakConfig.builder()
          .serverUrl("http://127.0.0.1:" + server.getAddress().getPort()).realm("r").clientId("c")
          .clientSecret(SECRET.toCharArray()).readTimeout(Duration.ofSeconds(10)).build())) {
        admin.users().get("x");
        thrown = null;
      } catch (Throwable t) {
        thrown = t;
      }
      List<String> handles = new ArrayList<>();
      List<String> bodies = new ArrayList<>();
      StringWriter trace = new StringWriter();
      if (thrown != null) {
        thrown.printStackTrace(new PrintWriter(trace, true));
        for (Throwable t : graph(thrown)) {
          String handle = responseHandle(t);
          if (handle == null) continue;
          handles.add(handle);
          if (t instanceof WebApplicationException w && w.getResponse() != null) {
            try {
              bodies.add(w.getResponse().readEntity(String.class));
            } catch (RuntimeException unreadable) {
              bodies.add("(unreadable: " + unreadable.getClass().getSimpleName() + ")");
            }
          }
        }
      }
      String label = "admin token · " + v;
      table.add(String.format("%-22s echoed=%-44s → %s · handles=%s · bodies=%s", label, echoed,
          thrown == null ? "성공" : thrown.getClass().getSimpleName() + "(" + thrown.getMessage() + ")", handles, bodies));
      if (!(thrown instanceof KeycloakTransportException) || !"admin transport failure".equals(thrown.getMessage())) {
        wrong.add(label + ": KeycloakTransportException(admin transport failure) 가 아니다 — " + thrown);
        continue;
      }
      if (!handles.isEmpty()) wrong.add(label + ": 던진 예외에서 Response 에 닿는다 — " + handles + " · readEntity → " + bodies);
      String text = thrown + "\n" + trace;
      if (text.contains(echoed)) wrong.add(label + ": 오류 표현이 되울린 꼴 「" + echoed + "」 을 찍었다");
      if (text.contains("Bad credentials")) wrong.add(label + ": 오류 표현이 토큰 엔드포인트의 본문을 찍었다");
      if (!trace.toString().contains("jakarta.ws.rs.NotAuthorizedException")) {
        wrong.add(label + ": 진단(원인의 타입 이름 NotAuthorizedException)을 잃었다");
      }
      if (!adminHits.isEmpty()) wrong.add(label + ": 토큰 없이 admin 요청이 나갔다 — " + adminHits);
    }
    System.out.println("[AdminTokenEchoTest]\n  " + String.join("\n  ", table));
    assertTrue(wrong.isEmpty(), () -> wrong.size() + " 건:\n" + String.join("\n", wrong));
  }
}
