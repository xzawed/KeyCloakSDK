package io.github.xzawed.keycloak;

import static org.junit.jupiter.api.Assertions.assertTrue;

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
import io.github.xzawed.keycloak.core.KeycloakConfig;
import io.github.xzawed.keycloak.core.exception.TokenValidationException;
import java.io.IOException;
import java.io.OutputStream;
import java.lang.reflect.Constructor;
import java.lang.reflect.Executable;
import java.lang.reflect.Field;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.lang.reflect.Modifier;
import java.lang.reflect.ParameterizedType;
import java.lang.reflect.Type;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.URI;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Base64;
import java.util.Collection;
import java.util.Comparator;
import java.util.Date;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.SortedSet;
import java.util.TreeMap;
import java.util.TreeSet;
import java.util.function.Function;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.stream.Collectors;
import java.util.stream.Stream;
import org.junit.jupiter.api.Test;

/**
 * 적대 경로 행렬 — 공개 호출 경로를 파생해 **실제로 보낸 요청**으로 가르고, 적대 변형을 메서드 손 목록이 아니라
 * **계급에** 붙인다(등록부 {@code guard-detection-surface-hand-narrowed}). Go 파일럿
 * {@code go/hostile_path_matrix_test.go}(#636 분류 · #639 W1+W3)의 Java 이식이고, 그 머리 주석의 함정을 물려받는다.
 *
 * <p>nonce·콜드캐시·토큰응답 형식 축은 {@code scripts/test/test-security-defaults.sh} 와 손 테스트가 **고른 자리**에만
 * 걸려 있다. 새 공개 교환 경로가 생기면 셋 다 그것을 모른다. 그래서 경로를 파생한다:
 * <ul>
 *   <li>선언 집합 — {@link FacadeDumpTest} 의 뿌리·걷기가 닿는 SDK 타입({@code Walker.reached})과, 클래스패스의 SDK
 *       산출물을 훑은 타입 전수({@code declaredTypes}, Go 의 「소스 선언」 자리)의 합. 그중 **공개 타입**의 공개
 *       메서드·생성자 전부(선언 클래스가 SDK 인 것만 — Object·Throwable 상속분은 뺀다, 오버로드는 따로 센다).
 *       추상 메서드는 행이 아니라 「SDK 구현 행이 있어야 한다」는 의무다 — 없으면 UNDETERMINED 행이 된다.</li>
 *   <li>호출 — 행마다 기록을 비운 IdP({@link Idp} — 서버는 하나, 경계는 칸)와 **새** 수신자. 수신자는 {@link #BUILDERS}(덜 데운 것부터)의 걷기가 닿는
 *       인스턴스이고, 어느 빌더에도 안 닿는 타입은 <b>서명에서 파생한 생산자</b>(공개 생성자 → 그 타입을 돌려주는
 *       정적 메서드 → 인스턴스 메서드)로 만든다 — Go 의 영값 수신자 자리다(Java 에는 영값 인스턴스가 없다). 인자는
 *       타입만 보고 합성한다.</li>
 *   <li>분류 — 그 호출이 IdP 에 실제로 보낸 요청으로({@link #classify}). 엔드포인트는 경로 <b>꼬리</b>로 본다.</li>
 * </ul>
 *
 * <p>단언: (1) UNDETERMINED 없음(면제는 이유와 함께 · 낡은 면제는 실패) · (2) CODE_EXCHANGE·TOKEN_GRANT·JWKS_FETCH 가
 * 각각 비지 않음 · (W1) 손으로 고른 테스트가 겨누는 메서드({@link #HAND})가 전부 행이고 기대 계급이고 그 축의 파생
 * 대상에 있다 — 표도 손 목록이라 셋과 대조한다: 앵커가 정말 그 이름을 부르는가, {@code MalformedIdpResponseTest.CALLS}
 * 의 키가 전부 표에 있고 그 호출을 이 IdP 에 돌린 계급이 표와 같은가, 보안 기본값 가드의 Java 앵커가 전부 표의 앵커인가
 * · (W3a·b·c) 계급별 적대 변형 — 각 메서드의 주석. 실패한 칸은 {@link #KNOWN_GAPS} 에 이유와 함께 있으면 GAP 이고,
 * 관측되지 않는 항목은 낡은 것이라 실패한다.
 *
 * <p>⚠️ Go 설계가 Java 에 안 맞은 자리:
 * <ul>
 *   <li><b>문자열 인자 둘.</b> 보편 인자는 이 IdP 키로 서명한 JWS 다(평문이면 validate 가 요청 전에 실패해 JWKS_FETCH
 *       가 빈다 — Go 함정 그대로). 그런데 Nimbus {@code CodeVerifier} 는 43–128 자만 받아 JWS(수백 자)를 요청 없이
 *       거부한다 — exchangeCode 두 행이 UNDETERMINED 로 빠졌다(실측). 그래서 요청 없이 실패한 행만 PKCE 에 안전한
 *       평문({@link #PLAIN})으로 **한 번** 다시 부르고, 그 행의 W3 칸도 같은 보편 인자를 쓴다. 제공하는 id_token 의
 *       nonce 는 늘 그때의 보편 인자다.</li>
 *   <li><b>매개변수 이름은 리플렉션에 없다</b>(pom 에 {@code -parameters} 없음 — 넣으면 게시 산출물의 클래스 파일이
 *       바뀐다). nonce 대상은 SDK 소스({@code src/main/java})의 선언을 읽어 파생한다.</li>
 *   <li><b>admin 은 지연 생성·무네트워크다</b> — Go 의 {@code (*Client).Admin} 은 TOKEN_GRANT 지만 Java
 *       {@code KeycloakClient.admin()} 은 NONE 이고, admin 자원 메서드가 admin-client 내장 TokenManager 로 부여한다.</li>
 *   <li><b>콜드 캐시 백오프는 SDK 가 아니라 Nimbus {@code RateLimitedJWKSetSource} 몫이다</b> — 창마다 둘을 허용하므로
 *       ({@code .claude/rules/security.md}) W3c 는 2 를 본다. 상한 k−1=4 는 그대로 성립한다.</li>
 * </ul>
 *
 * <p>⚠️ 한계(전부 NONE 으로 읽힌다 — Go 와 같다): 기록된 요청도 오류도 없이 끝나는 교환 경로, 합성 인자가 요청 앞에서
 * 갈라 세우는 것, 비동기로 나가는 요청(표는 반환 직후 찍힌다), 이 IdP 가 아닌 호스트로 나가 오류를 버리는 것. 비공개
 * 타입의 공개 메서드는 공개 API 가 아니라 행이 아니다(비공개 SDK 타입이 공개 인터페이스로 나가면 그 인터페이스의 추상
 * 메서드가 의무로 잡는다). 생산자가 만들 수 없는 수신자는 UNDETERMINED 로 드러난다.
 */
class HostilePathMatrixTest {
  static final String CODE_EXCHANGE = "CODE_EXCHANGE";
  static final String TOKEN_GRANT = "TOKEN_GRANT";
  static final String JWKS_FETCH = "JWKS_FETCH";
  static final String OTHER = "OTHER";
  static final String NONE = "NONE";
  static final String UNDETERMINED = "UNDETERMINED";
  private static final List<String> CLASSES = List.of(CODE_EXCHANGE, TOKEN_GRANT, JWKS_FETCH, OTHER, NONE, UNDETERMINED);

  private static final String REALM = "r";
  private static final String OC = "/realms/" + REALM + "/protocol/openid-connect";
  // 분류는 realm 과 무관하게 **꼬리**로 본다(Go 레그 실측: 정확한 경로로 가르면 인자로 받은 realm 의 certs 가 OTHER 였다).
  private static final String TOKEN_SUFFIX = "/protocol/openid-connect/token";
  private static final String CERTS_SUFFIX = "/protocol/openid-connect/certs";
  private static final String CLIENT_ID = "c";
  private static final String SECRET = "hp-client-secret";
  private static final String BASIC = Base64.getEncoder()
      .encodeToString((CLIENT_ID + ":" + SECRET).getBytes(StandardCharsets.UTF_8));
  /** PKCE 에 안전한 보편 인자(RFC 7636: 43–128 자, unreserved) — JWS 가 요청 없이 거부된 행만 이것으로 다시 부른다. */
  static final String PLAIN = "hpPlainUniversal-0123456789abcdefghijklmnopqrstuvwxyz";
  private static final URI CB = URI.create("https://app.example/cb");
  private static final String NOT_A_JWS = "hp-not-a-jws";
  /** 소스 파생이 공허하지 않은지 — SDK 오류 타입을 이만큼은 찾아야 한다. */
  private static final int MIN_SDK_ERRORS = 5;

  /** UNDETERMINED 여도 되는 행과 그 이유. ⚠️ 이유 없는 면제는 넣지 않는다 — 더는 UNDETERMINED 가 아니면 낡은 면제로 실패한다. */
  static final Map<String, String> UNDETERMINED_EXEMPT = Map.of(
      "KeycloakConfig.Builder.build()",
      "설정 검증 — 새 빌더는 serverUrl 이 없어 요청 없이 KeycloakConfigException 으로 거부된다(KeycloakConfig.java"
          + " require). 네트워크 경로가 아니다");

  /**
   * W3b 에서 빠져도 되는 CODE_EXCHANGE 행과 그 이유. nonce 대상은 **서명의 파라미터 이름**으로 파생하므로, nonce 를 다른
   * 이름으로 받는 새 교환 메서드는 이 표가 없으면 조용히 빠진다(Go 레그가 지목, 실측 SILENT). 낡은 항목은 실패한다.
   */
  static final Map<String, String> NONCE_DROP_EXEMPT = Map.of(
      "AuthClient.exchangeCode(String,URI,String)",
      "무-nonce 흐름 — 4 인자 판에 null 을 넘겨 id_token 검증을 건너뛰는 문서화된 계약이다(AuthClient.java 의"
          + " exchangeCode 주석). nonce 를 받는 흐름은 4 인자 판이 W3b 에서 잰다");

  /**
   * 현재 main 에서 실패하는 칸 — 키는 {@code W3<축> 행/변형}, 값은 {@code 등록부 id: 이유}. SDK 를 고치지 않고 드러내 둔다.
   * 관측되지 않는(이제 통과하거나 칸이 없는) 항목은 낡은 것이라 실패한다. ⚠️ 이유 없는 항목은 넣지 않는다.
   */
  static final Map<String, String> KNOWN_GAPS = knownGaps();

