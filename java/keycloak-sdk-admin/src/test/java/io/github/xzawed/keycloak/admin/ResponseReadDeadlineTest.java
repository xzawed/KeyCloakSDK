package io.github.xzawed.keycloak.admin;

import static org.junit.jupiter.api.Assertions.*;

import io.github.xzawed.keycloak.core.KeycloakConfig;
import io.github.xzawed.keycloak.core.ResponseLimits;
import io.github.xzawed.keycloak.core.exception.KeycloakTransportException;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.io.PrintWriter;
import java.io.StringWriter;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.SocketTimeoutException;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.concurrent.Callable;
import java.util.function.Function;
import org.apache.http.client.methods.HttpGet;
import org.apache.http.protocol.HttpCoreContext;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.Timeout;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.EnumSource;

/**
 * admin 레인이 스스로 읽는 응답(자체 토큰 부여 · 자원)은 요청을 보낸 때부터 읽기 타임아웃 안에 다 읽는다(등록부
 * {@code response-read-deadline-divergent}, 판정 2026-10-29). 공개 API 와 로컬 루프백만 쓴다.
 *
 * <p>왜: 읽기 타임아웃은 읽기 하나를 묶을 뿐이라, 바이트를 그보다 조금 짧은 간격으로 흘리는 서버 앞에서 응답 하나가 흘린 바이트마다 간격
 * 하나씩 걸렸다. 수정 전 실측은 이 시험을 수정 전 코드에 돌려 잰 것이다(커밋 메시지) — 흘리기 두 칸이 7 초 넘게 걸려 받아들여졌다. 자원의
 * 성공 본문에는 크기 상한이 없으므로(사용자 목록은 정당하게 크다) 그 본문도 이제 읽기 타임아웃 안에 다 와야 한다.
 *
 * <p>계약: 흘리기 — 읽기 타임아웃 {@value #READ_TIMEOUT_MILLIS} ms · 마지막 10 바이트를 {@value #GAP_MILLIS} ms 마다 — 는
 * {@value #BOUND_MILLIS} ms 안에 {@link KeycloakTransportException} 이다 — 같은 레인의 읽기 타임아웃(멈춤)과 같은 메시지·같은 원인 사슬(끝에
 * {@link SocketTimeoutException} — 응답을 인용할 수 있는 사슬이라 타입 이름만 남는다) · 응답 바이트를 인용하지 않는다. 경계 = 마감 1 초 + 읽기
 * 하나 1 초 + 여유 1 초(auth 의 같은 이름 시험과 같은 셈). 대조: 멈춤(머리와 몇 바이트
 * 뒤 침묵)은 지금처럼 읽기 타임아웃에 실패하고, 상한 바로 아래 본문을 네 조각으로 나눠 보내는 건강한 응답은 받아들여진다.
 *
 * <p>⚠️ 마감은 엔진의 엔티티 스트림({@code AdminEngine.Settled})에서 본다 — 응답 머리와, 읽기 하나 안의 틀(청크 크기 줄 · 트레일러)·TLS
 * 레코드는 그 밖이다(RESTEasy 가 지은 풀의 소켓이다). 그 자리는 지금처럼 읽기마다의 타임아웃이 묶는다 — 실측(2026-10-29, 저장소 밖 탐침,
 * 같은 조건): 머리 블록·청크 크기 줄·트레일러를 흘리면 7 초 넘게 걸린다(커밋 메시지).
 */
class ResponseReadDeadlineTest {
  private static final int READ_TIMEOUT_MILLIS = 1_000;
  private static final long GAP_MILLIS = 700;
  private static final int TRICKLED = 10;
  private static final long BOUND_MILLIS = 3_000;
  private static final long HEALTHY_GAP_MILLIS = 150;
  private static final long HOLD_MILLIS = 10_000;
  private static final int CAP = ResponseLimits.MAX_TOKEN_RESPONSE_BYTES;
  /** 실패의 어느 표현에도 찍히면 안 되는 응답 바이트. */
  private static final String MARKER = "ZdeadlineMARKER0123456789";
  private static final String TOKEN_PATH = "/realms/r/protocol/openid-connect/token";
  private static final String USER_PATH = "/admin/realms/r/users/x";
  private static final byte[] TOKEN_BODY = utf8("{\"access_token\":\"good\",\"token_type\":\"Bearer\",\"expires_in\":300}");
  private static final byte[] USER_BODY = utf8("{\"id\":\"x\",\"username\":\"" + MARKER + "\"}");

