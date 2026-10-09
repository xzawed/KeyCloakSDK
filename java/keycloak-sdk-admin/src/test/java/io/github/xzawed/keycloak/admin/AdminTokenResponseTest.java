package io.github.xzawed.keycloak.admin;

import static org.junit.jupiter.api.Assertions.*;

import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;
import io.github.xzawed.keycloak.core.KeycloakConfig;
import io.github.xzawed.keycloak.core.exception.KeycloakTransportException;
import java.io.BufferedInputStream;
import java.io.BufferedOutputStream;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.io.PrintWriter;
import java.io.StringWriter;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Deque;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Objects;
import java.util.function.Supplier;
import java.util.zip.GZIPOutputStream;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.keycloak.representations.idm.UserRepresentation;

/**
 * admin 레인의 토큰 응답 계약 — admin 은 토큰을 자체 소유하고(§4) keycloak-admin-client 내장 TokenManager 가 그 응답을
 * Jackson 으로 읽는다. 계약: 쓸 수 없는 {@code access_token}(누락·null·숫자·불리언·빈 문자열·객체·배열)이면 **admin API
 * 요청을 하나도 보내지 않고** {@link KeycloakTransportException} 으로 실패한다 — 오늘 null·객체·배열·누락이 이미 그렇게
 * 실패하던 타입이다. 쓸 수 있는 문자열 토큰은 그대로 동작하고, TokenManager 의 갱신(refresh_token 그랜트)도 같은 검사를
 * 받는다.
 *
 * <p>⚠️ 가짜 admin 엔드포인트는 <b>성공</b>(200 사용자)을 낸다 — 강제변환된 토큰으로 나간 요청이 404 로 우연히 실패해
 * 결함이 「실패했으니 됐다」로 가려지지 않게. 판정의 무게는 「admin 요청 0 건」이 진다(적대 행렬 W3a 와 같은 기준).
 * 네트워크는 로컬 루프백만 쓴다(Docker 불필요).
 */
class AdminTokenResponseTest {
  private static final String REALM = "r";
  private static final String TOKEN_PATH = "/realms/" + REALM + "/protocol/openid-connect/token";
  private static final String MISSING = "(missing)";

  private HttpServer server;
  /** 토큰 엔드포인트가 차례로 낼 응답 — 마지막 것은 계속 낸다. */
  private final Deque<Reply> tokenReplies = new ArrayDeque<>();
  private final List<String> grants = new ArrayList<>();
  /** admin 엔드포인트에 닿은 요청(메서드 경로 · Authorization). */
  private final List<String> adminHits = new ArrayList<>();

  /**
   * 토큰 엔드포인트의 응답 — {@code contentEncoding} 이 있으면 그 헤더를 달고(본문은 이미 그 코딩으로 된 바이트),
   * {@code typed} 가 거짓이면 Content-Type 을 달지 않는다.
   */
  private record Reply(int status, byte[] body, String contentEncoding, boolean typed) {
    Reply(int status, String body) {
      this(status, body.getBytes(StandardCharsets.UTF_8), null, true);
    }

    Reply(int status, byte[] body, String contentEncoding) {
      this(status, body, contentEncoding, true);
    }

    // 배열 컴포넌트라 record 기본 equals·hashCode 는 참조를 본다(SonarCloud java:S6218) — 내용으로 비교한다.
    @Override
    public boolean equals(Object o) {
      return o instanceof Reply r && status == r.status && typed == r.typed
          && Arrays.equals(body, r.body) && Objects.equals(contentEncoding, r.contentEncoding);
    }

    @Override
    public int hashCode() {
      return Objects.hash(status, Arrays.hashCode(body), contentEncoding, typed);
    }

    // 본문은 토큰 응답일 수 있다 — 길이만 찍는다.
    @Override
    public String toString() {
      return "Reply[status=" + status + ", body=" + body.length + " bytes, contentEncoding=" + contentEncoding
          + ", typed=" + typed + "]";
    }
  }

  @BeforeEach void start() throws IOException {
    server = HttpServer.create(new InetSocketAddress(InetAddress.getLoopbackAddress(), 0), 0);
    server.createContext("/", this::handle);
    server.start();
  }

  @AfterEach void stop() {
    server.stop(0);
  }

  private synchronized void handle(HttpExchange ex) throws IOException {
    String path = ex.getRequestURI().getPath();
    String body = new String(ex.getRequestBody().readAllBytes(), StandardCharsets.UTF_8);
    if (path.equals(TOKEN_PATH)) {
      grants.add(form(body).getOrDefault("grant_type", "?"));
      Reply r = tokenReplies.size() > 1 ? tokenReplies.poll() : tokenReplies.peek();
      if (r.contentEncoding() != null) ex.getResponseHeaders().add("Content-Encoding", r.contentEncoding());
      send(ex, r.status(), r.body(), r.typed());
    } else if (path.startsWith("/admin/realms/" + REALM + "/users")) {
      adminHits.add(ex.getRequestMethod() + " " + path + " · " + ex.getRequestHeaders().getFirst("Authorization"));
      if (ex.getRequestMethod().equals("POST")) {
        ex.getResponseHeaders().add("Location", "http://127.0.0.1/admin/realms/" + REALM + "/users/new-id");
        send(ex, 201, null);
      } else {
        send(ex, 200, "{\"id\":\"x\",\"username\":\"alice\"}");
      }
    } else {
      send(ex, 404, "{\"error\":\"not found\"}");
    }
  }

  private static void send(HttpExchange ex, int status, String body) throws IOException {
    if (body == null) {
      ex.sendResponseHeaders(status, -1);
      ex.close();
      return;
    }
    send(ex, status, body.getBytes(StandardCharsets.UTF_8), true);
  }

