package io.github.xzawed.keycloak;

import static org.junit.jupiter.api.Assertions.*;

import com.nimbusds.jose.JOSEException;
import com.nimbusds.jose.JWSAlgorithm;
import com.nimbusds.jose.JWSHeader;
import com.nimbusds.jose.crypto.RSASSASigner;
import com.nimbusds.jose.jwk.JWKSet;
import com.nimbusds.jose.jwk.RSAKey;
import com.nimbusds.jose.jwk.gen.RSAKeyGenerator;
import com.nimbusds.jwt.JWTClaimsSet;
import com.nimbusds.jwt.SignedJWT;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;
import io.github.xzawed.keycloak.admin.AdminClient;
import io.github.xzawed.keycloak.auth.AuthorizationUrlRequest;
import io.github.xzawed.keycloak.auth.ClientCredentialsTokenProvider;
import io.github.xzawed.keycloak.auth.IntrospectionResult;
import io.github.xzawed.keycloak.auth.Pkce;
import io.github.xzawed.keycloak.auth.ValidatedToken;
import io.github.xzawed.keycloak.core.InMemoryTokenStore;
import io.github.xzawed.keycloak.core.KeycloakConfig;
import io.github.xzawed.keycloak.core.TokenSet;
import io.github.xzawed.keycloak.core.exception.KeycloakAdminException;
import io.github.xzawed.keycloak.core.exception.KeycloakAuthException;
import io.github.xzawed.keycloak.core.exception.KeycloakConfigException;
import io.github.xzawed.keycloak.core.exception.KeycloakConflictException;
import io.github.xzawed.keycloak.core.exception.KeycloakForbiddenException;
import io.github.xzawed.keycloak.core.exception.KeycloakNotFoundException;
import io.github.xzawed.keycloak.core.exception.KeycloakSdkException;
import io.github.xzawed.keycloak.core.exception.KeycloakTransportException;
import io.github.xzawed.keycloak.core.exception.TokenValidationException;
import java.io.IOException;
import java.io.OutputStream;
import java.io.PrintWriter;
import java.io.StringWriter;
import java.lang.ref.Reference;
import java.lang.reflect.Field;
import java.lang.reflect.Modifier;
import java.lang.reflect.Proxy;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.URI;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.security.CodeSource;
import java.security.ProtectionDomain;
import java.time.Clock;
import java.time.Duration;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Base64;
import java.util.Collection;
import java.util.Collections;
import java.util.Date;
import java.util.Enumeration;
import java.util.HashMap;
import java.util.IdentityHashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.SortedSet;
import java.util.TreeSet;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;
import java.util.concurrent.atomic.AtomicReferenceArray;
import java.util.jar.JarEntry;
import java.util.jar.JarFile;
import java.util.stream.Stream;
import org.junit.jupiter.api.Test;
import org.keycloak.representations.idm.CredentialRepresentation;
import org.keycloak.representations.idm.UserRepresentation;

