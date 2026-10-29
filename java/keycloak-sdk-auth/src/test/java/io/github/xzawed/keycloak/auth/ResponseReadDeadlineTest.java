package io.github.xzawed.keycloak.auth;

import static org.junit.jupiter.api.Assertions.*;

import com.nimbusds.jose.JWSAlgorithm;
import com.nimbusds.jose.JWSHeader;
import com.nimbusds.jose.crypto.RSASSASigner;
import com.nimbusds.jose.jwk.JWKSet;
import com.nimbusds.jose.jwk.RSAKey;
import com.nimbusds.jose.jwk.gen.RSAKeyGenerator;
import com.nimbusds.jwt.JWTClaimsSet;
import com.nimbusds.jwt.SignedJWT;
import com.nimbusds.oauth2.sdk.http.HTTPRequest;
import io.github.xzawed.keycloak.core.KeycloakConfig;
import io.github.xzawed.keycloak.core.TokenSet;
import io.github.xzawed.keycloak.core.exception.KeycloakTransportException;
import io.github.xzawed.keycloak.core.exception.TokenValidationException;
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
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.security.KeyStore;
import java.time.Duration;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Date;
import java.util.List;
import java.util.concurrent.Callable;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;
import java.util.function.Function;
import javax.net.ssl.KeyManagerFactory;
import javax.net.ssl.SSLContext;
import javax.net.ssl.SSLSocket;
import javax.net.ssl.TrustManagerFactory;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.Timeout;
import org.junit.jupiter.api.io.TempDir;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.EnumSource;

/**
 * SDK 가 스스로 읽는 응답은 요청을 보낸 때부터 읽기 타임아웃 안에 다 읽는다 — auth(토큰) 레인과 JWKS(콜드 적재) 레인
 * (등록부 {@code response-read-deadline-divergent}, 판정 2026-10-29). 공개 API 와 로컬 루프백만 쓴다(TLS 레코드 한 칸만 송신기를 직접 부른다).
 *
 * <p>왜: 읽기 타임아웃({@code SO_TIMEOUT})은 읽기 <b>하나</b>를 묶을 뿐이라, 바이트를 그보다 조금 짧은 간격으로 흘리는 서버 앞에서 응답 하나가
 * 흘린 바이트마다 간격 하나씩 걸렸다(최악 ≈ 상한 × 읽기 타임아웃 — 토큰 1,048,577 · JWKS 51,200). 수정 전 실측은 이 시험을 수정 전 코드에
 * 돌려 잰 것이다(커밋 메시지) — 흘리기 여섯 칸이 모두 7 초 넘게 걸려 <b>받아들여졌고</b>, TLS 레코드 하나를 흘리면 그 레코드의 바이트 수만큼
 * 걸렸다.
 *
 * <p>계약: (1) 흘리기 — 읽기 타임아웃 {@value #READ_TIMEOUT_MILLIS} ms · 마지막 10 바이트를 {@value #GAP_MILLIS} ms 마다 — 는
 * {@value #BOUND_MILLIS} ms 안에 그 레인의 읽기 타임아웃과 같은 실패다(원인 사슬에 {@link SocketTimeoutException} · 응답 바이트를 인용하지
 * 않는다). 경계 = 마감(읽기 타임아웃) + 읽기 하나(마감 직전에 시작한 읽기는 지금처럼 읽기 타임아웃까지 기다린다) + 여유 1 초(다른 빌드가 함께 도는
 * 기계의 깨움 지연 — 그래도 수정 전과 4 초 넘게 떨어진다). (2) 응답의 틀(머리 줄 · 청크 크기 줄 · 트레일러)과 TLS 레코드를 흘려도 같다 — 마감은
 * 하위 운송의 호출 하나 <b>안</b>이 아니라 그 교환의 소켓 읽기마다(TLS 면 JSSE 아래의 평문 소켓) 본다. 대조: 멈춤(머리와 몇 바이트 뒤 침묵)은
 * 지금처럼 읽기 타임아웃에 실패하고, 상한 바로 아래 본문을 네 조각으로 나눠 보내는 건강한 응답은 받아들여진다.
 */