  private static void send(HttpExchange ex, int status, byte[] bytes, boolean typed) throws IOException {
    if (typed) ex.getResponseHeaders().add("Content-Type", "application/json");
    ex.sendResponseHeaders(status, bytes.length);
    try (OutputStream os = ex.getResponseBody()) {
      os.write(bytes);
    }
  }

  private static Map<String, String> form(String body) {
    Map<String, String> out = new LinkedHashMap<>();
    for (String kv : body.split("&")) {
      int eq = kv.indexOf('=');
      if (eq > 0) out.put(kv.substring(0, eq), kv.substring(eq + 1));
    }
    return out;
  }

  private AdminClient admin() {
    return admin(server.getAddress().getPort(), Duration.ofSeconds(5));
  }

  private static AdminClient admin(int port, Duration readTimeout) {
    return new AdminClient(KeycloakConfig.builder().serverUrl("http://127.0.0.1:" + port)
        .realm(REALM).clientId("app").clientSecret("s3cr3t".toCharArray())
        .connectTimeout(Duration.ofSeconds(5)).readTimeout(readTimeout).build());
  }

  private static String tokenBody(String rawAccessToken, String extra) {
    String at = rawAccessToken.equals(MISSING) ? "" : "\"access_token\":" + rawAccessToken + ",";
    return "{" + at + "\"token_type\":\"Bearer\",\"expires_in\":300" + extra + "}";
  }

  private synchronized void reset(Reply... replies) {
    tokenReplies.clear();
    tokenReplies.addAll(List.of(replies));
    grants.clear();
    adminHits.clear();
  }

  private synchronized List<String> adminHits() {
    return List.copyOf(adminHits);
  }

  private synchronized List<String> grants() {
    return List.copyOf(grants);
  }

  /** 같은 응답에 실린 refresh_token — 거부 오류의 어느 표현에도 찍히면 안 된다. */
  private static final String RT_CANARY = "ZadminRT-0123456789abcdef";

  @Test void unusableAccessToken_sendsNoAdminRequest_andFailsAsTransport() {
    List<String> table = new ArrayList<>();
    List<String> wrong = new ArrayList<>();
    // 마지막 행은 중복 키 — 결합은 마지막 값(숫자)을 쓴다(첫 값만 보는 검사는 여기서 Bearer 12345 로 나아간다).
    for (String raw : List.of("12345", "true", "\"\"", "null", "{\"v\":\"x\"}", "[\"x\"]", MISSING,
        "\"AT\",\"access_token\":12345")) {
      reset(new Reply(200, tokenBody(raw, ",\"refresh_token\":\"" + RT_CANARY + "\"")));
      table.add(callExpectingRejection("access_token " + raw, wrong));
    }
    System.out.println("[AdminTokenResponseTest]\n  " + String.join("\n  ", table));
    assertTrue(wrong.isEmpty(), () -> wrong.size() + " 건:\n" + String.join("\n", wrong));
  }

  /**
   * admin 호출 하나를 내고 거부 계약을 잰다 — {@link KeycloakTransportException}("admin transport failure") · admin 요청
   * 0 건 · 토큰 요청 정확히 1 건 · 원인 사슬에 java.* 밖 타입 없음(§4) · 응답의 refresh_token 미노출. 어긋남은 {@code wrong}
   * 에 쌓고 표의 한 행을 돌려준다.
   */
  private String callExpectingRejection(String label, List<String> wrong) {
    return callExpectingRejection(label, wrong, this::admin);
  }

  /** {@link #callExpectingRejection(String, List)} 와 같은 계약을 {@code client} 가 만든 admin 으로 잰다(다른 토큰 엔드포인트). */
  private String callExpectingRejection(String label, List<String> wrong, Supplier<AdminClient> client) {
    Throwable thrown;
    try (AdminClient admin = client.get()) {
      admin.users().get("x");
      thrown = null;
    } catch (Throwable t) {
      thrown = t;
    }
    List<String> hits = adminHits();
    String row = String.format("%-24s → %s · grants %s · admin %s", label,
        thrown == null ? "성공" : thrown.getClass().getSimpleName() + "(" + thrown.getMessage() + ")", grants(), hits);
    if (!(thrown instanceof KeycloakTransportException) || !"admin transport failure".equals(thrown.getMessage())) {
      wrong.add(label + ": KeycloakTransportException(admin transport failure) 가 아니다 — "
          + (thrown == null ? "성공" : thrown.getClass().getName()));
    }
    if (!hits.isEmpty()) wrong.add(label + ": 쓸 수 없는 토큰으로 admin 요청이 나갔다 — " + hits);
    if (grants().size() != 1) wrong.add(label + ": 토큰 요청이 정확히 한 번이 아니다 — " + grants());
    if (thrown == null) return row;
    // §4 — 원인 사슬에 하위 라이브러리 인스턴스가 없고(파서 사슬은 타입 이름만 남긴 사본이다), 응답을 인용하지 않는다.
    for (Throwable c = thrown.getCause(); c != null; c = c.getCause()) {
      if (!c.getClass().getName().startsWith("java.")) wrong.add(label + ": 원인 사슬에 하위 타입이 샜다 — " + c.getClass());
    }
    StringWriter trace = new StringWriter();
    thrown.printStackTrace(new PrintWriter(trace, true));
    if (trace.toString().contains(RT_CANARY.substring(0, 10))) wrong.add(label + ": 오류가 응답의 refresh_token 을 찍었다");
    return row;
  }