/**
 * 바닥 계약(기본 문자열 표현이 비밀을 찍지 않는다)을 **손으로 고른 값 타입이 아니라 도달 가능한 객체 전부**에
 * 건다. Go {@code facade_dump_test.go} · PHP {@code FacadeDumpTest.php} 와 같은 모양이다. Java 의 바닥은
 * {@code String.valueOf(obj)} · {@code obj.toString()} · {@code "" + obj} 이고, 예외는 로거가 찍는
 * {@code printStackTrace} 까지 잰다(원인 사슬의 메시지가 거기 실린다).
 *
 * <p>⚠️ **새 자리를 스스로 찾는 것이 요점이다**(등록부 {@code guard-detection-surface-hand-narrowed}). 검사
 * 대상은 (1) 공개 API 로 만든 뿌리에서 리플렉션으로 **닿는 SDK 객체 전부**이고 — 제3자 객체(Nimbus·RESTEasy)
 * 안에 든 SDK 객체까지 따라간다(예: JWKS 소스 사슬 속 {@code NoRedirectResourceRetriever}) — (2) 클래스패스에서
 * SDK 루트 패키지를 담은 **컴파일 산출물을 훑어 얻은 타입 전수**가 그 걷기에 걸렸는지 대조한다. 인스턴스 상태가
 * 없는 타입(인터페이스·정적 도우미)은 규칙으로 빠지고, 그 밖의 면제는 이유와 함께 {@link #EXEMPT} 에 적는다.
 * 레코드로 바꾸는 순간 자동 {@code toString} 이 모든 필드를 찍는다 — 그 회귀를 여기서 잡는다.
 *
 * <p>⚠️ 소유 판정은 패키지 접두가 아니라 **코드 소스 위치**다 — 이 테스트는 파사드와 같은 패키지에 있어서
 * 접두로 가르면 하네스 객체가 SDK 로 섞인다. 걷기가 이 테스트의 클래스(람다 포함)에 닿으면 그 자체를 실패로
 * 본다(PHP 에서 배운 오염 — 하네스 객체가 렌더링에 섞이면 SDK 와 무관한 누출이 잡힌다).
 *
 * <p>⚠️ 한계: 카나리아는 뿌리를 만드는 호출이 흘려 넣은 비밀뿐이다. 제3자 객체는 렌더링하지 않는다(§4(b) —
 * {@code raw()} 가 돌려주는 admin-client 는 탈출구다). Jackson/Gson 직렬화는 바닥이 아니다({@code SECURITY.md}).
 * Java admin 에는 소비자가 토큰 소스를 주입하는 경로가 없다({@code .claude/rules/java.md}) — 그 뿌리는 없다.
 * JDK 객체는 공개 API(컬렉션·Map·Optional·Atomic*·Reference·Map.Entry·원인 사슬)로만 건넌다 — {@code ThreadLocal}·
 * {@code CompletableFuture}·JDK 가 만든 람다 속에만 든 SDK 객체와 정적 필드는 걷지 않는다(독립 레그 지목). 그런
 * 자리에만 사는 **새 타입**은 대조에서 「닿지 않음」으로 걸리고, 이미 닿는 타입의 다른 인스턴스만 거기 살 때가 빈틈이다.
 */
class FacadeDumpTest {
  private static final String SECRET = "CANARY-DUMP-CLIENT-SECRET";
  private static final String ACCESS = "CANARY-DUMP-ACCESS-TOKEN";
  private static final String REFRESH = "CANARY-DUMP-REFRESH-TOKEN";
  private static final String GARBAGE = "CANARY-DUMP-GARBAGE-TOKEN";
  private static final String PASSWORD = "CANARY-DUMP-ADMIN-PASSWORD";
  private static final String CLIENT_ID = "c";
  private static final String OC = "/realms/r/protocol/openid-connect";
  /** SDK 루트 패키지 = 파사드의 패키지(손으로 적지 않는다). */
  private static final String SDK_PACKAGE = KeycloakClient.class.getPackageName() + ".";

  /** 걷기에 안 닿아도 되는 상태 있는 타입과 그 이유. ⚠️ 이유 없는 면제는 넣지 않는다. */
  private static final Map<String, String> EXEMPT = Map.of();

  /**
   * 알려진 누출 — {@code "뿌리|카나리아"} 와 사유. ⚠️ 고쳐져 더 안 새면 **여기서 지워야 통과한다**(낡은 항목 검사).
   */
  private static final Map<String, String> KNOWN_LEAKS = Map.of();