  private static byte[] utf8(String s) {
    return s.getBytes(StandardCharsets.UTF_8);
  }

  private static byte[] latin1(String s) {
    return s.getBytes(StandardCharsets.ISO_8859_1);
  }

  private static byte[] concat(byte[]... parts) {
    ByteArrayOutputStream out = new ByteArrayOutputStream();
    for (byte[] part : parts) out.writeBytes(part);
    return out.toByteArray();
  }

  private static byte[] padded(byte[] body, int total) {
    byte[] out = Arrays.copyOf(body, total);
    Arrays.fill(out, body.length, total, (byte) ' ');
    return out;
  }

  // ───────────── 응답 ─────────────

  /** 응답의 한 조각 — 쓰기 전에 {@code delayMillis} 를 쉰다. */
  private record Piece(long delayMillis, byte[] bytes) {}

  private static byte[] head(int contentLength) {
    return latin1("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: " + contentLength + "\r\n\r\n");
  }

  private static List<Piece> whole(byte[] body) {
    return List.of(new Piece(0, concat(head(body.length), body)));
  }

  /** 머리와 본문을 한 번에 쓰되 본문의 마지막 {@link #TRICKLED} 바이트는 {@link #GAP_MILLIS} 마다 하나씩. */
  private static List<Piece> trickledBody(byte[] body) {
    List<Piece> pieces = new ArrayList<>();
    pieces.add(new Piece(0, concat(head(body.length), Arrays.copyOf(body, body.length - TRICKLED))));
    for (int i = body.length - TRICKLED; i < body.length; i++) pieces.add(new Piece(GAP_MILLIS, new byte[] {body[i]}));
    return pieces;
  }

  /** 머리와 본문의 처음 5 바이트 뒤 침묵(알린 길이는 본문 전체). */
  private static List<Piece> stalledBody(byte[] body) {
    return List.of(new Piece(0, concat(head(body.length), Arrays.copyOf(body, 5))), new Piece(HOLD_MILLIS, new byte[0]));
  }

  /** 상한 바로 아래 본문을 네 조각으로 — 조각 사이 {@link #HEALTHY_GAP_MILLIS}. */
  private static List<Piece> healthyBody(byte[] body) {
    byte[] all = concat(head(body.length), body);
    List<Piece> pieces = new ArrayList<>();
    int quarter = all.length / 4;
    for (int i = 0; i < 4; i++) {
      int from = i * quarter;
      int to = i == 3 ? all.length : from + quarter;
      pieces.add(new Piece(i == 0 ? 0 : HEALTHY_GAP_MILLIS, Arrays.copyOfRange(all, from, to)));
    }
    return pieces;
  }

  // ───────────── 서버 ─────────────

  /**
   * 원시 HTTP/1.1 서버 — 연결 하나에 요청 여럿(keep-alive: 토큰 부여 뒤 admin 요청이 같은 연결로 온다). 요청마다 {@code reply}(경로 →
   * 조각)가 고른 조각을 차례로 쓴다(조각마다 쉬고 쓴다).
   */
  private static final class PacedServer implements AutoCloseable {
    final ServerSocket socket;
    final Function<String, List<Piece>> reply;

    PacedServer(Function<String, List<Piece>> reply) throws IOException {
      this.reply = reply;
      socket = new ServerSocket(0, 50, InetAddress.getLoopbackAddress());
      Thread t = new Thread(this::serve, "admin-paced-server");
      t.setDaemon(true);
      t.start();
    }

    String url() {
      return "http://127.0.0.1:" + socket.getLocalPort();
    }

    private void serve() {
      while (!socket.isClosed()) {
        Socket s;
        try {
          s = socket.accept();
        } catch (IOException closed) {
          return;
        }
        Thread t = new Thread(() -> exchanges(s), "admin-paced-connection");
        t.setDaemon(true);
        t.start();
      }
    }

