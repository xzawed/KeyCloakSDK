package io.github.xzawed.keycloak.admin;

import static org.junit.jupiter.api.Assertions.assertTrue;

import io.github.xzawed.keycloak.core.KeycloakConfig;
import io.github.xzawed.keycloak.core.exception.KeycloakTransportException;
import jakarta.ws.rs.ProcessingException;
import java.io.BufferedInputStream;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.time.Duration;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Base64;
import java.util.Deque;
import java.util.List;
import java.util.Locale;
import java.util.function.Consumer;
import javax.crypto.KeyGenerator;
import javax.crypto.Mac;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

/**
 * 아홉 언어 공통 bearer 규칙의 정본 표(등록부 {@code bearer-token-grammar-divergent}, 2026-10-29 판정) — admin 요청의
 * {@code Authorization: Bearer <토큰>} 은 토큰의 앞뒤에서 SP·HTAB·CR·LF <b>만</b> 떼고 남은 것이 비어 있지 않은 RFC 6750
 * {@code b64token}({@code [A-Za-z0-9\-._~+/]+=*}, ASCII)일 때만 나간다. 아니면 요청을 하나도 보내지 않고 그 레인의 기존 오류다.
 *
 * <p>⚠️ Java 는 규칙의 <b>받는 자리 갈래</b>다 — admin 요청의 헤더는 keycloak-admin-client 의 {@code BearerAuthFilter} 가
 * {@code TokenManager.getAccessTokenString()}(토큰 응답을 Jackson 이 결합한 값)으로 직접 단다. SDK 가 토큰을 만나는 곳은 결합 앞의
 * 토큰 응답 바이트({@link TokenResponseGuard})뿐이고, TokenManager 에는 토큰을 넣는 setter 가 없다(소비자가 토큰을 주입할 길이 없다).
 * 그래서 다듬을 필요가 있는 토큰(lf·crlf·lead-tab)은 다듬어 보내지 못하고 받을 때 거부한다 — 표의 그 세 행이 REJECT 다.
 *
 * <p>표는 세 길로 돈다: (a) 파사드 {@code users().get} · (b) 탈출구 {@code raw()} — 같은 BearerAuthFilter 를 지난다 · (c) 받는 자리 —
 * 각 길의 두 번째 호출이 거부한 토큰을 캐시하지 않았음을(토큰 엔드포인트가 다시 불린다), 보낸 토큰은 캐시했음을 보이고,
 * TokenManager 의 갱신(refresh_token 그랜트)이 받은 토큰도 같은 판정을 받는다. 서버는 받은 {@code Authorization} 바이트를 그대로
 * 남기는 날 소켓이다 — com.sun HttpServer 는 값을 다듬는다(HTAB 을 공백으로 읽는다).
 */
class BearerTokenGrammarTest {
  private static final String REALM = "r";
  private static final String TOKEN_PATH = "/realms/" + REALM + "/protocol/openid-connect/token";
  private static final String LOGOUT_PATH = "/realms/" + REALM + "/protocol/openid-connect/logout";
  private static final String USER_PATH = "/admin/realms/" + REALM + "/users/x";
  private static final String USER = "{\"id\":\"x\",\"username\":\"alice\"}";

  /** 행의 기대 — 그대로 보낸다 · 다듬어 보낸다(Java 는 받는 자리 갈래라 거부) · 거부한다. */
  private enum Want { AS_IS, TRIMMED, REJECT }

  /** 정본 표의 한 행 — {@code marker} 는 거부 오류의 메시지가 싣지 말아야 할 그 행의 글자(없으면 null). */
  private record Row(String id, String token, Want want, String marker) {}

  /** 정본 표(스펙의 스무 행) + UTF-16 문자열 언어의 추가 행(짝 없는 서로게이트). 글자는 이스케이프로 적는다. */
  private static List<Row> rows() throws GeneralSecurityException {
    return List.of(
        new Row("plain", "abc.DEF-ghi_jkl~mno+pqr/stu", Want.AS_IS, null),
        new Row("pad", "abc==", Want.AS_IS, null),
        new Row("jwt", jws(), Want.AS_IS, null),
        new Row("lf", "abc\n", Want.TRIMMED, "abc"),
        new Row("crlf", "abc\r\n", Want.TRIMMED, "abc"),
        new Row("lead-tab", " \tabc\t ", Want.TRIMMED, "abc"),
        new Row("inner-sp", "a bc", Want.REJECT, "bc"),
        new Row("inner-tab", "a\tbc", Want.REJECT, "bc"),
        new Row("inner-crlf", "a\r\nX-Evil: 1", Want.REJECT, "X-Evil"),
        new Row("mid-pad", "a=bc", Want.REJECT, "=bc"),
        new Row("empty", "", Want.REJECT, null),
        new Row("blank", " \t\r\n", Want.REJECT, null),
        new Row("latin1", "abcé", Want.REJECT, "abc"),
        new Row("above-ff", "abcĀ", Want.REJECT, "abc"),
        new Row("c1", "abc\u0085", Want.REJECT, "abc"),
        new Row("nul", "abc\u0000", Want.REJECT, "abc"),
        new Row("del", "abc\u007f", Want.REJECT, "abc"),
        new Row("nbsp", "abc ", Want.REJECT, "abc"),
        new Row("ideographic", "　abc", Want.REJECT, "abc"),
        new Row("vt", "abc\u000b", Want.REJECT, "abc"),
        new Row("lone-surrogate", "abc\ud800", Want.REJECT, "abc"));
  }

