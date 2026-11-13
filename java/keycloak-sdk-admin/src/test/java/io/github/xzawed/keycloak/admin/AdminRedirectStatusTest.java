package io.github.xzawed.keycloak.admin;

import static org.junit.jupiter.api.Assertions.*;

import io.github.xzawed.keycloak.core.KeycloakConfig;
import io.github.xzawed.keycloak.core.exception.KeycloakAdminException;
import io.github.xzawed.keycloak.core.exception.KeycloakNotFoundException;
import java.io.BufferedInputStream;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.Arrays;
import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicLong;
import java.util.stream.Stream;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.Timeout;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.Arguments;
import org.junit.jupiter.params.provider.EnumSource;
import org.junit.jupiter.params.provider.MethodSource;
import org.keycloak.representations.idm.ClientRepresentation;
import org.keycloak.representations.idm.GroupRepresentation;
import org.keycloak.representations.idm.RealmRepresentation;
import org.keycloak.representations.idm.RoleRepresentation;
import org.keycloak.representations.idm.UserRepresentation;

/**
 * 파사드 호출에 Location 없는 3xx(300 · 302 · 399)가 그 호출의 성공 본문 모양인 JSON 을 싣고 와도 성공이 아니다 — 25 호출(다섯 자원 ×
 * create · get · 목록 · update · delete, 통합 admin 표면 시험과 같은 25) 모두 admin 예외에 그 상태를 싣는다. 분류는 4xx 와 같다(상태가
 * 403 · 404 · 409 가 아니면 {@link KeycloakAdminException} 그 자체)이고 본문도 4xx 처럼 {@code keycloakError} 로 싣는다. 반환값 · null ·
 * 빈 목록 · id 는 실패이고, 전송 · 해석 예외도 실패다(등록부 go-admin-3xx-read-as-success 의 부류 재스캔).
 *
 * <p>수정 전(실측 2026-11-13, main 3ff48b96 · Windows · JDK 21.0.8 · 루프백): 세 상태 모두 25 중 13 만 통과했다. update 다섯 · delete
 * 다섯 · realms · roles 의 create 열둘은 오류 없이 돌아왔다(void 를 돌려주는 프록시의 추출기는 400 이상만 던지고, users · clients 의
 * delete 는 {@code Response} 의 400 이상만 본다) — 서버는 칸마다 그 호출의 요청 하나를 받았다.
 *
 * <p>대조: 같은 표 · 같은 본문의 404 는 25 호출 모두 {@link KeycloakNotFoundException}(404)이다 — 표의 배선(호출마다 그 요청 하나가
 * 서버에 닿는다)과 「4xx 가 받는 분류」를 같은 하네스로 보인다. 칸마다 서버가 받은 admin 요청이 그 호출의 메서드 · 경로 하나인지도 본다.
 *
 * <p>토큰 엔드포인트의 3xx 는 이 규칙 밖이다 — 토큰 레인이 가르고 그 상한이 본문을 끊는다
 * ({@link #aTokenEndpointRedirect_isLeftToTheTokenLane}).
 *
 * <p>공개 API(생성자 · 파사드)와 로컬 루프백만 쓴다(Docker 불필요). 토큰 엔드포인트는 (그 갈래 밖에서) 쓸 수 있는 토큰을 낸다.
 */
class AdminRedirectStatusTest {
  private static final String REALM = "r";
  private static final String TOKEN_PATH = "/realms/" + REALM + "/protocol/openid-connect/token";
  private static final byte[] TOKEN =
      "{\"access_token\":\"good\",\"token_type\":\"Bearer\",\"expires_in\":300}".getBytes(StandardCharsets.UTF_8);
  private static final String USER = "{\"id\":\"x\",\"username\":\"alice\"}";
  private static final String CLIENT = "{\"id\":\"x\",\"clientId\":\"app\"}";
  private static final String REALM_REP = "{\"id\":\"r\",\"realm\":\"r\"}";
  private static final String ROLE = "{\"id\":\"x\",\"name\":\"role\"}";
  private static final String GROUP = "{\"id\":\"x\",\"name\":\"group\"}";
  private static final String USERS = "/admin/realms/" + REALM + "/users";
  private static final String CLIENTS = "/admin/realms/" + REALM + "/clients";
  private static final String REALMS = "/admin/realms";
  private static final String ROLES = "/admin/realms/" + REALM + "/roles";
  private static final String GROUPS = "/admin/realms/" + REALM + "/groups";
  /** void 호출이 오류 없이 돌아왔다는 표시 — 칸의 기록에 「returned void」로 남는다. */
  private static final String VOID = "void";
  /** 토큰 엔드포인트 3xx 갈래의 본문 길이 — 토큰 레인의 상한(1 MiB)을 한참 넘는다. */
  private static final long HUGE = 64L << 20;
  /** 끊긴 교환에서 서버가 써도 되는 본문 — 상한 + 소켓 버퍼를 넉넉히 넘는 16 MiB({@code AdminRejectedResponseCutTest} 와 같은 한도). */
  private static final long WRITTEN_BOUND = 16L << 20;