  @Test
  void reachableObjectsDoNotRenderSecrets() throws Exception {
    RSAKey key = new RSAKeyGenerator(2048).keyID("k1").generate();
    List<AutoCloseable> closers = new ArrayList<>();
    try (FakeIdp idp = new FakeIdp(key)) {
      Map<String, String> canaries = new LinkedHashMap<>();
      Map<String, Object> roots = roots(idp, key, canaries, closers);

      Path harness = location(FacadeDumpTest.class);
      Set<Path> sdk = sdkLocations(harness);
      for (Class<?> anchor : List.of(KeycloakConfig.class, Pkce.class, AdminClient.class, KeycloakClient.class)) {
        assertTrue(sdk.contains(location(anchor)),
            () -> anchor.getName() + " 의 위치가 SDK 루트 파생에서 빠졌다 — 파생이 공허하다: " + sdk);
      }
      Walker w = new Walker(canaries, sdk, harness);
      roots.forEach(w::walk);

      assertTrue(w.leaks.isEmpty(), () -> "기본 표현이 비밀을 찍는다:\n" + String.join("\n", w.leaks));
      Set<String> stale = new TreeSet<>(KNOWN_LEAKS.keySet());
      stale.removeAll(w.knownSeen);
      assertTrue(stale.isEmpty(), () -> "알려진 누출이 더 안 난다 — 고쳐졌으면 KNOWN_LEAKS 를 지워라: " + stale);

      SortedSet<String> declared = declaredTypes(sdk);
      assertTrue(declared.size() >= 20, () -> "SDK 타입을 거의 못 찾았다 — 파생이 공허하다: " + declared);
      List<String> problems = new ArrayList<>(w.problems);
      int stateless = 0;
      for (String name : declared) {
        boolean noState = stateless(Class.forName(name, false, FacadeDumpTest.class.getClassLoader()));
        boolean reached = w.reached.contains(name);
        boolean exempt = EXEMPT.containsKey(name);
        stateless += noState ? 1 : 0;
        if (reached && exempt) {
          problems.add(name + ": 걷기에 닿는데 면제 표에도 있다 — 면제를 지워라(" + EXEMPT.get(name) + ")");
        } else if (exempt && noState) {
          problems.add(name + ": 상태가 없어 규칙으로 빠지는데 면제 표에도 있다 — 면제를 지워라");
        } else if (!reached && !exempt && !noState) {
          problems.add(name + ": 공개 API 뿌리에서 닿지 않는 상태 있는 타입이다 — 만드는 경로를 뿌리에 더하거나,"
              + " 이유와 함께 면제하라");
        }
      }
      for (String name : EXEMPT.keySet()) {
        if (!declared.contains(name)) problems.add(name + ": 면제 표에 있지만 선언이 없다 — 낡은 면제다");
      }
      System.out.printf("[FacadeDumpTest] roots=%d walked=%d rendered=%d reached=%d/%d declared (stateless %d,"
              + " exempt %d, known leaks %d)%n", roots.size(), w.seen.size(), w.rendered,
          declared.stream().filter(w.reached::contains).count(), declared.size(), stateless, EXEMPT.size(),
          KNOWN_LEAKS.size());
      assertTrue(problems.isEmpty(), () -> String.join("\n", problems));
    } finally {
      for (AutoCloseable c : closers) c.close();
    }
  }