  /** 진짜 세 조각 JWS(HS256) — 시험마다 새 키로 서명한다(소스에 키를 두지 않는다). */
  private static String jws() throws GeneralSecurityException {
    Base64.Encoder b64 = Base64.getUrlEncoder().withoutPadding();
    String head = b64.encodeToString("{\"alg\":\"HS256\",\"typ\":\"JWT\"}".getBytes(StandardCharsets.UTF_8));
    String claims = b64.encodeToString("{\"sub\":\"bearer-grammar\",\"iat\":1767225600}".getBytes(StandardCharsets.UTF_8));
    Mac mac = Mac.getInstance("HmacSHA256");
    mac.init(KeyGenerator.getInstance("HmacSHA256").generateKey());
    String signature = b64.encodeToString(mac.doFinal((head + "." + claims).getBytes(StandardCharsets.US_ASCII)));
    return head + "." + claims + "." + signature;
  }

  private Wire wire;

  @BeforeEach void start() throws IOException {
    wire = new Wire();
  }

  @AfterEach void stop() throws IOException {
    wire.close();
  }

  private AdminClient admin() {
    return new AdminClient(KeycloakConfig.builder().serverUrl("http://127.0.0.1:" + wire.port())
        .realm(REALM).clientId("app").clientSecret("s3cr3t".toCharArray())
        .connectTimeout(Duration.ofSeconds(5)).readTimeout(Duration.ofSeconds(5)).build());
  }

  /** 토큰 응답 — 문자열은 ASCII 밖·제어 문자·따옴표·역슬래시를 {@code \}uXXXX 로 싣는다(짝 없는 서로게이트도 그대로 결합된다). */
  private static String tokenBody(String token, String extra) {
    return "{\"access_token\":" + json(token) + ",\"token_type\":\"Bearer\",\"expires_in\":300" + extra + "}";
  }

  private static String json(String s) {
    StringBuilder out = new StringBuilder("\"");
    for (char c : s.toCharArray()) {
      if (c < 0x20 || c > 0x7e || c == '"' || c == '\\') out.append(String.format("\\u%04x", (int) c));
      else out.append(c);
    }
    return out.append('"').toString();
  }

  /** 갱신 길의 첫 응답 — expires_in 1 < TokenManager 최소 유효기간(30s) 이라 다음 호출이 refresh_token 으로 갱신한다. */
  private static final String REFRESHABLE =
      "{\"access_token\":\"AT-1\",\"token_type\":\"Bearer\",\"expires_in\":1,\"refresh_token\":\"RT-1\",\"refresh_expires_in\":300}";