    private void exchanges(Socket s) {
      try (s) {
        s.setSoTimeout((int) HOLD_MILLIS);
        InputStream in = s.getInputStream();
        OutputStream out = s.getOutputStream();
        for (String path = readRequest(in); path != null; path = readRequest(in)) {
          for (Piece piece : reply.apply(path)) {
            if (piece.delayMillis() > 0) Thread.sleep(piece.delayMillis());
            out.write(piece.bytes());
            out.flush();
          }
        }
      } catch (IOException clientLeft) {
        // 클라이언트가 끊었다 — 마감 뒤의 정상 결말이다
      } catch (InterruptedException interrupted) {
        Thread.currentThread().interrupt();
      }
    }

    /** 요청 하나(머리와 Content-Length 본문)를 읽고 경로를 돌려준다 — 연결이 끝났으면 null. */
    private static String readRequest(InputStream in) throws IOException {
      ByteArrayOutputStream head = new ByteArrayOutputStream();
      int last4 = 0;
      for (int b = in.read(); b != -1; b = in.read()) {
        head.write(b);
        last4 = (last4 << 8) | b;
        if (last4 == 0x0d0a0d0a) {
          String[] lines = head.toString(StandardCharsets.ISO_8859_1).split("\r\n");
          for (String line : lines) {
            if (line.regionMatches(true, 0, "Content-Length:", 0, 15)) in.readNBytes(Integer.parseInt(line.substring(15).trim()));
          }
          return lines[0].split(" ")[1];
        }
      }
      return null;
    }

    @Override public void close() throws IOException {
      socket.close();
    }
  }

  // ───────────── 레인 ─────────────

  /** 레인 — 응답의 모양을 바꾸는 경로와 그 본문. 호출은 둘 다 {@code users().get("x")} 다(첫 호출이 토큰을 부여받는다). */
  enum Lane {
    /** admin 자체 토큰 부여 — 내장 TokenManager 의 응답을 토큰 응답 가드가 상한까지 읽는다. */
    TOKEN(TOKEN_PATH, TOKEN_BODY),
    /** 자원의 성공 본문 — 결합(Jackson)이 엔진의 스트림으로 읽는다. 크기 상한이 없는 자리다. */
    RESOURCE(USER_PATH, USER_BODY);

    final String path;
    final byte[] body;

    Lane(String path, byte[] body) {
      this.path = path;
      this.body = body;
    }
  }

  private static KeycloakConfig config(String url) {
    return KeycloakConfig.builder().serverUrl(url).realm("r").clientId("app").clientSecret("s3cr3t".toCharArray())
        .connectTimeout(Duration.ofSeconds(5)).readTimeout(Duration.ofMillis(READ_TIMEOUT_MILLIS)).build();
  }

  /** 호출 하나 — 돌려준 값, 던진 것(없으면 null), 걸린 시간. */
  private record Outcome(Object result, Throwable thrown, long millis) {
    String describe() {
      return (thrown == null ? "accepted " + result : thrown.getClass().getName() + ": " + thrown.getMessage()) + " · " + millis + " ms";
    }
  }

  private static Outcome time(Callable<Object> call) {
    long start = System.nanoTime();
    Object result = null;
    Throwable thrown = null;
    try {
      result = call.call();
    } catch (Throwable t) {
      thrown = t;
    }
    return new Outcome(result, thrown, (System.nanoTime() - start) / 1_000_000);
  }

  /** {@code lane} 의 응답만 {@code shape} 로 내는 서버에 admin 호출 하나 — 다른 경로는 곧바로 온전히 답한다. */
  private static Outcome run(Lane lane, Function<byte[], List<Piece>> shape, byte[] body) throws Exception {
    try (PacedServer server = new PacedServer(path -> {
      if (path.equals(lane.path)) return shape.apply(body);
      if (path.equals(TOKEN_PATH)) return whole(TOKEN_BODY);
      if (path.equals(USER_PATH)) return whole(USER_BODY);
      return List.of(new Piece(0, latin1("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n")));
    }); AdminClient admin = new AdminClient(config(server.url()))) {
      return time(() -> admin.users().get("x").orElseThrow().getId());
    }
  }

  private static String trace(Throwable t) {
    StringWriter out = new StringWriter();
    t.printStackTrace(new PrintWriter(out, true));
    return out.toString();
  }