  /** 공개 API 로 뿌리를 만들고, 그 과정이 흘려 넣은 비밀 전부를 {@code canaries} 에 남긴다. */
  private static Map<String, Object> roots(FakeIdp idp, RSAKey key, Map<String, String> canaries,
      List<AutoCloseable> closers) throws Exception {
    KeycloakConfig.Builder builder = KeycloakConfig.builder()
        .serverUrl(idp.url()).realm("r").clientId(CLIENT_ID).clientSecret(SECRET.toCharArray());
    KeycloakConfig cfg = builder.build();
    KeycloakClient kc = KeycloakClient.create(cfg);
    closers.add(kc);

    // admin 은 생성 시 네트워크를 타지 않는다 — 토큰은 첫 호출에서 받아 캐시한다.
    int before = idp.hits.get();
    AdminClient admin = kc.admin();
    assertEquals(before, idp.hits.get(), "admin() 생성이 네트워크를 탔다 — 무네트워크 생성 전제가 깨졌다");
    KeycloakNotFoundException notFound =
        assertThrows(KeycloakNotFoundException.class, () -> admin.users().get("missing"));
    String adminToken = admin.raw().tokenManager().getAccessTokenString();

    TokenSet cc = kc.auth().clientCredentialsToken();
    AuthorizationUrlRequest ar = kc.auth().createAuthorizationRequest(URI.create("https://app/cb"));
    TokenSet code = kc.auth().exchangeCode("code-1", URI.create("https://app/cb"), ar.getCodeVerifier());
    TokenSet refreshed = kc.auth().refresh(REFRESH);
    IntrospectionResult ir = kc.auth().introspect(ACCESS);
    String issuer = idp.url() + "/realms/r";
    String jwt = jwt(key, issuer, "u1", 60);
    ValidatedToken vt = kc.auth().validate(jwt);
    kc.auth().logout(REFRESH);
    ClientCredentialsTokenProvider provider =
        new ClientCredentialsTokenProvider(kc.auth(), Clock.systemUTC(), Duration.ofSeconds(30));
    String provided = provider.getAccessToken();
    Pkce pkce = Pkce.generate();
    InMemoryTokenStore store = new InMemoryTokenStore();
    store.save(code);

    // ⚠️ 카나리아가 실제로 흘러 들어갔는가 — 안 흘렀으면 아래 누출 검사는 없는 것을 찾으며 통과한다.
    String basic = Base64.getEncoder().encodeToString((CLIENT_ID + ":" + SECRET).getBytes(StandardCharsets.UTF_8));
    assertArrayEquals(SECRET.toCharArray(), cfg.getClientSecret(), "시크릿이 설정에 안 흘렀다");
    assertTrue(idp.tokenAuth.contains("Basic " + basic), () -> "토큰 요청이 카나리아 시크릿을 안 실었다: " + idp.tokenAuth);
    assertEquals(List.of(ACCESS, REFRESH), List.of(cc.getAccessToken(), cc.getRefreshToken()), "client_credentials");
    assertEquals(List.of(ACCESS, REFRESH, idp.idToken),
        List.of(code.getAccessToken(), code.getRefreshToken(), code.getIdToken()), "exchangeCode");
    assertEquals(ACCESS, refreshed.getAccessToken(), "refresh");
    assertEquals(ACCESS, provided, "ClientCredentialsTokenProvider 캐시");
    assertEquals(ACCESS, adminToken, "admin 이 캐시한 토큰");
    assertEquals(Optional.of(code), store.load(), "InMemoryTokenStore");
    assertEquals("u1", vt.getSubject(), "validate");
    assertTrue(ir.isActive(), "introspect");
    assertFalse(ar.getCodeVerifier().isEmpty(), "authorization request verifier");
    assertFalse(pkce.getVerifier().isEmpty(), "Pkce verifier");

    // 오류 타입 — 실제 실패 호출에서 얻는다(원인 사슬이 요청·응답을 쥔다).
    KeycloakClient bad = KeycloakClient.create(KeycloakConfig.builder()
        .serverUrl(idp.url()).realm("bad").clientId(CLIENT_ID).clientSecret(SECRET.toCharArray()).build());
    closers.add(bad);
    int closedPort;
    try (ServerSocket s = new ServerSocket(0, 1, InetAddress.getLoopbackAddress())) {
      closedPort = s.getLocalPort();
    }
    KeycloakClient down = KeycloakClient.create(KeycloakConfig.builder()
        .serverUrl("http://127.0.0.1:" + closedPort).realm("r").clientId(CLIENT_ID)
        .clientSecret(SECRET.toCharArray()).connectTimeout(Duration.ofMillis(500)).build());
    closers.add(down);
    String expired = jwt(key, issuer, "u1", -600);
    UserRepresentation dup = new UserRepresentation();
    dup.setUsername("dup");
    CredentialRepresentation pw = new CredentialRepresentation();
    pw.setType(CredentialRepresentation.PASSWORD);
    pw.setValue(PASSWORD);
    dup.setCredentials(List.of(pw));

    KeycloakAdminException serverError = assertThrows(KeycloakAdminException.class, () -> admin.users().get("boom"));
    assertEquals(KeycloakAdminException.class, serverError.getClass(), "500 은 기본 분기다");

    canaries.put("SECRET", SECRET);
    canaries.put("BASIC", basic);   // Basic 헤더 값 — 시크릿의 인코딩된 형태도 비밀이다.
    canaries.put("ACCESS", ACCESS);
    canaries.put("REFRESH", REFRESH);
    canaries.put("ID", idp.idToken);
    canaries.put("GARBAGE", GARBAGE);
    canaries.put("PASSWORD", PASSWORD);
    canaries.put("VERIFIER", ar.getCodeVerifier());
    canaries.put("PKCE", pkce.getVerifier());
    canaries.put("JWT", jwt);
    canaries.put("EXPIRED", expired);

    Map<String, Object> roots = new LinkedHashMap<>();
    roots.put("KeycloakClient.create", kc);
    roots.put("KeycloakConfig.builder()", builder);
    roots.put("admin()", admin);
    roots.put("users()", admin.users());
    roots.put("clients()", admin.clients());
    roots.put("realms()", admin.realms());
    roots.put("roles()", admin.roles());
    roots.put("groups()", admin.groups());
    roots.put("clientCredentialsToken", cc);
    roots.put("createAuthorizationRequest", ar);
    roots.put("exchangeCode", code);
    roots.put("refresh", refreshed);
    roots.put("introspect", ir);
    roots.put("validate", vt);
    roots.put("ClientCredentialsTokenProvider", provider);
    roots.put("Pkce.generate", pkce);
    roots.put("InMemoryTokenStore", store);
    roots.put("auth error (401)", assertThrows(KeycloakAuthException.class, () -> bad.auth().clientCredentialsToken()));
    roots.put("admin error (bad realm)", assertThrows(KeycloakSdkException.class, () -> bad.admin().users().get("x")));
    roots.put("validation error (garbage)", assertThrows(TokenValidationException.class, () -> kc.auth().validate(GARBAGE)));
    roots.put("validation error (expired)", assertThrows(TokenValidationException.class, () -> kc.auth().validate(expired)));
    roots.put("admin 404", notFound);
    roots.put("admin 403", assertThrows(KeycloakForbiddenException.class, () -> admin.users().get("forbidden")));
    roots.put("admin 409", assertThrows(KeycloakConflictException.class, () -> admin.users().create(dup)));
    roots.put("admin 500", serverError);
    roots.put("clientCredentials transport error",
        assertThrows(KeycloakTransportException.class, () -> down.auth().clientCredentialsToken()));
    roots.put("introspect transport error", assertThrows(KeycloakTransportException.class, () -> down.auth().introspect(ACCESS)));
    roots.put("logout transport error", assertThrows(KeycloakTransportException.class, () -> down.auth().logout(REFRESH)));
    roots.put("admin transport error", assertThrows(KeycloakTransportException.class, () -> down.admin().users().get("x")));
    roots.put("config error", assertThrows(KeycloakConfigException.class,
        () -> KeycloakConfig.builder().clientSecret(SECRET.toCharArray()).build()));
    return roots;
  }