  private static Map<String, String> knownGaps() {
    Map<String, String> out = new TreeMap<>();
    // ⚠️ SDK 결함(2026-09-27 이 행렬이 처음 쟀다). admin 경로는 keycloak-admin-client 내장 TokenManager 가 토큰 응답을
    // Jackson 으로 읽는데, 그 스칼라 강제변환이 숫자·불리언·빈 문자열 access_token 을 문자열로 받아 **그 값을 bearer 로
    // admin API 를 부른다**(판정 사유의 Authorization 열) — 형식이 틀린 부여 응답을 거부하지 않는다. AuthClient 경로는
    // Nimbus TokenResponse.parse 가 같은 셋을 거부하고(AuthClientTokenTypeTest), Go admin 은 거부한다(#639).
    // MalformedIdpResponseTest b1 이 이 강제변환을 적어 두었지만 단언하지 않는다. null·객체·배열·누락은 admin 도 거부한다.
    String why = "등록부 id 미정(제안: java-admin-token-response-type-unchecked): admin-client TokenManager 의 Jackson 이 "
        + "비문자열·빈 access_token 을 강제변환해 그 값을 bearer 로 admin API 를 부른다";
    List<String> admin = List.of(
        "ClientsResource.create(ClientRepresentation)", "ClientsResource.delete(String)",
        "ClientsResource.findByClientId(String)", "ClientsResource.get(String)",
        "ClientsResource.update(String,ClientRepresentation)",
        "GroupsResource.create(GroupRepresentation)", "GroupsResource.delete(String)", "GroupsResource.get(String)",
        "GroupsResource.list(int,int)", "GroupsResource.update(String,GroupRepresentation)",
        "RealmsResource.create(RealmRepresentation)", "RealmsResource.delete(String)", "RealmsResource.get(String)",
        "RealmsResource.list()", "RealmsResource.update(String,RealmRepresentation)",
        "RolesResource.create(RoleRepresentation)", "RolesResource.delete(String)", "RolesResource.get(String)",
        "RolesResource.list()", "RolesResource.update(String,RoleRepresentation)",
        "UsersResource.create(UserRepresentation)", "UsersResource.delete(String)", "UsersResource.get(String)",
        "UsersResource.search(String,int,int)", "UsersResource.update(String,UserRepresentation)");
    for (String row : admin) {
      for (String variant : List.of("at:number", "at:bool", "at:empty_string")) out.put("W3a " + row + "/" + variant, why);
    }
    return out;
  }

  // ───────────────────────────── 기록하는 가짜 IdP ─────────────────────────────

  /** auth 는 Authorization 헤더의 앞 16 자 — 적대 토큰 뒤로 나아간 요청이 무엇을 bearer 로 실었는지 판정 사유에 싣는다. */
  record Req(String method, String path, String grant, String auth) {}

  /**
   * 모든 요청을 (메서드, 경로, 토큰 요청이면 grant_type) 으로 **라우팅 앞에서** 남긴다 — 라우트가 없는 경로(admin 404)도
   * 남는다. 분류는 SDK 가 무엇을 <b>시도했나</b>를 본다.
   *
   * <p>⚠️ <b>서버는 테스트 하나에 하나다</b>(행·칸마다 새로 띄우지 않는다). 칸마다 새 서버를 띄웠더니 한 번에 소켓 수천
   * 개가 TIME_WAIT 로 남았고, 같은 기계를 쓰는 다른 작업과 겹치자 동적 포트(16384)가 바닥나 admin 칸이 토큰 엔드포인트에
   * 닿지도 못한 채 FAIL 했다(실측 2026-09-27: loopback TIME_WAIT 5861). 칸의 경계는 서버가 아니라 {@link #activate} —
   * 기록을 비우고 칸 상태를 되돌린다. 칸은 순서대로 돌고 SDK 는 비동기 요청을 내지 않으므로 「activate 부터 snapshot
   * 까지 받은 요청」이 그 칸의 것이다(새 서버의 격리와 같다 — 비동기 경로는 머리 주석의 한계 그대로다). 클라이언트는
   * 여전히 칸마다 새것이다.
   */
  static final class Idp implements AutoCloseable {
    final RSAKey key;
    /** 이 IdP 키로 서명한 JWS — 문자열 인자의 첫 보편 인자. URL·폼·경로 어디에 들어가도 안전한 글자만 쓴다. */
    final String jws;
    private volatile String universal;
    private final HttpServer server;
    private final List<Req> reqs = new ArrayList<>();
    private final String jwks;
    private final Map<String, String> idTokens = new HashMap<>();
    /** null 이 아니면 토큰 엔드포인트가 정상 응답 대신 이것을 낸다(W3 — 수신자를 만든 **뒤에** 건다). */
    private volatile MalformedIdpResponseTest.Reply tokenReply;
    private volatile boolean certsDown;

    Idp(RSAKey key) throws IOException, JOSEException {
      this.key = key;
      this.jwks = new JWKSet(key.toPublicJWK()).toString();
      server = HttpServer.create(new InetSocketAddress(InetAddress.getLoopbackAddress(), 0), 0);
      server.createContext("/", this::handle);
      server.start();
      jws = sign(key, "k1", iss(), Map.of());
      universal = jws;
    }

    /** 새 칸 — 기록을 비우고, 보편 인자를 고르고, 토큰 응답·JWKS 를 정상으로 되돌린다. */
    void activate(boolean plain) {
      universal = plain ? PLAIN : jws;
      tokenReply = null;
      certsDown = false;
      reset();
    }

    String universal() {
      return universal;
    }

    String url() {
      return "http://127.0.0.1:" + server.getAddress().getPort();
    }

    String iss() {
      return url() + "/realms/" + REALM;
    }

    KeycloakConfig cfg() {
      return KeycloakConfig.builder().serverUrl(url()).realm(REALM).clientId(CLIENT_ID)
          .clientSecret(SECRET.toCharArray()).connectTimeout(Duration.ofSeconds(5))
          .readTimeout(Duration.ofSeconds(5)).build();
    }

    void reset() {
      synchronized (reqs) {
        reqs.clear();
      }
    }

    List<Req> snapshot() {
      synchronized (reqs) {
        return List.copyOf(reqs);
      }
    }

    void tokenReply(MalformedIdpResponseTest.Reply r) {
      tokenReply = r;
    }

    void certsDown(boolean down) {
      certsDown = down;
    }

    /** 토큰 응답의 id_token — nonce 가 보편 인자라 nonce 를 받는 교환이 검증까지 통과한다. */
    private synchronized String idToken() throws JOSEException {
      String t = idTokens.get(universal);
      if (t == null) {
        t = sign(key, "k1", iss(), Map.of("nonce", universal));
        idTokens.put(universal, t);
      }
      return t;
    }

    private void handle(HttpExchange ex) throws IOException {
      try {
        String body = new String(ex.getRequestBody().readAllBytes(), StandardCharsets.UTF_8);
        String path = ex.getRequestURI().getPath();
        String method = ex.getRequestMethod();
        String grant = "POST".equals(method) && path.endsWith(TOKEN_SUFFIX) ? form(body).get("grant_type") : null;
        String auth = ex.getRequestHeaders().getFirst("Authorization");
        synchronized (reqs) {
          reqs.add(new Req(method, path, grant, auth == null ? null : auth.substring(0, Math.min(16, auth.length()))));
        }
        MalformedIdpResponseTest.Resp r;
        if (path.equals(OC + "/token")) {
          MalformedIdpResponseTest.Reply over = tokenReply;
          // expires_in 을 기본 skew(30s)보다 짧게 준다 — 캐시가 늘 식어 있어 부여에 닿을 수 있는 메서드는 실제로 닿는다
          // (Go 함정: 300 이면 캐시가 부여 경로를 가려 TOKEN_GRANT 29→3 이 됐다).
          r = over != null ? over.reply(body, ex.getRequestHeaders().getFirst("Authorization"))
              : new MalformedIdpResponseTest.Resp(200, "application/json", "{\"access_token\":\"hp-access\","
                  + "\"token_type\":\"Bearer\",\"expires_in\":1,\"refresh_token\":\"hp-refresh\",\"id_token\":\""
                  + idToken() + "\",\"scope\":\"openid\"}");
        } else if (path.equals(OC + "/token/introspect")) {
          r = new MalformedIdpResponseTest.Resp(200, "application/json",
              "{\"active\":true,\"username\":\"svc\",\"client_id\":\"c\",\"sub\":\"u1\"}");
        } else if (path.equals(OC + "/certs")) {
          r = certsDown ? new MalformedIdpResponseTest.Resp(503, null, null)
              : new MalformedIdpResponseTest.Resp(200, "application/json", jwks);
        } else if (path.equals(OC + "/logout")) {
          r = new MalformedIdpResponseTest.Resp(204, null, null);
        } else {
          r = new MalformedIdpResponseTest.Resp(404, "application/json", "{\"error\":\"not found\"}");
        }
        send(ex, r);
      } catch (JOSEException | RuntimeException e) {
        send(ex, new MalformedIdpResponseTest.Resp(500, null, null));
      }
    }

    private static void send(HttpExchange ex, MalformedIdpResponseTest.Resp r) throws IOException {
      if (r.body() == null) {
        ex.sendResponseHeaders(r.status(), -1);
        ex.close();
        return;
      }
      byte[] bytes = r.body().getBytes(StandardCharsets.UTF_8);
      if (r.contentType() != null) ex.getResponseHeaders().add("Content-Type", r.contentType());
      ex.sendResponseHeaders(r.status(), bytes.length);
      try (OutputStream os = ex.getResponseBody()) {
        os.write(bytes);
      }
    }

    @Override public void close() {
      server.stop(0);
    }
  }

  private static Map<String, String> form(String body) {
    Map<String, String> out = new LinkedHashMap<>();
    for (String kv : body.split("&")) {
      int eq = kv.indexOf('=');
      if (eq > 0) {
        out.put(URLDecoder.decode(kv.substring(0, eq), StandardCharsets.UTF_8),
            URLDecoder.decode(kv.substring(eq + 1), StandardCharsets.UTF_8));
      }
    }
    return out;
  }

  static String sign(RSAKey key, String kid, String iss, Map<String, Object> extra) throws JOSEException {
    JWTClaimsSet.Builder b = new JWTClaimsSet.Builder().issuer(iss).subject("u1").audience(CLIENT_ID)
        .expirationTime(new Date(System.currentTimeMillis() + 300_000)).issueTime(new Date());
    extra.forEach(b::claim);
    SignedJWT jwt = new SignedJWT(new JWSHeader.Builder(JWSAlgorithm.RS256).keyID(kid).build(), b.build());
    jwt.sign(new RSASSASigner(key));
    return jwt.serialize();
  }

  // ───────────────────────────── 수신자: 빌더 · 생산자 ─────────────────────────────

  private interface Build {
    Object build(Env e) throws Exception;
  }

  /**
   * 수신자를 얻는 공개 API 뿌리 — <b>덜 데운 것부터</b>. 타입은 자기를 처음 닿게 하는 빌더의 새 인스턴스에서 불린다.
   * {@code create+validator} 는 JWS 가 아닌 문자열로 validate 를 불러 지연 생성되는 JwtValidator 만 만든다 — 파싱에서
   * 실패하므로 JWKS 에 닿지 않아 캐시·rate-limit 이 식은 채다. 어느 빌더에도 안 닿는 타입은 생산자로 만든다.
   */
  private static final List<Map.Entry<String, Build>> BUILDERS = List.of(
      Map.entry("create", Env::client),
      Map.entry("create+validator", e -> {
        KeycloakClient kc = e.client();
        try {
          kc.auth().validate(NOT_A_JWS);
        } catch (TokenValidationException expected) {
          // 지연 생성만 일으킨다 — 요청은 없다.
        }
        return kc;
      }));

  record Outcome(Object value, Throwable thrown) {}

  /** 행·칸마다 하나 — 기록을 비운 IdP({@link Idp#activate}), 새 클라이언트. 만든 것은 닫는다. */
  final class Env implements AutoCloseable {
    final Idp idp;
    final boolean plain;
    private final List<AutoCloseable> closers = new ArrayList<>();
    private final Map<Integer, Map<Class<?>, Object>> built = new HashMap<>();
    private final Map<Class<?>, String> via = new HashMap<>();

    Env(boolean plain) {
      this.idp = server;
      this.plain = plain;
      idp.activate(plain);
    }

    KeycloakClient client() {
      KeycloakClient kc = KeycloakClient.create(idp.cfg());
      closers.add(kc);
      return kc;
    }