  @FunctionalInterface
  private interface Call {
    Object run(AdminClient admin);
  }

  /** 파사드 25 호출 — 서버가 받아야 할 「메서드 경로」(질의 뺌)와, 성공이었다면 그 호출이 받았을 모양의 JSON 본문. */
  enum Op {
    USERS_CREATE("POST", USERS, USER, a -> a.users().create(user())),
    USERS_GET("GET", USERS + "/x", USER, a -> a.users().get("x")),
    USERS_SEARCH("GET", USERS, list(USER), a -> a.users().search("alice", 0, 10)),
    USERS_UPDATE("PUT", USERS + "/x", USER, a -> {
      a.users().update("x", user());
      return VOID;
    }),
    USERS_DELETE("DELETE", USERS + "/x", USER, a -> {
      a.users().delete("x");
      return VOID;
    }),
    CLIENTS_CREATE("POST", CLIENTS, CLIENT, a -> a.clients().create(client())),
    CLIENTS_GET("GET", CLIENTS + "/x", CLIENT, a -> a.clients().get("x")),
    CLIENTS_FIND("GET", CLIENTS, list(CLIENT), a -> a.clients().findByClientId("app")),
    CLIENTS_UPDATE("PUT", CLIENTS + "/x", CLIENT, a -> {
      a.clients().update("x", client());
      return VOID;
    }),
    CLIENTS_DELETE("DELETE", CLIENTS + "/x", CLIENT, a -> {
      a.clients().delete("x");
      return VOID;
    }),
    REALMS_CREATE("POST", REALMS, REALM_REP, a -> {
      a.realms().create(realm());
      return VOID;
    }),
    REALMS_GET("GET", REALMS + "/r", REALM_REP, a -> a.realms().get("r")),
    REALMS_LIST("GET", REALMS, list(REALM_REP), a -> a.realms().list()),
    REALMS_UPDATE("PUT", REALMS + "/r", REALM_REP, a -> {
      a.realms().update("r", realm());
      return VOID;
    }),
    REALMS_DELETE("DELETE", REALMS + "/r", REALM_REP, a -> {
      a.realms().delete("r");
      return VOID;
    }),
    ROLES_CREATE("POST", ROLES, ROLE, a -> {
      a.roles().create(role());
      return VOID;
    }),
    ROLES_GET("GET", ROLES + "/role", ROLE, a -> a.roles().get("role")),
    ROLES_LIST("GET", ROLES, list(ROLE), a -> a.roles().list()),
    ROLES_UPDATE("PUT", ROLES + "/role", ROLE, a -> {
      a.roles().update("role", role());
      return VOID;
    }),
    ROLES_DELETE("DELETE", ROLES + "/role", ROLE, a -> {
      a.roles().delete("role");
      return VOID;
    }),
    GROUPS_CREATE("POST", GROUPS, GROUP, a -> a.groups().create(group())),
    GROUPS_GET("GET", GROUPS + "/x", GROUP, a -> a.groups().get("x")),
    GROUPS_LIST("GET", GROUPS, list(GROUP), a -> a.groups().list(0, 10)),
    GROUPS_UPDATE("PUT", GROUPS + "/x", GROUP, a -> {
      a.groups().update("x", group());
      return VOID;
    }),
    GROUPS_DELETE("DELETE", GROUPS + "/x", GROUP, a -> {
      a.groups().delete("x");
      return VOID;
    });

    final String request;
    final String body;
    final Call call;

    Op(String method, String path, String body, Call call) {
      this.request = method + " " + path;
      this.body = body;
      this.call = call;
    }
  }