  private static String jwt(RSAKey key, String issuer, String subject, long expiresInSeconds) throws JOSEException {
    long exp = System.currentTimeMillis() + expiresInSeconds * 1000;
    SignedJWT jwt = new SignedJWT(new JWSHeader.Builder(JWSAlgorithm.RS256).keyID(key.getKeyID()).build(),
        new JWTClaimsSet.Builder().issuer(issuer).subject(subject).audience(CLIENT_ID)
            .issueTime(new Date(exp - 300_000)).expirationTime(new Date(exp)).build());
    jwt.sign(new RSASSASigner(key));
    return jwt.serialize();
  }

  /** 가짜 IdP — 경로로 응답을 고른다(호출 순서가 바뀌어도 안 깨진다). 토큰·introspect·JWKS·logout·실패 realm·admin 4xx/5xx. */
  private static final class FakeIdp implements AutoCloseable {
    final AtomicInteger hits = new AtomicInteger();
    final Set<String> tokenAuth = ConcurrentHashMap.newKeySet();
    final String idToken;
    private final HttpServer server;

    FakeIdp(RSAKey key) throws IOException, JOSEException {
      server = HttpServer.create(new InetSocketAddress(InetAddress.getLoopbackAddress(), 0), 0);
      // id_token 은 OIDC 파서가 JWT 로 파싱하므로 실제 서명 JWT 여야 한다 — 그 직렬화 전체가 카나리아다.
      idToken = jwt(key, url() + "/realms/r", "id-canary", 60);
      String tokens = "{\"access_token\":\"" + ACCESS + "\",\"token_type\":\"Bearer\",\"expires_in\":300,"
          + "\"refresh_token\":\"" + REFRESH + "\",\"id_token\":\"" + idToken + "\"}";
      String jwks = new JWKSet(key.toPublicJWK()).toString();
      server.createContext("/", ex -> {
        hits.incrementAndGet();
        ex.getRequestBody().readAllBytes();
        String path = ex.getRequestURI().getPath();
        if (path.equals(OC + "/token")) {
          Optional.ofNullable(ex.getRequestHeaders().getFirst("Authorization")).ifPresent(tokenAuth::add);
          reply(ex, 200, tokens);
        } else if (path.equals(OC + "/token/introspect")) {
          reply(ex, 200, "{\"active\":true,\"username\":\"svc\",\"client_id\":\"c\",\"sub\":\"u1\"}");
        } else if (path.equals(OC + "/certs")) {
          reply(ex, 200, jwks);
        } else if (path.equals(OC + "/logout")) {
          reply(ex, 204, null);
        } else if (path.equals("/realms/bad/protocol/openid-connect/token")) {
          reply(ex, 401, "{\"error\":\"invalid_client\"}");
        } else if (path.equals("/admin/realms/r/users/missing")) {
          reply(ex, 404, "{\"error\":\"User not found\"}");
        } else if (path.equals("/admin/realms/r/users/forbidden")) {
          reply(ex, 403, "{\"error\":\"HTTP 403 Forbidden\"}");
        } else if (path.equals("/admin/realms/r/users/boom")) {
          reply(ex, 500, "{\"error\":\"unknown_error\"}");
        } else if (path.equals("/admin/realms/r/users") && "POST".equals(ex.getRequestMethod())) {
          reply(ex, 409, "{\"errorMessage\":\"User exists with same username\"}");
        } else {
          reply(ex, 404, null);
        }
      });
      server.start();
    }