class ResponseReadDeadlineTest {
  /** 교환의 읽기 타임아웃 — 등록부 실측과 같은 값. 마감도 이 길이다(요청을 보낸 때부터). */
  private static final int READ_TIMEOUT_MILLIS = 1_000;
  /** 흘리는 바이트 사이의 간격 — 읽기 타임아웃의 0.7 배라 읽기마다의 타임아웃은 터지지 않는다. */
  private static final long GAP_MILLIS = 700;
  /** 흘리는 바이트 수 — 수정 전에는 그 수만큼 간격이 걸렸다(10 × 700 ms). */
  private static final int TRICKLED = 10;
  /** 실패해야 하는 시한 — 마감 1 초 + 읽기 하나 1 초 + 여유 1 초(클래스 설명). */
  private static final long BOUND_MILLIS = 3_000;
  /** 건강한 대조의 조각 사이 간격 — 네 조각이 마감 안에(합 0.45 초) 온다. */
  private static final long HEALTHY_GAP_MILLIS = 150;
  /** 멈춤 대조에서 서버가 아무것도 쓰지 않고 붙드는 시간 — 읽기 타임아웃보다 넉넉히 길다. */
  private static final long HOLD_MILLIS = 10_000;
  private static final int TOKEN_CAP = 1_048_576;
  private static final int JWKS_CAP = 51_200;
  /** 실패의 어느 표현에도 찍히면 안 되는 응답 바이트. */
  private static final String MARKER = "ZdeadlineMARKER0123456789";
  private static final String REALM_PATH = "/realms/r/protocol/openid-connect";
  private static final byte[] TOKEN_BODY =
      utf8("{\"access_token\":\"" + MARKER + "\",\"token_type\":\"Bearer\",\"expires_in\":300}");

  @TempDir static Path dir;
  /** 시험 키 저장소의 암호 — 실행마다 새로 만든다(저장소에 키도, 그 암호도 두지 않는다). */
  private static final String STOREPASS = java.util.UUID.randomUUID().toString();
  private static SSLContext serverTls;
  private static SSLContext clientTls;
  private static RSAKey signing;
  private static byte[] jwks;