  /**
   * 원인 사슬의 타입 이름 — 보류된 사본(「&lt;타입&gt; (message withheld …)」 — 응답을 인용할 수 있는 사슬은 SDK 예외가 타입 이름과 프레임만
   * 남긴다, {@code WithheldCauses})은 원래 타입의 이름으로.
   */
  private static List<String> chain(Throwable thrown) {
    List<String> names = new ArrayList<>();
    for (Throwable t = thrown; t != null; t = t.getCause()) {
      String message = t.getMessage();
      int withheld = message == null ? -1 : message.indexOf(" (message withheld");
      names.add(withheld > 0 ? message.substring(0, withheld) : t.getClass().getName());
    }
    return names;
  }

  /**
   * (1) 응답을 흘리는 서버 — 마감에 실패한다, 같은 레인의 읽기 타임아웃(멈춤)과 같은 실패로: 같은 타입 · 같은 메시지 · 같은 원인 사슬(끝에
   * {@link SocketTimeoutException}). 수정 전: 두 레인 모두 7 초 넘게 걸려 받아들였다.
   */
  @ParameterizedTest
  @EnumSource(Lane.class)
  @Timeout(value = 60, threadMode = Timeout.ThreadMode.SEPARATE_THREAD)
  void aTrickledResponse_failsAtTheDeadline(Lane lane) throws Exception {
    Outcome stall = run(lane, ResponseReadDeadlineTest::stalledBody, lane.body);
    Outcome o = run(lane, ResponseReadDeadlineTest::trickledBody, lane.body);
    String label = "admin " + lane + " 흘리기";
    System.out.println("[admin.ResponseReadDeadlineTest] " + label + " → " + o.describe());
    assertNotNull(o.thrown(), () -> label + ": 마감 뒤에도 오는 응답을 받아들였다 — " + o.describe());
    assertInstanceOf(KeycloakTransportException.class, o.thrown(), () -> label + ": 전송 실패여야 한다 — " + trace(o.thrown()));
    assertTrue(o.millis() < BOUND_MILLIS, () -> label + ": " + BOUND_MILLIS + " ms 안에 실패해야 한다 — " + o.describe());
    assertNotNull(stall.thrown(), () -> label + ": 대조(멈춤)가 실패하지 않았다 — " + stall.describe());
    assertEquals(stall.thrown().getMessage(), o.thrown().getMessage(), label + ": 읽기 타임아웃과 같은 메시지여야 한다");
    assertEquals(chain(stall.thrown()), chain(o.thrown()), () -> label + ": 읽기 타임아웃과 같은 원인 사슬이어야 한다 — " + trace(o.thrown()));
    assertTrue(chain(o.thrown()).contains(SocketTimeoutException.class.getName()), () -> label + ": " + chain(o.thrown()));
    assertFalse(trace(o.thrown()).contains(MARKER), () -> label + ": 실패가 응답 바이트를 인용했다 — " + trace(o.thrown()));
  }

  /** 대조 — 머리와 몇 바이트 뒤 침묵: 지금처럼 읽기 타임아웃 무렵에 전송 실패다. */
  @ParameterizedTest
  @EnumSource(Lane.class)
  @Timeout(value = 60, threadMode = Timeout.ThreadMode.SEPARATE_THREAD)
  void control_aStalledResponse_stillFailsAtTheReadTimeout(Lane lane) throws Exception {
    Outcome o = run(lane, ResponseReadDeadlineTest::stalledBody, lane.body);
    String label = "admin " + lane + " 멈춤";
    System.out.println("[admin.ResponseReadDeadlineTest] " + label + " → " + o.describe());
    assertInstanceOf(KeycloakTransportException.class, o.thrown(), () -> label + ": 전송 실패여야 한다 — " + o.describe());
    assertTrue(o.millis() >= READ_TIMEOUT_MILLIS - 100 && o.millis() < BOUND_MILLIS,
        () -> label + ": 읽기 타임아웃 무렵에 실패해야 한다 — " + o.describe());
  }

  /** 읽기마다 {@code millis} 를 쉬고 {@code result} 를 내주는 스트림(-1 이면 끝) — 읽힌 수를 센다. */
  private static final class SlowStream extends InputStream {
    final long millis;
    final int result;
    int reads;

