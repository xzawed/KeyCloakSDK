package io.github.xzawed.keycloak.auth;

import static org.junit.jupiter.api.Assertions.*;

import com.nimbusds.jose.util.DefaultResourceRetriever;
import com.nimbusds.jose.util.Resource;
import com.nimbusds.oauth2.sdk.ClientCredentialsGrant;
import com.nimbusds.oauth2.sdk.TokenRequest;
import com.nimbusds.oauth2.sdk.auth.ClientSecretBasic;
import com.nimbusds.oauth2.sdk.auth.Secret;
import com.nimbusds.oauth2.sdk.http.HTTPRequest;
import com.nimbusds.oauth2.sdk.http.HTTPResponse;
import com.nimbusds.oauth2.sdk.id.ClientID;
import io.github.xzawed.keycloak.core.KeycloakConfig;
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
import java.net.URI;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.security.KeyStore;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicLong;
import java.util.function.Function;
import javax.net.ssl.HostnameVerifier;
import javax.net.ssl.HttpsURLConnection;
import javax.net.ssl.KeyManagerFactory;
import javax.net.ssl.SSLContext;
import javax.net.ssl.SSLHandshakeException;
import javax.net.ssl.SSLParameters;
import javax.net.ssl.SSLSocket;
import javax.net.ssl.SSLSocketFactory;
import javax.net.ssl.TrustManagerFactory;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

/**
 * 운송을 바꿔도({@link BoundedTransport}) <b>HttpURLConnection 이 하던 그대로</b>인가 — 같은 서버에 Nimbus 의 {@code send()}
 * (HttpURLConnection)와 {@link CappedResponseSender} 를 나란히 붙여 서버가 받은 요청 바이트, 돌려받은 응답, TLS·프록시의 결말을
 * 대조한다. JWKS 레인은 Nimbus 의 {@code DefaultResourceRetriever} 와 대조한다.
 *
 * <p>대조의 기준은 지금 이 JVM 의 HttpURLConnection 자신이다 — 그래서 JDK 판마다 다른 값(17 의 Accept 목록 · User-Agent 의 판
 * 번호)도 그 JDK 에서 맞는지 잰다. ⚠️ 응답 헤더 값의 순서는 JDK 17 의 HttpURLConnection 이 뒤집는다(JDK-8133686 은 18 에서
 * 고쳐졌다) — 같은 이름이 거듭 오는 헤더는 17 에서만 값의 집합으로 비교한다.
 *
 * <p>⚠️ 전역 상태(시스템 프록시 속성 · Nimbus·HttpURLConnection 의 TLS 기본값 · {@code https.protocols})를 바꾸는 시험은 끝에서
 * 되돌린다 — surefire 는 한 JVM 에서 클래스를 차례로 돈다.
 */
class TransportParityTest {
  private static final String REALM = "r";
  private static final String TOKEN_PATH = "/realms/" + REALM + "/protocol/openid-connect/token";
  private static final byte[] TOKEN = utf8("{\"access_token\":\"AT\",\"token_type\":\"Bearer\",\"expires_in\":300}");
  private static final byte[] JWKS = utf8("{\"keys\":[{\"kty\":\"oct\",\"kid\":\"k1\",\"k\":\"AAAA\"}]}");
  private static final String MARKER = "ZparityMARKER0123";
  /** 인증서의 이름(other.example)이 아니라 접속한 이름이 루프백이면 받아들이는 검증기 — 엄격한 검사 뒤에 묻는 자리를 잰다. */
  private static final HostnameVerifier ACCEPTS_LOOPBACK = (host, session) -> "127.0.0.1".equals(host);

  @TempDir static Path dir;
  /** 시험 키 저장소의 암호 — 실행마다 새로 만든다(저장소에 키도, 그 암호도 두지 않는다). */
  private static final String STOREPASS = java.util.UUID.randomUUID().toString();
  /** SAN 이 127.0.0.1 인 서버 키 · 다른 이름(other.example)의 서버 키 · 둘을 믿는 클라이언트 팩토리. */
  private static SSLContext serverIp;
  private static SSLContext serverOther;
  /** 프록시 터널 너머의 이름(kc.invalid) — 터널 시험의 TLS 서버 키. */
  private static SSLContext serverTunnelled;
  private static SSLSocketFactory trusting;