  private static byte[] gzip(String s) throws IOException {
    return gzip(s.getBytes(StandardCharsets.UTF_8));
  }

  private static byte[] gzip(byte[] plain) throws IOException {
    ByteArrayOutputStream out = new ByteArrayOutputStream();
    try (GZIPOutputStream z = new GZIPOutputStream(out)) {
      z.write(plain);
    }
    return out.toByteArray();
  }

  /** JSON 뒤를 JSON 공백으로 채워 정확히 {@code size} 바이트로 — 결합에게는 같은 값이다. */
  private static byte[] padTo(String json, int size) {
    byte[] body = new byte[size];
    Arrays.fill(body, (byte) ' ');
    byte[] head = json.getBytes(StandardCharsets.UTF_8);
    System.arraycopy(head, 0, body, 0, head.length);
    return body;
  }

  /** admin 호출 하나가 {@code Bearer good} 으로 나아가 성공하는지 — 어긋남은 {@code wrong} 에, 행은 {@code table} 에. */
  private void expectGood(String label, List<String> wrong, List<String> table) {
    try (AdminClient admin = admin()) {
      admin.users().get("x");
    } catch (RuntimeException e) {
      wrong.add(label + ": 성공해야 한다 — " + e);
    }
    table.add(label + " → admin " + adminHits());
    if (!adminHits().equals(List.of("GET /admin/realms/r/users/x · Bearer good"))) wrong.add(label + ": " + adminHits());
    if (!grants().equals(List.of("client_credentials"))) wrong.add(label + ": 토큰 요청 " + grants());
  }

  /**
   * 크기 상한 — 토큰 응답 본문이 상한(1,048,576 바이트 — {@link io.github.xzawed.keycloak.core.ResponseLimits}, auth 레인과 함께
   * 쓰는 값)을 넘으면 그 안의 토큰이 쓸 수 있어도 쓸 수 없는 토큰과 똑같이 거부한다 — KeycloakTransportException · admin 요청
   * 0 건 · 토큰 요청 1 건. 상한은 리터럴로 고정한다(SDK 상수를 빌리면 그 값이 바뀌어도 시험이 따라 움직인다). 상한 안의 쓸 수 있는
   * 토큰은 평문·gzip 모두 그대로 동작한다. 판정은 결합이 읽는 바이트로 하므로 gzip 은 <b>푼</b> 크기로 잰다. 본문은 쓸 수 있는
   * 토큰 뒤를 JSON 공백으로 채운 것이다 — 가드 없이 결합만 있으면 스트리밍으로 통과하는 모양이고, 본문을 통째로 버퍼링하던
   * 가드는 힙보다 크면 OutOfMemoryError 를 냈다.
   */
  @Test void tokenResponseAboveTheCap_isRejectedLikeAnUnusableToken() throws IOException {
    int cap = 1_048_576;
    List<String> table = new ArrayList<>();
    List<String> wrong = new ArrayList<>();
    String body = tokenBody("\"good\"", ",\"refresh_token\":\"" + RT_CANARY + "\"");
    reset(new Reply(200, padTo(body, cap), null));
    expectGood("평문 = 상한", wrong, table);
    reset(new Reply(200, padTo(body, cap + 1), null));
    table.add(callExpectingRejection("평문 = 상한+1", wrong));
    for (int status : new int[] {200, 201}) {
      reset(new Reply(status, padTo(body, cap + 1), null, false));
      table.add(callExpectingRejection("Content-Type 없음 " + status + " = 상한+1", wrong));
    }
    System.setProperty("resteasy.allowGzip", "true");
    try {
      reset(new Reply(200, gzip(padTo(body, cap)), "gzip"));
      expectGood("gzip 푼 크기 = 상한", wrong, table);
      reset(new Reply(200, gzip(padTo(body, cap + 1)), "gzip"));
      table.add(callExpectingRejection("gzip 푼 크기 = 상한+1", wrong));
    } finally {
      System.clearProperty("resteasy.allowGzip");
    }
    System.out.println("[AdminTokenResponseTest 크기 상한 " + cap + "]\n  " + String.join("\n  ", table));
    assertTrue(wrong.isEmpty(), () -> wrong.size() + " 건:\n" + String.join("\n", wrong));
  }

  /**
   * Keycloak 26.6(start-dev 기본 설정)이 받아들이는 가장 긴 Bearer — 실측(curl GET /admin/realms): 65,459 바이트면 401(헤더는
   * 받고 토큰이 무효), 65,460 바이트면 431.
   */
  private static final int KEYCLOAK_MAX_BEARER = 65_459;

  /**
   * 서버가 받아들이는 토큰은 거부하지 않는다 — 가장 긴 Bearer 를 담은 토큰 응답(본문 약 65.6 KB)은 결합에 그대로 넘어가고 admin
   * 요청이 그 토큰을 싣는다. 큰 배포의 토큰이 이만큼 자란다: master 렐름 서비스 계정에 admin 역할을 주면 렐름 하나마다
   * {@code resource_access} 항목이 붙어 access_token 이 456 바이트씩 자란다(Keycloak 26.6.4 실측 — 렐름 0 개에 1,733 바이트,
   * 이름 두 글자 렐름). 본문을 통째로 읽던 가드는 통과시켰고, JWKS 응답 상한(51,200)을 빌린 상한은 렐름 109 개부터 그 토큰을 쓸
   * 수 없는 토큰처럼 거부했다(서버는 139 개까지 받아들인다) — admin 이 통째로 멈춘다.
   */
  @Test void largestBearerTheServerAccepts_isHandedOn_andCarriedByTheAdminRequest() {
    String token = "a".repeat(KEYCLOAK_MAX_BEARER);
    byte[] body = tokenBody("\"" + token + "\"", ",\"refresh_token\":\"" + RT_CANARY + "\"").getBytes(StandardCharsets.UTF_8);
    reset(new Reply(200, body, null));
    Throwable thrown = null;
    try (AdminClient admin = admin()) {
      admin.users().get("x");
    } catch (RuntimeException e) {
      thrown = e;
    }
    String row = "본문 " + body.length + " 바이트 · Bearer " + token.length() + " 바이트 → "
        + (thrown == null ? "성공" : thrown.getClass().getSimpleName() + "(" + thrown.getMessage() + ")")
        + " · grants " + grants() + " · admin " + bearerLengths(adminHits());
    System.out.println("[AdminTokenResponseTest 서버가 받아들이는 가장 긴 Bearer]\n  " + row);
    assertNull(thrown, row);
    assertEquals(List.of("client_credentials"), grants(), row);
    assertTrue(adminHits().equals(List.of("GET /admin/realms/r/users/x · Bearer " + token)), row);
  }