    String url() {
      return "http://127.0.0.1:" + server.getAddress().getPort();
    }

    private static void reply(HttpExchange ex, int status, String body) throws IOException {
      if (body == null) {
        ex.sendResponseHeaders(status, -1);
        ex.close();
        return;
      }
      byte[] bytes = body.getBytes(StandardCharsets.UTF_8);
      ex.getResponseHeaders().add("Content-Type", "application/json");
      ex.sendResponseHeaders(status, bytes.length);
      try (OutputStream os = ex.getResponseBody()) {
        os.write(bytes);
      }
    }

    @Override public void close() {
      server.stop(0);
    }
  }

  // ── 걷기 ──

  private static Path location(Class<?> c) {
    ProtectionDomain pd = c.getProtectionDomain();
    CodeSource cs = pd == null ? null : pd.getCodeSource();
    if (cs == null || cs.getLocation() == null) return null;
    try {
      return Paths.get(cs.getLocation().toURI()).toAbsolutePath().normalize();
    } catch (Exception e) {
      return null;
    }
  }

  /** SDK 루트 패키지(파사드의 패키지)를 담은 클래스패스 루트 전부 — 이 테스트의 산출물만 뺀다. */
  private static Set<Path> sdkLocations(Path harness) throws Exception {
    String dir = SDK_PACKAGE.substring(0, SDK_PACKAGE.length() - 1).replace('.', '/');
    Set<Path> out = new TreeSet<>();
    Enumeration<URL> urls = FacadeDumpTest.class.getClassLoader().getResources(dir);
    while (urls.hasMoreElements()) {
      URL u = urls.nextElement();
      Path root;
      if ("jar".equals(u.getProtocol())) {
        String s = u.getPath();
        root = Paths.get(new URI(s.substring(0, s.indexOf("!/"))));
      } else {
        root = Paths.get(u.toURI());
        for (int i = 0; i < dir.split("/").length; i++) root = root.getParent();
      }
      root = root.toAbsolutePath().normalize();
      if (!root.equals(harness)) out.add(root);
    }
    return out;
  }

  /** SDK 산출물의 이름 있는 타입 전수(익명·합성 제외) — 손 목록이 아니라 트리에서 파생한다. */
  private static SortedSet<String> declaredTypes(Set<Path> locations) throws Exception {
    SortedSet<String> names = new TreeSet<>();
    for (Path loc : locations) {
      if (Files.isDirectory(loc)) {
        try (Stream<Path> s = Files.walk(loc)) {
          s.map(p -> loc.relativize(p).toString().replace('\\', '/')).filter(n -> n.endsWith(".class"))
              .forEach(names::add);
        }
      } else {
        try (JarFile jar = new JarFile(loc.toFile())) {
          jar.stream().map(JarEntry::getName).filter(n -> n.endsWith(".class") && !n.startsWith("META-INF/"))
              .forEach(names::add);
        }
      }
    }
    SortedSet<String> out = new TreeSet<>();
    for (String n : names) {
      String name = n.substring(0, n.length() - ".class".length()).replace('/', '.');
      if (name.endsWith("module-info") || name.endsWith("package-info")) continue;
      Class<?> c = Class.forName(name, false, FacadeDumpTest.class.getClassLoader());
      if (!c.isAnonymousClass() && !c.isSynthetic()) out.add(name);
    }
    return out;
  }