    Map<Class<?>, Object> build(int i) throws Exception {
      Map<Class<?>, Object> f = built.get(i);
      if (f == null) {
        f = walk(BUILDERS.get(i).getValue().build(this));
        built.put(i, f);
      }
      return f;
    }

    void track(Object v) {
      if (v instanceof AutoCloseable c && own(v.getClass())) closers.add(c);
    }

    /** 타입의 인스턴스 — 빌더의 걷기가 먼저, 그다음 서명에서 파생한 생산자. 못 만들면 null. */
    Object resolve(Class<?> type, int depth) throws Exception {
      Integer bi = builderFor(type);
      if (bi != null) {
        for (Map.Entry<Class<?>, Object> f : build(bi).entrySet()) {
          if (type.isAssignableFrom(f.getKey())) {
            via.putIfAbsent(type, BUILDERS.get(bi).getKey());
            return f.getValue();
          }
        }
      }
      if (depth > 3) return null;
      for (Executable p : producers(type)) {
        Object recv = null;
        if (p instanceof Method m && !Modifier.isStatic(m.getModifiers())) {
          recv = resolve(m.getDeclaringClass(), depth + 1);
          if (recv == null) continue;
        }
        Outcome o = invoke(p, recv, args(p, Set.of(), depth + 1));
        track(o.value());
        if (o.thrown() == null && type.isInstance(o.value())) {
          via.putIfAbsent(type, label(p));
          return o.value();
        }
      }
      return null;
    }

    String via(Class<?> type) {
      return via.getOrDefault(type, "?");
    }

    Object[] args(Executable x, Set<Integer> blank, int depth) throws Exception {
      Class<?>[] ps = x.getParameterTypes();
      Type[] gs = x.getGenericParameterTypes();
      Object[] out = new Object[ps.length];
      for (int i = 0; i < ps.length; i++) {
        out[i] = blank.contains(i) ? null : arg(ps[i], i < gs.length ? gs[i] : ps[i], depth);
      }
      return out;
    }

    /** 인자 합성 — 타입만 본다. SDK 타입은 같은 IdP 위에서 만든 인스턴스다. */
    Object arg(Class<?> t, Type g, int depth) throws Exception {
      String u = idp.universal();
      if (t == String.class || t == Object.class || t == CharSequence.class) return u;
      if (t == char[].class) return u.toCharArray();
      if (t == String[].class) return new String[] {u};
      if (t == int.class || t == Integer.class) return 1;
      if (t == long.class || t == Long.class) return 1L;
      if (t == short.class || t == Short.class) return (short) 1;
      if (t == byte.class || t == Byte.class) return (byte) 1;
      if (t == double.class || t == Double.class) return 1.0;
      if (t == float.class || t == Float.class) return 1.0f;
      if (t == boolean.class || t == Boolean.class) return false;
      if (t == char.class || t == Character.class) return 'x';
      if (t == URI.class) return CB;
      if (t == Duration.class) return Duration.ofSeconds(1);
      if (t == Clock.class) return Clock.systemUTC();
      if (t == Instant.class) return Instant.now();
      if (t.isEnum()) return t.getEnumConstants()[0];
      if (own(t)) return resolve(t, depth);
      if (Throwable.class.isAssignableFrom(t)) return null;
      if (t == Optional.class) return Optional.empty();
      if (t == Map.class) return Map.of();
      if (t == List.class || t == Collection.class) return element(g).map(List::of).orElse(List.of());
      if (t == Set.class) return element(g).map(Set::of).orElse(Set.of());
      try {
        return t.getConstructor().newInstance();
      } catch (ReflectiveOperationException | RuntimeException e) {
        return null;
      }
    }

    /** 제네릭 컬렉션의 원소 하나 — 열거형 첫 상수, 그 타입의 공개 정적 상수, 또는 같은 규칙의 인자. */
    private Optional<Object> element(Type g) throws Exception {
      if (!(g instanceof ParameterizedType pt) || !(pt.getActualTypeArguments()[0] instanceof Class<?> e)) {
        return Optional.empty();
      }
      if (e.isEnum()) return Optional.of(e.getEnumConstants()[0]);
      for (Field f : e.getFields()) {
        if (Modifier.isStatic(f.getModifiers()) && f.getType() == e) return Optional.ofNullable(f.get(null));
      }
      return Optional.ofNullable(arg(e, e, 99));
    }

    @Override public void close() {
      for (int i = closers.size() - 1; i >= 0; i--) {
        try {
          closers.get(i).close();
        } catch (Exception ignored) {
          // 닫기 실패는 판정과 무관하다.
        }
      }
    }
  }

  // ───────────────────────────── 파생 상태(테스트 한 번) ─────────────────────────────

  private RSAKey key;
  private RSAKey otherKey;
  /** 기록하는 가짜 IdP — 테스트 하나에 하나({@link Idp} 주석). */
  private Idp server;
  private Path harness;
  private Set<Path> sdk;
  private final Map<Class<?>, Optional<Path>> locations = new HashMap<>();
  /** 선언 집합 — 라벨 → 공개 메서드·생성자. */
  private final Map<String, Executable> declared = new TreeMap<>();
  private final Map<Class<?>, Integer> builderOf = new LinkedHashMap<>();
  private final Map<Class<?>, List<Executable>> producerCache = new HashMap<>();

  private boolean own(Class<?> c) {
    Path p = locations.computeIfAbsent(c, k -> Optional.ofNullable(FacadeDumpTest.location(k))).orElse(null);
    return p != null && sdk.contains(p);
  }

  private Map<Class<?>, Object> walk(Object root) {
    FacadeDumpTest.Walker w = new FacadeDumpTest.Walker(Map.of(), sdk, harness);
    w.walk("root", root);
    return w.found;
  }

  private Integer builderFor(Class<?> type) {
    Integer best = null;
    for (Map.Entry<Class<?>, Integer> e : builderOf.entrySet()) {
      if (type.isAssignableFrom(e.getKey()) && (best == null || e.getValue() < best)) best = e.getValue();
    }
    return best;
  }

  /** 서명에서 파생한 생산자 — 공개 생성자(인자 적은 것부터) → 그 타입을 돌려주는 정적 메서드 → 인스턴스 메서드. */
  private List<Executable> producers(Class<?> type) {
    return producerCache.computeIfAbsent(type, t -> {
      List<Executable> ctors = new ArrayList<>();
      List<Executable> statics = new ArrayList<>();
      List<Executable> instance = new ArrayList<>();
      for (Executable x : declared.values()) {
        if (x instanceof Constructor<?> c) {
          if (t.isAssignableFrom(c.getDeclaringClass())) ctors.add(c);
        } else if (x instanceof Method m && t.isAssignableFrom(m.getReturnType()) && m.getReturnType() != Object.class) {
          (Modifier.isStatic(m.getModifiers()) ? statics : instance).add(m);
        }
      }
      ctors.sort(Comparator.comparingInt(Executable::getParameterCount).thenComparing(HostilePathMatrixTest::label));
      List<Executable> out = new ArrayList<>(ctors);
      out.addAll(statics);
      out.addAll(instance);
      return out;
    });
  }

  static Outcome invoke(Executable x, Object recv, Object[] args) {
    try {
      Object v = x instanceof Method m ? m.invoke(recv, args) : ((Constructor<?>) x).newInstance(args);
      return new Outcome(v, null);
    } catch (InvocationTargetException e) {
      return new Outcome(null, e.getCause());
    } catch (Throwable t) {
      return new Outcome(null, new AssertionError("하네스가 호출하지 못했다: " + t, t));
    }
  }

  static String simpleName(Class<?> c) {
    String n = c.getName();
    return n.substring(n.lastIndexOf('.') + 1).replace('$', '.');
  }

  static String label(Executable x) {
    String params = Arrays.stream(x.getParameterTypes()).map(Class::getSimpleName).collect(Collectors.joining(","));
    String owner = simpleName(x.getDeclaringClass());
    return x instanceof Constructor ? "new " + owner + "(" + params + ")" : owner + "." + x.getName() + "(" + params + ")";
  }

  private static boolean accessible(Class<?> c) {
    for (Class<?> k = c; k != null; k = k.getEnclosingClass()) {
      if (!Modifier.isPublic(k.getModifiers())) return false;
    }
    return true;
  }

  private static boolean needsReceiver(Executable x) {
    return x instanceof Method m && !Modifier.isStatic(m.getModifiers());
  }

  // ───────────────────────────── 분류 ─────────────────────────────

  static boolean isTokenPost(Req r) {
    return "POST".equals(r.method()) && r.path().endsWith(TOKEN_SUFFIX);
  }

  static boolean isCertsGet(Req r) {
    return "GET".equals(r.method()) && r.path().endsWith(CERTS_SUFFIX);
  }

  /**
   * 요청으로 가른다. 앞 줄이 이긴다: 코드 교환 > 토큰 부여 > JWKS 조회 > 그 밖의 요청 > 요청 없음. ⚠️ 토큰 엔드포인트
   * POST 는 grant_type 이 무엇이든 TOKEN_GRANT 다 — 새 grant 가 OTHER 로 새지 않게. grant 는 표의 요청 열에 찍힌다.
   */
  static String classify(List<Req> reqs, boolean failed) {
    if (reqs.stream().anyMatch(r -> isTokenPost(r) && "authorization_code".equals(r.grant()))) return CODE_EXCHANGE;
    if (reqs.stream().anyMatch(HostilePathMatrixTest::isTokenPost)) return TOKEN_GRANT;
    if (reqs.stream().anyMatch(HostilePathMatrixTest::isCertsGet)) return JWKS_FETCH;
    if (!reqs.isEmpty()) return OTHER;
    return failed ? UNDETERMINED : NONE;
  }

  static String format(List<Req> reqs, String universal) {
    if (reqs.isEmpty()) return "-";
    Map<String, Integer> count = new LinkedHashMap<>();
    for (Req r : reqs) {
      String p = r.path().startsWith(OC) ? r.path().substring(OC.length()) : r.path();
      if (universal != null && !universal.isEmpty()) p = p.replace(universal, "{U}");
      String k = r.method() + " " + p + (r.grant() == null ? "" : "[" + r.grant() + "]");
      count.merge(k, 1, Integer::sum);
    }
    return count.entrySet().stream().map(e -> e.getValue() > 1 ? e.getKey() + " ×" + e.getValue() : e.getKey())
        .collect(Collectors.joining(", "));
  }

  static int count(List<Req> reqs, java.util.function.Predicate<Req> p) {
    return (int) reqs.stream().filter(p).count();
  }

  // ───────────────────────────── 행 ─────────────────────────────

  record Row(String label, String cls, String reqs, String recv, String outcome, String note, List<Req> sent,
      Executable x, boolean plain) {}

  private Row run(Executable x) throws Exception {
    Row last = null;
    for (boolean plain : new boolean[] {false, true}) {
      try (Env e = new Env(plain)) {
        Object recv = null;
        String src = needsReceiver(x) ? null : x instanceof Constructor ? "생성자" : "정적";
        if (src == null) {
          recv = e.resolve(x.getDeclaringClass(), 0);
          src = recv == null ? "없음" : e.via(x.getDeclaringClass());
        }
        Object[] a = e.args(x, Set.of(), 1);
        e.idp.reset(); // 수신자·인자를 만들며 나간 요청은 이 메서드의 몫이 아니다
        Outcome o = needsReceiver(x) && recv == null ? new Outcome(null, null) : invoke(x, recv, a);
        e.track(o.value());
        List<Req> sent = e.idp.snapshot();
        boolean noRecv = needsReceiver(x) && recv == null;
        String cls = classify(sent, noRecv || o.thrown() != null);
        String outcome = noRecv ? "-" : o.thrown() == null ? "ok" : "err";
        String note = "";
        if (cls.equals(UNDETERMINED)) {
          note = noRecv ? " · 수신자를 만들 빌더·생산자가 없다" : " · " + brief(o.thrown());
        }
        Row r = new Row(label(x), cls, format(sent, e.idp.universal()), src, outcome, note, sent, x, plain);
        if (!cls.equals(UNDETERMINED)) return r;
        last = r;
      }
    }
    return last;
  }