  /** admin 요청 기록의 Bearer 를 길이로만 적는다 — 긴 토큰을 표에 그대로 찍지 않는다. */
  private static List<String> bearerLengths(List<String> hits) {
    List<String> out = new ArrayList<>();
    for (String hit : hits) {
      int at = hit.indexOf("Bearer ");
      out.add(at < 0 ? hit : hit.substring(0, at) + "Bearer(len " + (hit.length() - at - "Bearer ".length()) + ")");
    }
    return out;
  }

  /**
   * 거부한 뒤 연결을 놓다가 실패해도 거부는 그대로다 — 상한을 넘는 응답(쓸 수 있는 토큰 + 공백)의 나머지 전송이 깨져도
   * ({@link ReleaseFault}) 결과는 쓸 수 없는 토큰과 같다: KeycloakTransportException · admin 요청 0 건 · 토큰 요청 1 건 ·
   * 걸러진 원인 사슬 · 응답 바이트 미노출. ⚠️ 미디어 타입이 없는 2xx 는 응답 필터에서 거부되고 RESTEasy
   * ({@code ClientInvocation.invoke})가 그 응답을 try/catch 없이 닫는다 — 닫기가 HttpCore 로 나머지를 비우다 난 오류가 거부를
   * 대신해 {@code jakarta.ws.rs.ProcessingException}·{@code org.apache.http.*} 사슬로 나갔고, 청크 크기 줄 오류는
   * 「Bad chunk header: &lt;그 줄&gt;」 로 응답 바이트(여기서는 refresh_token)를 찍었다. 본문을 통째로 읽던 그 전 가드는 그
   * 오류를 판정 안에서 만나 걸러진 사슬이었다(실측). 미디어 타입이 있으면 RESTEasy 가 닫기 실패를 삼킨다(대조 행).
   */
  @Test void tokenResponseAboveTheCap_staysRejectedWhenReleasingTheConnectionFails() throws IOException {
    List<String> table = new ArrayList<>();
    List<String> wrong = new ArrayList<>();
    try (RawEndpoint raw = new RawEndpoint()) {
      Supplier<AdminClient> client = () -> admin(raw.port(), Duration.ofSeconds(2));
      for (ReleaseFault fault : ReleaseFault.values()) {
        for (int status : new int[] {200, 201}) {
          raw.reply(fault, status, false);
          table.add(callExpectingRejection("Content-Type 없음 " + status + " · " + fault, wrong, client));
        }
      }
      raw.reply(ReleaseFault.BAD_CHUNK_HEADER, 200, true);
      table.add(callExpectingRejection("application/json 200 · " + ReleaseFault.BAD_CHUNK_HEADER, wrong, client));
    }
    System.out.println("[AdminTokenResponseTest 거부 뒤 연결 해제 실패]\n  " + String.join("\n  ", table));
    assertTrue(wrong.isEmpty(), () -> wrong.size() + " 건:\n" + String.join("\n", wrong));
  }

  /** 상한을 넘는 첫 부분 뒤에서 깨지는 전송 — 가드가 거부한 뒤 연결을 놓으며 나머지를 비울 때 그 비우기가 실패한다. */
  private enum ReleaseFault {
    /** 다음 청크 크기 줄이 16진이 아니다 — HttpCore 가 그 줄을 「Bad chunk header: …」 에 그대로 싣는다(여기서는 refresh_token). */
    BAD_CHUNK_HEADER,
    /** 청크 도중에 연결이 끊긴다(TruncatedChunkException). */
    TRUNCATED_CHUNK,
    /** Content-Length 보다 적게 보내고 끊는다(ConnectionClosedException). */
    SHORT_CONTENT_LENGTH,
    /** Content-Length 보다 적게 보내고 멈춘다 — 비우기가 읽기 타임아웃을 만난다(SocketTimeoutException). */
    STALL
  }

  /**
   * 바이트를 그대로 쓰는 토큰 엔드포인트 — com.sun HttpServer 는 전송 틀(청크·길이)을 스스로 짜서 깨진 틀을 낼 수 없다. 토큰
   * 요청과 admin 요청을 이 시험의 {@code grants}·{@code adminHits} 에 적고, admin 은 {@link #handle} 처럼 성공을 낸다.
   */
  private final class RawEndpoint implements AutoCloseable {
    /** 첫 부분(쓸 수 있는 토큰 + 공백) — 상한+1 보다 커서 가드는 그 앞 상한+1 바이트만 읽고 거부한다. */
    private static final int FIRST = 1_048_576 + 10_000;
    private final ServerSocket socket;
    private volatile ReleaseFault fault = ReleaseFault.BAD_CHUNK_HEADER;
    private volatile int status = 200;
    private volatile boolean typed;