  /** 인스턴스 상태가 없다 — 인터페이스이거나, 계층 어디에도 비정적 필드가 없다(예외는 Throwable 의 상태를 가진다). */
  private static boolean stateless(Class<?> c) {
    if (c.isInterface()) return true;
    for (Class<?> k = c; k != null; k = k.getSuperclass()) {
      for (Field f : k.getDeclaredFields()) {
        if (!Modifier.isStatic(f.getModifiers()) && !f.isSynthetic()) return false;
      }
    }
    return true;
  }

  /** 이 타입의 인스턴스를 렌더링할 때 실제로 도는 구현 — 바닥 경로가 부르는 메서드들의 선언 클래스. */
  private static List<Class<?>> renderedBy(Class<?> c) {
    List<Class<?>> out = new ArrayList<>();
    try {
      out.add(c.getMethod("toString").getDeclaringClass());
      if (Throwable.class.isAssignableFrom(c)) {
        out.add(c.getMethod("getMessage").getDeclaringClass());
        out.add(c.getMethod("getLocalizedMessage").getDeclaringClass());
        out.add(c.getMethod("printStackTrace", PrintWriter.class).getDeclaringClass());
      }
    } catch (NoSuchMethodException e) {
      throw new AssertionError(e);
    }
    return out;
  }

  private static final class Walker {
    private record Item(Object value, String root, String path) {}

    final Set<String> reached = new TreeSet<>();
    final List<String> leaks = new ArrayList<>();
    final List<String> problems = new ArrayList<>();
    final Set<String> knownSeen = new TreeSet<>();
    int rendered;
    private final Map<String, String> canaries;
    private final Set<Path> sdk;
    private final Path harness;
    private final Map<Class<?>, Optional<Path>> locations = new HashMap<>();
    final Set<Object> seen = Collections.newSetFromMap(new IdentityHashMap<>());
    private final ArrayDeque<Item> queue = new ArrayDeque<>();

    Walker(Map<String, String> canaries, Set<Path> sdk, Path harness) {
      this.canaries = canaries;
      this.sdk = sdk;
      this.harness = harness;
    }

    void walk(String root, Object value) {
      push(value, root, root);
      while (!queue.isEmpty()) {
        Item it = queue.poll();
        step(it.value(), it.root(), it.path());
      }
    }

    private void push(Object v, String root, String path) {
      if (v != null && seen.add(v)) queue.add(new Item(v, root, path));
    }

    private Path loc(Class<?> c) {
      return locations.computeIfAbsent(c, k -> Optional.ofNullable(location(k))).orElse(null);
    }

    private boolean own(Class<?> c) {
      Path p = loc(c);
      return p != null && sdk.contains(p);
    }