  /** 계약의 세 상태 — 300 · 302(Location 없음) · 399. 어느 것도 Location 을 싣지 않는다. */
  private static final int[] REDIRECTS = {300, 302, 399};

  static Stream<Arguments> cells() {
    return Arrays.stream(Op.values())
        .flatMap(op -> Arrays.stream(REDIRECTS).mapToObj(status -> Arguments.of(op, status)));
  }

  /** 75 칸 — 칸마다 그 상태를 실은 admin 예외(분류는 「그 밖」)여야 하고, 서버는 그 호출의 요청 하나를 받았어야 한다. */
  @ParameterizedTest(name = "{0} {1}")
  @MethodSource("cells")
  @Timeout(30)
  void aLocationlessRedirect_isAnAdminErrorCarryingItsStatus(Op op, int status) throws Exception {
    try (RawServer server = new RawServer(status, op.body)) {
      Throwable thrown = run(server, op);
      String row = row(op, status, thrown, server);
      System.out.println("[AdminRedirectStatusTest] " + row);
      KeycloakAdminException e = assertInstanceOf(KeycloakAdminException.class, thrown, row);
      assertEquals(KeycloakAdminException.class, e.getClass(), () -> "3xx 는 403 · 404 · 409 의 갈래가 아니다 — " + row);
      assertEquals(status, e.getStatus(), row);
      assertEquals(op.body, e.getKeycloakError(), () -> "본문은 4xx 처럼 keycloakError 로 — " + row);
      assertEquals(List.of(op.request), server.adminRequests, row);
    }
  }

  /** 대조 — 같은 표 · 같은 본문의 404: 25 호출 모두 {@link KeycloakNotFoundException}(404)이고 그 호출의 요청 하나가 서버에 닿는다. */
  @ParameterizedTest
  @EnumSource(Op.class)
  @Timeout(30)
  void control_aNotFound_isTheNotFoundLeafOnEveryCall(Op op) throws Exception {
    try (RawServer server = new RawServer(404, op.body)) {
      Throwable thrown = run(server, op);
      String row = row(op, 404, thrown, server);
      KeycloakNotFoundException e = assertInstanceOf(KeycloakNotFoundException.class, thrown, row);
      assertEquals(404, e.getStatus(), row);
      assertEquals(List.of(op.request), server.adminRequests, row);
    }
  }

  /**
   * 토큰 엔드포인트의 3xx 는 이 규칙의 것이 아니다 — 엔진은 토큰 응답 본문에 상한을 걸지 않으므로(그 레인의 상한은
   * {@code TokenResponseGuard} 가 건다) 이 규칙이 그것을 버퍼에 담으면 끝까지 읽는다. 파사드 호출 안의 토큰 부여가 64 MiB 본문의 302 를
   * 받으면 호출은 admin 예외가 아니고(토큰 레인이 가른다) admin 요청은 나가지 않으며 서버는 {@link #WRITTEN_BOUND} 를 넘어 쓰지 못한다.
   * 규칙에서 토큰 엔드포인트를 빼는 조건을 지우면 서버가 64 MiB 를 다 쓴다.
   */
  @Test
  @Timeout(60)
  void aTokenEndpointRedirect_isLeftToTheTokenLane() throws Exception {
    try (RawServer server = new RawServer(200, USER, 302, HUGE)) {
      Throwable thrown = run(server, Op.USERS_GET);
      boolean finished = server.tokenReplied.await(30, TimeUnit.SECONDS);
      String row = row(Op.USERS_GET, 302, thrown, server) + " · token endpoint wrote " + server.tokenWritten.get() + " B"
          + (finished ? "" : " (still writing)");
      System.out.println("[AdminRedirectStatusTest] " + row);
      assertFalse(thrown instanceof Returned || thrown instanceof KeycloakAdminException, row);
      assertEquals(List.of(), server.adminRequests, row);
      assertTrue(finished && server.tokenWritten.get() <= WRITTEN_BOUND, () -> "토큰 레인의 상한을 넘어 읽었다 — " + row);
    }
  }

  /** 호출 하나 — 던진 것을 돌려준다. 오류 없이 돌아오면 돌려준 값을 담은 표시를 던진 것 대신 돌려준다(단언이 그 값을 보인다). */
  private static Throwable run(RawServer server, Op op) {
    try (AdminClient admin = new AdminClient(config(server.port()))) {
      Object result = op.call.run(admin);
      return new Returned(result);
    } catch (Throwable t) {
      return t;
    }
  }