  @BeforeAll static void keys() throws Exception {
    signing = new RSAKeyGenerator(2048).keyID("k1").generate();
    jwks = utf8(new JWKSet(signing.toPublicJWK()).toString());
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

  /** {@code body} 뒤를 JSON 공백으로 채워 {@code total} 바이트로. */
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

  private static final byte[] CHUNKED_HEAD =
      latin1("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n");

  /** {@code at} 의 바이트를 {@code gap} 마다 하나씩 — 앞의 조각에 이어. */
  private static void trickle(List<Piece> pieces, byte[] at, long gap) {
    for (byte b : at) pieces.add(new Piece(gap, new byte[] {b}));
  }

  /** 머리와 본문을 한 번에 쓰되 본문의 마지막 {@link #TRICKLED} 바이트는 {@link #GAP_MILLIS} 마다 하나씩. */
  private static List<Piece> trickledBody(byte[] body) {
    List<Piece> pieces = new ArrayList<>();
    pieces.add(new Piece(0, concat(head(body.length), Arrays.copyOf(body, body.length - TRICKLED))));
    trickle(pieces, Arrays.copyOfRange(body, body.length - TRICKLED, body.length), GAP_MILLIS);
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

  /** 응답의 틀 중 흘리는 자리 — 흘리는 바이트는 모두 {@link #TRICKLED} 개다. */
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
  }

  // ───────────── 서버 ─────────────

  /**
   * 원시 HTTP/1.1 서버(평문 또는 TLS) — 연결마다 요청 하나(머리와 Content-Length 본문)를 읽고 {@code reply}(경로 → 조각)가 고른 조각을
   * 차례로 쓴다(조각마다 쉬고 쓴다). 다 쓴 뒤에는 쓰지 않고 붙든다 — 클라이언트가 닫을 때까지(최대 {@link #HOLD_MILLIS}).
   * {@link #beforeLast} 가 있으면 마지막 조각을 쓰기 직전에 부른다(TLS 중계가 거기서부터 흘린다).
   */
  private static final class PacedServer implements AutoCloseable {
    final ServerSocket socket;
    final Function<String, List<Piece>> reply;
    final AtomicReference<Runnable> beforeLast = new AtomicReference<>();

    PacedServer(SSLContext tls, Function<String, List<Piece>> reply) throws IOException {
      this.reply = reply;
      socket = tls == null ? new ServerSocket(0, 50, InetAddress.getLoopbackAddress())
          : tls.getServerSocketFactory().createServerSocket(0, 50, InetAddress.getLoopbackAddress());
      Thread t = new Thread(this::serve, "paced-server");
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
        Thread t = new Thread(() -> answer(s), "paced-connection");
        t.setDaemon(true);
        t.start();
      }
    }

    private void answer(Socket s) {
      try (s) {
        s.setSoTimeout((int) HOLD_MILLIS);
        if (s instanceof SSLSocket tls) tls.startHandshake();
        InputStream in = s.getInputStream();
        String path = readRequest(in);
        if (path == null) return;
        OutputStream out = s.getOutputStream();
        List<Piece> pieces = reply.apply(path);
        for (int i = 0; i < pieces.size(); i++) {
          Piece piece = pieces.get(i);
          if (piece.delayMillis() > 0) Thread.sleep(piece.delayMillis());
          Runnable last = beforeLast.get();
          if (i == pieces.size() - 1 && last != null) last.run();
          out.write(piece.bytes());
          out.flush();
        }
        while (in.read() >= 0) { /* 클라이언트가 닫을 때까지 붙든다 */ }
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
   * 조각(TLS 레코드 하나)을 쓰기 직전에 그것을 부른다 — 그 앞의 레코드는 300 ms 전에 이미 넘어갔다.
   */
  private static final class TrickleRelay implements AutoCloseable {
    final ServerSocket socket;
    final int target;
    volatile boolean trickling;

    TrickleRelay(int target) throws IOException {
      this.target = target;
      socket = new ServerSocket(0, 50, InetAddress.getLoopbackAddress());
      Thread t = new Thread(this::serve, "trickle-relay");
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
      }, "trickle-relay-pump");
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

  private static KeycloakConfig config(String url) {
    return KeycloakConfig.builder().serverUrl(url).realm("r").clientId("app").clientSecret("s3cr3t".toCharArray())
        .connectTimeout(Duration.ofSeconds(5)).readTimeout(Duration.ofMillis(READ_TIMEOUT_MILLIS)).build();
  }

  private static AuthClient auth(String url) {
    KeycloakConfig cfg = config(url);
    return new AuthClient(cfg, OidcMetadata.forRealm(cfg));
  }

  private static String signedToken(String url) throws Exception {
    SignedJWT jwt = new SignedJWT(new JWSHeader.Builder(JWSAlgorithm.RS256).keyID("k1").build(),
        new JWTClaimsSet.Builder().issuer(url + "/realms/r").audience("app").subject("u1")
            .expirationTime(new Date(System.currentTimeMillis() + 60_000)).build());
    jwt.sign(new RSASSASigner(signing));
    return jwt.serialize();
  }

  /** 레인 — 응답을 내는 경로, 그 본문, 공개 API 의 호출과 그 실패 타입. */
  enum Lane {
    /** client_credentials 토큰 — {@code AuthClient.clientCredentialsToken}. */
    TOKEN(REALM_PATH + "/token", KeycloakTransportException.class) {
      @Override byte[] body() {
        return TOKEN_BODY;
      }

      @Override byte[] healthyBody() {
        return padded(TOKEN_BODY, TOKEN_CAP - 1);
      }

      @Override Object call(String url) {
        TokenSet tokens = auth(url).clientCredentialsToken();
        assertEquals(MARKER, tokens.getAccessToken(), "받아들인 토큰이 응답의 것이 아니다");
        return "token";
      }
    },
    /** JWKS 콜드 적재 — {@code AuthClient.validate} 의 첫 호출(키 집합 상한 51,200 바이트). */
    JWKS(REALM_PATH + "/certs", TokenValidationException.class) {
      @Override byte[] body() {
        return jwks;
      }

      @Override byte[] healthyBody() {
        return padded(jwks, JWKS_CAP - 1); // 상한에 닿으면 넘침이다(Nimbus 의 셈) — 한 바이트 아래
      }

      @Override Object call(String url) throws Exception {
        return auth(url).validate(signedToken(url)).getSubject();
      }
    };

    final String path;
    final Class<? extends RuntimeException> failure;

    Lane(String path, Class<? extends RuntimeException> failure) {
      this.path = path;
      this.failure = failure;
    }

    abstract byte[] body();

    abstract byte[] healthyBody();

    abstract Object call(String url) throws Exception;
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

  private static Outcome run(Lane lane, Function<byte[], List<Piece>> shape, byte[] body) throws Exception {
    try (PacedServer server = new PacedServer(path -> path.equals(lane.path) ? shape.apply(body) : List.of(
        new Piece(0, latin1("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n"))))) {
      return time(() -> lane.call(server.url()));
    }
  }

  private static String trace(Throwable t) {
    StringWriter out = new StringWriter();
    t.printStackTrace(new PrintWriter(out, true));
    return out.toString();
  }

  /** 마감의 실패 — 그 레인의 실패 타입 · 원인 사슬에 읽기 타임아웃과 같은 타입 · 응답 바이트 인용 없음 · 시한 안. */
  private static void expectDeadline(String label, Class<? extends Throwable> failure, Outcome o) {
    System.out.println("[ResponseReadDeadlineTest] " + label + " → " + o.describe());
    assertNotNull(o.thrown(), () -> label + ": 마감 뒤에도 오는 응답을 받아들였다 — " + o.describe());
    assertInstanceOf(failure, o.thrown(), () -> label + ": 그 레인의 실패 타입이 아니다 — " + trace(o.thrown()));
    assertTrue(o.millis() < BOUND_MILLIS, () -> label + ": " + BOUND_MILLIS + " ms 안에 실패해야 한다 — " + o.describe());
    boolean timedOut = false;
    for (Throwable t = o.thrown(); t != null; t = t.getCause()) timedOut |= t instanceof SocketTimeoutException;
    assertTrue(timedOut, () -> label + ": 읽기 타임아웃과 같은 타입(SocketTimeoutException)이 원인 사슬에 없다 — " + trace(o.thrown()));
    assertFalse(trace(o.thrown()).contains(MARKER), () -> label + ": 실패가 응답 바이트를 인용했다 — " + trace(o.thrown()));
  }

  // ───────────── 본문 ─────────────

  /** (1) 본문을 흘리는 서버 — 마감에 실패한다. 수정 전: 두 레인 모두 7 초 넘게 걸려 받아들였다. */
  @ParameterizedTest
  @EnumSource(Lane.class)
  @Timeout(value = 60, threadMode = Timeout.ThreadMode.SEPARATE_THREAD)
  void aTrickledBody_failsAtTheDeadline(Lane lane) throws Exception {
    expectDeadline(lane + " 흘리기", lane.failure, run(lane, ResponseReadDeadlineTest::trickledBody, lane.body()));
  }

  /** 대조 — 머리와 몇 바이트 뒤 침묵: 지금처럼 읽기 타임아웃에 실패한다(마감이 먼저 끊지도, 더 기다리지도 않는다). */
  @ParameterizedTest
  @EnumSource(Lane.class)
  @Timeout(value = 60, threadMode = Timeout.ThreadMode.SEPARATE_THREAD)
  void control_aStalledBody_stillFailsAtTheReadTimeout(Lane lane) throws Exception {
    Outcome o = run(lane, ResponseReadDeadlineTest::stalledBody, lane.body());
    String label = lane + " 멈춤";
    System.out.println("[ResponseReadDeadlineTest] " + label + " → " + o.describe());
    assertInstanceOf(lane.failure, o.thrown(), () -> label + ": 실패해야 한다 — " + o.describe());
    assertTrue(o.millis() >= READ_TIMEOUT_MILLIS - 100 && o.millis() < BOUND_MILLIS,
        () -> label + ": 읽기 타임아웃 무렵에 실패해야 한다 — " + o.describe());
  }

  /** 대조 — 상한 바로 아래 본문이 네 조각으로 마감 안에 온다: 받아들인다(거짓 마감이 없다). */
  @ParameterizedTest
  @EnumSource(Lane.class)
  @Timeout(value = 60, threadMode = Timeout.ThreadMode.SEPARATE_THREAD)
  void control_aHealthyResponseJustUnderTheCap_isAccepted(Lane lane) throws Exception {
    Outcome o = run(lane, ResponseReadDeadlineTest::healthyBody, lane.healthyBody());
    System.out.println("[ResponseReadDeadlineTest] " + lane + " 건강 → " + o.describe());
    assertNull(o.thrown(), () -> lane + " 건강: 받아들여야 한다 — " + (o.thrown() == null ? "" : trace(o.thrown())));
  }

  // ───────────── 틀과 TLS 레코드 ─────────────

  /**
   * (2) 응답의 틀을 흘리는 서버 — 본문 읽기 하나 <b>안</b>(청크 크기 줄 · 트레일러)이나 본문 앞(머리)이어도 마감에 실패한다. 수정 전: 셋 다 7 초
   * 넘게 걸려 받아들였다. 레인은 토큰이다 — JWKS 레인은 같은 운송이다.
   */
  @ParameterizedTest
  @EnumSource(Framing.class)
  @Timeout(value = 60, threadMode = Timeout.ThreadMode.SEPARATE_THREAD)
  void trickledFraming_failsAtTheDeadline(Framing framing) throws Exception {
    expectDeadline("TOKEN 틀 " + framing, KeycloakTransportException.class, run(Lane.TOKEN, framing::pieces, TOKEN_BODY));
  }

  // ───────────── 마감 스트림 ─────────────

  /** 읽기마다 {@code millis} 를 쉬고 한 바이트를 내주는 스트림 — 읽힌 수를 센다. */
  private static final class SlowStream extends InputStream {
    final long millis;
    int reads;

    SlowStream(long millis) {
      this.millis = millis;
    }

    @Override public int read() throws IOException {
      reads++;
      try {
        Thread.sleep(millis);
      } catch (InterruptedException e) {
        Thread.currentThread().interrupt();
        throw new IOException(e);
      }
      return 'x';
    }

    @Override public int read(byte[] b, int off, int len) throws IOException {
      int c = read();
      b[off] = (byte) c;
      return 1;
    }
  }

  private static SocketTimeoutException late(InputStream in, boolean array) {
    return assertThrows(SocketTimeoutException.class, () -> {
      if (array) {
        in.read(new byte[4], 0, 4);
      } else {
        in.read();
      }
    });
  }

  /**
   * 마감 스트림 — 마감이 없는 스레드의 읽기는 그대로다 · 마감 안의 읽기는 그대로다 · 마감 뒤에 시작하는 읽기는 읽지 않고 실패한다 · 마감 뒤에 끝난
   * 읽기는 그 결과를 내주지 않는다 · 0 은 마감을 두지 않는다. 두 읽기(한 바이트 · 배열) 모두.
   */
  @Test
  void theDeadlinedStream_checksBeforeAndAfterEveryRead() throws Exception {
    try {
      for (boolean array : new boolean[] {false, true}) {
        BoundedTransport.disarm();
        SlowStream free = new SlowStream(0);
        assertEquals(array ? 1 : 'x', array ? BoundedTransport.deadlined(free).read(new byte[4], 0, 4)
            : BoundedTransport.deadlined(free).read(), "마감이 없는 스레드의 읽기는 그대로다");

        BoundedTransport.arm(10_000);
        SlowStream inTime = new SlowStream(0);
        assertEquals(array ? 1 : 'x', array ? BoundedTransport.deadlined(inTime).read(new byte[4], 0, 4)
            : BoundedTransport.deadlined(inTime).read(), "마감 안의 읽기는 그대로다");

        BoundedTransport.arm(50);
        Thread.sleep(80);
        SlowStream before = new SlowStream(0);
        SocketTimeoutException e = late(BoundedTransport.deadlined(before), array);
        assertEquals(0, before.reads, "마감 뒤에는 읽기를 시작하지 않는다");
        assertEquals(BoundedTransport.LATE + "50 ms of sending the request", e.getMessage());

        BoundedTransport.arm(50);
        SlowStream after = new SlowStream(120);
        late(BoundedTransport.deadlined(after), array);
        assertEquals(1, after.reads, "마감을 넘겨 끝난 읽기 — 읽었지만 그 결과를 내주지 않는다");

        BoundedTransport.arm(0);
        Thread.sleep(20);
        assertEquals(array ? 1 : 'x', array ? BoundedTransport.deadlined(new SlowStream(0)).read(new byte[4], 0, 4)
            : BoundedTransport.deadlined(new SlowStream(0)).read(), "읽기 타임아웃 0(끝없이)에는 마감도 없다");
      }
    } finally {
      BoundedTransport.disarm();
    }
  }

  /**
   * 교환의 끝은 그 스레드의 마감을 지운다 — 남으면 그 스레드가 나중에 하는 소켓 읽기(다음 교환이 연결을 빌리며 엿보는 1 ms 읽기)가 지난 교환의
   * 마감에 걸린다. 짧은 읽기 타임아웃의 교환 하나 뒤, 그 마감을 넘겨 시작한 읽기가 그대로다.
   */
  @Test
  @Timeout(value = 60, threadMode = Timeout.ThreadMode.SEPARATE_THREAD)
  void anExchange_leavesNoDeadlineOnItsThread() throws Exception {
    try (PacedServer server = new PacedServer(path -> List.of(new Piece(0, concat(head(TOKEN_BODY.length), TOKEN_BODY))))) {
      HTTPRequest req = new HTTPRequest(HTTPRequest.Method.POST, URI.create(server.url() + REALM_PATH + "/token").toURL());
      req.setBody("grant_type=client_credentials");
      req.setConnectTimeout(5_000);
      req.setReadTimeout(200);
      req.setFollowRedirects(false);
      assertEquals(200, CappedResponseSender.send(req, "token").getStatusCode());
      Thread.sleep(300);
      assertEquals('x', BoundedTransport.deadlined(new SlowStream(0)).read(), "교환이 끝난 스레드에 마감이 남았다");
    }
  }

  /**
   * (2) TLS 레코드 하나를 흘리는 서버 — JSSE 는 레코드가 다 올 때까지 읽기 하나 안에서 기다린다(그 아래 평문 소켓의 읽기는 바이트마다 끝난다).
   * 마감을 TLS 스트림의 읽기마다만 보면 이 칸이 그대로다 — 마감은 JSSE 아래의 평문 소켓에서 본다. 송신기를 직접 부른다(요청의 소켓 팩토리가
   * 시험 인증서를 믿는다 — 전역 기본값을 바꾸지 않는다). 수정 전: 레코드의 바이트 수 × 0.7 초 뒤 받아들였다.
   */
  @Test
  @Timeout(value = 120, threadMode = Timeout.ThreadMode.SEPARATE_THREAD)
  void aTrickledTlsRecord_failsAtTheDeadline() throws Exception {
    try (PacedServer server = new PacedServer(serverTls, path -> List.of(
            new Piece(0, concat(head(TOKEN_BODY.length), Arrays.copyOf(TOKEN_BODY, TOKEN_BODY.length - TRICKLED))),
            new Piece(300, Arrays.copyOfRange(TOKEN_BODY, TOKEN_BODY.length - TRICKLED, TOKEN_BODY.length))));
         TrickleRelay relay = new TrickleRelay(server.port())) {
      server.beforeLast.set(relay::trickle);
      HTTPRequest req = new HTTPRequest(HTTPRequest.Method.POST,
          URI.create("https://127.0.0.1:" + relay.port() + REALM_PATH + "/token").toURL());
      req.setBody("grant_type=client_credentials");
      req.setConnectTimeout(5_000);
      req.setReadTimeout(READ_TIMEOUT_MILLIS);
      req.setFollowRedirects(false);
      req.setSSLSocketFactory(clientTls.getSocketFactory());
      expectDeadline("TOKEN TLS 레코드", IOException.class, time(() -> CappedResponseSender.send(req, "token")));
    }
  }
}