  @BeforeAll static void keys() throws Exception {
    KeyStore ip = keystore("ip", "CN=127.0.0.1", "SAN=ip:127.0.0.1,dns:localhost");
    KeyStore other = keystore("other", "CN=other.example", "SAN=dns:other.example");
    KeyStore tunnelled = keystore("tunnelled", "CN=kc.invalid", "SAN=dns:kc.invalid");
    serverIp = serverContext(ip);
    serverOther = serverContext(other);
    serverTunnelled = serverContext(tunnelled);
    KeyStore trust = KeyStore.getInstance("PKCS12");
    trust.load(null, null);
    trust.setCertificateEntry("ip", ip.getCertificate("ip"));
    trust.setCertificateEntry("other", other.getCertificate("other"));
    trust.setCertificateEntry("tunnelled", tunnelled.getCertificate("tunnelled"));
    TrustManagerFactory tmf = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm());
    tmf.init(trust);
    SSLContext client = SSLContext.getInstance("TLS");
    client.init(null, tmf.getTrustManagers(), null);
    trusting = client.getSocketFactory();
  }

  /** 시험 때마다 keytool 로 만든다 — 저장소에 키를 두지 않는다. */
  private static KeyStore keystore(String alias, String dname, String san) throws Exception {
    Path file = dir.resolve(alias + ".p12");
    Process p = new ProcessBuilder(Path.of(System.getProperty("java.home"), "bin", "keytool").toString(),
        "-genkeypair", "-alias", alias, "-keyalg", "EC", "-groupname", "secp256r1", "-validity", "2", "-dname", dname,
        "-ext", san, "-keystore", file.toString(), "-storetype", "PKCS12", "-storepass", STOREPASS, "-keypass", STOREPASS)
        .redirectErrorStream(true).start();
    String out = new String(p.getInputStream().readAllBytes(), StandardCharsets.UTF_8);
    assertTrue(p.waitFor(60, TimeUnit.SECONDS) && p.exitValue() == 0, () -> "keytool 실패: " + out);
    KeyStore ks = KeyStore.getInstance("PKCS12");
    try (InputStream in = new FileInputStream(file.toFile())) {
      ks.load(in, STOREPASS.toCharArray());
    }
    return ks;
  }

  private static SSLContext serverContext(KeyStore ks) throws Exception {
    KeyManagerFactory kmf = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm());
    kmf.init(ks, STOREPASS.toCharArray());
    SSLContext ctx = SSLContext.getInstance("TLS");
    ctx.init(kmf.getKeyManagers(), null, null);
    return ctx;
  }

  private static byte[] utf8(String s) {
    return s.getBytes(StandardCharsets.UTF_8);
  }

  private static byte[] latin1(String s) {
    return s.getBytes(StandardCharsets.ISO_8859_1);
  }

  // ───────────── 서버 ─────────────

  /** 받은 요청 하나 — 요청 줄, 헤더 줄들, 본문. */
  private record Captured(String requestLine, List<String> headers, String body) {
    /** 비교용 — 헤더 줄은 순서와 무관하게 같은 묶음이어야 한다(값은 바이트 그대로). */
    String normalized() {
      List<String> sorted = new ArrayList<>(headers);
      Collections.sort(sorted);
      return requestLine + "\n" + String.join("\n", sorted) + "\n\n" + body;
    }

    String header(String name) {
      for (String h : headers) {
        if (h.regionMatches(true, 0, name + ":", 0, name.length() + 1)) return h.substring(name.length() + 1).trim();
      }
      return null;
    }
  }

  /** 요청 하나에 응답을 쓴다 — 끝없는 응답은 쓰기가 실패할 때까지 쓴다. */
  @FunctionalInterface
  private interface Responder {
    void respond(Captured request, OutputStream out, CaptureServer server) throws IOException;
  }

  /**
   * 기록하는 원시 서버 — 연결 하나에 요청을 여럿 받는다(HttpURLConnection 은 연결을 다시 쓴다). 요청마다 {@code reply} 가 응답을
   * 쓴다. TLS 면 맺은 규약을 적는다.
   */
  private static final class CaptureServer implements AutoCloseable {
    final ServerSocket socket;
    final List<Captured> requests = new CopyOnWriteArrayList<>();
    final List<String> protocols = new CopyOnWriteArrayList<>();
    final List<String> suites = new CopyOnWriteArrayList<>();
    final AtomicLong written = new AtomicLong();
    final Responder reply;
    volatile boolean stop;

    CaptureServer(SSLContext tls, Function<Captured, byte[]> reply) throws IOException {
      this(tls, (Responder) (request, out, server) -> {
        byte[] r = reply.apply(request);
        out.write(r);
        server.written.addAndGet(r.length);
      });
    }

    CaptureServer(SSLContext tls, Responder reply) throws IOException {
      this.reply = reply;
      socket = tls == null ? new ServerSocket(0, 50, InetAddress.getLoopbackAddress())
          : tls.getServerSocketFactory().createServerSocket(0, 50, InetAddress.getLoopbackAddress());
      Thread t = new Thread(this::serve, "parity-capture-server");
      t.setDaemon(true);
      t.start();
    }

    int port() {
      return socket.getLocalPort();
    }

    private void serve() {
      while (!stop) {
        Socket s;
        try {
          s = socket.accept();
        } catch (IOException closed) {
          return;
        }
        Thread t = new Thread(() -> answer(s), "parity-capture-exchange");
        t.setDaemon(true);
        t.start();
      }
    }

    private void answer(Socket s) {
      try (s) {
        s.setSoTimeout(10_000);
        if (s instanceof SSLSocket tls) {
          tls.startHandshake();
          protocols.add(tls.getSession().getProtocol());
          suites.add(tls.getSession().getCipherSuite());
        }
        InputStream in = s.getInputStream();
        OutputStream out = s.getOutputStream();
        while (!stop) {
          Captured c = readRequest(in);
          if (c == null) return;
          requests.add(c);
          reply.respond(c, out, this);
          out.flush();
          if (c.requestLine().startsWith("CONNECT")) return;
        }
      } catch (IOException clientLeft) {
        // 클라이언트가 떠났다(TLS 거부·끊기 포함)
      }
    }

    private static Captured readRequest(InputStream in) throws IOException {
      ByteArrayOutputStream head = new ByteArrayOutputStream();
      int last4 = 0;
      for (int b = in.read(); ; b = in.read()) {
        if (b == -1) return null;
        head.write(b);
        last4 = (last4 << 8) | b;
        if (last4 == 0x0d0a0d0a) break;
      }
      String[] lines = head.toString(StandardCharsets.ISO_8859_1).split("\r\n");
      List<String> headers = new ArrayList<>(List.of(lines).subList(1, lines.length));
      int length = 0;
      for (String h : headers) {
        if (h.regionMatches(true, 0, "Content-Length:", 0, 15)) length = Integer.parseInt(h.substring(15).trim());
      }
      return new Captured(lines[0], headers, new String(in.readNBytes(length), StandardCharsets.ISO_8859_1));
    }

    @Override public void close() throws IOException {
      stop = true;
      socket.close();
    }
  }

  private static byte[] ok(byte[] body) {
    ByteArrayOutputStream out = new ByteArrayOutputStream();
    out.writeBytes(latin1("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: " + body.length + "\r\n\r\n"));
    out.writeBytes(body);
    return out.toByteArray();
  }

  private static AuthClient authClient(String base) {
    KeycloakConfig c = KeycloakConfig.builder().serverUrl(base).realm(REALM).clientId("app")
        .clientSecret("s3cr3t".toCharArray()).build();
    return new AuthClient(c, OidcMetadata.forRealm(c));
  }

  /** AuthClient 가 내는 다섯 요청 모양 — {@code base} 의 엔드포인트로. */
  private static Map<String, HTTPRequest> shapes(String base) {
    AuthClient auth = authClient(base);
    Map<String, HTTPRequest> out = new TreeMap<>();
    out.put("client_credentials", auth.applyTimeouts(new TokenRequest.Builder(URI.create(base + TOKEN_PATH),
        new ClientSecretBasic(new ClientID("app"), new Secret("s3cr3t")), new ClientCredentialsGrant()).build().toHTTPRequest()));
    out.put("refresh_token", auth.applyTimeouts(auth.buildRefreshRequest("rt-1")));
    out.put("authorization_code", auth.applyTimeouts(auth.buildExchangeCodeRequest("code-1", URI.create("https://app.example/cb"),
        "v".repeat(43))));
    out.put("introspection", auth.applyTimeouts(auth.buildIntrospectionRequest("tok-1")));
    out.put("logout", auth.applyTimeouts(auth.buildLogoutRequest("rt-1")));
    return out;
  }

  private static String trace(Throwable t) {
    StringWriter out = new StringWriter();
    t.printStackTrace(new PrintWriter(out, true));
    return out.toString();
  }

  private static Throwable outcome(ThrowingCall call) {
    try {
      call.run();
      return null;
    } catch (Throwable t) {
      return t;
    }
  }

  @FunctionalInterface
  private interface ThrowingCall {
    void run() throws Exception;
  }

  // ───────────── 요청 ─────────────

  /** AuthClient 의 다섯 요청 — 서버가 받은 요청 줄·헤더 줄 묶음·본문이 HttpURLConnection 이 보낸 것과 바이트까지 같다. */
  @Test void requests_areByteForByteWhatHttpURLConnectionSends() throws Exception {
    try (CaptureServer server = new CaptureServer(null, c -> ok(TOKEN))) {
      String base = "http://127.0.0.1:" + server.port();
      List<String> wrong = new ArrayList<>();
      for (Map.Entry<String, HTTPRequest> shape : shapes(base).entrySet()) {
        server.requests.clear();
        shape.getValue().send();
        CappedResponseSender.send(shape.getValue(), "token");
        assertEquals(2, server.requests.size(), shape.getKey());
        String stock = server.requests.get(0).normalized();
        String capped = server.requests.get(1).normalized();
        System.out.println("[TransportParityTest] " + shape.getKey() + " 요청\n" + capped.replaceAll("(?m)^Authorization: .*$",
            "Authorization: <생략>"));
        if (!stock.equals(capped)) wrong.add(shape.getKey() + ":\n--- HttpURLConnection\n" + stock + "\n--- 새 운송\n" + capped);
      }
      assertTrue(wrong.isEmpty(), () -> String.join("\n", wrong));
    }
  }

  /** 본문 없는 요청(GET)과 요청에 실린 Accept — HttpURLConnection 처럼 Accept 를 덮지 않고 Content-Length 도 싣지 않는다. */
  @Test void aGetWithItsOwnAccept_isSentLikeHttpURLConnectionSendsIt() throws Exception {
    try (CaptureServer server = new CaptureServer(null, c -> ok(TOKEN))) {
      HTTPRequest get = new HTTPRequest(HTTPRequest.Method.GET,
          URI.create("http://127.0.0.1:" + server.port() + "/x?a=1&b=%20").toURL());
      get.setHeader("Accept", "application/json");
      get.send();
      CappedResponseSender.send(get, "token");
      assertEquals(server.requests.get(0).normalized(), server.requests.get(1).normalized());
      assertEquals("application/json", server.requests.get(1).header("Accept"));
      assertNull(server.requests.get(1).header("Content-Length"));
    }
  }

  /**
   * HttpURLConnection 이 조용히 버리는 헤더를 요청이 싣고 오면 새 운송도 버린다 — Content-Length(HttpClient 는 「already
   * present」로 던졌다)·Host(HttpClient 는 그대로 보냈다)·Transfer-Encoding·Origin·Sec-*·Keep-Alive·Via. {@code Connection: close} 는
   * 그대로 간다.
   */
  @Test void restrictedHeaders_areDroppedLikeHttpURLConnectionDropsThem() throws Exception {
    try (CaptureServer server = new CaptureServer(null, c -> ok(TOKEN))) {
      String base = "http://127.0.0.1:" + server.port();
      HTTPRequest req = shapes(base).get("client_credentials");
      req.setHeader("Content-Length", "999");
      req.setHeader("Host", "evil.example");
      req.setHeader("Transfer-Encoding", "chunked");
      req.setHeader("Origin", "https://evil.example");
      req.setHeader("Sec-Fetch-Mode", "cors");
      req.setHeader("Keep-Alive", "timeout=5");
      req.setHeader("Via", "1.1 evil");
      req.setHeader("Connection", "close");
      req.send();
      HTTPResponse capped = CappedResponseSender.send(req, "token");
      assertEquals(200, capped.getStatusCode());
      Captured stock = server.requests.get(0);
      Captured mine = server.requests.get(1);
      assertEquals(stock.normalized(), mine.normalized());
      assertEquals("127.0.0.1:" + server.port(), mine.header("Host"));
      assertEquals(String.valueOf(mine.body().length()), mine.header("Content-Length"));
      assertEquals("close", mine.header("Connection"));
      assertNull(mine.header("Origin"));
      assertNull(mine.header("Sec-Fetch-Mode"));
    }
  }

  /**
   * 리다이렉트는 따르지 않는다 — HttpClient 의 기본은 POST 의 303 을 GET 으로, GET 의 302 를 따른다. AuthClient 가 끄는 플래그
   * ({@code followRedirects=false})의 POST 303 은 HttpURLConnection 과 같이 303 을 돌려주고, ⚠️ 플래그가 켜진 GET 302 도 이
   * 송신은 따르지 않는다(Nimbus 의 send() 는 따른다 — SSRF 하드닝, 클래스 설명).
   */
  @Test void redirects_areNeverFollowed() throws Exception {
    try (CaptureServer server = new CaptureServer(null, c -> c.requestLine().contains("/elsewhere") ? ok(TOKEN)
        : latin1("HTTP/1.1 " + (c.requestLine().startsWith("POST") ? "303 See Other" : "302 Found")
            + "\r\nLocation: /elsewhere\r\nContent-Length: 0\r\n\r\n"))) {
      HTTPRequest post = shapes("http://127.0.0.1:" + server.port()).get("client_credentials");
      assertEquals(303, post.send().getStatusCode());
      assertEquals(303, CappedResponseSender.send(post, "token").getStatusCode());
      HTTPRequest get = new HTTPRequest(HTTPRequest.Method.GET, URI.create("http://127.0.0.1:" + server.port() + "/x").toURL());
      assertTrue(get.getFollowRedirects(), "Nimbus 의 기본은 따르기다");
      assertEquals(302, CappedResponseSender.send(get, "token").getStatusCode());
      assertTrue(server.requests.stream().noneMatch(r -> r.requestLine().contains("/elsewhere")),
          () -> "리다이렉트 대상에 요청이 갔다 — " + server.requests);
    }
  }

  // ───────────── 응답 ─────────────

  /**
   * Keycloak 26.6.4 의 토큰 응답 머리(소문자 {@code content-length} 포함 — 실측 캡처)와 거듭 오는 헤더 — 상태·메시지·헤더 표·본문이
   * Nimbus {@code send()} 와 같다. ⚠️ JDK 17 의 HttpURLConnection 은 거듭 오는 헤더의 값 순서를 뒤집는다 — 17 에서는 값의 집합을
   * 비교한다.
   */
  @Test void aKeycloakShapedResponse_isWhatNimbusSendBuilds() throws Exception {
    byte[] response = latin1("HTTP/1.1 200 OK\r\nCache-Control: no-store\r\nPragma: no-cache\r\ncontent-length: " + TOKEN.length
        + "\r\nContent-Type: application/json\r\nReferrer-Policy: no-referrer\r\n"
        + "Strict-Transport-Security: max-age=31536000; includeSubDomains\r\nX-Content-Type-Options: nosniff\r\n"
        + "X-Frame-Options: SAMEORIGIN\r\nX-Robots-Tag: none\r\nX-Multi: a\r\nX-Multi: b\r\nSet-Cookie: k1=v1\r\n"
        + "Set-Cookie: k2=v2\r\n\r\n" + new String(TOKEN, StandardCharsets.ISO_8859_1));
    try (CaptureServer server = new CaptureServer(null, c -> response)) {
      HTTPRequest req = shapes("http://127.0.0.1:" + server.port()).get("client_credentials");
      HTTPResponse stock = req.send();
      HTTPResponse capped = CappedResponseSender.send(req, "token");
      assertEquals(stock.getStatusCode(), capped.getStatusCode());
      assertEquals(stock.getStatusMessage(), capped.getStatusMessage());
      assertEquals(stock.getBody(), capped.getBody());
      assertEquals(comparable(stock.getHeaderMap()), comparable(capped.getHeaderMap()));
    }
  }

  private static Map<String, List<String>> comparable(Map<String, List<String>> headers) {
    Map<String, List<String>> out = new TreeMap<>(String.CASE_INSENSITIVE_ORDER);
    for (Map.Entry<String, List<String>> e : headers.entrySet()) {
      List<String> values = new ArrayList<>(e.getValue());
      if (Runtime.version().feature() < 18) Collections.sort(values); // JDK 17 의 HttpURLConnection 은 순서를 뒤집는다
      out.put(e.getKey(), values);
    }
    return out;
  }

  // ───────────── 프록시 ─────────────

  /**
   * 시스템 프록시({@code http.proxyHost})를 따른다 — 프록시가 받은 요청(절대 URI 의 요청 줄 · {@code Proxy-Connection})이
   * HttpURLConnection 의 것과 같다. HTTPS 의 CONNECT 를 프록시가 거절하면(502) 둘 다 IOException 이다 — 새 운송은 프록시의 응답을
   * 돌려주지 않고(HttpClient 의 기본은 그 502 를 응답으로 돌려준다), 메시지에 프록시의 바이트를 싣지 않는다.
   */
  @Test void theSystemProxy_isHonoured_andARefusedConnectIsAnIOException() throws Exception {
    try (CaptureServer proxy = new CaptureServer(null, c -> c.requestLine().startsWith("CONNECT")
        ? latin1("HTTP/1.1 502 Bad Gateway " + MARKER + "\r\nContent-Length: 0\r\n\r\n") : ok(TOKEN))) {
      String[] keys = {"http.proxyHost", "http.proxyPort", "https.proxyHost", "https.proxyPort"};
      Map<String, String> saved = new TreeMap<>();
      for (String k : keys) saved.put(k, System.getProperty(k));
      try {
        System.setProperty("http.proxyHost", "127.0.0.1");
        System.setProperty("http.proxyPort", String.valueOf(proxy.port()));
        System.setProperty("https.proxyHost", "127.0.0.1");
        System.setProperty("https.proxyPort", String.valueOf(proxy.port()));

        HTTPRequest plain = shapes("http://kc.invalid").get("client_credentials");
        plain.send();
        assertEquals(200, CappedResponseSender.send(plain, "token").getStatusCode());
        assertEquals(2, proxy.requests.size(), "두 요청 모두 프록시를 지나야 한다");
        assertEquals("POST http://kc.invalid" + TOKEN_PATH + " HTTP/1.1", proxy.requests.get(1).requestLine());
        assertEquals(proxy.requests.get(0).normalized(), proxy.requests.get(1).normalized());

        proxy.requests.clear();
        HTTPRequest tls = shapes("https://kc.invalid").get("client_credentials");
        Throwable stock = outcome(tls::send);
        Throwable capped = outcome(() -> CappedResponseSender.send(tls, "token"));
        System.out.println("[TransportParityTest] 거절된 CONNECT → HttpURLConnection " + stock + " · 새 운송 " + capped
            + " · 프록시가 받은 " + proxy.requests);
        assertInstanceOf(IOException.class, stock);
        assertInstanceOf(IOException.class, capped);
        assertEquals(BoundedTransport.TUNNEL_REFUSED, capped.getMessage());
        assertFalse(trace(capped).contains(MARKER), "거절이 프록시의 응답을 인용했다");
        assertTrue(proxy.requests.stream().allMatch(r -> r.requestLine().startsWith("CONNECT kc.invalid:443")),
            () -> "CONNECT 만 받았어야 한다 — " + proxy.requests);
      } finally {
        for (String k : keys) {
          if (saved.get(k) == null) System.clearProperty(k);
          else System.setProperty(k, saved.get(k));
        }
      }
    }
  }

  /** CONNECT 를 받아 주는 프록시 — 어느 대상이든 {@code target} 포트로 잇고 두 방향을 그대로 나른다. */
  private static final class TunnelProxy implements AutoCloseable {
    final ServerSocket socket;
    final int target;
    final List<String> connects = new CopyOnWriteArrayList<>();

    TunnelProxy(int target) throws IOException {
      this.target = target;
      socket = new ServerSocket(0, 50, InetAddress.getLoopbackAddress());
      Thread t = new Thread(this::serve, "parity-tunnel-proxy");
      t.setDaemon(true);
      t.start();
    }

    private void serve() {
      while (!socket.isClosed()) {
        try {
          Socket client = socket.accept();
          Thread t = new Thread(() -> tunnel(client), "parity-tunnel");
          t.setDaemon(true);
          t.start();
        } catch (IOException closed) {
          return;
        }
      }
    }

    private void tunnel(Socket client) {
      try (client; Socket upstream = new Socket(InetAddress.getLoopbackAddress(), target)) {
        Captured connect = CaptureServer.readRequest(client.getInputStream());
        if (connect == null) return;
        connects.add(connect.requestLine());
        client.getOutputStream().write(latin1("HTTP/1.1 200 Connection established\r\n\r\n"));
        client.getOutputStream().flush();
        Thread up = new Thread(() -> pipe(client, upstream), "parity-tunnel-up");
        up.setDaemon(true);
        up.start();
        pipe(upstream, client);
      } catch (IOException gone) {
        // 한쪽이 닫았다
      }
    }

    private static void pipe(Socket from, Socket to) {
      try {
        from.getInputStream().transferTo(to.getOutputStream());
        to.shutdownOutput();
      } catch (IOException gone) {
        // 한쪽이 닫았다
      }
    }

    @Override public void close() throws IOException {
      socket.close();
    }
  }

  /**
   * 프록시를 지나는 HTTPS — CONNECT 가 받아지면 터널 너머의 TLS 서버가 받은 요청(Host · {@code Connection} — 터널 안에서는
   * {@code Proxy-Connection} 이 아니다)이 HttpURLConnection 의 것과 같고, 이름 검사는 대상 이름({@code kc.invalid})으로 한다.
   */
  @Test void anHttpsRequestThroughAProxyTunnel_isWhatHttpURLConnectionSends() throws Exception {
    try (CaptureServer tls = new CaptureServer(serverTunnelled, TransportParityTest::okToken);
         TunnelProxy proxy = new TunnelProxy(tls.port())) {
      String host = System.getProperty("https.proxyHost");
      String port = System.getProperty("https.proxyPort");
      SSLSocketFactory nimbusDefault = HTTPRequest.getDefaultSSLSocketFactory();
      try {
        System.setProperty("https.proxyHost", "127.0.0.1");
        System.setProperty("https.proxyPort", String.valueOf(proxy.socket.getLocalPort()));
        HTTPRequest.setDefaultSSLSocketFactory(trusting);
        HTTPRequest req = shapes("https://kc.invalid").get("client_credentials");
        String stock = fate(req::send);
        String capped = fate(() -> CappedResponseSender.send(req, "token"));
        System.out.println("[TransportParityTest] 프록시 터널 HTTPS → " + stock + " · " + capped + " · CONNECT " + proxy.connects);
        assertEquals("ok", stock);
        assertEquals("ok", capped);
        assertEquals(List.of("CONNECT kc.invalid:443 HTTP/1.1", "CONNECT kc.invalid:443 HTTP/1.1"), proxy.connects);
        assertEquals(2, tls.requests.size());
        assertEquals(tls.requests.get(0).normalized(), tls.requests.get(1).normalized());
        assertEquals("kc.invalid", tls.requests.get(1).header("Host"));
      } finally {
        HTTPRequest.setDefaultSSLSocketFactory(nimbusDefault);
        if (host == null) System.clearProperty("https.proxyHost");
        else System.setProperty("https.proxyHost", host);
        if (port == null) System.clearProperty("https.proxyPort");
        else System.setProperty("https.proxyPort", port);
      }
    }
  }

  /** 본문 없는 204(Keycloak 의 logout 모양) — 상태·메시지·헤더·본문 없음이 Nimbus {@code send()} 와 같다. */
  @Test void aNoContentResponse_isWhatNimbusSendBuilds() throws Exception {
    try (CaptureServer server = new CaptureServer(null,
        c -> latin1("HTTP/1.1 204 No Content\r\nCache-Control: no-cache\r\nX-Frame-Options: SAMEORIGIN\r\n\r\n"))) {
      HTTPRequest req = shapes("http://127.0.0.1:" + server.port()).get("logout");
      HTTPResponse stock = req.send();
      HTTPResponse capped = CappedResponseSender.send(req, "logout");
      assertEquals(204, capped.getStatusCode());
      assertEquals(stock.getStatusMessage(), capped.getStatusMessage());
      assertNull(capped.getBody());
      assertEquals(stock.getBody(), capped.getBody());
      assertEquals(comparable(stock.getHeaderMap()), comparable(capped.getHeaderMap()));
    }
  }

  // ───────────── TLS ─────────────

  private static byte[] okToken(Captured c) {
    return ok(TOKEN);
  }

  /**
   * 같은 요청을 둘에 보내고 결말(상태 또는 예외 타입·메시지)을 비교할 수 있게 적는다. ⚠️ JDK 25 의 HttpURLConnection 은 이름 검사
   * 실패를 「Wrong HTTPS hostname: should be &lt;…&gt;」로 쓴다(17·21 은 「HTTPS hostname wrong:  should be &lt;…&gt;」 — 실측 25.0.4) —
   * 타입은 같다. 새 운송은 17·21 의 문구를 쓰므로 비교 전에 25 의 문구를 그것으로 맞춘다.
   */
  private static String fate(ThrowingCall call) {
    Throwable t = outcome(call);
    return t == null ? "ok" : t.getClass().getName() + (t instanceof SSLHandshakeException ? ""
        : ": " + t.getMessage().replace("Wrong HTTPS hostname: ", "HTTPS hostname wrong:  "));
  }

  private static HTTPRequest tlsRequest(int port, SSLSocketFactory factory, HostnameVerifier verifier) throws IOException {
    HTTPRequest req = shapes("https://127.0.0.1:" + port).get("client_credentials");
    req.setSSLSocketFactory(factory);
    req.setHostnameVerifier(verifier);
    return req;
  }

  /**
   * TLS 근원 — 요청의 팩토리, 없으면 Nimbus 의 기본 팩토리(HttpURLConnection 의 전역이 아니다 — 오늘과 같다)를 쓴다. 검증기가 JDK
   * 기본이면 이름이 맞지 않는 인증서는 핸드셰이크에서 거부되고(같은 예외 타입), 다른 검증기면 그 판정을 따른다(맞지 않으면 같은
   * 「HTTPS hostname wrong」). 결말이 HttpURLConnection 과 같다.
   */
  @Test void tls_followsTheRequestAndNimbusDefaults_likeHttpURLConnection() throws Exception {
    try (CaptureServer ip = new CaptureServer(serverIp, TransportParityTest::okToken)) {
      List<String> wrong = new ArrayList<>();
      HostnameVerifier jdkDefault = HTTPRequest.getDefaultHostnameVerifier();
      // ⚠️ 행마다 새 서버(새 포트)다 — HttpURLConnection 은 TLS 연결을 URL·팩토리로 캐시해 다시 쓰고, 다시 쓴 연결은 검증기를
      // 다시 묻지 않는다(앞 행이 받아들이는 검증기로 맺은 연결이면 거부하는 검증기의 행도 통과했다 — 실측).
      Object[][] rows = {
          {"요청의 팩토리 · JDK 기본 검증기", serverIp, trusting, jdkDefault, "ok"},
          {"이름이 다른 인증서 · JDK 기본 검증기", serverOther, trusting, jdkDefault, SSLHandshakeException.class.getName()},
          {"이름이 다른 인증서 · 받아들이는 검증기", serverOther, trusting, ACCEPTS_LOOPBACK, "ok"},
          {"이름이 다른 인증서 · 거부하는 검증기", serverOther, trusting, (HostnameVerifier) (h, s) -> false,
              "java.io.IOException: HTTPS hostname wrong:  should be <127.0.0.1>"},
          // 엄격한 검사가 먼저다 — 이름이 맞으면 검증기는 묻지 않는다(HttpsClient.checkURLSpoofing)
          {"맞는 인증서 · 거부하는 검증기", serverIp, trusting, (HostnameVerifier) (h, s) -> false, "ok"},
          {"믿지 않는 인증서", serverIp, (SSLSocketFactory) SSLSocketFactory.getDefault(), jdkDefault,
              SSLHandshakeException.class.getName()},
          {"팩토리가 이미 HTTPS 검사를 건다 · 받아들이는 검증기", serverOther, presetIdentification(trusting, "HTTPS"),
              ACCEPTS_LOOPBACK, SSLHandshakeException.class.getName()},
          // 빈 이름은 없는 것과 같다 — 기본 검증기면 HTTPS 검사를 건다
          {"팩토리가 빈 식별을 건다 · JDK 기본 검증기", serverOther, presetIdentification(trusting, ""), jdkDefault,
              SSLHandshakeException.class.getName()},
          // HTTPS 가 아닌 식별(LDAPS)은 핸드셰이크 안에서 그 규칙으로 검사된다 — 맞지 않으면 핸드셰이크가 실패한다
          {"팩토리가 LDAPS 식별을 건다 · 받아들이는 검증기", serverOther, presetIdentification(trusting, "LDAPS"),
              ACCEPTS_LOOPBACK, SSLHandshakeException.class.getName()},
      };
      for (Object[] row : rows) {
        try (CaptureServer server = new CaptureServer((SSLContext) row[1], TransportParityTest::okToken)) {
          HTTPRequest req = tlsRequest(server.port(), (SSLSocketFactory) row[2], (HostnameVerifier) row[3]);
          String stock = fate(req::send);
          String capped = fate(() -> CappedResponseSender.send(req, "token"));
          System.out.println("[TransportParityTest] TLS " + row[0] + " → HttpURLConnection " + stock + " · 새 운송 " + capped);
          if (!stock.equals(row[4]) || !capped.equals(row[4])) wrong.add(row[0] + ": 기대 " + row[4] + " · " + stock + " · " + capped);
        }
      }

      SSLSocketFactory nimbusDefault = HTTPRequest.getDefaultSSLSocketFactory();
      String protocols = System.getProperty("https.protocols");
      try {
        HTTPRequest.setDefaultSSLSocketFactory(trusting);
        HTTPRequest req = tlsRequest(ip.port(), null, null);
        String stock = fate(req::send);
        String capped = fate(() -> CappedResponseSender.send(req, "token"));
        if (!"ok".equals(stock) || !"ok".equals(capped)) wrong.add("Nimbus 기본 팩토리: " + stock + " · " + capped);

        System.setProperty("https.protocols", "TLSv1.2");
        try (CaptureServer fresh = new CaptureServer(serverIp, TransportParityTest::okToken)) { // 캐시된 연결을 쓰지 않게
          HTTPRequest req12 = tlsRequest(fresh.port(), null, null);
          String stock12 = fate(req12::send);
          String capped12 = fate(() -> CappedResponseSender.send(req12, "token"));
          System.out.println("[TransportParityTest] https.protocols=TLSv1.2 → " + stock12 + " · " + capped12 + " · 맺은 규약 "
              + fresh.protocols);
          if (!"ok".equals(stock12) || !"ok".equals(capped12) || !fresh.protocols.equals(List.of("TLSv1.2", "TLSv1.2"))) {
            wrong.add("https.protocols=TLSv1.2: " + stock12 + " · " + capped12 + " · " + fresh.protocols);
          }
        }
        String suite = "TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256";
        System.setProperty("https.cipherSuites", suite);
        try (CaptureServer fresh = new CaptureServer(serverIp, TransportParityTest::okToken)) {
          HTTPRequest reqSuite = tlsRequest(fresh.port(), null, null);
          String stockSuite = fate(reqSuite::send);
          String cappedSuite = fate(() -> CappedResponseSender.send(reqSuite, "token"));
          System.out.println("[TransportParityTest] https.cipherSuites=" + suite + " → " + stockSuite + " · " + cappedSuite
              + " · 맺은 묶음 " + fresh.suites);
          if (!"ok".equals(stockSuite) || !"ok".equals(cappedSuite) || !fresh.suites.equals(List.of(suite, suite))) {
            wrong.add("https.cipherSuites: " + stockSuite + " · " + cappedSuite + " · " + fresh.suites);
          }
        } finally {
          System.clearProperty("https.cipherSuites");
        }
      } finally {
        HTTPRequest.setDefaultSSLSocketFactory(nimbusDefault);
        if (protocols == null) System.clearProperty("https.protocols");
        else System.setProperty("https.protocols", protocols);
      }
      assertTrue(wrong.isEmpty(), () -> String.join("\n", wrong));
    }
  }

  /**
   * 소켓을 만들 때 끝점 식별을 미리 거는 팩토리 — HttpURLConnection 은 그것이 HTTPS 면 핸드셰이크 뒤 검사를 하지 않고, 비었으면 없는
   * 것으로 본다.
   */
  private static SSLSocketFactory presetIdentification(SSLSocketFactory delegate, String algorithm) {
    return new SSLSocketFactory() {
      private Socket preset(Socket s) {
        SSLSocket tls = (SSLSocket) s;
        SSLParameters p = tls.getSSLParameters();
        p.setEndpointIdentificationAlgorithm(algorithm);
        tls.setSSLParameters(p);
        return tls;
      }

      @Override public String[] getDefaultCipherSuites() {
        return delegate.getDefaultCipherSuites();
      }

      @Override public String[] getSupportedCipherSuites() {
        return delegate.getSupportedCipherSuites();
      }

      @Override public Socket createSocket(Socket s, String host, int port, boolean autoClose) throws IOException {
        return preset(delegate.createSocket(s, host, port, autoClose));
      }

      @Override public Socket createSocket(String host, int port) throws IOException {
        return preset(delegate.createSocket(host, port));
      }

      @Override public Socket createSocket(String host, int port, InetAddress local, int localPort) throws IOException {
        return preset(delegate.createSocket(host, port, local, localPort));
      }

      @Override public Socket createSocket(InetAddress host, int port) throws IOException {
        return preset(delegate.createSocket(host, port));
      }

      @Override public Socket createSocket(InetAddress host, int port, InetAddress local, int localPort) throws IOException {
        return preset(delegate.createSocket(host, port, local, localPort));
      }
    };
  }

  /** 닫힌 포트에 HTTPS — 연결 거부는 HttpURLConnection 처럼 JDK 의 ConnectException 이다(HttpClient 의 감싼 타입이 아니다). */
  @Test void aRefusedHttpsConnection_isTheJdksConnectException() throws Exception {
    int closed;
    try (ServerSocket s = new ServerSocket(0, 1, InetAddress.getLoopbackAddress())) {
      closed = s.getLocalPort();
    }
    HTTPRequest req = tlsRequest(closed, trusting, HTTPRequest.getDefaultHostnameVerifier());
    Throwable stock = outcome(req::send);
    Throwable capped = outcome(() -> CappedResponseSender.send(req, "token"));
    assertEquals(stock.getClass(), capped.getClass());
    assertEquals(java.net.ConnectException.class, capped.getClass());
  }

  /**
   * 상한을 넘는 HTTPS 본문 — 끝없는 1 바이트 청크를 전속력으로. 거부한 뒤 끊으므로 곧바로 돌아온다(예전 운송의 HTTPS 닫기는
   * 바이트가 이어지는 동안 버리기를 멈추지 않았다). 끊는 동안 JSSE 가 이미 도착한 바이트를 버리는 몫은 서버가 쓴 양으로 적는다.
   */
  @Test void anEndlessHttpsBody_isRefusedPromptly() throws Exception {
    byte[] one = latin1("1\r\n \r\n");
    byte[] block = new byte[one.length * 10_922];
    for (int i = 0; i < 10_922; i++) System.arraycopy(one, 0, block, i * one.length, one.length);
    byte[] head = latin1("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n"
        + Integer.toHexString(TOKEN.length) + "\r\n" + new String(TOKEN, StandardCharsets.ISO_8859_1) + "\r\n");
    try (CaptureServer server = new CaptureServer(serverIp, (Responder) (request, out, s) -> {
      out.write(head);
      while (!s.stop) {
        out.write(block);
        s.written.addAndGet(block.length);
      }
    })) {
      HTTPRequest req = tlsRequest(server.port(), trusting, HTTPRequest.getDefaultHostnameVerifier());
      long start = System.nanoTime();
      Throwable thrown = outcome(() -> CappedResponseSender.send(req, "token"));
      long millis = (System.nanoTime() - start) / 1_000_000;
      long atReturn = server.written.get();
      Thread.sleep(500);
      System.out.println("[TransportParityTest] HTTPS 끝없는 1 바이트 청크 → " + thrown + " · " + millis + " ms · 서버가 쓴 "
          + atReturn + " B(돌아온 뒤 0.5 초 동안 " + (server.written.get() - atReturn) + " B 더)");
      assertInstanceOf(CappedResponseSender.TooLarge.class, thrown);
      assertTrue(millis < 10_000, () -> millis + " ms");
    }
  }

  // ───────────── JWKS 레인 ─────────────

  /**
   * JWKS 조회 — 요청이 Nimbus 의 {@code DefaultResourceRetriever}(HttpURLConnection) 와 같고, 51,200 바이트 상한의 경계도 같다(정확히
   * 51,200 바이트는 그쪽도 거부한다 — {@code BoundedInputStream} 은 상한에 닿으면 던진다).
   */
  @Test void jwks_requestAndSizeLimit_matchNimbusDefaultRetriever() throws Exception {
    int limit = com.nimbusds.jose.jwk.source.JWKSourceBuilder.DEFAULT_HTTP_SIZE_LIMIT;
    for (int size : new int[] {JWKS.length, limit - 1, limit}) {
      byte[] body = new byte[size];
      java.util.Arrays.fill(body, (byte) ' ');
      System.arraycopy(JWKS, 0, body, 0, JWKS.length);
      try (CaptureServer server = new CaptureServer(null, c -> ok(body))) {
        URL certs = URI.create("http://127.0.0.1:" + server.port() + "/realms/r/protocol/openid-connect/certs").toURL();
        String stock = fate(() -> new DefaultResourceRetriever(5_000, 20_000, limit).retrieveResource(certs));
        String capped = fate(() -> new NoRedirectResourceRetriever(5_000, 20_000).retrieveResource(certs));
        System.out.println("[TransportParityTest] JWKS " + size + " 바이트 → " + stock + " · " + capped);
        assertEquals(stock, capped, size + " 바이트");
        assertEquals(size < limit ? "ok" : "java.io.IOException: Exceeded configured input limit of 51200 bytes", capped);
        if (size == JWKS.length) assertEquals(server.requests.get(0).normalized(), server.requests.get(1).normalized());
      }
    }
  }

  /** JWKS 레인의 TLS 근원은 HttpURLConnection 의 전역 기본값이다(Nimbus 기본 리트리버와 같다) — 내용과 Content-Type 도 같다. */
  @Test void jwks_tlsFollowsHttpsURLConnectionDefaults() throws Exception {
    try (CaptureServer server = new CaptureServer(serverIp, c -> ok(JWKS))) {
      URL certs = URI.create("https://127.0.0.1:" + server.port() + "/certs").toURL();
      SSLSocketFactory saved = HttpsURLConnection.getDefaultSSLSocketFactory();
      try {
        assertInstanceOf(SSLHandshakeException.class,
            outcome(() -> new NoRedirectResourceRetriever(5_000, 20_000).retrieveResource(certs)), "믿지 않는 인증서");
        HttpsURLConnection.setDefaultSSLSocketFactory(trusting);
        Resource stock = new DefaultResourceRetriever(5_000, 20_000, 51_200).retrieveResource(certs);
        Resource capped = new NoRedirectResourceRetriever(5_000, 20_000).retrieveResource(certs);
        assertEquals(stock.getContent(), capped.getContent());
        assertEquals(stock.getContentType(), capped.getContentType());
      } finally {
        HttpsURLConnection.setDefaultSSLSocketFactory(saved);
      }
    }
  }

  /** Content-Type 이 없는 JWKS 응답 — 내용은 같고 Content-Type 은 둘 다 없다. */
  @Test void jwks_withoutAContentType_isWhatNimbusDefaultRetrieverReturns() throws Exception {
    byte[] untyped = latin1("HTTP/1.1 200 OK\r\nContent-Length: " + JWKS.length + "\r\n\r\n"
        + new String(JWKS, StandardCharsets.ISO_8859_1));
    try (CaptureServer server = new CaptureServer(null, c -> untyped)) {
      URL certs = URI.create("http://127.0.0.1:" + server.port() + "/certs").toURL();
      Resource stock = new DefaultResourceRetriever(5_000, 20_000, 51_200).retrieveResource(certs);
      Resource capped = new NoRedirectResourceRetriever(5_000, 20_000).retrieveResource(certs);
      assertEquals(stock.getContent(), capped.getContent());
      assertNull(stock.getContentType());
      assertNull(capped.getContentType());
    }
  }

  /** JWKS 의 비-2xx 는 조회 실패다 — 메시지는 상태 코드만 싣는다(이유 문구는 응답 바이트다). */
  @Test void jwks_aNon2xxStatus_failsWithoutQuotingTheReason() throws Exception {
    try (CaptureServer server = new CaptureServer(null,
        c -> latin1("HTTP/1.1 503 " + MARKER + "\r\nContent-Length: 0\r\n\r\n"))) {
      URL certs = URI.create("http://127.0.0.1:" + server.port() + "/certs").toURL();
      Throwable t = outcome(() -> new NoRedirectResourceRetriever(5_000, 20_000).retrieveResource(certs));
      assertInstanceOf(IOException.class, t);
      assertEquals("JWKS endpoint returned HTTP 503", t.getMessage());
      assertFalse(trace(t).contains(MARKER));
    }
  }
}