  /** 호출이 오류 없이 돌아왔다 — 그 값이 메시지다(칸의 기록과 단언 실패에 「returned …」로 보인다). */
  private static final class Returned extends Throwable {
    Returned(Object result) {
      super("returned " + result, null, false, false);
    }
  }

  private static String row(Op op, int status, Throwable thrown, RawServer server) {
    String what = thrown instanceof Returned
        ? thrown.getMessage()
        : thrown.getClass().getName() + (thrown instanceof KeycloakAdminException e ? "(status " + e.getStatus() + ")" : "")
            + ": " + thrown.getMessage();
    return op + " " + status + " → " + what + " · admin requests " + server.adminRequests;
  }

  private static KeycloakConfig config(int port) {
    return KeycloakConfig.builder().serverUrl("http://127.0.0.1:" + port).realm(REALM).clientId("app")
        .clientSecret("s3cr3t".toCharArray()).connectTimeout(Duration.ofSeconds(5)).readTimeout(Duration.ofSeconds(5))
        .build();
  }

  private static String list(String element) {
    return "[" + element + "]";
  }

  private static UserRepresentation user() {
    UserRepresentation u = new UserRepresentation();
    u.setUsername("alice");
    return u;
  }

  private static ClientRepresentation client() {
    ClientRepresentation c = new ClientRepresentation();
    c.setClientId("app");
    return c;
  }

  private static RealmRepresentation realm() {
    RealmRepresentation r = new RealmRepresentation();
    r.setRealm("r");
    return r;
  }

  private static RoleRepresentation role() {
    RoleRepresentation r = new RoleRepresentation();
    r.setName("role");
    return r;
  }

  private static GroupRepresentation group() {
    GroupRepresentation g = new GroupRepresentation();
    g.setName("group");
    return g;
  }

  private static byte[] latin1(String s) {
    return s.getBytes(StandardCharsets.ISO_8859_1);
  }

  private static String reason(int status) {
    return switch (status) {
      case 300 -> "Multiple Choices";
      case 302 -> "Found";
      case 404 -> "Not Found";
      default -> "Unassigned";
    };
  }

  /**
   * 원시 HTTP/1.1 서버(연결 하나에 요청 여럿) — 토큰 엔드포인트는 쓸 수 있는 토큰을, {@code /admin/} 아래는 고른 상태와 JSON 본문을
   * (Location 없이) 내고 그 요청의 「메서드 경로」(질의 뺌)를 적는다. 그 밖은 빈 404 다. 토큰 엔드포인트의 상태가 200 이 아니면 그 상태와
   * {@code tokenSize} 바이트의 본문(토큰 뒤 공백)을 내고 쓴 바이트를 센다.
   */
  private static final class RawServer implements AutoCloseable {
    private final ServerSocket socket = new ServerSocket(0, 50, InetAddress.getLoopbackAddress());
    private final byte[] adminReply;
    private final int tokenStatus;
    private final long tokenSize;
    final List<String> adminRequests = new CopyOnWriteArrayList<>();
    final AtomicLong tokenWritten = new AtomicLong();
    /** 200 이 아닌 토큰 응답의 쓰기가 끝났다(성공 · 실패). */
    final CountDownLatch tokenReplied = new CountDownLatch(1);

    RawServer(int status, String body) throws IOException {
      this(status, body, 200, 0);
    }

    RawServer(int status, String body, int tokenStatus, long tokenSize) throws IOException {
      this.tokenStatus = tokenStatus;
      this.tokenSize = tokenSize;
      byte[] b = body.getBytes(StandardCharsets.UTF_8);
      ByteArrayOutputStream reply = new ByteArrayOutputStream();
      reply.writeBytes(latin1("HTTP/1.1 " + status + " " + reason(status) + "\r\nContent-Type: application/json\r\n"
          + "Content-Length: " + b.length + "\r\n\r\n"));
      reply.writeBytes(b);
      adminReply = reply.toByteArray();
      Thread t = new Thread(this::serve, "admin-3xx-server");
      t.setDaemon(true);
      t.start();
    }

    int port() {
      return socket.getLocalPort();
    }

