package io.github.xzawed.keycloak.admin;

import static org.junit.jupiter.api.Assertions.*;

import io.github.xzawed.keycloak.core.KeycloakConfig;
import io.github.xzawed.keycloak.core.ResponseLimits;
import io.github.xzawed.keycloak.core.exception.KeycloakTransportException;
import jakarta.ws.rs.client.Client;
import jakarta.ws.rs.core.Response;
import java.io.ByteArrayOutputStream;
import java.io.FileInputStream;
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
import java.nio.file.Path;
import java.security.KeyStore;
import java.time.Duration;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.concurrent.Callable;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.FutureTask;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;
import java.util.function.Function;
import javax.net.ssl.KeyManagerFactory;
import javax.net.ssl.SSLContext;
import javax.net.ssl.SSLSocket;
import javax.net.ssl.TrustManagerFactory;
import org.apache.http.client.methods.HttpGet;
import org.apache.http.protocol.HttpCoreContext;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.Timeout;
import org.junit.jupiter.api.io.TempDir;
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
 * <p>(2) 응답의 틀(머리 블록 · 청크 크기 줄 · 트레일러)과 TLS 레코드를 흘려도 같은 마감에 실패한다 — 엔진의 엔티티 스트림({@code
 * AdminEngine.Settled})은 읽기 하나의 앞뒤만 보므로, 마감은 그 교환의 소켓 읽기마다(TLS 면 JSSE 아래의 평문 소켓) 본다({@code AdminSockets}).
 * 수정 전 측정은 이 시험을 수정 전 코드에 돌려 잰 것이다(커밋 메시지).
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

  @TempDir static Path dir;
  /** 시험 키 저장소의 암호 — 실행마다 새로 만든다(저장소에 키도, 그 암호도 두지 않는다). */
  private static final String STOREPASS = java.util.UUID.randomUUID().toString();
  private static SSLContext serverTls;
  private static SSLContext clientTls;

  @BeforeAll static void keys() throws Exception {
    Path file = dir.resolve("ip.p12");
    Process p = new ProcessBuilder(Path.of(System.getProperty("java.home"), "bin", "keytool").toString(),
        "-genkeypair", "-alias", "ip", "-keyalg", "EC", "-groupname", "secp256r1", "-validity", "2", "-dname", "CN=127.0.0.1",
        "-ext", "SAN=ip:127.0.0.1", "-keystore", file.toString(), "-storetype", "PKCS12", "-storepass", STOREPASS,
        "-keypass", STOREPASS).redirectErrorStream(true).start();
    String out = new String(p.getInputStream().readAllBytes(), StandardCharsets.UTF_8);
    assertTrue(p.waitFor(60, TimeUnit.SECONDS) && p.exitValue() == 0, () -> "keytool 실패: " + out);
    KeyStore ks = KeyStore.getInstance("PKCS12");
    try (InputStream in = new FileInputStream(file.toFile())) {
      ks.load(in, STOREPASS.toCharArray());
    }
    KeyManagerFactory kmf = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm());
    kmf.init(ks, STOREPASS.toCharArray());
    serverTls = SSLContext.getInstance("TLSv1.3");
    serverTls.init(kmf.getKeyManagers(), null, null);
    KeyStore trust = KeyStore.getInstance("PKCS12");
    trust.load(null, null);
    trust.setCertificateEntry("ip", ks.getCertificate("ip"));
    TrustManagerFactory tmf = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm());
    tmf.init(trust);
    clientTls = SSLContext.getInstance("TLSv1.3");
    clientTls.init(null, tmf.getTrustManagers(), null);
  }

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

  /**
   * 응답의 한 조각 — 쓰기 전에 {@code delayMillis} 를 쉰다. record 가 아닌 까닭: 배열 성분의 record 는 equals·hashCode·toString 이
   * 배열 내용이 아니라 identity 를 본다(Sonar java:S6218) — 이 조각은 비교하지 않으므로 값 의미를 약속하지 않는 클래스로 둔다.
   */
  private static final class Piece {
    private final long delayMillis;
    private final byte[] bytes;

    Piece(long delayMillis, byte[] bytes) {
      this.delayMillis = delayMillis;
      this.bytes = bytes;
    }

    long delayMillis() {
      return delayMillis;
    }

    byte[] bytes() {
      return bytes;
    }
  }

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

  private static final byte[] CHUNKED_HEAD =
      latin1("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n");

  /** {@code at} 의 바이트를 {@code gap} 마다 하나씩 — 앞의 조각에 이어. */
  private static void trickle(List<Piece> pieces, byte[] at, long gap) {
    for (byte b : at) pieces.add(new Piece(gap, new byte[] {b}));
  }

  /** 응답의 틀 중 흘리는 자리 — 흘리는 바이트는 모두 {@link #TRICKLED} 개다(auth 의 같은 이름 시험과 같은 모양). */
  enum Framing {
    /** 머리 블록 — 헤더 하나의 값 열 바이트. */
    HEAD {
      @Override List<Piece> pieces(byte[] body) {
        List<Piece> pieces = new ArrayList<>();
        pieces.add(new Piece(0, latin1("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nX-Pace: ")));
        trickle(pieces, latin1("0123456789"), GAP_MILLIS);
        pieces.add(new Piece(0, concat(latin1("\r\nContent-Length: " + body.length + "\r\n\r\n"), body)));
        return pieces;
      }
    },
    /** 마지막 청크의 크기 줄(확장 포함) 열 바이트. */
    CHUNK_SIZE_LINE {
      @Override List<Piece> pieces(byte[] body) {
        List<Piece> pieces = new ArrayList<>();
        pieces.add(new Piece(0, concat(CHUNKED_HEAD, latin1(Integer.toHexString(body.length - 1) + "\r\n"),
            Arrays.copyOf(body, body.length - 1), latin1("\r\n"))));
        trickle(pieces, latin1("1;a=bcde\r\n"), GAP_MILLIS);
        pieces.add(new Piece(0, concat(new byte[] {body[body.length - 1]}, latin1("\r\n0\r\n\r\n"))));
        return pieces;
      }
    },
    /** 마지막 청크 뒤 트레일러 한 줄 열 바이트. */
    TRAILER {
      @Override List<Piece> pieces(byte[] body) {
        List<Piece> pieces = new ArrayList<>();
        pieces.add(new Piece(0, concat(CHUNKED_HEAD, latin1(Integer.toHexString(body.length) + "\r\n"), body,
            latin1("\r\n0\r\n"))));
        trickle(pieces, latin1("X-T: 012\r\n"), GAP_MILLIS);
        pieces.add(new Piece(0, latin1("\r\n")));
        return pieces;
      }
    };

    abstract List<Piece> pieces(byte[] body);

    /** 대조 — 같은 자리(흘리기 직전)에서 멈춘다: 그 자리의 읽기 타임아웃이 내는 실패와 견준다(머리의 실패는 본문의 것과 사슬이 다르다). */
    List<Piece> stalled(byte[] body) {
      return List.of(pieces(body).get(0), new Piece(HOLD_MILLIS, new byte[0]));
    }
  }

  /** TLS 레코드 둘 — 본문의 마지막 {@link #TRICKLED} 바이트는 300 ms 뒤 따로 쓴다(그 레코드를 중계가 흘린다). */
  private static List<Piece> twoRecords(byte[] body) {
    return List.of(new Piece(0, concat(head(body.length), Arrays.copyOf(body, body.length - TRICKLED))),
        new Piece(300, Arrays.copyOfRange(body, body.length - TRICKLED, body.length)));
  }

  // ───────────── 서버 ─────────────

  /**
   * 원시 HTTP/1.1 서버 — 연결 하나에 요청 여럿(keep-alive: 토큰 부여 뒤 admin 요청이 같은 연결로 온다). 요청마다 {@code reply}(경로 →
   * 조각)가 고른 조각을 차례로 쓴다(조각마다 쉬고 쓴다).
   */
  private static final class PacedServer implements AutoCloseable {
    final ServerSocket socket;
    final Function<String, List<Piece>> reply;
    /** {@link #beforeLastPath} 의 응답의 마지막 조각을 쓰기 직전에 부른다(TLS 중계가 거기서부터 흘린다). */
    final AtomicReference<Runnable> beforeLast = new AtomicReference<>();
    volatile String beforeLastPath;

    PacedServer(SSLContext tls, Function<String, List<Piece>> reply) throws IOException {
      this.reply = reply;
      socket = tls == null ? new ServerSocket(0, 50, InetAddress.getLoopbackAddress())
          : tls.getServerSocketFactory().createServerSocket(0, 50, InetAddress.getLoopbackAddress());
      Thread t = new Thread(this::serve, "admin-paced-server");
      t.setDaemon(true);
      t.start();
    }

    PacedServer(Function<String, List<Piece>> reply) throws IOException {
      this(null, reply);
    }

    int port() {
      return socket.getLocalPort();
    }

    String url() {
      return "http://127.0.0.1:" + port();
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
        if (s instanceof SSLSocket tls) tls.startHandshake();
        InputStream in = s.getInputStream();
        OutputStream out = s.getOutputStream();
        for (String path = readRequest(in); path != null; path = readRequest(in)) {
          List<Piece> pieces = reply.apply(path);
          for (int i = 0; i < pieces.size(); i++) {
            Piece piece = pieces.get(i);
            if (piece.delayMillis() > 0) Thread.sleep(piece.delayMillis());
            Runnable last = beforeLast.get();
            if (i == pieces.size() - 1 && last != null && path.equals(beforeLastPath)) last.run();
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

  /**
   * TLS 앞의 TCP 중계 — 서버의 바이트를 곧바로 넘기다가 {@link #trickle} 뒤로는 한 바이트씩 {@link #GAP_MILLIS} 마다 넘긴다. 서버는 마지막
   * 조각(TLS 레코드 하나)을 쓰기 직전에 그것을 부른다 — 그 앞의 레코드는 300 ms 전에 이미 넘어갔다(auth 의 같은 이름 중계와 같다).
   */
  private static final class TrickleRelay implements AutoCloseable {
    final ServerSocket socket;
    final int target;
    volatile boolean trickling;

    TrickleRelay(int target) throws IOException {
      this.target = target;
      socket = new ServerSocket(0, 50, InetAddress.getLoopbackAddress());
      Thread t = new Thread(this::serve, "admin-trickle-relay");
      t.setDaemon(true);
      t.start();
    }

    void trickle() {
      trickling = true;
    }

    private void serve() {
      while (!socket.isClosed()) {
        try {
          Socket client = socket.accept();
          Socket server = new Socket(InetAddress.getLoopbackAddress(), target);
          pump(client, server, false);
          pump(server, client, true);
        } catch (IOException closed) {
          return;
        }
      }
    }

    private void pump(Socket from, Socket to, boolean paced) {
      Thread t = new Thread(() -> {
        try (from; to) {
          InputStream in = from.getInputStream();
          OutputStream out = to.getOutputStream();
          byte[] buffer = new byte[16 * 1024];
          boolean first = true;
          for (int n = in.read(buffer); n > 0; n = in.read(buffer)) {
            if (!paced || !trickling) {
              out.write(buffer, 0, n);
              out.flush();
              continue;
            }
            for (int i = 0; i < n; i++) {
              // 첫 바이트는 곧바로 — 그 앞의 침묵(서버의 300 ms)에 간격을 더하면 읽기 타임아웃이 먼저 터진다
              if (!first) Thread.sleep(GAP_MILLIS);
              first = false;
              out.write(buffer[i]);
              out.flush();
            }
          }
        } catch (IOException gone) {
          // 한쪽이 닫았다 — 중계도 끝난다
        } catch (InterruptedException interrupted) {
          Thread.currentThread().interrupt();
        }
      }, "admin-trickle-relay-pump");
      t.setDaemon(true);
      t.start();
    }

    int port() {
      return socket.getLocalPort();
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

  /**
   * {@code lane} 의 응답만 TLS 레코드 둘({@link #twoRecords})로 내는 TLS 서버를 중계 너머에 두고 admin 호출 하나 — 중계는 그 응답의 마지막
   * 레코드를 흘린다. 엔진은 시험 인증서를 믿는 기본 SSLContext 로 짓는다(RESTEasy 와 이 레인의 풀은 지을 때 그것을 읽는다) — 지은 뒤 되돌린다.
   */
  private static Outcome runTls(Lane lane) throws Exception {
    try (PacedServer server = new PacedServer(serverTls, path -> {
      if (path.equals(lane.path)) return twoRecords(lane.body);
      if (path.equals(TOKEN_PATH)) return whole(TOKEN_BODY);
      if (path.equals(USER_PATH)) return whole(USER_BODY);
      return List.of(new Piece(0, latin1("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n")));
    }); TrickleRelay relay = new TrickleRelay(server.port())) {
      server.beforeLastPath = lane.path;
      server.beforeLast.set(relay::trickle);
      AdminClient built;
      SSLContext saved = SSLContext.getDefault();
      SSLContext.setDefault(clientTls);
      try {
        built = new AdminClient(config("https://127.0.0.1:" + relay.port()));
      } finally {
        SSLContext.setDefault(saved);
      }
      try (AdminClient admin = built) {
        return time(() -> admin.users().get("x").orElseThrow().getId());
      }
    }
  }

  /**
   * 마감의 판정 — 같은 레인의 읽기 타임아웃(멈춤)과 같은 실패여야 한다: 같은 타입 · 같은 메시지 · 같은 원인 사슬(끝에
   * {@link SocketTimeoutException}) · {@link #BOUND_MILLIS} 안 · 응답 바이트를 인용하지 않는다.
   */
  private static void expectDeadline(String label, Lane lane, Outcome o) throws Exception {
    expectDeadline(label, lane, o, ResponseReadDeadlineTest::stalledBody);
  }

  /** {@code stalled} — 대조로 쓸 멈춤(실패가 나는 자리가 같아야 사슬이 같다). */
  private static void expectDeadline(String label, Lane lane, Outcome o, Function<byte[], List<Piece>> stalled)
      throws Exception {
    Outcome stall = run(lane, stalled, lane.body);
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
    expectDeadline("admin " + lane + " 흘리기", lane, run(lane, ResponseReadDeadlineTest::trickledBody, lane.body));
  }

  /**
   * (2) 응답의 틀을 흘리는 서버 — 본문 앞(머리)이나 본문 읽기 하나 <b>안</b>(청크 크기 줄 · 트레일러)이어도 마감에 실패한다. 두 레인 모두. 수정
   * 전 측정은 커밋 메시지.
   */
  @ParameterizedTest
  @EnumSource(Framing.class)
  @Timeout(value = 120, threadMode = Timeout.ThreadMode.SEPARATE_THREAD)
  void trickledFraming_failsAtTheDeadline(Framing framing) throws Exception {
    for (Lane lane : Lane.values()) {
      expectDeadline("admin " + lane + " 틀 " + framing, lane, run(lane, framing::pieces, lane.body), framing::stalled);
    }
  }

  /**
   * (2) TLS 레코드 하나를 흘리는 서버 — JSSE 는 레코드가 다 올 때까지 읽기 하나 안에서 기다린다(그 아래 평문 소켓의 읽기는 바이트마다 끝난다).
   * 마감을 TLS 스트림의 읽기마다만 보면 이 칸이 그대로다 — 마감은 JSSE 아래의 평문 소켓에서 본다. 수정 전 측정은 커밋 메시지.
   */
  @ParameterizedTest
  @EnumSource(Lane.class)
  @Timeout(value = 120, threadMode = Timeout.ThreadMode.SEPARATE_THREAD)
  void aTrickledTlsRecord_failsAtTheDeadline(Lane lane) throws Exception {
    expectDeadline("admin " + lane + " TLS 레코드", lane, runTls(lane));
  }

  /**
   * 교환의 끝은 그 스레드의 소켓 마감을 지운다 — 남으면 그 스레드가 나중에 하는 소켓 읽기(다음 교환이 연결을 빌리며 엿보는 읽기)가 지난 교환의
   * 마감에 걸린다. 건강한 admin 호출 하나(토큰 부여 + 자원) 뒤, 그 마감을 넘겨 시작한 읽기가 그대로다.
   */
  @Test
  @Timeout(value = 60, threadMode = Timeout.ThreadMode.SEPARATE_THREAD)
  void anExchange_leavesNoDeadlineOnItsThread() throws Exception {
    Outcome o = run(Lane.RESOURCE, ResponseReadDeadlineTest::whole, USER_BODY);
    assertNull(o.thrown(), () -> "건강한 호출이 실패했다 — " + o.describe());
    Thread.sleep(READ_TIMEOUT_MILLIS + 200L);
    assertEquals('x', AdminSockets.deadlined(new SlowStream(0, 'x')).read(), "교환이 끝난 스레드에 마감이 남았다");
  }

  /**
   * 닫지 않은 응답도 보낸 스레드에 마감을 남기지 않는다 — 남으면 그 스레드의 다음 admin 호출이 새 연결의 TLS 핸드셰이크에서 곧바로 실패했다
   * (독립 검토의 실측: 열어 둠 46 ms · 다른 스레드에서 닫음 8 ms). 이 레인의 JAX-RS 클라이언트로 응답을 받고 읽지도 닫지도 않은 채 마감을 넘긴다.
   */
  @Test
  @Timeout(value = 60, threadMode = Timeout.ThreadMode.SEPARATE_THREAD)
  void aResponseLeftOpen_leavesNoDeadlineOnTheSendingThread() throws Exception {
    try (PacedServer server = new PacedServer(path -> whole(USER_BODY));
         Client client = AdminClient.buildTimeoutClient(config(server.url()));
         Response open = client.target(server.url() + USER_PATH).request().get()) {
      // 본문을 읽지 않은 채 열어 둔 동안 마감을 넘긴다 — 닫는 것은 이 블록의 끝이다
      Thread.sleep(READ_TIMEOUT_MILLIS + 200L);
      try (SlowStream after = new SlowStream(0, 'x')) {
        assertEquals('x', AdminSockets.deadlined(after).read(), "닫지 않은 응답이 보낸 스레드에 마감을 남겼다");
      }
      assertEquals(200, open.getStatus());
    }
  }

  /**
   * 본문을 다른 스레드에서 읽어도 같은 마감이다 — 엔진의 스트림이 읽는 스레드에 읽기마다 그 교환의 마감을 건다. 머리는 곧바로 오고 청크 크기 줄을
   * 흘린다(읽기 하나 안 — 엔티티 스트림의 앞뒤로는 못 본다). 보낸 때부터 {@link #BOUND_MILLIS} 안에 실패해야 한다.
   */
  @Test
  @Timeout(value = 60, threadMode = Timeout.ThreadMode.SEPARATE_THREAD)
  void aBodyReadOnAnotherThread_stillMeetsTheDeadline() throws Exception {
    try (PacedServer server = new PacedServer(path -> Framing.CHUNK_SIZE_LINE.pieces(USER_BODY));
         Client client = AdminClient.buildTimeoutClient(config(server.url()))) {
      long start = System.nanoTime();
      Response response = client.target(server.url() + USER_PATH).request().get();
      FutureTask<String> body = new FutureTask<>(() -> response.readEntity(String.class));
      Thread other = new Thread(body, "admin-deadline-other-reader");
      other.setDaemon(true);
      other.start();
      ExecutionException e = assertThrows(ExecutionException.class, body::get, "다른 스레드의 읽기가 흘린 틀을 받아들였다");
      long millis = (System.nanoTime() - start) / 1_000_000;
      assertTrue(chain(e.getCause()).contains(SocketTimeoutException.class.getName()), () -> trace(e.getCause()));
      assertTrue(millis < BOUND_MILLIS, () -> "다른 스레드의 읽기가 " + BOUND_MILLIS + " ms 안에 실패해야 한다 — " + millis + " ms");
    }
  }

  /**
   * 소켓의 마감 스트림({@code AdminSockets.deadlined}) — 마감이 없는 스레드의 읽기는 그대로다 · 마감 안의 읽기는 그대로다 · 마감 뒤에 시작하는
   * 읽기는 읽지 않고 실패한다 · 마감 뒤에 끝난 읽기는 그 결과를 내주지 않는다 · 0 은 마감을 두지 않는다. 두 읽기 모두.
   */
  @Test
  void theDeadlinedSocketStream_checksBeforeAndAfterEveryRead() throws Exception {
    try {
      for (boolean array : new boolean[] {false, true}) {
        AdminSockets.disarm();
        assertEquals(array ? 1 : 'x', read(AdminSockets.deadlined(new SlowStream(0, 'x')), array), "마감이 없는 스레드의 읽기는 그대로다");

        AdminSockets.arm(System.nanoTime(), 10_000);
        assertEquals(array ? 1 : 'x', read(AdminSockets.deadlined(new SlowStream(0, 'x')), array), "마감 안의 읽기는 그대로다");

        AdminSockets.arm(System.nanoTime(), 50);
        Thread.sleep(80);
        try (SlowStream before = new SlowStream(0, 'x')) {
          SocketTimeoutException e = assertThrows(SocketTimeoutException.class,
              () -> read(AdminSockets.deadlined(before), array));
          assertEquals(0, before.reads, "마감 뒤에는 읽기를 시작하지 않는다");
          assertEquals(AdminEngine.LATE + "50 ms of sending the request", e.getMessage());
        }

        AdminSockets.arm(System.nanoTime(), 50);
        try (SlowStream after = new SlowStream(120, 'x')) {
          assertThrows(SocketTimeoutException.class, () -> read(AdminSockets.deadlined(after), array));
          assertEquals(1, after.reads, "마감을 넘겨 끝난 읽기 — 읽었지만 그 결과를 내주지 않는다");
        }

        AdminSockets.arm(System.nanoTime(), 0);
        Thread.sleep(20);
        assertEquals(array ? 1 : 'x', read(AdminSockets.deadlined(new SlowStream(0, 'x')), array),
            "읽기 타임아웃 0(끝없이)에는 마감도 없다");
      }
    } finally {
      AdminSockets.disarm();
    }
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
    try {
      engineStreamChecks();
    } finally {
      AdminSockets.disarm(); // 보낸 표시가 이 스레드의 소켓 마감도 건다 — 다음 시험에 남기지 않는다
    }
  }

  private static void engineStreamChecks() throws Exception {
    for (boolean array : new boolean[] {false, true}) {
      AdminEngine.Exchange exchange = new AdminEngine.Exchange(new HttpGet("http://127.0.0.1:1/"), 100);
      Thread.sleep(150); // 손잡이를 만든 때부터 세면 마감이 지났다
      exchange.setAttribute(HttpCoreContext.HTTP_REQ_SENT, Boolean.FALSE); // 이제 보낸다
      assertEquals(array ? 1 : 'x', read(new AdminEngine.Settled(new SlowStream(0, 'x'), exchange, Long.MAX_VALUE), array),
          "마감은 요청을 보낸 때부터다");
      exchange.setAttribute(HttpCoreContext.HTTP_REQ_SENT, Boolean.TRUE);
      Thread.sleep(150);
      try (SlowStream before = new SlowStream(0, 'x')) {
        SocketTimeoutException e = assertThrows(SocketTimeoutException.class,
            () -> read(new AdminEngine.Settled(before, exchange, Long.MAX_VALUE), array), "보낸 뒤의 표시가 마감을 옮겼다");
        assertEquals(0, before.reads, "마감 뒤에는 읽기를 시작하지 않는다");
        assertEquals(AdminEngine.LATE + "100 ms of sending the request", e.getMessage());
      }

      AdminEngine.Exchange late = new AdminEngine.Exchange(new HttpGet("http://127.0.0.1:1/"), 100);
      late.setAttribute(HttpCoreContext.HTTP_REQ_SENT, Boolean.FALSE);
      try (SlowStream end = new SlowStream(200, -1)) {
        assertThrows(SocketTimeoutException.class, () -> read(new AdminEngine.Settled(end, late, Long.MAX_VALUE), array),
            "마감을 넘겨 온 끝을 받아들였다");
        assertEquals(1, end.reads);
      }
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