  private static String brief(Throwable t) {
    if (t == null) return "?";
    String m = String.valueOf(t.getMessage());
    return t.getClass().getSimpleName() + ": " + (m.length() > 120 ? m.substring(0, 120) + "…" : m);
  }

  // ───────────────────────────── 테스트 ─────────────────────────────

  @Test
  void hostilePathMatrix() throws Exception {
    key = new RSAKeyGenerator(2048).keyID("k1").generate();
    otherKey = new RSAKeyGenerator(2048).keyID("k1").generate();
    try (Idp idp = new Idp(key)) {
      server = idp;
      matrix();
    } finally {
      server = null;
    }
  }

  private void matrix() throws Exception {
    harness = FacadeDumpTest.location(FacadeDumpTest.class);
    sdk = FacadeDumpTest.sdkLocations(harness);
    List<String> fails = new ArrayList<>();

    // 선언 집합 — 걷기가 닿은 타입 ∪ 산출물의 타입 전수.
    SortedSet<String> source = FacadeDumpTest.declaredTypes(sdk);
    Set<String> reached = dumpReached();
    for (String r : reached) {
      if (!source.contains(r)) fails.add("파생 불일치: 걷기가 " + r + " 에 닿았는데 산출물 전수에 없다");
    }
    Set<String> typeNames = new TreeSet<>(source);
    typeNames.addAll(reached);
    int fromWalk = 0;
    List<Method> abstracts = new ArrayList<>();
    Set<Class<?>> sdkErrors = new LinkedHashSet<>();
    for (String name : typeNames) {
      Class<?> t = Class.forName(name, false, getClass().getClassLoader());
      if (Throwable.class.isAssignableFrom(t) && accessible(t)) sdkErrors.add(t);
      if (!accessible(t)) continue; // 비공개 타입의 공개 메서드는 공개 API 가 아니다
      int before = declared.size();
      for (Method m : t.getMethods()) {
        if (!own(m.getDeclaringClass()) || m.isSynthetic() || m.isBridge()) continue;
        if (Modifier.isAbstract(m.getModifiers())) {
          abstracts.add(m);
        } else {
          declared.putIfAbsent(label(m), m);
        }
      }
      if (!Modifier.isAbstract(t.getModifiers()) && !t.isInterface()) {
        for (Constructor<?> c : t.getConstructors()) declared.putIfAbsent(label(c), c);
      }
      if (reached.contains(name)) fromWalk += declared.size() - before;
    }
    if (sdkErrors.size() < MIN_SDK_ERRORS) fails.add("SDK 오류 타입을 거의 못 찾았다 — 파생이 공허하다: " + sdkErrors);

    // 빌더 탐침 — 타입마다 처음 닿게 하는 빌더(버리는 IdP 위에서).
    for (int i = 0; i < BUILDERS.size(); i++) {
      try (Env e = new Env(false)) {
        for (Class<?> c : e.build(i).keySet()) builderOf.putIfAbsent(c, i);
      }
    }

    List<Row> rows = new ArrayList<>();
    Map<String, Row> byLabel = new LinkedHashMap<>();
    for (Executable x : declared.values()) {
      Row r = run(x);
      rows.add(r);
      byLabel.put(r.label(), r);
    }
    // 추상 메서드의 의무 — SDK 구현 행이 하나는 있어야 한다.
    for (Method a : abstracts) {
      boolean covered = declared.values().stream().anyMatch(x -> x instanceof Method m && !m.equals(a)
          && m.getName().equals(a.getName()) && Arrays.equals(m.getParameterTypes(), a.getParameterTypes())
          && a.getDeclaringClass().isAssignableFrom(m.getDeclaringClass()));
      if (!covered && !byLabel.containsKey(label(a))) {
        Row r = new Row(label(a), UNDETERMINED, "-", "없음", "-",
            " · 추상 메서드인데 SDK 구현 행이 없다(구현을 뿌리에 닿게 하거나 이유와 함께 면제하라)", List.of(), a, false);
        rows.add(r);
        byLabel.put(r.label(), r);
      }
    }
    Map<String, Integer> counts = logTable(rows, fromWalk, abstracts.size());

    // (1) UNDETERMINED 없음 — 면제는 이유와 함께, 낡은 면제는 실패.
    for (Row r : rows) {
      if (r.cls().equals(UNDETERMINED) && !UNDETERMINED_EXEMPT.containsKey(r.label())) {
        fails.add(r.label() + ": 분류하지 못했다(UNDETERMINED) — 인자 합성·수신자를 고치거나 이유와 함께 면제하라" + r.note());
      }
    }
    UNDETERMINED_EXEMPT.forEach((label, why) -> {
      Row r = byLabel.get(label);
      if (r == null || !r.cls().equals(UNDETERMINED)) {
        fails.add(label + ": 낡은 면제다 — 선언 집합에 없거나 더는 UNDETERMINED 가 아니다(" + why + ")");
      }
    });
    // (2) 세 교환 계급이 각각 비지 않는다 — 비면 분류기·가짜 IdP·인자 합성 중 하나가 공허해진 것이다.
    for (String c : List.of(CODE_EXCHANGE, TOKEN_GRANT, JWKS_FETCH)) {
      if (counts.getOrDefault(c, 0) == 0) fails.add(c + " 계급이 비었다 — 교환 경로를 하나도 못 찾았다");
    }

    // 손 테스트의 호출을 같은 IdP·분류기에 돌린다 — W1 대조와 W3a 의 「그 테스트가 단언하는 계급」에 쓴다.
    Map<String, String> callClass = classifyExistingCalls();

    // W3 — 대상은 전부 파생이다: (a) 계급 · (b) 계급 ∩ 서명 · (c) 분류 실행이 보낸 요청.
    Map<String, List<Integer>> nonceParams = nonceParams(rows, fails);
    Map<String, List<Row>> tgt = new HashMap<>();
    for (String axis : List.of("a", "b", "c")) tgt.put(axis, new ArrayList<>());
    List<String> late = new ArrayList<>();
    for (Row r : rows) {
      if (r.x() == null || r.recv().equals("없음") || r.x() instanceof Method m && Modifier.isAbstract(m.getModifiers())) {
        continue;
      }
      if (r.cls().equals(TOKEN_GRANT) || r.cls().equals(CODE_EXCHANGE)) tgt.get("a").add(r);
      if (r.cls().equals(CODE_EXCHANGE)) {
        if (!nonceParams.getOrDefault(r.label(), List.of()).isEmpty()) {
          tgt.get("b").add(r);
        } else if (NONCE_DROP_EXEMPT.containsKey(r.label())) {
          log("(b) nonce 파라미터가 없어 빠진 CODE_EXCHANGE 행: " + r.label() + " — " + NONCE_DROP_EXEMPT.get(r.label()));
        } else {
          late.add("W3b " + r.label() + ": CODE_EXCHANGE 인데 이름에 nonce 가 든 파라미터가 없어 W3b 가 붙지 않는다 — nonce 를"
              + " 그 이름으로 받게 하거나, 정말 nonce 없는 흐름이면 이유와 함께 NONCE_DROP_EXEMPT 에 적어라");
        }
      }
      if (count(r.sent(), HostilePathMatrixTest::isCertsGet) > 0) tgt.get("c").add(r);
    }
    NONCE_DROP_EXEMPT.forEach((label, why) -> {
      Row r = byLabel.get(label);
      if (r == null || !r.cls().equals(CODE_EXCHANGE) || !nonceParams.getOrDefault(label, List.of()).isEmpty()) {
        late.add("NONCE_DROP_EXEMPT[" + label + "]: 낡은 면제다 — nonce 파라미터 없는 CODE_EXCHANGE 행이 아니다(" + why + ")");
      }
    });

    List<Cell> cells = new ArrayList<>();
    cells.addAll(runVariantsA(tgt.get("a"), nonceParams, sdkErrors, callClass, byLabel));
    cells.addAll(runNonceB(tgt.get("b"), nonceParams, sdkErrors));
    cells.addAll(runColdJwksC(tgt.get("c"), sdkErrors));
    List<String> judged = judge(cells);

    // W1 — 손 목록 포함.
    List<String> hand = checkHand(byLabel, tgt, callClass);
    fails.addAll(late);
    fails.addAll(hand);
    fails.addAll(judged);
    for (String f : fails) log("FAIL " + f);
    logSummaries(counts, cells);
    assertTrue(fails.isEmpty(), () -> fails.size() + " 건:\n" + String.join("\n", fails));
  }

  /** {@link FacadeDumpTest} 의 뿌리·걷기가 닿는 SDK 타입 — 그 테스트의 가짜 IdP 위에서, 카나리아 검사 없이. */
  private Set<String> dumpReached() throws Exception {
    List<AutoCloseable> closers = new ArrayList<>();
    try (FacadeDumpTest.FakeIdp fidp = new FacadeDumpTest.FakeIdp(key)) {
      Map<String, Object> roots = FacadeDumpTest.roots(fidp, key, new LinkedHashMap<>(), closers);
      FacadeDumpTest.Walker w = new FacadeDumpTest.Walker(Map.of(), sdk, harness);
      roots.forEach(w::walk);
      return new TreeSet<>(w.reached);
    } finally {
      for (AutoCloseable c : closers) c.close();
    }
  }

  private static void log(String s) {
    System.out.println("HP " + s);
  }

  private Map<String, Integer> logTable(List<Row> rows, int fromWalk, int abstractCount) {
    Map<String, Integer> counts = new LinkedHashMap<>();
    log("선언 집합 " + rows.size() + " 행(걷기가 닿은 타입의 것 " + fromWalk + " · 산출물에만 있는 타입의 것 "
        + (rows.size() - fromWalk) + " · 추상 의무 " + abstractCount + ") — 경로의 " + OC + " 는 생략, {U} 는 보편 인자");
    for (Row r : rows) {
      counts.merge(r.cls(), 1, Integer::sum);
      log(String.format("%-62s → %-13s · %s  [수신자 %s · %s · %s]%s", r.label(), r.cls(), r.reqs(), r.recv(),
          r.plain() ? "plain" : "jws", r.outcome(), r.note()));
    }
    log("계급별: " + CLASSES.stream().map(c -> c + " " + counts.getOrDefault(c, 0)).collect(Collectors.joining(" · ")));
    return counts;
  }

  // ───────────────────────────── 손 테스트 · 소스 ─────────────────────────────

  private Path javaRoot() {
    return harness.getParent().getParent().getParent(); // java/keycloak-sdk/target/test-classes → java
  }

  private final Map<String, String> testSources = new HashMap<>();

  /** java/ 아래 테스트 소스에서 파일 하나 — 정확히 하나여야 한다. */
  private String testSource(String fileName) throws IOException {
    String cached = testSources.get(fileName);
    if (cached != null) return cached;
    List<Path> hits;
    try (Stream<Path> s = Files.walk(javaRoot())) {
      hits = s.filter(p -> p.getFileName().toString().equals(fileName))
          .filter(p -> p.toString().replace('\\', '/').contains("/src/test/java/")).toList();
    }
    if (hits.size() != 1) throw new AssertionError(fileName + ": 테스트 소스가 정확히 하나가 아니다 — " + hits);
    String src = Files.readString(hits.get(0));
    testSources.put(fileName, src);
    return src;
  }