    RawEndpoint() throws IOException {
      socket = new ServerSocket(0, 50, InetAddress.getLoopbackAddress());
      Thread t = new Thread(this::serve, "raw-token-endpoint");
      t.setDaemon(true);
      t.start();
    }

    void reply(ReleaseFault fault, int status, boolean typed) {
      this.fault = fault;
      this.status = status;
      this.typed = typed;
      reset();
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
        Thread t = new Thread(() -> answer(s), "raw-token-exchange");
        t.setDaemon(true);
        t.start();
      }
    }

    private void answer(Socket s) {
      try (s) {
        s.setSoTimeout(10_000);
        InputStream in = new BufferedInputStream(s.getInputStream());
        String[] requestLine = httpLine(in).split(" ");
        Map<String, String> headers = new LinkedHashMap<>();
        for (String h = httpLine(in); !h.isEmpty(); h = httpLine(in)) {
          int colon = h.indexOf(':');
          if (colon > 0) headers.put(h.substring(0, colon).trim().toLowerCase(Locale.ROOT), h.substring(colon + 1).trim());
        }
        String body = new String(in.readNBytes(Integer.parseInt(headers.getOrDefault("content-length", "0"))),
            StandardCharsets.UTF_8);
        String path = requestLine.length > 1 ? requestLine[1] : "";
        OutputStream out = new BufferedOutputStream(s.getOutputStream());
        if (path.equals(TOKEN_PATH)) {
          synchronized (AdminTokenResponseTest.this) {
            grants.add(form(body).getOrDefault("grant_type", "?"));
          }
          writeBrokenToken(out);
          if (fault == ReleaseFault.STALL) in.read(); // 클라이언트가 끊을 때까지(읽기 타임아웃 뒤) 연결을 붙든다
        } else if (path.startsWith("/admin/realms/" + REALM + "/users")) {
          synchronized (AdminTokenResponseTest.this) {
            adminHits.add(requestLine[0] + " " + path + " · " + headers.get("authorization"));
          }
          byte[] user = "{\"id\":\"x\",\"username\":\"alice\"}".getBytes(StandardCharsets.UTF_8);
          out.write(("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: " + user.length
              + "\r\nConnection: close\r\n\r\n").getBytes(StandardCharsets.ISO_8859_1));
          out.write(user);
          out.flush();
        } else {
          out.write("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
              .getBytes(StandardCharsets.ISO_8859_1));
          out.flush();
        }
      } catch (IOException clientWentAway) {
        // 클라이언트가 연결을 끊었다 — 깨진 전송의 정상 결말이다
      }
    }

    private void writeBrokenToken(OutputStream out) throws IOException {
      boolean chunked = fault == ReleaseFault.BAD_CHUNK_HEADER || fault == ReleaseFault.TRUNCATED_CHUNK;
      int declared = fault == ReleaseFault.BAD_CHUNK_HEADER ? FIRST : FIRST + 10_000;
      out.write(("HTTP/1.1 " + status + (status == 200 ? " OK" : " Created") + "\r\n"
          + (typed ? "Content-Type: application/json\r\n" : "")
          + (chunked ? "Transfer-Encoding: chunked\r\n" : "Content-Length: " + declared + "\r\n")
          + "Connection: close\r\n\r\n").getBytes(StandardCharsets.ISO_8859_1));
      if (chunked) out.write((Integer.toHexString(declared) + "\r\n").getBytes(StandardCharsets.ISO_8859_1));
      out.write(padTo(tokenBody("\"good\"", ",\"refresh_token\":\"" + RT_CANARY + "\""), FIRST));
      if (fault == ReleaseFault.BAD_CHUNK_HEADER) {
        // 다음 청크 크기 자리에 응답 내용 — 16진이 아니므로 HttpCore 가 이 줄을 오류 메시지에 그대로 싣는다
        out.write(("\r\n\"refresh_token\":\"" + RT_CANARY + "\"\r\n").getBytes(StandardCharsets.ISO_8859_1));
      }
      out.flush();
    }