  @Test void theCanonicalTable_throughTheFacade_raw_andBothGrants() throws GeneralSecurityException {
    List<String> table = new ArrayList<>();
    List<String> wrong = new ArrayList<>();
    for (Row row : rows()) {
      // Java 는 받는 자리 갈래다 — 다듬을 필요가 있는 토큰은 받을 때 거부한다(클래스 주석).
      boolean sent = row.want() == Want.AS_IS;
      String header = "Bearer " + row.token();
      // (a) 파사드 — 두 번 부른다: 보낸 토큰은 캐시되고(그랜트 1) 거부한 토큰은 캐시되지 않는다(그랜트 2).
      wire.reset(tokenBody(row.token(), ""));
      List<Throwable> facade = twice(admin -> admin.users().get("x"));
      table.add(line(row, "facade", facade));
      judge(row, "facade", facade, sent, KeycloakTransportException.class, "admin transport failure", wrong);
      expect(row, "facade", wire.admin(), sent ? List.of(header, header) : List.of(), wrong);
      expect(row, "facade 그랜트", wire.grants(),
          sent ? List.of("client_credentials") : List.of("client_credentials", "client_credentials"), wrong);
      // (b) raw() — 같은 BearerAuthFilter 를 지난다. 거부는 하위 라이브러리의 ProcessingException 그대로다(§4(b) 탈출구).
      wire.reset(tokenBody(row.token(), ""));
      List<Throwable> raw = twice(admin -> admin.raw().realm(REALM).users().get("x").toRepresentation());
      table.add(line(row, "raw", raw));
      judge(row, "raw", raw, sent, ProcessingException.class, null, wrong);
      expect(row, "raw", wire.admin(), sent ? List.of(header, header) : List.of(), wrong);
      expect(row, "raw 그랜트", wire.grants(),
          sent ? List.of("client_credentials") : List.of("client_credentials", "client_credentials"), wrong);
      // (c) 갱신 그랜트 — 첫 호출은 AT-1 로 나가고, 두 번째 호출의 갱신이 그 행의 토큰을 받는다.
      wire.reset(REFRESHABLE, tokenBody(row.token(), ""));
      List<Throwable> refresh = twice(admin -> admin.users().get("x"));
      table.add(line(row, "refresh", refresh));
      if (refresh.get(0) != null) wrong.add(row.id() + " refresh: 첫 호출(AT-1)은 성공해야 한다 — " + refresh.get(0));
      judge(row, "refresh", refresh.subList(1, 2), sent, KeycloakTransportException.class, "admin transport failure", wrong);
      expect(row, "refresh", wire.admin(), sent ? List.of("Bearer AT-1", header) : List.of("Bearer AT-1"), wrong);
      expect(row, "refresh 그랜트", wire.grants(), List.of("client_credentials", "refresh_token"), wrong);
    }
    System.out.println("[BearerTokenGrammarTest]\n  " + String.join("\n  ", table));
    assertTrue(wrong.isEmpty(), () -> wrong.size() + " 건:\n" + String.join("\n", wrong));
  }

  /** admin 하나로 같은 호출을 두 번 낸다 — 결과(성공이면 null, 실패면 그 예외)를 차례로. */
  private List<Throwable> twice(Consumer<AdminClient> call) {
    List<Throwable> out = new ArrayList<>();
    try (AdminClient admin = admin()) {
      for (int i = 0; i < 2; i++) {
        try {
          call.accept(admin);
          out.add(null);
        } catch (RuntimeException e) {
          out.add(e);
        }
      }
    }
    return out;
  }

  /** 보낸 행이면 실패가 없어야 하고, 거부 행이면 기존 오류 타입(·메시지)이고 그 행의 글자를 메시지 사슬 어디에도 싣지 않는다. */
  private static void judge(Row row, String route, List<Throwable> outcomes, boolean sent, Class<?> type, String message,
                            List<String> wrong) {
    for (Throwable t : outcomes) {
      if (sent) {
        if (t != null) wrong.add(row.id() + " " + route + ": 보내야 한다 — " + t);
        continue;
      }
      if (!type.isInstance(t) || (message != null && !message.equals(t.getMessage()))) {
        wrong.add(row.id() + " " + route + ": " + type.getSimpleName() + (message == null ? "" : "(" + message + ")")
            + " 가 아니다 — " + (t == null ? "성공" : t.getClass().getName()));
      } else if (row.marker() != null && quotes(t, row.marker())) {
        wrong.add(row.id() + " " + route + ": 오류 메시지가 토큰(" + row.marker() + ")을 실었다");
      }
    }
  }

  private static void expect(Row row, String what, List<String> got, List<String> want, List<String> wrong) {
    if (!got.equals(want)) wrong.add(row.id() + " " + what + ": " + printable(got.toString()) + " — 기대 " + printable(want.toString()));
  }

  /** 오류 사슬(원인·suppressed)의 메시지 어디에 {@code marker} 가 있는가. */
  private static boolean quotes(Throwable t, String marker) {
    List<Throwable> todo = new ArrayList<>(List.of(t));
    for (int i = 0; i < todo.size() && i < 64; i++) {
      Throwable c = todo.get(i);
      if (String.valueOf(c.getMessage()).contains(marker)) return true;
      if (c.getCause() != null) todo.add(c.getCause());
      todo.addAll(List.of(c.getSuppressed()));
    }
    return false;
  }

  private String line(Row row, String route, List<Throwable> outcomes) {
    List<String> shown = new ArrayList<>();
    for (Throwable t : outcomes) shown.add(t == null ? "성공" : t.getClass().getSimpleName());
    return String.format("%-15s %-8s → %s · grants %s · admin %s", row.id(), route, shown, wire.grants(),
        printable(wire.admin().toString()));
  }

  /** 표에 찍을 수 있게 — 제어 문자·DEL·ASCII 밖은 {@code \}uXXXX 로. */
  private static String printable(String s) {
    StringBuilder out = new StringBuilder();
    for (char c : s.toCharArray()) {
      if (c < 0x20 || c > 0x7e) out.append(String.format("\\u%04X", (int) c));
      else out.append(c);
    }
    return out.toString();
  }