  /**
   * SDK 소스 파일 — 클래스의 산출물 위치에서 모듈을 거슬러 src/main/java 로 간다. ⚠️ 산출물은 둘 중 하나다:
   * {@code mvn test} 는 형제 모듈의 {@code target/classes}, {@code mvn verify} 는 그 모듈의 {@code target/*.jar}(실측 —
   * 디렉터리만 받던 첫 판이 verify 에서 실패했다). 둘 다 부모의 부모가 모듈이다.
   */
  private String mainSource(Class<?> c) throws IOException {
    Class<?> top = c;
    while (top.getEnclosingClass() != null) top = top.getEnclosingClass();
    Path loc = FacadeDumpTest.location(top);
    Path src = loc == null ? null : loc.getParent().getParent().resolve("src/main/java")
        .resolve(top.getName().replace('.', '/') + ".java");
    if (src == null || !Files.isRegularFile(src)) {
      throw new AssertionError(top.getName() + ": 산출물(" + loc + ") 옆에서 소스를 못 찾았다 — " + src);
    }
    return Files.readString(src);
  }

  /** 주석과 문자열·문자 리터럴의 **내용**을 공백으로 지운다(길이 보존) — 괄호·중괄호 짝과 선언 정규식이 그 안에 속지 않게. */
  static String blankLiterals(String s) {
    StringBuilder out = new StringBuilder(s);
    int i = 0;
    while (i < s.length()) {
      char ch = s.charAt(i);
      if (ch == '/' && i + 1 < s.length() && s.charAt(i + 1) == '/') {
        int end = s.indexOf('\n', i);
        end = end < 0 ? s.length() : end;
        for (int k = i; k < end; k++) out.setCharAt(k, ' ');
        i = end;
      } else if (ch == '/' && i + 1 < s.length() && s.charAt(i + 1) == '*') {
        int end = s.indexOf("*/", i + 2);
        end = end < 0 ? s.length() : end + 2;
        for (int k = i; k < end; k++) if (s.charAt(k) != '\n') out.setCharAt(k, ' ');
        i = end;
      } else if (ch == '"' || ch == '\'') {
        int k = i + 1;
        while (k < s.length() && s.charAt(k) != ch) {
          if (s.charAt(k) == '\\') k++;
          k++;
        }
        for (int j = i + 1; j < k && j < s.length(); j++) out.setCharAt(j, ' ');
        i = k + 1;
      } else {
        i++;
      }
    }
    return out.toString();
  }

  // 수식어·반환 타입은 한 글자 클래스의 반복으로만 건넌다 — 그룹 반복은 Java 정규식이 반복마다 재귀한다(Sonar S5998,
  // AuthClient.describe 의 교훈). `(`·`{`·`;`·`=` 를 못 건너므로 필드·클래스 선언에는 걸리지 않는다.
  private static final Pattern DECL = Pattern.compile("\\bpublic\\b[^;{}()=]*?\\b(\\w+)\\s*\\(([^()]*)\\)");

  /** 소스 선언(공개 메서드·생성자) — 이름, 지운 타입의 단순 이름 목록, 파라미터 이름 목록. */
  record SrcDecl(String name, List<String> types, List<String> names) {}

  static List<SrcDecl> parseDecls(String src) {
    String clean = blankLiterals(src);
    List<SrcDecl> out = new ArrayList<>();
    Matcher m = DECL.matcher(clean);
    while (m.find()) {
      List<String> types = new ArrayList<>();
      List<String> names = new ArrayList<>();
      for (String p : splitTopLevel(m.group(2))) {
        String q = p.replaceAll("@\\w+(\\([^)]*\\))?", "").replaceAll("\\bfinal\\b", "").trim();
        if (q.isEmpty()) continue;
        int sp = q.lastIndexOf(' ');
        String type = q.substring(0, sp).trim();
        names.add(q.substring(sp + 1).trim());
        types.add(erase(type));
      }
      out.add(new SrcDecl(m.group(1), types, names));
    }
    return out;
  }

  private static List<String> splitTopLevel(String params) {
    List<String> out = new ArrayList<>();
    int depth = 0;
    int start = 0;
    for (int i = 0; i < params.length(); i++) {
      char c = params.charAt(i);
      if (c == '<') depth++;
      else if (c == '>') depth--;
      else if (c == ',' && depth == 0) {
        out.add(params.substring(start, i));
        start = i + 1;
      }
    }
    out.add(params.substring(start));
    return out;
  }

  private static String erase(String type) {
    String t = type.replace("...", "[]");
    StringBuilder noGen = new StringBuilder();
    int depth = 0;
    for (char c : t.toCharArray()) {
      if (c == '<') depth++;
      else if (c == '>') depth--;
      else if (depth == 0 && !Character.isWhitespace(c)) noGen.append(c);
    }
    String s = noGen.toString();
    int dims = s.indexOf('[');
    String base = dims < 0 ? s : s.substring(0, dims);
    String arr = dims < 0 ? "" : s.substring(dims);
    return base.substring(base.lastIndexOf('.') + 1) + arr;
  }

  /**
   * 행마다 이름에 "nonce" 가 든(대소문자 무시) 파라미터의 위치 — **이름 목록이 아니라 소스의 서명에서** 얻는다.
   * CODE_EXCHANGE 행의 선언을 소스에서 못 찾으면 대상을 파생할 수 없으니 실패다.
   */
  private Map<String, List<Integer>> nonceParams(List<Row> rows, List<String> fails) throws IOException {
    Map<String, List<Integer>> out = new TreeMap<>();
    Map<Class<?>, List<SrcDecl>> cache = new HashMap<>();
    for (Row r : rows) {
      if (r.x() == null || !r.cls().equals(CODE_EXCHANGE) && !r.cls().equals(TOKEN_GRANT)) continue;
      Executable x = r.x();
      Class<?> top = x.getDeclaringClass();
      while (top.getEnclosingClass() != null) top = top.getEnclosingClass();
      List<SrcDecl> decls = cache.get(top);
      if (decls == null) {
        decls = parseDecls(mainSource(top));
        cache.put(top, decls);
      }
      String name = x instanceof Constructor ? x.getDeclaringClass().getSimpleName() : x.getName();
      List<String> types = Arrays.stream(x.getParameterTypes()).map(Class::getSimpleName).toList();
      Optional<SrcDecl> d = decls.stream().filter(s -> s.name().equals(name) && s.types().equals(types)).findFirst();
      if (d.isEmpty()) {
        if (r.cls().equals(CODE_EXCHANGE)) fails.add(r.label() + ": 소스에서 선언을 못 찾아 nonce 파라미터를 파생할 수 없다");
        continue;
      }
      List<Integer> idx = new ArrayList<>();
      for (int i = 0; i < d.get().names().size(); i++) {
        if (d.get().names().get(i).toLowerCase(java.util.Locale.ROOT).contains("nonce")) idx.add(i);
      }
      out.put(r.label(), idx);
    }
    log("(b) nonce 파라미터(소스 서명에서 파생 — 위치): " + out.entrySet().stream().filter(e -> !e.getValue().isEmpty())
        .map(e -> e.getKey() + e.getValue()).collect(Collectors.joining(", ")));
    return out;
  }

  /**
   * 메서드 선언 {@code name(…) [throws …] {} 의 중괄호 블록(반환 타입 무관 — 호출은 {@code ;}·{@code )} 로 끝나 걸리지
   * 않는다). 리터럴을 지운 사본에서 짝을 맞추고 원문을 돌려준다.
   */
  static String methodBody(String src, String method) {
    String clean = blankLiterals(src);
    Matcher m = Pattern.compile("\\b" + Pattern.quote(method) + "\\s*\\([^;{)]*\\)\\s*(?:throws\\s+[\\w.,\\s]+)?\\{")
        .matcher(clean);
    if (!m.find()) return null;
    int open = m.end() - 1;
    int depth = 0;
    for (int i = open; i < clean.length(); i++) {
      if (clean.charAt(i) == '{') depth++;
      else if (clean.charAt(i) == '}' && --depth == 0) return src.substring(open, i + 1);
    }
    return null;
  }

  private static boolean calls(String code, String name) {
    return code.contains("." + name + "(") || code.contains("::" + name);
  }

  /** {@code MalformedIdpResponseTest.CALLS} 를 이 IdP 에 돌려 가른다 — 키 → 계급. */
  private Map<String, String> classifyExistingCalls() throws Exception {
    MalformedIdpResponseTest.signValidateJwt(key);
    Map<String, String> out = new LinkedHashMap<>();
    for (Map.Entry<String, MalformedIdpResponseTest.Call> c : MalformedIdpResponseTest.CALLS.entrySet()) {
      try (Env e = new Env(false)) {
        KeycloakClient kc = e.client();
        e.idp.reset();
        boolean failed = false;
        try {
          c.getValue().run(kc);
        } catch (Exception ex) {
          failed = true;
        }
        out.put(c.getKey(), classify(e.idp.snapshot(), failed));
      }
    }
    log("W1 MalformedIdpResponseTest.CALLS 를 이 IdP 에 돌린 계급: " + out);
    return out;
  }

  // ───────────────────────────── W1: 손 목록 포함 ─────────────────────────────

  /**
   * 손으로 고른 Java 테스트가 겨누는 메서드 — 파생 집합이 이것 밑으로 <b>조용히</b> 줄지 않게 한다. anchor 는 그 손
   * 테스트({@code 파일|메서드} 또는 {@code MalformedIdpResponseTest.java|CALLS[키]}), call 은 그 앵커가 실제로 부르는
   * 공개 이름이다 — 앵커가 같은 파일의 도우미를 거쳐 부르면 {@code 도우미>이름}(한 단계씩 대조한다). axis: a·b·c = 그 W3
   * 축의 파생 대상에 있어야 한다 · row = 행이고 계급이 맞기만 하면 된다.
   */
  record Hand(String label, String cls, String axis, String anchor, String call) {}