    SlowStream(long millis, int result) {
      this.millis = millis;
      this.result = result;
    }

    @Override public int read() throws IOException {
      reads++;
      try {
        Thread.sleep(millis);
      } catch (InterruptedException e) {
        Thread.currentThread().interrupt();
        throw new IOException(e);
      }
      return result;
    }

    @Override public int read(byte[] b, int off, int len) throws IOException {
      int c = read();
      if (c < 0) return -1;
      b[off] = (byte) c;
      return 1;
    }
  }

  private static int read(InputStream in, boolean array) throws IOException {
    return array ? in.read(new byte[4], 0, 4) : in.read();
  }

  /**
   * 엔진의 스트림({@code AdminEngine.Settled}) — 마감은 요청을 보낸 때부터다(HttpCore 가 요청 머리를 쓰기 직전에 {@code http.request_sent} 를
   * 거짓으로 두는 때 — 연결을 빌리고 맺는 시간은 들지 않는다 · 보낸 뒤의 참 표시는 마감을 옮기지 않는다) · 마감 뒤에 시작하는 읽기는 읽지 않고
   * 실패한다 · 마감을 넘겨 끝난 읽기는 그 결과를 내주지 않는다(늦게 온 끝 -1 도 — 청크의 끝 표시가 늦은 응답). 두 읽기 모두.
   */
  @Test
  void theEngineStream_checksTheDeadlineFromWhenTheRequestWasSent() throws Exception {
    for (boolean array : new boolean[] {false, true}) {
      AdminEngine.Exchange exchange = new AdminEngine.Exchange(new HttpGet("http://127.0.0.1:1/"), 100);
      Thread.sleep(150); // 손잡이를 만든 때부터 세면 마감이 지났다
      exchange.setAttribute(HttpCoreContext.HTTP_REQ_SENT, Boolean.FALSE); // 이제 보낸다
      assertEquals(array ? 1 : 'x', read(new AdminEngine.Settled(new SlowStream(0, 'x'), exchange, Long.MAX_VALUE), array),
          "마감은 요청을 보낸 때부터다");
      exchange.setAttribute(HttpCoreContext.HTTP_REQ_SENT, Boolean.TRUE);
      Thread.sleep(150);
      SlowStream before = new SlowStream(0, 'x');
      SocketTimeoutException e = assertThrows(SocketTimeoutException.class,
          () -> read(new AdminEngine.Settled(before, exchange, Long.MAX_VALUE), array), "보낸 뒤의 표시가 마감을 옮겼다");
      assertEquals(0, before.reads, "마감 뒤에는 읽기를 시작하지 않는다");
      assertEquals(AdminEngine.LATE + "100 ms of sending the request", e.getMessage());

      AdminEngine.Exchange late = new AdminEngine.Exchange(new HttpGet("http://127.0.0.1:1/"), 100);
      late.setAttribute(HttpCoreContext.HTTP_REQ_SENT, Boolean.FALSE);
      SlowStream end = new SlowStream(200, -1);
      assertThrows(SocketTimeoutException.class, () -> read(new AdminEngine.Settled(end, late, Long.MAX_VALUE), array),
          "마감을 넘겨 온 끝을 받아들였다");
      assertEquals(1, end.reads);
    }
  }

  /** 대조 — 상한 바로 아래 본문이 네 조각으로 마감 안에 온다: 받아들인다(거짓 마감이 없다). */
  @ParameterizedTest
  @EnumSource(Lane.class)
  @Timeout(value = 60, threadMode = Timeout.ThreadMode.SEPARATE_THREAD)
  void control_aHealthyResponseJustUnderTheCap_isAccepted(Lane lane) throws Exception {
    Outcome o = run(lane, ResponseReadDeadlineTest::healthyBody, padded(lane.body, CAP - 1));
    String label = "admin " + lane + " 건강";
    System.out.println("[admin.ResponseReadDeadlineTest] " + label + " → " + o.describe());
    assertNull(o.thrown(), () -> label + ": 받아들여야 한다 — " + (o.thrown() == null ? "" : trace(o.thrown())));
    assertEquals("x", o.result(), label);
  }
}