    private void step(Object v, String root, String path) {
      Class<?> c = v.getClass();
      if (c.isArray()) {
        if (!c.getComponentType().isPrimitive()) {
          Object[] a = (Object[]) v;
          for (int i = 0; i < a.length; i++) push(a[i], root, path + "[" + i + "]");
        }
        return;
      }
      if (harness.equals(loc(c))) {
        problems.add(path + ": 하네스 객체(" + c.getName() + ")가 SDK 뿌리에서 닿았다 — 오염을 걷어라, 면제하지 말고");
        return;
      }
      // 소유 판정의 독립 대조 — SDK 패키지 이름인데 SDK 위치가 아니면(복사·셰이딩·코드 소스 없음) 렌더링이 빠진다.
      if (c.getName().startsWith(SDK_PACKAGE) && !own(c)) {
        problems.add(path + ": SDK 패키지의 " + c.getName() + " 이 SDK 산출물 밖(" + loc(c) + ")에서 왔다 — 소유 판정이 샌다");
      }
      if (own(c)) {
        // 상위 SDK 타입은 **같은 렌더링 구현을 쓸 때만** 닿은 것으로 센다 — 그때 그 타입의 상태 전부와 그 구현이
        // 이 인스턴스로 렌더링된다. 하위가 toString 을 덮으면 상위 자신의 렌더링은 한 번도 안 돈 것이다.
        List<Class<?>> impl = renderedBy(c);
        for (Class<?> k = c; k != null && own(k); k = k.getSuperclass()) {
          if (renderedBy(k).equals(impl)) reached.add(k.getName());
        }
        render(v, root, path, c);
      }
      if (v instanceof Throwable) {
        Throwable t = (Throwable) v;
        push(t.getCause(), root, path + ".cause");
        for (Throwable s : t.getSuppressed()) push(s, root, path + ".suppressed");
      }
      if (Proxy.isProxyClass(c)) push(Proxy.getInvocationHandler(v), root, path + ".<handler>");
      try {
        if (v instanceof Collection) {
          int i = 0;
          for (Object x : new ArrayList<>((Collection<?>) v)) push(x, root, path + "[" + i++ + "]");
        } else if (v instanceof Map) {
          for (Map.Entry<?, ?> e : new ArrayList<>(((Map<?, ?>) v).entrySet())) {
            push(e.getKey(), root, path + "{key}");
            push(e.getValue(), root, path + "{value}");
          }
        } else if (v instanceof Optional) {
          push(((Optional<?>) v).orElse(null), root, path + ".get()");
        } else if (v instanceof AtomicReference) {
          push(((AtomicReference<?>) v).get(), root, path + ".get()");
        } else if (v instanceof AtomicReferenceArray) {
          AtomicReferenceArray<?> a = (AtomicReferenceArray<?>) v;
          for (int i = 0; i < a.length(); i++) push(a.get(i), root, path + "[" + i + "]");
        } else if (v instanceof Map.Entry) {
          push(((Map.Entry<?, ?>) v).getKey(), root, path + ".key");
          push(((Map.Entry<?, ?>) v).getValue(), root, path + ".value");
        } else if (v instanceof Reference) {
          push(((Reference<?>) v).get(), root, path + ".get()");
        }
      } catch (RuntimeException e) {
        if (own(c)) problems.add(path + ": SDK 컨테이너를 못 훑었다 — " + e);
      }
      // JDK 타입은 모듈이 열리지 않아 필드를 못 읽는다 — 위의 공개 API 로만 건넌다. ⚠️ SDK 타입은 모듈과 무관하게
      // 필드를 걷는다 — 못 읽으면 아래에서 문제로 남아야지 조용히 건너뛰면 안 된다.
      if (c.getModule().isNamed() && !own(c)) return;
      for (Class<?> k = c; k != null; k = k.getSuperclass()) {
        boolean ownK = own(k);
        for (Field f : k.getDeclaredFields()) {
          if (Modifier.isStatic(f.getModifiers()) || f.getType().isPrimitive()) continue;
          if (!f.trySetAccessible()) {
            // 이름 없는 모듈(SDK·클래스패스 jar)의 필드는 늘 읽혀야 한다 — 못 읽으면 조용히 건너뛰지 않는다.
            if (ownK || !k.getModule().isNamed()) {
              problems.add(path + "." + f.getName() + ": 필드를 못 읽는다(" + k.getName() + ") — 걷기가 이 자리를 못 잰다");
            }
            continue;
          }
          try {
            push(f.get(v), root, path + "." + f.getName());
          } catch (IllegalAccessException e) {
            if (ownK) problems.add(path + "." + f.getName() + ": " + e);
          }
        }
      }
    }

    private void render(Object v, String root, String path, Class<?> c) {
      rendered++;
      Map<String, String> outs = new LinkedHashMap<>();
      outs.put("String.valueOf", String.valueOf(v));
      outs.put("toString()", v.toString());
      outs.put("\"\" + obj", "" + v);
      if (v instanceof Throwable) {
        StringWriter sw = new StringWriter();
        ((Throwable) v).printStackTrace(new PrintWriter(sw, true));
        outs.put("printStackTrace", sw.toString());
      }
      outs.forEach((how, out) -> canaries.forEach((name, secret) -> {
        if (!out.contains(secret)) return;
        String known = root + "|" + name;
        if (KNOWN_LEAKS.containsKey(known)) {
          knownSeen.add(known);
        } else {
          leaks.add(path + " [" + c.getName() + "] " + how + ": 비밀 " + name + " 이 원문으로 찍혔다");
        }
      }));
    }
  }
}