  static final List<Hand> HAND = List.of(
      // MalformedIdpResponseTest(#617)의 공개 호출 아홉 — Go 의 causeRun 자리.
      new Hand("AuthClient.clientCredentialsToken()", TOKEN_GRANT, "a",
          "MalformedIdpResponseTest.java|CALLS[clientCredentialsToken]", "clientCredentialsToken"),
      new Hand("AuthClient.exchangeCode(String,URI,String)", CODE_EXCHANGE, "a",
          "MalformedIdpResponseTest.java|CALLS[exchangeCode]", "exchangeCode"),
      new Hand("AuthClient.exchangeCode(String,URI,String,String)", CODE_EXCHANGE, "a",
          "MalformedIdpResponseTest.java|CALLS[exchangeCode+nonce]", "exchangeCode"),
      new Hand("AuthClient.refresh(String)", TOKEN_GRANT, "a", "MalformedIdpResponseTest.java|CALLS[refresh]", "refresh"),
      new Hand("ClientCredentialsTokenProvider.getAccessToken()", TOKEN_GRANT, "a",
          "MalformedIdpResponseTest.java|CALLS[ClientCredentialsTokenProvider]", "getAccessToken"),
      new Hand("AuthClient.introspect(String)", OTHER, "row", "MalformedIdpResponseTest.java|CALLS[introspect]",
          "introspect"),
      new Hand("AuthClient.logout(String)", OTHER, "row", "MalformedIdpResponseTest.java|CALLS[logout]", "logout"),
      new Hand("UsersResource.get(String)", TOKEN_GRANT, "a", "MalformedIdpResponseTest.java|CALLS[admin().users().get]",
          "get"),
      new Hand("AuthClient.validate(String)", JWKS_FETCH, "c", "MalformedIdpResponseTest.java|CALLS[validate]",
          "validate"),
      // 보안 기본값 가드(scripts/test/test-security-defaults.sh)의 Java 앵커 — nonce 셋 · 토큰 타입 · 빈 JWKS.
      new Hand("AuthClient.exchangeCode(String,URI,String,String)", CODE_EXCHANGE, "b",
          "AuthClientNonceTest.java|exchangeCode_rejectsMismatchedNonce_endToEnd", "exchangeCode"),
      new Hand("AuthClient.exchangeCode(String,URI,String,String)", CODE_EXCHANGE, "b",
          "AuthClientNonceTest.java|exchangeCode_rejectsMissingIdToken_whenNonceExpected", "exchangeCode"),
      new Hand("AuthClient.exchangeCode(String,URI,String,String)", CODE_EXCHANGE, "b",
          "AuthClientNonceTest.java|exchangeCode_rejectsIdTokenWithoutNonceClaim", "exchangeCode"),
      new Hand("AuthClient.clientCredentialsToken()", TOKEN_GRANT, "a",
          "AuthClientTokenTypeTest.java|clientCredentialsToken_rejectsNonStringOrEmptyAccessToken", "clientCredentialsToken"),
      new Hand("JwtValidator.validate(String)", JWKS_FETCH, "c", "JwksEmptyKeysetTest.java|empty200_doesNotPoisonGoodCache",
          "validate"),
      // 가드의 백오프 축은 JVM 을 뺀다(Nimbus 가 fetch 를 소유) — Java 의 콜드 캐시 손 테스트가 그 자리다.
      new Hand("JwtValidator.validate(String)", JWKS_FETCH, "c", "JwksColdCacheOutageTest.java|coldCacheDuringIdpOutage_isBounded",
          "run>validate"));

  /** 가드가 Java 행위 앵커를 적는 두 모양 — {@code java/…/X.java|void m(} 와 {@code "java/…/X.java" "m"}. */
  private static final Pattern SCRIPT_ANCHOR = Pattern.compile(
      "java/[A-Za-z0-9_./-]*/([A-Za-z0-9_]+Test\\.java)(?:\\|void ([A-Za-z0-9_]+)\\(|\"\\s+\"([A-Za-z0-9_]+)\")");

  private List<String> checkHand(Map<String, Row> byLabel, Map<String, List<Row>> tgt, Map<String, String> callClass)
      throws IOException {
    List<String> why = new ArrayList<>();
    Set<String> anchors = new TreeSet<>();
    Set<String> tableCalls = new TreeSet<>();
    String malformed = testSource("MalformedIdpResponseTest.java");
    for (Hand h : HAND) {
      anchors.add(h.anchor());
      Row r = byLabel.get(h.label());
      if (r == null) {
        why.add("W1 " + h.label() + ": 손 테스트(" + h.anchor() + ")가 겨누는데 파생 집합에 행이 없다");
      } else if (!r.cls().equals(h.cls())) {
        why.add("W1 " + h.label() + ": 손 테스트(" + h.anchor() + ")가 겨누는 계급은 " + h.cls() + " 인데 파생은 " + r.cls());
      } else if (!h.axis().equals("row") && tgt.get(h.axis()).stream().noneMatch(t -> t.label().equals(h.label()))) {
        why.add("W1 " + h.label() + ": 손 테스트(" + h.anchor() + ")가 겨누는데 W3" + h.axis() + " 의 파생 대상에 없다");
      }
      String[] chain = h.call().split(">");
      String call = chain[chain.length - 1];
      if (!h.label().contains("." + call + "(")) {
        why.add("W1 " + h.label() + ": 표의 이름(" + call + ")이 행의 메서드가 아니다");
      }
      String[] a = h.anchor().split("\\|", 2);
      String code;
      if (a[1].startsWith("CALLS[")) {
        String k = a[1].substring("CALLS[".length(), a[1].length() - 1);
        tableCalls.add(k);
        code = callsLine(malformed, k);
        String got = callClass.get(k);
        if (got == null) {
          why.add("W1 " + h.anchor() + ": CALLS 에 그 키가 없다 — 손 테스트가 바뀌었으면 표를 따라 고쳐라");
        } else if (!got.equals(h.cls())) {
          why.add("W1 " + h.anchor() + ": 그 호출을 이 IdP 에 돌린 계급은 " + got + " 인데 표는 " + h.cls());
        }
      } else {
        String file = testSource(a[0]);
        code = methodBody(file, a[1]);
        for (int i = 0; code != null && i < chain.length - 1; i++) {
          if (!Pattern.compile("\\b" + Pattern.quote(chain[i]) + "\\(").matcher(code).find()) {
            why.add("W1 " + h.anchor() + ": 앵커가 도우미 " + chain[i] + "( 를 부르지 않는다 — 손 테스트의 대상이 바뀌었다");
          }
          code = methodBody(file, chain[i]);
        }
      }
      if (code == null) {
        why.add("W1 " + h.anchor() + ": 앵커가 없다 — 손 테스트가 옮겨졌으면 표를 따라 고쳐라");
      } else if (!calls(code, call)) {
        why.add("W1 " + h.anchor() + ": 앵커가 ." + call + "( 를 부르지 않는다 — 손 테스트의 대상이 바뀌었다");
      }
    }
    // CALLS 의 키는 전부 표에 있다 — 손 테스트에 호출이 늘면 여기가 먼저 운다.
    for (String k : MalformedIdpResponseTest.CALLS.keySet()) {
      if (!tableCalls.contains(k)) why.add("W1 MalformedIdpResponseTest.CALLS 에 " + k + " 가 있는데 HAND 에 없다");
    }
    if (MalformedIdpResponseTest.CALLS.isEmpty()) why.add("W1 CALLS 가 비었다 — 대조가 공허하다");
    // 보안 기본값 가드의 Java 행위 앵커는 전부 표의 앵커다 — 가드에 Java 앵커가 늘면 여기가 운다.
    Path script = javaRoot().getParent().resolve("scripts/test/test-security-defaults.sh");
    Matcher m = SCRIPT_ANCHOR.matcher(Files.readString(script));
    int found = 0;
    while (m.find()) {
      found++;
      String anchor = m.group(1) + "|" + (m.group(2) != null ? m.group(2) : m.group(3));
      if (!anchors.contains(anchor)) why.add("W1 보안 기본값 가드의 Java 앵커 " + anchor + " 가 HAND 에 없다");
    }
    if (found == 0) why.add("W1 test-security-defaults.sh 에서 Java 행위 앵커를 하나도 못 읽었다 — 적는 모양이 바뀌었나?");
    log("W1 손 목록 " + HAND.size() + " 항목 · 앵커 " + anchors.size() + " — CALLS " + MalformedIdpResponseTest.CALLS.size()
        + " · 보안 기본값 가드의 Java 행위 앵커 " + found + " 와 대조");
    return why;
  }

  /** {@code CALLS.put(CONST, kc -> …);} 의 본문 — CONST 는 그 파일의 {@code String CONST = "키";} 로 푼다. */
  private static String callsLine(String src, String key) {
    Matcher c = Pattern.compile("static final String (\\w+) = \"" + Pattern.quote(key) + "\";").matcher(src);
    if (!c.find()) return null;
    Matcher p = Pattern.compile("CALLS\\.put\\(" + c.group(1) + ",\\s*(.*?)\\);", Pattern.DOTALL).matcher(src);
    return p.find() ? p.group(1) : null;
  }

  // ───────────────────────────── W3: 계급별 적대 변형 ─────────────────────────────

  /** 판정표의 한 칸. why 가 비면 통과, measure 면 단언하지 않고 결과만 찍는다. */
  record Cell(String axis, String label, String variant, List<String> why, boolean measure, String note) {
    String key() {
      return "W3" + axis + " " + label + "/" + variant;
    }
  }

  record CellRun(List<Req> sent, List<Outcome> outcomes, String universal) {}

  /** 수신자를 정상 응답 위에서 새로 만든 **뒤에** 토큰 응답·JWKS 를 바꾸고 times 번 부른다. */
  private CellRun cell(Row row, Set<Integer> blank, Function<Idp, MalformedIdpResponseTest.Reply> reply,
      boolean certsDown, int times) throws Exception {
    try (Env e = new Env(row.plain())) {
      Executable x = row.x();
      Object recv = needsReceiver(x) ? e.resolve(x.getDeclaringClass(), 0) : null;
      Object[] a = e.args(x, blank, 1);
      e.idp.reset();
      e.idp.tokenReply(reply == null ? null : reply.apply(e.idp));
      e.idp.certsDown(certsDown);
      List<Outcome> outs = new ArrayList<>();
      for (int i = 0; i < times; i++) {
        Outcome o = invoke(x, recv, a);
        e.track(o.value());
        outs.add(o);
      }
      return new CellRun(e.idp.snapshot(), outs, e.idp.universal());
    }
  }

  private static boolean sdkError(Throwable t, Set<Class<?>> sdkErrors) {
    return t != null && sdkErrors.contains(t.getClass());
  }

  /** 토큰 요청 수와, 첫 토큰 요청 **뒤에** 나간 토큰 아닌 요청. */
  private static List<Req> afterToken(List<Req> reqs) {
    List<Req> after = new ArrayList<>();
    boolean seen = false;
    for (Req r : reqs) {
      if (isTokenPost(r)) seen = true;
      else if (seen) after.add(r);
    }
    return after;
  }

  /**
   * 토큰 응답 변형 — 새로 만들지 않고 기존 테스트에서 가져온다. 계급은 원 테스트의 호출을 이 IdP·분류기에 돌려 정한다.
   * {@code attach}: 원 테스트가 그 계급의 자기 호출 가운데 <b>하나라도</b> 이 변형으로 겨누는 계급(하나도 안 겨누면 그 계급에
   * 맞지 않는 모양이다 — a1–a3 는 id_token 모양이라 교환만 겨눈다). {@code assertOn}: 그 계급의 자기 호출 <b>전부에서</b>
   * 실패를 단언하는 계급 — 일부만 단언하면 원 테스트가 나머지를 일부러 뺀 것이라 계약을 새로 만들지 않고 측정만 한다.
   * byDesign 은 원 테스트의 {@code KNOWN_LEAKS} 가 그 계급의 호출에서 「설계상 남긴다」고 적은 카나리아다 — 그 카나리아는
   * 이 칸에서도 누출 단언을 받지 않는다.
   */
  record Variant(String code, String from, MalformedIdpResponseTest.Reply reply, Map<String, String> canaries,
      Set<String> attach, Set<String> assertOn, Map<String, Set<String>> byDesign) {}