    private void serve() {
      while (!socket.isClosed()) {
        Socket s;
        try {
          s = socket.accept();
        } catch (IOException closed) {
          return;
        }
        Thread t = new Thread(() -> exchanges(s), "admin-3xx-connection");
        t.setDaemon(true);
        t.start();
      }
    }

    private void exchanges(Socket s) {
      try (s) {
        s.setSoTimeout(20_000);
        InputStream in = new BufferedInputStream(s.getInputStream());
        OutputStream out = s.getOutputStream();
        for (String request = request(in); request != null; request = request(in)) {
          answer(request, out);
        }
      } catch (IOException clientLeft) {
        // 클라이언트가 끊었다 — 읽지 않은 본문의 연결은 SDK 가 끊는다
      }
    }

    private void answer(String request, OutputStream out) throws IOException {
      String path = request.substring(request.indexOf(' ') + 1);
      if (path.equals(TOKEN_PATH) && tokenStatus != 200) {
        try {
          out.write(latin1("HTTP/1.1 " + tokenStatus + " " + reason(tokenStatus) + "\r\nContent-Type: application/json\r\n"
              + "Content-Length: " + tokenSize + "\r\n\r\n"));
          out.write(TOKEN);
          tokenWritten.addAndGet(TOKEN.length);
          byte[] slab = new byte[64 * 1024];
          Arrays.fill(slab, (byte) ' ');
          for (long left = tokenSize - TOKEN.length; left > 0; ) {
            int k = (int) Math.min(left, slab.length);
            out.write(slab, 0, k);
            tokenWritten.addAndGet(k);
            left -= k;
          }
        } finally {
          tokenReplied.countDown();
        }
      } else if (path.equals(TOKEN_PATH)) {
        out.write(latin1("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: " + TOKEN.length + "\r\n\r\n"));
        out.write(TOKEN);
      } else if (path.startsWith("/admin/")) {
        adminRequests.add(request);
        out.write(adminReply);
      } else {
        out.write(latin1("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n"));
      }
      out.flush();
    }

    /** 요청 하나(머리와 본문 — Content-Length 또는 chunked)를 읽고 「메서드 경로」(질의 뺌)를 돌려준다 — 연결이 끝났으면 null. */
    private static String request(InputStream in) throws IOException {
      ByteArrayOutputStream head = new ByteArrayOutputStream();
      int last4 = 0;
      for (int b = in.read(); b != -1; b = in.read()) {
        head.write(b);
        last4 = (last4 << 8) | b;
        if (last4 == 0x0d0a0d0a) {
          String[] lines = head.toString(StandardCharsets.ISO_8859_1).split("\r\n");
          for (String line : lines) {
            if (line.regionMatches(true, 0, "Content-Length:", 0, 15)) {
              in.readNBytes(Integer.parseInt(line.substring(15).trim()));
            } else if (line.regionMatches(true, 0, "Transfer-Encoding:", 0, 18)
                && line.substring(18).trim().equalsIgnoreCase("chunked")) {
              skipChunked(in);
            }
          }
          String[] first = lines[0].split(" ");
          int query = first[1].indexOf('?');
          return first[0] + " " + (query < 0 ? first[1] : first[1].substring(0, query));
        }
      }
      return null;
    }

    private static void skipChunked(InputStream in) throws IOException {
      for (int size = chunkSize(in); size > 0; size = chunkSize(in)) {
        in.readNBytes(size + 2); // 청크와 그 뒤의 CRLF
      }
      for (String line = line(in); line != null && !line.isEmpty(); line = line(in)) {
        // 트레일러 — 빈 줄까지
      }
    }

    private static int chunkSize(InputStream in) throws IOException {
      String line = line(in);
      if (line == null) return 0;
      int ext = line.indexOf(';');
      return Integer.parseInt((ext < 0 ? line : line.substring(0, ext)).trim(), 16);
    }

    private static String line(InputStream in) throws IOException {
      ByteArrayOutputStream buf = new ByteArrayOutputStream();
      for (int b = in.read(); b != -1; b = in.read()) {
        if (b == '\n') return buf.toString(StandardCharsets.ISO_8859_1).stripTrailing();
        buf.write(b);
      }
      return null;
    }

    @Override
    public void close() throws IOException {
      socket.close();
    }
  }
}