    @Override public void close() throws IOException {
      socket.close();
    }
  }

  /** CRLF(또는 LF)로 끝나는 HTTP 한 줄 — 줄 끝은 빼고. */
  private static String httpLine(InputStream in) throws IOException {
    ByteArrayOutputStream line = new ByteArrayOutputStream();
    for (int c = in.read(); c >= 0 && c != '\n'; c = in.read()) {
      if (c != '\r') line.write(c);
    }
    return line.toString(StandardCharsets.ISO_8859_1);
  }

  /**
   * 내용 코딩(Content-Encoding)이 붙은 토큰 응답도 <b>결합이 읽는 바이트</b>로 판정한다. 소비자가 RESTEasy 의 gzip 해제를
   * 켜면({@code resteasy.allowGzip=true} → GZIPDecodingInterceptor) 결합은 응답 필터 뒤의 ReaderInterceptor 에서 푼 바이트를
   * 읽는다 — 원시 바이트를 보던 가드는 gzip 으로 온 쓸 수 있는 토큰을 거부해 admin 이 통째로 멈췄다(수정 전 실측: 가드 없이는
   * {@code Bearer good} 으로 성공, 가드가 있으면 KeycloakTransportException · admin []). 해제기가 없는 코딩은 결합이 원시
   * 바이트를 그대로 읽으므로 그 바이트로 판정한다 — 헤더 하나로 검사를 건너뛰지 못한다.
   */
  @Test void contentCodedTokenResponse_isJudgedOnTheBytesTheBindingReads() throws IOException {
    List<String> table = new ArrayList<>();
    List<String> wrong = new ArrayList<>();
    String canary = ",\"refresh_token\":\"" + RT_CANARY + "\"";
    System.setProperty("resteasy.allowGzip", "true");
    try {
      reset(new Reply(200, gzip(tokenBody("\"good\"", canary)), "gzip"));
      try (AdminClient admin = admin()) {
        admin.users().get("x");
      } catch (RuntimeException e) {
        wrong.add("gzip 쓸 수 있는 토큰: 성공해야 한다 — " + e);
      }
      table.add("gzip \"good\" → admin " + adminHits());
      if (!adminHits().equals(List.of("GET /admin/realms/r/users/x · Bearer good"))) wrong.add("gzip \"good\": " + adminHits());
      if (!grants().equals(List.of("client_credentials"))) wrong.add("gzip \"good\": 토큰 요청 " + grants());

      reset(new Reply(200, gzip(tokenBody("12345", canary)), "gzip"));
      table.add(callExpectingRejection("gzip 12345", wrong));

      // 갱신(refresh_token 그랜트) 응답도 같은 자리에서 판정한다 — 푼 바이트가 쓸 수 있으면 새 토큰으로 나아간다.
      String first = tokenBody("\"AT-1\"", ",\"refresh_token\":\"RT-1\",\"refresh_expires_in\":300")
          .replace("\"expires_in\":300", "\"expires_in\":1");
      reset(new Reply(200, first), new Reply(200, gzip(tokenBody("\"AT-2\"", "")), "gzip"));
      try (AdminClient admin = admin()) {
        admin.users().get("x");
        admin.users().get("x");
      } catch (RuntimeException e) {
        wrong.add("gzip 갱신: 성공해야 한다 — " + e);
      }
      table.add("gzip 갱신 \"AT-2\" → grants " + grants() + " · admin " + adminHits());
      if (!adminHits().equals(List.of("GET /admin/realms/r/users/x · Bearer AT-1", "GET /admin/realms/r/users/x · Bearer AT-2"))) {
        wrong.add("gzip 갱신: " + adminHits());
      }
    } finally {
      System.clearProperty("resteasy.allowGzip");
    }
    // 해제기가 없는 코딩(br) — 결합은 원시 바이트(여기서는 평문 JSON)를 읽는다.
    reset(new Reply(200, tokenBody("12345", canary).getBytes(StandardCharsets.UTF_8), "br"));
    table.add(callExpectingRejection("br(평문) 12345", wrong));
    reset(new Reply(200, tokenBody("\"good\"", "").getBytes(StandardCharsets.UTF_8), "br"));
    try (AdminClient admin = admin()) {
      admin.users().get("x");
    } catch (RuntimeException e) {
      wrong.add("br(평문) 쓸 수 있는 토큰: 성공해야 한다 — " + e);
    }
    table.add("br(평문) \"good\" → admin " + adminHits());
    if (!adminHits().equals(List.of("GET /admin/realms/r/users/x · Bearer good"))) wrong.add("br(평문) \"good\": " + adminHits());
    // Content-Type 이 없는 2xx — 결합이 아예 읽지 않는다(RESTEasy extractResult 는 200 이면 스스로 ResponseProcessingException
    // 을 던지고, 그 밖의 2xx 면 null 을 돌려줘 TokenManager 가 NPE 로 멈춘다). 판정은 응답 필터가 원시 바이트로 한다 — 그
    // 자리가 빠지면 201 행의 원인 사슬에 ProcessingException 이 그대로 달린다(§4, 200 행은 RESTEasy 가 대신 막아 가려진다).
    for (int status : new int[] {200, 201}) {
      reset(new Reply(status, tokenBody("12345", canary).getBytes(StandardCharsets.UTF_8), null, false));
      table.add(callExpectingRejection("Content-Type 없음 " + status + " 12345", wrong));
    }
    System.out.println("[AdminTokenResponseTest 내용 코딩]\n  " + String.join("\n  ", table));
    assertTrue(wrong.isEmpty(), () -> wrong.size() + " 건:\n" + String.join("\n", wrong));
  }

  /** 대조 — 같은 경로에서 문자열 토큰은 GET·POST 둘 다 admin 에 닿는다(위 실패가 다른 원인이 아님을 보인다). */
  @Test void stringAccessToken_reachesAdmin_forReadsAndWrites() {
    reset(new Reply(200, tokenBody("\"AT-1\"", "")));
    try (AdminClient admin = admin()) {
      assertEquals("alice", admin.users().get("x").orElseThrow().getUsername());
      UserRepresentation u = new UserRepresentation();
      u.setUsername("bob");
      assertEquals("new-id", admin.users().create(u));
    }
    assertEquals(List.of("client_credentials"), grants(), "토큰은 캐시되어 한 번만 부여돼야 한다");
    assertEquals(List.of("GET /admin/realms/r/users/x · Bearer AT-1", "POST /admin/realms/r/users · Bearer AT-1"),
        adminHits());
  }

  /**
   * HTTP 필드 값이 싣지 못하는 문자(RFC 9110 §5.5 — CR·LF·NUL·HTAB 밖의 C0·DEL)를 담은 access_token 은 쓸 수 없는 토큰이다: admin
   * 요청을 하나도 보내지 않고, 캐시하지도 않는다(두 번째 호출이 다시 부여한다). 오류는 토큰을 인용하지 않는다. 수정 전 HttpCore 는 그
   * Bearer 를 조용히 고쳐 보냈다 — CR·LF·VT·FF 는 공백으로, NUL·그 밖의 C0·DEL 은 {@code ?} 로(실측 2026-10-09: 모든 행에서 admin 요청이
   * 나갔고 토큰은 캐시됐다). 대조: HTAB·SP·U+00E9·U+0100·U+0085·{@code ~} 는 지금처럼 보낸다 — 그 밖의 판정은 아홉 언어가 함께 정할
   * 일이다(등록부 bearer-token-grammar-divergent). 서버가 해석한 값은 표로 찍는다 — 선 위 바이트가 아니다(com.sun HttpServer 는 HTAB 을
   * 공백으로 읽는다). 원시 소켓으로 잰 선 위 바이트(2026-10-09): HTAB 0x09 · SP 0x20 · U+00E9 0xE9 · U+0100·U+0085 {@code ?}.
   */
  @Test void anAccessTokenNoHttpHeaderCanCarry_isNeitherSentNorCached() {
    List<String> table = new ArrayList<>();
    List<String> wrong = new ArrayList<>();
    List<String> refused = new ArrayList<>();
    for (char c = 0; c < 0x20; c++) {
      if (c != '\t') refused.add("tok-" + c + "-end");
    }
    refused.add("tok-\u007f-end");
    for (char c : new char[] {0, '\r', '\n', 0x7f}) {
      refused.add(c + "tok-end");
      refused.add("tok-end" + c);
    }
    for (String token : refused) {
      reset(new Reply(200, tokenBody(jsonString(token), ",\"refresh_token\":\"" + RT_CANARY + "\"")));
      List<Throwable> thrown = new ArrayList<>();
      try (AdminClient admin = admin()) {
        for (int call = 0; call < 2; call++) thrown.add(outcome(() -> admin.users().get("x")));
      }
      String label = "access_token " + printable(token);
      table.add(label + " → " + thrown.stream().map(t -> t == null ? "성공" : t.getClass().getSimpleName()).toList()
          + " · grants " + grants() + " · admin " + printable(adminHits().toString()));
      for (Throwable t : thrown) {
        if (!(t instanceof KeycloakTransportException) || !"admin transport failure".equals(t.getMessage())) {
          wrong.add(label + ": KeycloakTransportException(admin transport failure) 가 아니다 — " + t);
        } else if (trace(t).contains("tok-") || trace(t).contains(RT_CANARY.substring(0, 10))) {
          wrong.add(label + ": 오류가 응답을 인용했다");
        }
      }
      if (!adminHits().isEmpty()) wrong.add(label + ": admin 요청이 나갔다 — " + printable(adminHits().toString()));
      if (!grants().equals(List.of("client_credentials", "client_credentials"))) {
        wrong.add(label + ": 토큰을 캐시했다(두 번째 호출이 다시 부여하지 않았다) — grants " + grants());
      }
    }
    for (String token : List.of("tok-\t-end", "tok- -end", "tok-é-end", "tok-Ā-end", "tok-\u0085-end", "tok-~-end")) {
      reset(new Reply(200, tokenBody(jsonString(token), "")));
      List<Throwable> thrown = new ArrayList<>();
      try (AdminClient admin = admin()) {
        for (int call = 0; call < 2; call++) thrown.add(outcome(() -> admin.users().get("x")));
      }
      String label = "대조 access_token " + printable(token);
      table.add(label + " → " + thrown.stream().map(t -> t == null ? "성공" : t.getClass().getSimpleName()).toList()
          + " · grants " + grants() + " · 서버가 받은 값 " + printable(adminHits().toString()));
      if (thrown.stream().anyMatch(java.util.Objects::nonNull)) wrong.add(label + ": 보내야 한다 — " + thrown);
      if (adminHits().size() != 2) wrong.add(label + ": admin 요청 두 건이어야 한다 — " + printable(adminHits().toString()));
      if (!grants().equals(List.of("client_credentials"))) wrong.add(label + ": 토큰은 캐시돼야 한다 — grants " + grants());
    }
    System.out.println("[AdminTokenResponseTest 헤더가 싣지 못하는 access_token]\n  " + String.join("\n  ", table));
    assertTrue(wrong.isEmpty(), () -> wrong.size() + " 건:\n" + String.join("\n", wrong));
  }

  private static Throwable outcome(Runnable call) {
    try {
      call.run();
      return null;
    } catch (RuntimeException e) {
      return e;
    }
  }

  private static String trace(Throwable t) {
    StringWriter out = new StringWriter();
    t.printStackTrace(new PrintWriter(out, true));
    return out.toString();
  }

  /** JSON 문자열 리터럴 — 제어 문자·DEL·따옴표·역슬래시는 이스케이프한다(그 밖은 그대로 — 본문은 UTF-8). */
  private static String jsonString(String s) {
    StringBuilder out = new StringBuilder("\"");
    for (char c : s.toCharArray()) {
      if (c < 0x20 || c == 0x7f || c == '"' || c == '\\') out.append(String.format("\\u%04x", (int) c));
      else out.append(c);
    }
    return out.append('"').toString();
  }

  /** 표에 찍을 수 있게 — 제어 문자·DEL·C1·Latin-1 밖은 {@code \}uXXXX 로. */
  private static String printable(String s) {
    StringBuilder out = new StringBuilder();
    for (char c : s.toCharArray()) {
      if (c < 0x20 || (c >= 0x7f && c < 0xa0) || c > 0xff) out.append(String.format("\\u%04X", (int) c));
      else out.append(c);
    }
    return out.toString();
  }

  /** TokenManager 의 갱신(refresh_token 그랜트) 응답도 같은 검사를 받는다 — 쓸 수 있으면 새 토큰으로 나아간다. */
  @Test void refreshedStringAccessToken_isUsed() {
    String first = tokenBody("\"AT-1\"", ",\"refresh_token\":\"RT-1\",\"refresh_expires_in\":300")
        .replace("\"expires_in\":300", "\"expires_in\":1");
    reset(new Reply(200, first), new Reply(200, tokenBody("\"AT-2\"", "")));
    try (AdminClient admin = admin()) {
      admin.users().get("x");
      admin.users().get("x"); // expires_in 1 < TokenManager 최소 유효기간(30s) — 갱신한다
    }
    assertEquals(List.of("client_credentials", "refresh_token"), grants());
    assertEquals(List.of("GET /admin/realms/r/users/x · Bearer AT-1", "GET /admin/realms/r/users/x · Bearer AT-2"),
        adminHits());
  }

  @Test void refreshedUnusableAccessToken_sendsNoAdminRequest() {
    String first = tokenBody("\"AT-1\"", ",\"refresh_token\":\"RT-1\",\"refresh_expires_in\":300")
        .replace("\"expires_in\":300", "\"expires_in\":1");
    reset(new Reply(200, first), new Reply(200, tokenBody("12345", "")));
    try (AdminClient admin = admin()) {
      admin.users().get("x");
      KeycloakTransportException e = assertThrows(KeycloakTransportException.class, () -> admin.users().get("x"));
      assertEquals("admin transport failure", e.getMessage());
    }
    assertEquals(List.of("client_credentials", "refresh_token"), grants());
    assertEquals(List.of("GET /admin/realms/r/users/x · Bearer AT-1"), adminHits(), "갱신된 숫자 토큰으로 나아갔다");
  }

  /**
   * 오류 상태의 토큰 응답은 검사하지 않고 TokenManager 에 그대로 넘긴다 — 갱신이 400 이면 TokenManager 가
   * {@code BadRequestException} 을 받아 client_credentials 로 다시 부여한다(admin-client 의 복구 경로). 검사가 오류 본문
   * (access_token 없음)까지 거부하면 그 예외가 바뀌어 복구가 끊긴다.
   */
  @Test void tokenErrorStatus_isLeftToTokenManager() {
    String first = tokenBody("\"AT-1\"", ",\"refresh_token\":\"RT-1\",\"refresh_expires_in\":300")
        .replace("\"expires_in\":300", "\"expires_in\":1");
    reset(new Reply(200, first), new Reply(400, "{\"error\":\"invalid_grant\"}"), new Reply(200, tokenBody("\"AT-3\"", "")));
    try (AdminClient admin = admin()) {
      admin.users().get("x");
      admin.users().get("x");
    }
    assertEquals(List.of("client_credentials", "refresh_token", "client_credentials"), grants());
    assertEquals(List.of("GET /admin/realms/r/users/x · Bearer AT-1", "GET /admin/realms/r/users/x · Bearer AT-3"),
        adminHits());
  }

  /**
   * 오류 상태의 토큰 응답 본문도 상한(1,048,576 바이트)까지만 읽는다. 상한 안의 갱신 400 은 지금처럼 TokenManager 에 넘어가
   * client_credentials 로 다시 부여되고({@link #tokenErrorStatus_isLeftToTokenManager} 의 복구 경로), 한 바이트 더 길면 그 응답은
   * 거부되어 admin 요청 없이 {@link KeycloakTransportException} 으로 실패한다. 수정 전에는 RESTEasy 가 오류 본문을 통째로 버퍼에
   * 담았다 — 32 MiB 오류 본문 하나에 약 107 MB 할당(실측 — 공개 API 행렬은 {@code TokenResponseCapTest}). 상한은 리터럴로 고정한다.
   */
  @Test void tokenErrorStatus_isReadUpToTheCapOnly() {
    int cap = 1_048_576;
    String first = tokenBody("\"AT-1\"", ",\"refresh_token\":\"RT-1\",\"refresh_expires_in\":300")
        .replace("\"expires_in\":300", "\"expires_in\":1");
    String error = "{\"error\":\"invalid_grant\",\"error_description\":\"" + RT_CANARY + "\"}";
    reset(new Reply(200, first), new Reply(400, padTo(error, cap), null), new Reply(200, tokenBody("\"AT-3\"", "")));
    try (AdminClient admin = admin()) {
      admin.users().get("x");
      admin.users().get("x");
    }
    assertEquals(List.of("client_credentials", "refresh_token", "client_credentials"), grants(), "상한 안: 복구 경로");
    assertEquals(List.of("GET /admin/realms/r/users/x · Bearer AT-1", "GET /admin/realms/r/users/x · Bearer AT-3"),
        adminHits());

    reset(new Reply(200, first), new Reply(400, padTo(error, cap + 1), null), new Reply(200, tokenBody("\"AT-3\"", "")));
    try (AdminClient admin = admin()) {
      admin.users().get("x");
      KeycloakTransportException e = assertThrows(KeycloakTransportException.class, () -> admin.users().get("x"),
          "상한+1: 오류 본문을 거부해야 한다(복구로 가면 그 본문을 통째로 읽은 것이다)");
      assertEquals("admin transport failure", e.getMessage());
      StringWriter trace = new StringWriter();
      e.printStackTrace(new PrintWriter(trace, true));
      assertFalse(trace.toString().contains(RT_CANARY.substring(0, 10)), "거부가 응답을 인용했다");
    }
    assertEquals(List.of("client_credentials", "refresh_token"), grants(), "상한+1: 다시 부여하지 않는다");
    assertEquals(List.of("GET /admin/realms/r/users/x · Bearer AT-1"), adminHits(), "상한+1: admin 요청이 더 나가면 안 된다");
  }
}