  private List<Variant> tokenVariants(Map<String, String> callClass, Map<String, Row> byLabel) throws Exception {
    List<Variant> out = new ArrayList<>();
    List<String> skipped = new ArrayList<>();
    Map<String, List<String>> callsOf = new HashMap<>();
    callClass.forEach((k, c) -> callsOf.computeIfAbsent(c, x -> new ArrayList<>()).add(k));
    for (MalformedIdpResponseTest.Variant v : MalformedIdpResponseTest.variants(key, otherKey, "https://unused/realms/a4")) {
      if (v.token() == MalformedIdpResponseTest.TOKEN_OK) {
        skipped.add(v.id() + "(토큰 응답은 정상)");
        continue;
      }
      if (v.certs() != null) {
        skipped.add(v.id() + "(JWKS 변형)");
        continue;
      }
      Set<String> attach = new TreeSet<>();
      Set<String> assertOn = new TreeSet<>();
      Map<String, Set<String>> byDesign = new HashMap<>();
      for (String cls : List.of(TOKEN_GRANT, CODE_EXCHANGE)) {
        List<String> calls = callsOf.getOrDefault(cls, List.of());
        if (calls.stream().anyMatch(v.mustFail()::contains)) attach.add(cls);
        if (!calls.isEmpty() && v.mustFail().containsAll(calls)) assertOn.add(cls);
        for (String k : calls) {
          for (String name : v.canaries().keySet()) {
            if (MalformedIdpResponseTest.KNOWN_LEAKS.containsKey(v.id() + "|" + k + "|" + name)) {
              byDesign.computeIfAbsent(cls, x -> new TreeSet<>()).add(name);
            }
          }
        }
      }
      if (attach.isEmpty()) {
        skipped.add(v.id() + "(토큰 계급의 호출을 겨누지 않는다)");
        continue;
      }
      out.add(new Variant(v.id(), "MalformedIdpResponseTest " + v.id(), v.token(), v.canaries(), attach, assertOn,
          byDesign));
    }
    // AuthClientTokenTypeTest 의 비문자열·빈 access_token — 소스의 List.of(…) 를 읽는다(손으로 옮겨 적지 않는다).
    Hand tt = HAND.stream().filter(h -> h.anchor().startsWith("AuthClientTokenTypeTest.java|")).findFirst().orElseThrow();
    String body = methodBody(testSource("AuthClientTokenTypeTest.java"), tt.anchor().split("\\|")[1]);
    Matcher lm = Pattern.compile("for \\(String raw : List\\.of\\((.*?)\\)\\)").matcher(body == null ? "" : body);
    List<String> raws = lm.find() ? stringLiterals(lm.group(1)) : List.of();
    if (raws.isEmpty()) throw new AssertionError("AuthClientTokenTypeTest 에서 access_token 변형을 하나도 못 읽었다");
    // 원 테스트의 호출은 clientCredentialsToken 하나 — 그 계급(TOKEN_GRANT)에 단언한다. CODE_EXCHANGE 는 그 테스트가 부르지
    // 않으므로 측정만 한다(Go 는 교환에도 단언했다 — 여기서는 계약을 새로 만들지 않는다).
    Row ttRow = byLabel.get(tt.label());
    Set<String> ttOn = ttRow == null ? Set.of() : Set.of(ttRow.cls());
    Set<String> both = Set.of(TOKEN_GRANT, CODE_EXCHANGE);
    String atRT = "ZatRT-0123456789abcdef";
    Set<String> codes = new TreeSet<>();
    for (String raw : raws) {
      String body2 = "{\"access_token\":" + raw + ",\"token_type\":\"Bearer\",\"expires_in\":300,\"refresh_token\":\""
          + atRT + "\"}";
      String code = "at:" + jsonKind(raw);
      if (!codes.add(code)) code += "#" + codes.size();
      out.add(new Variant(code, "AuthClientTokenTypeTest " + raw,
          (b, a) -> new MalformedIdpResponseTest.Resp(200, "application/json", body2),
          Map.of("ZatRT-0123", atRT), both, ttOn, Map.of()));
    }
    // 누락된 access_token — 어느 기존 테스트도 단언하지 않는다. 측정만.
    out.add(new Variant("at:missing", "", (b, a) -> new MalformedIdpResponseTest.Resp(200, "application/json",
        "{\"token_type\":\"Bearer\",\"expires_in\":300,\"refresh_token\":\"" + atRT + "\"}"),
        Map.of("ZatRT-0123", atRT), both, Set.of(), Map.of()));
    log("(a) 토큰응답 형식 변형 " + out.size() + " — 기존 테스트에서 파생 · 뺀 것: " + String.join(", ", skipped));
    return out;
  }

  /** Java 문자열 리터럴들의 값(\" 와 \\ 만 푼다 — 원 테스트의 리터럴이 쓰는 이스케이프가 그 둘뿐이다). */
  static List<String> stringLiterals(String code) {
    List<String> out = new ArrayList<>();
    int i = code.indexOf('"');
    while (i >= 0) {
      StringBuilder v = new StringBuilder();
      int k = i + 1;
      while (k < code.length() && code.charAt(k) != '"') {
        if (code.charAt(k) == '\\' && k + 1 < code.length()) k++;
        v.append(code.charAt(k));
        k++;
      }
      out.add(v.toString());
      i = k + 1 < code.length() ? code.indexOf('"', k + 1) : -1;
    }
    return out;
  }

  /** 변형 이름 — JSON 값의 종류(숫자·객체·배열·불리언·null·빈 문자열). */
  private static String jsonKind(String raw) {
    if (raw.startsWith("{")) return "object";
    if (raw.startsWith("[")) return "array";
    if (raw.equals("true") || raw.equals("false")) return "bool";
    if (raw.equals("null")) return "null";
    if (raw.equals("\"\"")) return "empty_string";
    if (raw.startsWith("\"")) return "string";
    return "number";
  }

  /** W3a 대조 — 변형과 같은 모양(id_token 없음)의 쓸 수 있는 토큰 응답. */
  private static final MalformedIdpResponseTest.Reply WELL_FORMED = (b, a) -> new MalformedIdpResponseTest.Resp(200,
      "application/json", "{\"access_token\":\"hp-access\",\"token_type\":\"Bearer\",\"expires_in\":300,"
          + "\"refresh_token\":\"hp-refresh\"}");

  /**
   * (a) TOKEN_GRANT·CODE_EXCHANGE 행마다 형식이 틀린 토큰 응답. 칸마다: 오류 · 그 오류가 SDK 오류 타입(JDK·하위 예외나
   * Error 는 충돌) · 카나리아가 toString·printStackTrace(원인 사슬·suppressed) 어디에도 없음 · 토큰 엔드포인트에 닿음 ·
   * 같은 행 대조보다 토큰 요청이 많지 않음 · 그 응답 **뒤로** 요청 없음. ⚠️ nonce 파라미터는 비운다 — id_token 없는 변형이
   * 「missing id_token」으로 공허하게 통과하지 않게(Go 공허 함정). 행마다 정상 응답 대조를 먼저 돈다 — admin 자원
   * 메서드는 정상 응답에도 404 로 실패하므로 거기서 무게는 「토큰 뒤로 안 나아갔다」가 진다.
   */
  private List<Cell> runVariantsA(List<Row> targets, Map<String, List<Integer>> nonceParams, Set<Class<?>> sdkErrors,
      Map<String, String> callClass, Map<String, Row> byLabel) throws Exception {
    List<Variant> variants = tokenVariants(callClass, byLabel);
    List<Cell> cells = new ArrayList<>();
    for (Row row : targets) {
      Set<Integer> blank = new HashSet<>(nonceParams.getOrDefault(row.label(), List.of()));
      CellRun ctl = cell(row, blank, i -> WELL_FORMED, false, 1);
      Outcome co = ctl.outcomes().get(0);
      int ctlHits = count(ctl.sent(), HostilePathMatrixTest::isTokenPost);
      List<Req> ctlAfter = afterToken(ctl.sent());
      List<String> cw = new ArrayList<>();
      if (co.thrown() != null && !sdkError(co.thrown(), sdkErrors)) cw.add("정상 응답에 충돌: " + brief(co.thrown()));
      if (ctlHits == 0) cw.add("정상 응답에서 토큰 엔드포인트에 안 닿았다 — 이 행의 변형은 공허하다");
      if (co.thrown() != null && ctlAfter.isEmpty()) {
        cw.add("정상 응답에 실패했고 토큰 뒤로 나아가지도 않았다 — 변형이 무엇을 바꿨는지 가를 수 없다: " + brief(co.thrown()));
      }
      cells.add(new Cell("a", row.label(), "대조", cw, false, co.thrown() == null ? "ok" : "↓" + ctlAfter.size()));
      for (Variant v : variants) {
        if (!v.attach().contains(row.cls())) continue;
        CellRun run = cell(row, blank, i -> v.reply(), false, 1);
        Map<String, String> canaries = new LinkedHashMap<>(v.canaries());
        // 호출이 흘려 넣은 비밀도 카나리아다 — 되울림 변형(e1·e7·h5)은 그것을 돌려준다(MalformedIdpResponseTest 와 같다).
        canaries.put("SECRET", SECRET);
        canaries.put("BASIC", BASIC);
        canaries.put("UNIVERSAL", run.universal());
        canaries.keySet().removeAll(v.byDesign().getOrDefault(row.cls(), Set.of()));
        List<String> why = hostileWhy(run, canaries, sdkErrors, ctlHits);
        boolean measure = !v.assertOn().contains(row.cls());
        Throwable t = run.outcomes().get(0).thrown();
        cells.add(new Cell("a", row.label(), v.code(), why, measure, t == null ? "성공" : t.getClass().getSimpleName()));
      }
    }
    return cells;
  }

  private static List<String> hostileWhy(CellRun run, Map<String, String> canaries, Set<Class<?>> sdkErrors,
      int ctlHits) {
    List<String> why = new ArrayList<>();
    Throwable t = run.outcomes().get(0).thrown();
    if (t == null) {
      why.add("오류 없이 성공했다");
    } else {
      if (!sdkError(t, sdkErrors)) why.add("SDK 오류 타입이 아니다(충돌): " + brief(t));
      Map<String, String> outs = MalformedIdpResponseTest.render(t);
      outs.forEach((how, out) -> canaries.forEach((name, secret) -> {
        String exposed = MalformedIdpResponseTest.exposure(out, secret);
        if (exposed != null) why.add("카나리아 " + name + " 가 " + how + " 에 찍혔다(" + exposed + ")");
      }));
    }
    int hits = count(run.sent(), HostilePathMatrixTest::isTokenPost);
    List<Req> after = afterToken(run.sent());
    if (hits == 0) why.add("토큰 엔드포인트에 한 번도 안 닿았다 — 변형이 공허하다(" + brief(t) + ")");
    // 하한만 두면 틀린 응답마다 재시도하는 새 메서드가 통과한다(Go 레그 지목, 실측 SILENT) — 상한은 같은 행의 대조다.
    if (hits > ctlHits) why.add("토큰 요청 " + hits + " 건 — 정상 응답 대조(" + ctlHits + " 건)보다 많다: 틀린 응답이 재시도를 부른다");
    if (!after.isEmpty()) {
      why.add("적대 토큰 응답 뒤로 나아갔다: " + format(after, run.universal()) + " (Authorization: "
          + after.stream().map(r -> String.valueOf(r.auth())).distinct().collect(Collectors.joining(" | ")) + ")");
    }
    return why;
  }

  /**
   * (b) CODE_EXCHANGE 행 중 서명에 nonce 파라미터가 있는 것 — 대조(맞는 id_token)와 다섯. 다른 키로 서명할 때 kid 가
   * k1 이면 캐시된 키로 서명 검증이 실패하고, k2 면 키를 못 찾는다(둘 다 재야 서명 생략을 잡는다 — Go 변이 7).
   * 대조는 성공해야 하고, id_token 이 있는 변형은 검증기까지 가야 한다(콜드 캐시 JWKS 조회 ≥ 1).
   */
  private record NonceVariant(String code, String kid, boolean otherKey, Map<String, Object> claims, boolean noIdToken,
      String want) {}