  /**
   * 받은 바이트를 그대로 남기는 가짜 Keycloak — 토큰 엔드포인트(차례로 낼 본문, 마지막 것은 계속) · admin GET(받은
   * {@code Authorization} 값의 바이트를 남긴다 — 콜론 뒤 공백 하나만 뗀다) · logout(204). 응답마다 연결을 닫는다.
   */
  private static final class Wire implements AutoCloseable {
    private final ServerSocket socket;
    private final Deque<String> replies = new ArrayDeque<>();
    private final List<String> grants = new ArrayList<>();
    private final List<String> admin = new ArrayList<>();

    Wire() throws IOException {
      socket = new ServerSocket(0, 50, InetAddress.getLoopbackAddress());
      Thread t = new Thread(this::serve, "bearer-grammar-wire");
      t.setDaemon(true);
      t.start();
    }

    int port() {
      return socket.getLocalPort();
    }

    synchronized void reset(String... tokenBodies) {
      replies.clear();
      replies.addAll(List.of(tokenBodies));
      grants.clear();
      admin.clear();
    }

    synchronized List<String> grants() {
      return List.copyOf(grants);
    }

    /** admin 요청이 실은 Authorization 값 — 받은 바이트를 ISO-8859-1 로 한 글자씩 옮긴 것(바이트 그대로). */
    synchronized List<String> admin() {
      return List.copyOf(admin);
    }

    private void serve() {
      while (!socket.isClosed()) {
        Socket s;
        try {
          s = socket.accept();
        } catch (IOException closed) {
          return;
        }
        Thread t = new Thread(() -> answer(s), "bearer-grammar-exchange");
        t.setDaemon(true);
        t.start();
      }
    }

    private void answer(Socket s) {
      try (s) {
        s.setSoTimeout(10_000);
        InputStream in = new BufferedInputStream(s.getInputStream());
        String path = null;
        String authorization = null;
        int length = 0;
        for (String line = crlfLine(in); line != null && !line.isEmpty(); line = crlfLine(in)) {
          if (path == null) {
            String[] parts = line.split(" ");
            path = parts.length > 1 ? parts[1] : "";
            continue;
          }
          int colon = line.indexOf(':');
          if (colon <= 0) continue;
          String name = line.substring(0, colon).toLowerCase(Locale.ROOT);
          String value = line.substring(colon + 1);
          if (name.equals("content-length")) length = Integer.parseInt(value.trim());
          if (name.equals("authorization")) authorization = value.startsWith(" ") ? value.substring(1) : value;
        }
        if (path == null) return;
        String body = new String(in.readNBytes(length), StandardCharsets.ISO_8859_1);
        OutputStream out = s.getOutputStream();
        if (path.equals(TOKEN_PATH)) {
          String reply;
          synchronized (this) {
            grants.add(grantType(body));
            reply = replies.size() > 1 ? replies.poll() : replies.peek();
          }
          respond(out, "200 OK", reply);
        } else if (path.equals(USER_PATH)) {
          synchronized (this) {
            admin.add(authorization);
          }
          respond(out, "200 OK", USER);
        } else if (path.equals(LOGOUT_PATH)) {
          respond(out, "204 No Content", null);
        } else {
          respond(out, "404 Not Found", "{\"error\":\"not found\"}");
        }
      } catch (IOException clientWentAway) {
        // 클라이언트가 연결을 끊었다
      }
    }

    private static String grantType(String form) {
      for (String kv : form.split("&")) {
        if (kv.startsWith("grant_type=")) return kv.substring("grant_type=".length());
      }
      return "?";
    }

    private static void respond(OutputStream out, String status, String json) throws IOException {
      byte[] body = json == null ? new byte[0] : json.getBytes(StandardCharsets.UTF_8);
      String head = "HTTP/1.1 " + status + "\r\n"
          + (json == null ? "" : "Content-Type: application/json\r\nContent-Length: " + body.length + "\r\n")
          + "Connection: close\r\n\r\n";
      out.write(head.getBytes(StandardCharsets.ISO_8859_1));
      out.write(body);
      out.flush();
    }

    /** CRLF 로 끝나는 한 줄(줄 끝 제외) — 바이트를 ISO-8859-1 로 옮긴다. 홀로 선 CR·LF 는 줄의 일부로 남긴다. 끝이면 null. */
    private static String crlfLine(InputStream in) throws IOException {
      ByteArrayOutputStream line = new ByteArrayOutputStream();
      int prev = -1;
      for (int c = in.read(); c >= 0; c = in.read()) {
        if (prev == '\r' && c == '\n') {
          byte[] bytes = line.toByteArray();
          return new String(bytes, 0, bytes.length - 1, StandardCharsets.ISO_8859_1);
        }
        line.write(c);
        prev = c;
      }
      return line.size() == 0 ? null : line.toString(StandardCharsets.ISO_8859_1);
    }

    @Override public void close() throws IOException {
      socket.close();
    }
  }
}