  private static final List<NonceVariant> NONCE_VARIANTS = List.of(
      new NonceVariant("대조", "k1", false, null, false, "ok"),
      new NonceVariant("nonce≠", "k1", false, Map.of("nonce", "hp-other-nonce"), false, "reject"),
      new NonceVariant("key≠·kid=k1", "k1", true, null, false, "reject"),
      new NonceVariant("key≠·kid=k2", "k2", true, null, false, "reject"),
      new NonceVariant("id_token없음", null, false, null, true, "reject"),
      new NonceVariant("nonce클레임없음", "k1", false, Map.of(), false, "reject"));

  private List<Cell> runNonceB(List<Row> targets, Map<String, List<Integer>> nonceParams, Set<Class<?>> sdkErrors)
      throws Exception {
    log("(b) nonce 대상(서명에서 파생): " + targets.stream().map(r -> r.label() + nonceParams.get(r.label()))
        .collect(Collectors.joining(", ")));
    List<Cell> cells = new ArrayList<>();
    for (Row row : targets) {
      for (NonceVariant nv : NONCE_VARIANTS) {
        CellRun run = cell(row, Set.of(), idp -> {
          String body = "\"access_token\":\"hp-access\",\"token_type\":\"Bearer\",\"expires_in\":300,"
              + "\"refresh_token\":\"hp-refresh\"";
          if (!nv.noIdToken()) {
            Map<String, Object> claims = nv.claims() == null ? Map.of("nonce", idp.universal()) : nv.claims();
            try {
              body += ",\"id_token\":\"" + sign(nv.otherKey() ? otherKey : key, nv.kid(), idp.iss(), claims) + "\"";
            } catch (JOSEException e) {
              throw new IllegalStateException(e);
            }
          }
          String b = "{" + body + "}";
          return (rb, ra) -> new MalformedIdpResponseTest.Resp(200, "application/json", b);
        }, false, 1);
        Throwable t = run.outcomes().get(0).thrown();
        int certs = count(run.sent(), HostilePathMatrixTest::isCertsGet);
        List<String> why = new ArrayList<>();
        if (count(run.sent(), HostilePathMatrixTest::isTokenPost) == 0) why.add("토큰 엔드포인트에 안 닿았다 — 변형이 공허하다");
        if (certs == 0 && !nv.noIdToken()) why.add("JWKS 를 조회하지 않았다 — id_token 이 검증기에 닿지 않았다");
        if (nv.want().equals("ok") && t != null) {
          why.add("맞는 id_token 에 실패했다 — 아래 변형의 실패가 아무것도 증명하지 않는다: " + brief(t));
        } else if (!nv.want().equals("ok") && t == null) {
          why.add("틀린 id_token 을 받아들였다");
        } else if (!nv.want().equals("ok") && !sdkError(t, sdkErrors)) {
          why.add("SDK 오류 타입이 아니다(충돌): " + brief(t));
        }
        cells.add(new Cell("b", row.label(), nv.code(), why, nv.want().equals("measure"), "certs " + certs));
      }
    }
    return cells;
  }

  /** 콜드 캐시 JWKS 칸의 호출 수 — 상한 k−1 이 백오프, 하한 1 이 콜드 경로 도달의 증명이다. 시간이 아니라 요청 수만 잰다. */
  private static final int COLD_K = 5;

  /** (c) 분류 실행에서 JWKS 를 조회한 행마다 — 새 수신자(빈 캐시) · /certs 503 · k 회: 전부 실패 · 1 ≤ /certs ≤ k−1. */
  private List<Cell> runColdJwksC(List<Row> targets, Set<Class<?>> sdkErrors) throws Exception {
    log("(c) 콜드 캐시 JWKS 대상(분류 실행이 /certs 를 조회한 행): "
        + targets.stream().map(Row::label).collect(Collectors.joining(", ")));
    List<Cell> cells = new ArrayList<>();
    for (Row row : targets) {
      CellRun run = cell(row, Set.of(), null, true, COLD_K);
      List<String> why = new ArrayList<>();
      for (int i = 0; i < run.outcomes().size(); i++) {
        Throwable t = run.outcomes().get(i).thrown();
        if (t == null) why.add((i + 1) + "번째 호출이 JWKS 503 인데 성공했다");
        else if (!sdkError(t, sdkErrors)) why.add((i + 1) + "번째 호출의 오류가 SDK 오류 타입이 아니다(충돌): " + brief(t));
      }
      int hits = count(run.sent(), HostilePathMatrixTest::isCertsGet);
      if (hits < 1) why.add("/certs 요청 " + hits + " — 콜드 경로에 닿지 않았다(하한 1)");
      if (hits > COLD_K - 1) why.add("/certs 요청 " + hits + " — 실패한 조회가 물러서지 않았다(상한 " + (COLD_K - 1) + ")");
      cells.add(new Cell("c", row.label(), "503×" + COLD_K, why, false, "certs " + hits));
    }
    return cells;
  }

  // ───────────────────────────── 판정 ─────────────────────────────

  private final Map<String, String> verdict = new LinkedHashMap<>();

  /** 칸마다 pass·GAP·FAIL·m:rej·m:ACC 를 정하고 판정표를 찍는다. 실패 사유를 돌려준다. */
  private List<String> judge(List<Cell> cells) {
    List<String> fails = new ArrayList<>();
    Set<String> observed = new TreeSet<>();
    for (Cell c : cells) {
      String v;
      if (c.measure()) {
        v = c.why().isEmpty() ? "m:rej" : "m:ACC";
      } else if (c.why().isEmpty()) {
        v = "pass";
      } else if (KNOWN_GAPS.containsKey(c.key())) {
        v = "GAP";
        observed.add(c.key());
      } else {
        v = "FAIL";
        fails.add(c.key() + ": " + String.join(" · ", c.why()));
      }
      if (!c.note().isEmpty() && (!c.axis().equals("a") || c.variant().equals("대조"))) v += "(" + c.note() + ")";
      verdict.put(c.key(), v);
    }
    for (String axis : List.of("a", "b", "c")) logVerdicts(axis, cells);
    // 측정 칸은 변형마다 한 줄로 모은다 — 받아들인 행만 이름과 사유를 적는다.
    Map<String, List<Cell>> measured = new LinkedHashMap<>();
    for (Cell c : cells) {
      if (c.measure()) measured.computeIfAbsent("W3" + c.axis() + " " + c.variant(), k -> new ArrayList<>()).add(c);
    }
    measured.forEach((k, cs) -> {
      List<Cell> acc = cs.stream().filter(c -> !c.why().isEmpty()).toList();
      Set<String> kinds = cs.stream().filter(c -> c.why().isEmpty()).map(Cell::note).collect(Collectors.toCollection(TreeSet::new));
      log("측정(단언 안 함) " + k + " — 거부 " + (cs.size() - acc.size()) + " · 받아들임 " + acc.size() + " · 거부 오류 " + kinds
          + (acc.isEmpty() ? "" : " · 받아들인 행 " + acc.stream().map(Cell::label).toList() + " · 사유 " + reasons(acc)));
    });
    // GAP 칸은 변형마다 한 줄로 — 이유 문자열이 아니라 **이번 실행이 본 것**을 찍는다.
    Map<String, List<Cell>> gaps = new LinkedHashMap<>();
    for (Cell c : cells) {
      if (verdict.get(c.key()).startsWith("GAP")) {
        gaps.computeIfAbsent("W3" + c.axis() + " " + c.variant(), k -> new ArrayList<>()).add(c);
      }
    }
    gaps.forEach((k, cs) -> log("GAP " + k + " ×" + cs.size() + " — 관측: " + reasons(cs)));
    KNOWN_GAPS.forEach((k, why) -> {
      if (!observed.contains(k)) fails.add("KNOWN_GAPS[" + k + "]: 더는 관측되지 않는다 — 낡은 항목을 지워라(" + why + ")");
    });
    return fails;
  }

  private static final Pattern BEARER = Pattern.compile("나아갔다: .*\\(Authorization: (.*)\\)$");

  /** 칸들의 사유를 종류로 접는다 — 「토큰 뒤로 나아갔다」는 경로가 행마다 달라 bearer 만 남긴다. */
  private static String reasons(List<Cell> cs) {
    return cs.stream().flatMap(c -> c.why().stream()).map(w -> {
      Matcher bm = BEARER.matcher(w);
      return bm.find() ? "토큰 뒤로 나아감, bearer=" + bm.group(1) : w;
    }).distinct().collect(Collectors.joining(" | "));
  }

  private void logVerdicts(String axis, List<Cell> cells) {
    List<String> labels = new ArrayList<>();
    List<String> cols = new ArrayList<>();
    for (Cell c : cells) {
      if (!c.axis().equals(axis)) continue;
      if (!labels.contains(c.label())) labels.add(c.label());
      if (!cols.contains(c.variant())) cols.add(c.variant());
    }
    if (labels.isEmpty()) {
      log("W3" + axis + " 판정표: 대상 행이 없다");
      return;
    }
    int[] width = new int[cols.size()];
    for (int i = 0; i < cols.size(); i++) {
      width[i] = cols.get(i).length();
      for (String l : labels) {
        width[i] = Math.max(width[i], verdict.getOrDefault("W3" + axis + " " + l + "/" + cols.get(i), "").length());
      }
    }
    log("W3" + axis + " 판정표 — " + labels.size() + "행 × " + cols.size()
        + "열 (pass · GAP=알려진 틈 · FAIL · m:rej/m:ACC=측정만: 거부/받아들임)");
    StringBuilder head = new StringBuilder(String.format("%-52s", "행 \\ 변형"));
    for (int i = 0; i < cols.size(); i++) head.append(' ').append(String.format("%-" + width[i] + "s", cols.get(i)));
    log(head.toString().stripTrailing());
    for (String l : labels) {
      StringBuilder line = new StringBuilder(String.format("%-52s", l));
      for (int i = 0; i < cols.size(); i++) {
        line.append(' ').append(String.format("%-" + width[i] + "s",
            verdict.getOrDefault("W3" + axis + " " + l + "/" + cols.get(i), "")));
      }
      log(line.toString().stripTrailing());
    }
  }

  /** 요약은 실패 줄 **뒤에** 찍는다 — 변이 프로브는 출력 꼬리만 보여 준다. */
  private void logSummaries(Map<String, Integer> counts, List<Cell> cells) {
    log("계급별: " + CLASSES.stream().map(c -> c + " " + counts.getOrDefault(c, 0)).collect(Collectors.joining(" · ")));
    for (String axis : List.of("a", "b", "c")) {
      Map<String, Integer> n = new HashMap<>();
      Map<String, Integer> failedBy = new LinkedHashMap<>();
      for (Cell c : cells) {
        if (!c.axis().equals(axis)) continue;
        String v = verdict.get(c.key()).split("\\(", 2)[0];
        n.merge(v, 1, Integer::sum);
        if (v.equals("FAIL")) failedBy.merge(c.variant(), 1, Integer::sum);
      }
      log("W3" + axis + " 요약: pass " + n.getOrDefault("pass", 0) + " · GAP " + n.getOrDefault("GAP", 0) + " · FAIL "
          + n.getOrDefault("FAIL", 0) + " · 측정 " + (n.getOrDefault("m:rej", 0) + n.getOrDefault("m:ACC", 0)) + "(m:rej "
          + n.getOrDefault("m:rej", 0) + " · m:ACC " + n.getOrDefault("m:ACC", 0) + ") · FAIL 열 "
          + failedBy.entrySet().stream().map(e -> e.getKey() + "×" + e.getValue()).toList());
    }
  }
}
