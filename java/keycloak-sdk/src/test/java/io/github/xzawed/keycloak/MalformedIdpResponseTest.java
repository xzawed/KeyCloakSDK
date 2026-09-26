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
import io.github.xzawed.keycloak.auth.ClientCredentialsTokenProvider;
import io.github.xzawed.keycloak.core.KeycloakConfig;
import io.github.xzawed.keycloak.core.exception.KeycloakAuthException;
import io.github.xzawed.keycloak.core.exception.KeycloakSdkException;
import io.github.xzawed.keycloak.core.exception.KeycloakTransportException;
import io.github.xzawed.keycloak.core.exception.TokenValidationException;
import java.io.IOException;
import java.io.OutputStream;
import java.io.PrintWriter;
import java.io.StringWriter;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.URI;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Base64;
import java.util.Date;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.TreeSet;
import java.util.concurrent.ConcurrentHashMap;
import java.util.stream.Collectors;
import org.junit.jupiter.api.Test;

/**
 * 형식이 틀리거나 적대적인 IdP 응답에서 난 SDK 오류가 **로거가 찍는 표현**에 토큰을 싣지 않는다 —
 * {@code toString()} 과 {@code printStackTrace(PrintWriter)}(원인 사슬의 「Caused by:」 메시지와 suppressed
 * 전부). Node #603 과 같은 부류다: 하위 파서의 예외가 응답 본문을 인용하고, SDK 가 그 예외를 원인으로 그대로
 * 달면 로거가 그 사슬을 따라가 토큰을 찍는다.
 *
 * <p>{@link FacadeDumpTest} 옆에 따로 둔 이유: 거기는 「도달 가능한 객체 전부」를 걷는 바닥 계약이고, 여기는
 * 변형 × 공개 호출 × 출력 경로마다 **어디서 새는지**를 가려 적는 측정이다. 걷기 쪽에도 뿌리를 더했다.
 *
 * <p>⚠️ 흐름 검사가 요점의 절반이다 — 변형이 정말 그 호출을 실패시켰는가(기대한 SDK 타입으로). 실패하지 않으면
 * 렌더링할 오류가 없어서 누출 검사가 없는 것을 찾으며 통과한다.
 *
 * <p>⚠️ 카나리아 둘은 모양이 다르다 — {@code -} 가 든 것과 식별자 글자만인 것. Jackson 은 JSON 이 아닌 본문을
 * 식별자 글자까지만 인용해서, {@code -} 가 든 카나리아만 쓰면 admin 경로의 누출이 첫 네 글자로 줄어 안 보였다.
 */
class MalformedIdpResponseTest {
  private static final String CLIENT_ID = "c";
  private static final URI CB = URI.create("https://app/cb");
  private static final String NONCE = "n-1";

  // 호출이 흘려 넣는 비밀 — 에코 변형이 이것들을 되돌려준다.
  private static final String SECRET = c("inSECRET");
  private static final String BASIC = Base64.getEncoder()
      .encodeToString((CLIENT_ID + ":" + SECRET).getBytes(StandardCharsets.UTF_8));
  private static final String CODE = c("inCODE");
  private static final String VERIFIER = "ZinVERIF-0123456789abcdefghijklmnopqrstuvwxyzABCD"; // RFC 7636: 43–128
  private static final String REFRESH_IN = c("inRT");
  private static final String TOKEN_IN = c("inTOK");

  private static final String CC = "clientCredentialsToken";
  private static final String EX = "exchangeCode";
  private static final String EXN = "exchangeCode+nonce";
  private static final String RF = "refresh";
  private static final String PROV = "ClientCredentialsTokenProvider";
  private static final String IN = "introspect";
  private static final String LO = "logout";
  private static final String ADMIN = "admin().users().get";
  private static final String VALIDATE = "validate";
  private static final List<String> TOKEN_CALLS = List.of(CC, EX, EXN, RF, PROV);
  /** admin 도 첫 호출에서 같은 토큰 엔드포인트로 client_credentials 를 한다(admin-client 내장 TokenManager·Jackson). */
  private static final List<String> TOKEN_CALLS_ADMIN = List.of(CC, EX, EXN, RF, PROV, ADMIN);
  private static final List<String> ERROR_CALLS = List.of(CC, EX, EXN, RF, PROV, IN, LO, ADMIN);

  /**
   * 알려진 누출 — {@code "변형|호출|카나리아"} 와 사유. ⚠️ 고쳐져 더 안 새면 **여기서 지워야 통과한다**(낡은 항목 검사).
   */
  static final Map<String, String> KNOWN_LEAKS = knownLeaks();

  private static Map<String, String> knownLeaks() {
    // ⚠️ 설계 경계: error_description 은 IdP 가 쓴 산문이라 메시지에 싣는다(진단 가치 — 아홉 언어 공통). SDK 가 가리는
    // 것은 이 요청이 보낸 비밀과 그와 겹치는 조각, 토큰 모양의 20 자 이상 연속이다(`AuthClient.describe`). 보내지 않았고
    // 토큰 모양도 아닌 값은 낱말과 못 가른다 — 가리려면 산문을 버려야 하고, 그러면 메시지의 뜻이 바뀐다.
    String shortWhy = "IdP prose kept by design; an unsent value under 20 chars is indistinguishable from a word";
    String lowerWhy = "IdP prose kept by design; an unsent lowercase-only value reads like code_challenge_method";
    Map<String, String> out = new LinkedHashMap<>();
    for (String call : List.of(CC, EX, EXN, RF, PROV, IN)) {
      out.put("e6|" + call + "|Ze6sQwErTy", shortWhy);
      out.put("h1|" + call + "|eyJhbGciOi", shortWhy);   // Grok 레그: 보내지 않은 19 자
      out.put("h4|" + call + "|qwertyuiop", lowerWhy);   // Grok 레그: 보내지 않은 소문자 26 자
    }
    return Map.copyOf(out);
  }

  /** 모든 카나리아는 첫 10 자가 서로 다르다 — 접두 누출을 이름으로 가려낸다. {@code -} 가 든다. */
  private static String c(String tag) {
    return "Z" + tag + "-0123456789abcdef";
  }

  /** 식별자 글자만 — Jackson 이 끝까지 인용한다. */
  private static String ident(String tag) {
    return "Z" + tag + "0123456789abcdefXYZ";
  }

  private record Resp(int status, String contentType, String body) {}

  /** 요청 본문과 Authorization 헤더를 보고 응답을 고른다 — 에코 변형용. */
  private interface Reply {
    Resp reply(String requestBody, String authorization);
  }

  /** {@code certs} 가 null 이면 가짜 IdP 가 진짜 JWKS 를 준다. */
  private record Variant(String id, String shape, Reply token, Reply introspect, Reply logout, Reply admin,
      Reply certs, List<String> mustFail, Map<String, String> canaries) {
    Variant(String id, String shape, Reply token, Reply introspect, Reply logout, List<String> mustFail,
        Map<String, String> canaries) {
      this(id, shape, token, introspect, logout, ADMIN_404, null, mustFail, canaries);
    }

    Variant(String id, String shape, Reply token, Reply introspect, Reply logout, Reply admin,
        List<String> mustFail, Map<String, String> canaries) {
      this(id, shape, token, introspect, logout, admin, null, mustFail, canaries);
    }
  }

  private static Reply fixed(int status, String contentType, String body) {
    return (b, a) -> new Resp(status, contentType, body);
  }

  private static Reply json(int status, String body) {
    return fixed(status, "application/json", body);
  }

  private static final Reply TOKEN_OK = json(200, "{\"access_token\":\"okAT\",\"token_type\":\"Bearer\","
      + "\"expires_in\":300,\"refresh_token\":\"okRT\"}");
  private static final Reply INTROSPECT_OK = json(200, "{\"active\":true,\"username\":\"svc\",\"client_id\":\"c\"}");
  private static final Reply LOGOUT_OK = fixed(204, null, null);
  private static final Reply ADMIN_404 = json(404, "{\"error\":\"User not found\"}");

  /** 요청이 실어 보낸 비밀(폼 값·Basic 자격)을 error_description 에 되울린다 — 「입력을 인용하는 IdP」. */
  private static final Reply ECHO_REQUEST = echo(Integer.MAX_VALUE, "");
  /** 같은 에코를 앞 12 자로 자른다 — 잘린 되울림(10 자 이상 조각). */
  private static final Reply ECHO_PREFIX = echo(12, "...");
  /** 잘린 되울림이 이름표에 붙는다 — {@code token=<앞 12 자>}(연속 하나가 비밀의 부분 문자열이 아니다). */
  private static final Reply ECHO_GLUED = echo(12, "", "token=");

  private static Reply echo(int keep, String ellipsis) {
    return echo(keep, ellipsis, "");
  }

  private static Reply echo(int keep, String ellipsis, String label) {
    return (body, auth) -> {
      List<String> sent = new ArrayList<>();
      for (String kv : body == null ? new String[0] : body.split("&")) {
        int eq = kv.indexOf('=');
        String k = eq < 0 ? kv : kv.substring(0, eq);
        String v = eq < 0 ? "" : URLDecoder.decode(kv.substring(eq + 1), StandardCharsets.UTF_8);
        if (Set.of("code", "code_verifier", "refresh_token", "token", "client_secret").contains(k)) sent.add(v);
      }
      if (auth != null) sent.add(auth.substring(auth.indexOf(' ') + 1));
      String echoed = sent.stream().map(s -> label + (s.length() > keep ? s.substring(0, keep) + ellipsis : s))
          .collect(Collectors.joining(" "));
      return new Resp(400, "application/json",
          "{\"error\":\"invalid_grant\",\"error_description\":\"rejected " + echoed + "\"}");
    };
  }

  private static String b64u(String s) {
    return Base64.getUrlEncoder().withoutPadding().encodeToString(s.getBytes(StandardCharsets.UTF_8));
  }

  private static String tokens(String access, String type, String expires, String refresh, String idToken) {
    StringBuilder sb = new StringBuilder("{\"access_token\":").append(access);
    if (type != null) sb.append(",\"token_type\":").append(type);
    if (expires != null) sb.append(",\"expires_in\":").append(expires);
    if (refresh != null) sb.append(",\"refresh_token\":").append(refresh);
    if (idToken != null) sb.append(",\"id_token\":").append(idToken);
    return sb.append('}').toString();
  }

  private static String q(String s) {
    return "\"" + s + "\"";
  }

  private static Variant token(String id, String shape, Reply token, List<String> mustFail, String... canaries) {
    return new Variant(id, shape, token, INTROSPECT_OK, LOGOUT_OK, mustFail, named(canaries));
  }

  private static Variant error(String id, String shape, Reply all, String... canaries) {
    return new Variant(id, shape, all, all, all, all, ERROR_CALLS, named(canaries));
  }

  private static Variant introspect(String id, String shape, Reply introspect, String... canaries) {
    return new Variant(id, shape, TOKEN_OK, introspect, LOGOUT_OK, List.of(IN), named(canaries));
  }

  private static Variant admin(String id, String shape, Reply admin, String... canaries) {
    return new Variant(id, shape, TOKEN_OK, INTROSPECT_OK, LOGOUT_OK, admin, List.of(ADMIN), named(canaries));
  }

  /** 카나리아 이름은 그 값의 첫 10 자다(접두 누출 판정의 단위와 같다 — 변형 안에서 서로 다르다). */
  private static Map<String, String> named(String... values) {
    Map<String, String> out = new LinkedHashMap<>();
    for (String v : values) {
      assertNull(out.put(v.substring(0, 10), v), () -> "카나리아 첫 10 자가 겹친다: " + v);
    }
    return out;
  }

  static List<Variant> variants(RSAKey key, RSAKey otherKey, String a4Issuer) throws JOSEException {
    List<Variant> out = new ArrayList<>();
    // (a) id_token 이 JWT 가 아니다 — OIDC 파서를 타는 교환 경로만 실패한다(평문 파서는 id_token 을 안 본다).
    String aAT = c("aAT"), aRT = c("aRT"), aID = c("aID");
    out.add(token("a1", "200 JSON, id_token not a JWT (no dots)",
        json(200, tokens(q(aAT), q("Bearer"), "300", q(aRT), q(aID))), List.of(EX, EXN), aAT, aRT, aID));
    String a2AT = c("a2AT"), a2ID = c("a2ID") + "." + c("a2IDp") + "." + c("a2IDs");
    out.add(token("a2", "200 JSON, id_token dotted garbage",
        json(200, tokens(q(a2AT), q("Bearer"), "300", null, q(a2ID))), List.of(EX, EXN), a2AT, a2ID));
    String a3AT = c("a3AT"), a3HDR = c("a3HDR");
    String a3ID = b64u("{\"alg\":" + a3HDR + "}") + "." + b64u("{}") + "." + b64u("sig");
    out.add(token("a3", "200 JSON, id_token header is not JSON (unquoted canary)",
        json(200, tokens(q(a3AT), q("Bearer"), "300", null, q(a3ID))), List.of(EX, EXN), a3AT, a3HDR, a3ID));
    // JWT 모양이라 파싱은 통과한다 — nonce 를 넘긴 교환만 검증에서 실패한다(서명 키가 다르다).
    String a4AT = c("a4AT"), a4RT = c("a4RT");
    SignedJWT forged = new SignedJWT(new JWSHeader.Builder(JWSAlgorithm.RS256).keyID(key.getKeyID()).build(),
        new JWTClaimsSet.Builder().issuer(a4Issuer).subject(c("a4SUB")).audience(CLIENT_ID).claim("nonce", NONCE)
            .expirationTime(Date.from(Instant.now().plusSeconds(60))).build());
    forged.sign(new RSASSASigner(otherKey));
    String a4ID = forged.serialize();
    out.add(token("a4", "200 JSON, id_token a JWT signed by another key",
        json(200, tokens(q(a4AT), q("Bearer"), "300", q(a4RT), q(a4ID))), List.of(EXN), a4AT, a4RT, a4ID));
    // (b) access_token 이 문자열이 아니다 — refresh_token 이 카나리아. admin 의 Jackson 은 숫자를 문자열로 받아 준다.
    String bRT = c("bRT");
    out.add(token("b1", "200 JSON, access_token a number",
        json(200, tokens("12345", q("Bearer"), "300", q(bRT), null)), TOKEN_CALLS, bRT));
    String b2AT = c("b2AT"), b2RT = c("b2RT");
    out.add(token("b2", "200 JSON, access_token an object holding a canary",
        json(200, tokens("{\"v\":" + q(b2AT) + "}", q("Bearer"), "300", q(b2RT), null)), TOKEN_CALLS_ADMIN,
        b2AT, b2RT));
    // (c) expires_in / token_type 의 타입이 틀렸다 — 토큰은 카나리아.
    String cAT = c("cAT"), cRT = c("cRT");
    out.add(token("c1", "200 JSON, expires_in a non-numeric string",
        json(200, tokens(q(cAT), q("Bearer"), q("soon"), q(cRT), null)), TOKEN_CALLS_ADMIN, cAT, cRT));
    String c2AT = c("c2AT"), c2RT = c("c2RT");
    out.add(token("c2", "200 JSON, token_type a number",
        json(200, tokens(q(c2AT), "5", "300", q(c2RT), null)), TOKEN_CALLS, c2AT, c2RT));
    String c3AT = c("c3AT"), c3RT = c("c3RT"), c3TT = c("c3TT");
    out.add(token("c3", "200 JSON, token_type holds a token (fields swapped)",
        json(200, tokens(q(c3AT), q(c3TT), "300", q(c3RT), null)), TOKEN_CALLS, c3AT, c3RT, c3TT));
    String c4AT = c("c4AT"), c4RT = c("c4RT"), c4EXP = c("c4EXP");
    out.add(token("c4", "200 JSON, expires_in a string holding a canary",
        json(200, tokens(q(c4AT), q("Bearer"), q(c4EXP), q(c4RT), null)), TOKEN_CALLS_ADMIN, c4AT, c4RT, c4EXP));
    String c5AT = c("c5AT");
    out.add(token("c5", "200 JSON, refresh_token a number",
        json(200, tokens(q(c5AT), q("Bearer"), "300", "7", null)), TOKEN_CALLS, c5AT));
    // (d) 200 인데 본문이 JSON 이 아니다 — 짧은 카나리아(≤20 자)와 카나리아로 시작하는 긴 본문.
    String dS = c("dS");
    assertTrue(dS.length() <= 20, "짧은 본문 카나리아는 20 자 이하여야 한다: " + dS.length());
    out.add(token("d1", "200 non-JSON body, short canary", json(200, dS), TOKEN_CALLS_ADMIN, dS));
    String dL = c("dL") + "-" + "x".repeat(400) + " tail";
    out.add(token("d2", "200 non-JSON body, long, starts with a canary", json(200, dL), TOKEN_CALLS_ADMIN, dL));
    String dP = c("dP");
    out.add(token("d3", "200 non-JSON body served as text/plain", fixed(200, "text/plain", dP), TOKEN_CALLS_ADMIN,
        dP));
    String d4AT = c("d4AT"), d4RT = c("d4RT");
    out.add(token("d4", "200 truncated JSON",
        json(200, "{\"access_token\":" + q(d4AT) + ",\"refresh_token\":\"" + d4RT), TOKEN_CALLS_ADMIN, d4AT, d4RT));
    String d5AT = c("d5AT"), d5W = c("d5W");
    out.add(token("d5", "200 JSON followed by a canary word",
        json(200, tokens(q(d5AT), q("Bearer"), "300", null, null) + " " + d5W), TOKEN_CALLS_ADMIN, d5AT, d5W));
    String d6 = c("d6");
    out.add(token("d6", "200 JSON array holding a canary", json(200, "[" + q(d6) + "]"), TOKEN_CALLS_ADMIN, d6));
    String d7 = c("d7");
    out.add(token("d7", "200 JSON string that is a canary", json(200, q(d7)), TOKEN_CALLS_ADMIN, d7));
    String d8 = ident("dI");
    assertTrue(d8.length() <= 25, "식별자 카나리아는 짧아야 한다: " + d8.length());
    out.add(token("d8", "200 non-JSON body, identifier-only canary", json(200, d8), TOKEN_CALLS_ADMIN, d8));
    String d9 = b64u("{\"kid\":\"Zd9\",\"alg\":\"RS256\"}") + "." + b64u("{\"sub\":\"Zd9SUB\"}") + "."
        + b64u("Zd9SIG0123456789");
    out.add(token("d9", "200 body that is a bare JWT", json(200, d9), TOKEN_CALLS_ADMIN, d9));
    // (e) 오류 본문 — error_description 이 요청의 비밀을 되울리거나, 모르는 토큰을 싣는다.
    out.add(error("e1", "400 JSON, error_description echoes the request's secrets", ECHO_REQUEST));
    // ⚠️ 모르는 토큰은 보낸 비밀의 카나리아와 10 자 창을 나누지 않아야 한다 — c() 모양은 `0123456789` 를 나눠 창 규칙이
    // 우연히 가렸고, 토큰 모양 규칙을 지운 변이가 e2 에서 안 보였다(변이 c3 이 드러냈다).
    String eF = "ZeF" + "Kq7Wm2Xp9Rt4Ys6Vb8Nc";
    out.add(error("e2", "401 JSON, error_description carries an unknown token",
        json(401, "{\"error\":\"invalid_client\",\"error_description\":\"rejected " + eF + "\"}"), eF));
    String eC = c("eC");
    out.add(error("e3", "400 JSON, error code is a canary", json(400, "{\"error\":" + q(eC) + "}"), eC));
    String eN = ident("eN");
    out.add(error("e4", "400 non-JSON body that is a canary", json(400, eN), eN));
    String e5AT = c("e5AT"), e5RT = c("e5RT");
    out.add(error("e5", "401 carrying a success-shaped token body",
        json(401, tokens(q(e5AT), q("Bearer"), "300", q(e5RT), null)), e5AT, e5RT));
    // ⚠️ 보낸 비밀의 카나리아와 10 자 창을 나누지 않는 값이어야 한다 — `0123456789` 를 품었더니 창 규칙이 우연히 가려
    // 경계가 안 보였다(낡은 항목 검사가 알렸다).
    String e6 = "Ze6sQwErTy7x4k";
    out.add(error("e6", "401 JSON, error_description carries a short (<20) unknown token",
        json(401, "{\"error\":\"invalid_client\",\"error_description\":\"rejected " + e6 + "\"}"), e6));
    out.add(error("e7", "400 JSON, error_description echoes a 12-char prefix of each secret sent", ECHO_PREFIX));
    // (f) introspect — 같은 모양을 introspection 엔드포인트에.
    String fS = c("fS");
    out.add(introspect("f1", "introspect: 200 non-JSON body, short canary", json(200, fS), fS));
    String fL = c("fL") + "-" + "y".repeat(400) + " tail";
    out.add(introspect("f2", "introspect: 200 non-JSON body, long, starts with a canary", json(200, fL), fL));
    String fA = c("fA");
    out.add(introspect("f3", "introspect: 200 JSON, active a canary string",
        json(200, "{\"active\":" + q(fA) + ",\"username\":\"svc\"}"), fA));
    String f4W = c("f4W");
    out.add(introspect("f4", "introspect: 200 JSON followed by a canary word",
        json(200, "{\"active\":true} " + f4W), f4W));
    String f5T = c("f5T");
    out.add(introspect("f5", "introspect: 200 truncated JSON", json(200, "{\"active\":true,\"username\":\"" + f5T), f5T));
    String f6 = ident("fI");
    out.add(introspect("f6", "introspect: 200 non-JSON body, identifier-only canary", json(200, f6), f6));
    // (g) admin 리소스 응답 — 같은 경계(AdminExceptions)를 지나는 Jackson 역직렬화 실패.
    String g1 = c("g1");
    out.add(admin("g1", "admin GET: 200 JSON string that is a canary", json(200, q(g1)), g1));
    String g2 = c("g2");
    // ⚠️ attributes 를 문자열로 주는 모양은 Jackson 이 받아 줘 실패하지 않았다(흐름 검사가 잡았다) — Long 필드로.
    out.add(admin("g2", "admin GET: 200 user whose createdTimestamp is a canary string",
        json(200, "{\"id\":\"u\",\"username\":\"x\",\"createdTimestamp\":" + q(g2) + "}"), g2));
    String g3 = ident("gI");
    out.add(admin("g3", "admin GET: 200 non-JSON body, identifier-only canary", json(200, g3), g3));
    // (h) 독립 레그(Grok)가 낸 모양 — 수정 뒤에 하나씩 쟀다. 판정은 커밋 메시지와 KNOWN_LEAKS.
    // JWT 모양은 실행 중에 만든다 — 소스에 JWT 리터럴을 두지 않는다(비밀 스캐너가 진짜와 못 가른다).
    String h1 = b64u("{\"alg\":\"none\"}");
    assertEquals(19, h1.length());
    out.add(error("h1", "error_description is an unsent 19-char token", described(h1), h1));
    String h2 = h1 + "." + b64u("{\"sub\":\"1\"}") + ".abc";
    out.add(error("h2", "error_description is a whole JWT whose dot-separated pieces are each < 20", described(h2),
        h2));
    String h3 = h1 + "." + b64u("{\"sub\":\"1234567890\"}") + "." + b64u("h3-signature-0123456789-abcdefghij");
    out.add(error("h3", "error_description is a long JWT with a 19-char header", described(h3), h3));
    // ⚠️ 알파벳 순서 값은 VERIFIER 안에 들어 있어 교환 경로에서 보낸 비밀로 가려졌다 — 겹치지 않는 값을 쓴다.
    String h4 = "qwertyuiopasdfghjklzxcvbnm";
    out.add(error("h4", "error_description is an unsent 26-char lowercase-only value", described(h4), h4));
    out.add(error("h5", "error_description echoes 12-char prefixes glued to a label (token=...)", ECHO_GLUED));
    // 정규식이 오류 경로에서 스택을 넘치면 SDK 타입이 아니라 StackOverflowError 가 나간다(흐름 검사가 잡는다).
    String h8 = "Zh8" + ".ab".repeat(200_000);
    out.add(error("h8", "error_description is one 600 KB dotted run", described(h8), h8));
    String h6 = ident("hJ");
    SignedJWT id = new SignedJWT(new JWSHeader.Builder(JWSAlgorithm.RS256).keyID(key.getKeyID()).build(),
        new JWTClaimsSet.Builder().subject("u").audience(CLIENT_ID).claim("nonce", NONCE)
            .expirationTime(Date.from(Instant.now().plusSeconds(60))).build());
    id.sign(new RSASSASigner(key));
    Reply withIdToken = json(200, tokens(q("okAT"), q("Bearer"), "300", null, q(id.serialize())));
    out.add(new Variant("h6", "JWKS: 200 non-JSON body, identifier-only canary (validate · exchangeCode+nonce)",
        withIdToken, INTROSPECT_OK, LOGOUT_OK, ADMIN_404, json(200, h6), List.of(VALIDATE, EXN), named(h6)));
    String h7 = ident("hK");
    out.add(new Variant("h7", "JWKS: 200 JSON whose keys is a canary string",
        withIdToken, INTROSPECT_OK, LOGOUT_OK, ADMIN_404, json(200, "{\"keys\":" + q(h7) + "}"),
        List.of(VALIDATE, EXN), named(h7)));
    return out;
  }

  private static Reply described(String description) {
    return json(400, "{\"error\":\"invalid_request\",\"error_description\":\"" + description + "\"}");
  }

  /** 공개 호출 — 이름 → 실행. */
  private interface Call {
    void run(KeycloakClient kc) throws Exception;
  }

  /** validate 가 JWKS 를 가져오게 하는 서명 JWT(kid 가 가짜 IdP 의 키와 같다) — 테스트마다 채운다. */
  private static volatile String validateJwt;

  static final Map<String, Call> CALLS = new LinkedHashMap<>();

  static {
    CALLS.put(CC, kc -> kc.auth().clientCredentialsToken());
    CALLS.put(EX, kc -> kc.auth().exchangeCode(CODE, CB, VERIFIER));
    CALLS.put(EXN, kc -> kc.auth().exchangeCode(CODE, CB, VERIFIER, NONCE));
    CALLS.put(RF, kc -> kc.auth().refresh(REFRESH_IN));
    CALLS.put(PROV, kc -> new ClientCredentialsTokenProvider(kc.auth(), Clock.systemUTC(), Duration.ofSeconds(30))
        .getAccessToken());
    CALLS.put(IN, kc -> kc.auth().introspect(TOKEN_IN));
    CALLS.put(LO, kc -> kc.auth().logout(REFRESH_IN));
    CALLS.put(ADMIN, kc -> kc.admin().users().get("x"));
    CALLS.put(VALIDATE, kc -> kc.auth().validate(validateJwt));
  }

  private static void signValidateJwt(RSAKey key) throws JOSEException {
    SignedJWT jwt = new SignedJWT(new JWSHeader.Builder(JWSAlgorithm.RS256).keyID(key.getKeyID()).build(),
        new JWTClaimsSet.Builder().subject("u").expirationTime(Date.from(Instant.now().plusSeconds(60))).build());
    jwt.sign(new RSASSASigner(key));
    validateJwt = jwt.serialize();
  }

  /** 흐름 검사가 기대하는 타입 — auth 는 인증 오류, admin 은 (분류를 바꾸지 않은 채) 전송 오류, validate 는 검증 오류. */
  private static Class<? extends KeycloakSdkException> expected(String call) {
    if (call.equals(ADMIN)) return KeycloakTransportException.class;
    if (call.equals(VALIDATE)) return TokenValidationException.class;
    return KeycloakAuthException.class;
  }

  @Test
  void hostileResponsesDoNotPrintTokens() throws Exception {
    RSAKey key = new RSAKeyGenerator(2048).keyID("k1").generate();
    RSAKey other = new RSAKeyGenerator(2048).keyID("k1").generate();
    signValidateJwt(key);
    try (FakeIdp idp = new FakeIdp(key)) {
      List<Variant> variants = variants(key, other, idp.url() + "/realms/a4");
      variants.forEach(v -> idp.variants.put(v.id(), v));

      Map<String, String> inputs = new LinkedHashMap<>();
      inputs.put("SECRET", SECRET);
      inputs.put("BASIC", BASIC);
      inputs.put("CODE", CODE);
      inputs.put("VERIFIER", VERIFIER);
      inputs.put("REFRESH_IN", REFRESH_IN);
      inputs.put("TOKEN_IN", TOKEN_IN);

      List<String> leaks = new ArrayList<>();
      List<String> flow = new ArrayList<>();
      Set<String> knownSeen = new TreeSet<>();
      List<String> table = new ArrayList<>();
      for (Variant v : variants) {
        Map<String, String> canaries = new LinkedHashMap<>(inputs);
        canaries.putAll(v.canaries());
        for (Map.Entry<String, Call> call : CALLS.entrySet()) {
          Throwable thrown = run(idp, v, call.getValue());
          boolean target = v.mustFail().contains(call.getKey());
          if (target && !expected(call.getKey()).isInstance(thrown)) {
            flow.add(v.id() + " [" + v.shape() + "] " + call.getKey() + ": " + expected(call.getKey()).getSimpleName()
                + " 로 실패하지 않았다(" + (thrown == null ? "성공" : thrown.getClass().getName())
                + ") — 변형이 그 경로에 안 닿는다");
          }
          if (thrown == null) continue;
          table.add((target ? "*" : " ") + v.id() + "|" + call.getKey() + "|" + thrown.getClass().getSimpleName());
          if ((v.id() + "@" + call.getKey()).equals(System.getenv("KCSDK_DUMP_TRACE"))) {
            System.out.println("[TRACE " + v.id() + "|" + call.getKey() + "]\n" + render(thrown).get("printStackTrace"));
          }
          render(thrown).forEach((how, out) -> canaries.forEach((name, secret) -> {
            String exposed = exposure(out, secret);
            if (exposed == null) return;
            String known = v.id() + "|" + call.getKey() + "|" + name;
            if (KNOWN_LEAKS.containsKey(known)) {
              knownSeen.add(known);
            } else {
              leaks.add(known + "|" + how + "|" + exposed + "  <<" + lineWith(out, secret) + ">>");
            }
          }));
        }
      }
      System.out.println("[MalformedIdpResponseTest] variants=" + variants.size() + " failing(variant|call|type, *=target)="
          + table.size() + "\n  " + String.join("\n  ", table));
      System.out.println("[MalformedIdpResponseTest] leaks=" + leaks.size() + "\n  " + String.join("\n  ", leaks));
      assertTrue(flow.isEmpty(), () -> "흐름 — 변형이 호출을 실패시키지 않았다:\n" + String.join("\n", flow));
      assertTrue(leaks.isEmpty(), () -> "오류 표현이 토큰을 찍는다:\n" + String.join("\n", leaks));
      Set<String> stale = new TreeSet<>(KNOWN_LEAKS.keySet());
      stale.removeAll(knownSeen);
      assertTrue(stale.isEmpty(), () -> "알려진 누출이 더 안 난다 — 고쳐졌으면 KNOWN_LEAKS 를 지워라: " + stale);
    }
  }

  /**
   * 가린 뒤에도 진단은 남는다 — SDK 메시지·분류(auth/transport)·OAuth 오류 코드·IdP 산문, 그리고 원인 사슬의 하위
   * **타입 이름**. 하위 타입 인스턴스 자체는 원인으로 새지 않는다(§4).
   */
  @Test
  void failuresKeepTheirDiagnosis() throws Exception {
    RSAKey key = new RSAKeyGenerator(2048).keyID("k1").generate();
    signValidateJwt(key);
    try (FakeIdp idp = new FakeIdp(key)) {
      variants(key, key, idp.url() + "/realms/a4").forEach(v -> idp.variants.put(v.id(), v));

      KeycloakAuthException parse = assertInstanceOf(KeycloakAuthException.class,
          run(idp, idp.variants.get("d1"), CALLS.get(CC)));
      assertEquals("Client credentials request error", parse.getMessage());
      assertFalse(parse.getCause() instanceof com.nimbusds.oauth2.sdk.ParseException, "하위 타입이 원인으로 샜다(§4)");
      String trace = render(parse).get("printStackTrace");
      assertTrue(trace.contains("com.nimbusds.oauth2.sdk.ParseException (message withheld"), trace);
      assertTrue(trace.contains("net.minidev.json.parser.ParseException (message withheld"), trace);

      KeycloakTransportException admin = assertInstanceOf(KeycloakTransportException.class,
          run(idp, idp.variants.get("d8"), CALLS.get(ADMIN)));
      assertEquals("admin transport failure", admin.getMessage());
      String adminTrace = render(admin).get("printStackTrace");
      assertTrue(adminTrace.contains("jakarta.ws.rs.client.ResponseProcessingException (message withheld"), adminTrace);
      assertTrue(adminTrace.contains("com.fasterxml.jackson."), adminTrace);

      KeycloakAuthException echo = assertInstanceOf(KeycloakAuthException.class,
          run(idp, idp.variants.get("e1"), CALLS.get(RF)));
      assertEquals("invalid_grant", echo.getError());
      assertEquals("Token refresh failed: rejected *** ***", echo.getMessage()); // refresh 토큰 · Basic 자격
      KeycloakAuthException prefix = assertInstanceOf(KeycloakAuthException.class,
          run(idp, idp.variants.get("e7"), CALLS.get(IN)));
      assertEquals("Introspection failed: rejected ***... ***...", prefix.getMessage()); // 잘린 되울림
    }
  }

  private static Throwable run(FakeIdp idp, Variant v, Call call) {
    try (KeycloakClient kc = KeycloakClient.create(KeycloakConfig.builder().serverUrl(idp.url())
        .realm(v.id()).clientId(CLIENT_ID).clientSecret(SECRET.toCharArray()).build())) {
      call.run(kc);
      return null;
    } catch (Throwable t) {
      return t;
    }
  }

  /** 로거가 찍는 두 표현 — {@code toString()} 과 원인 사슬·suppressed 를 전부 싣는 {@code printStackTrace}. */
  static Map<String, String> render(Throwable t) {
    Map<String, String> outs = new LinkedHashMap<>();
    outs.put("toString", t.toString());
    StringWriter sw = new StringWriter();
    t.printStackTrace(new PrintWriter(sw, true));
    outs.put("printStackTrace", sw.toString());
    return outs;
  }

  /** 전부면 FULL, 첫 10 자만 있으면 PREFIX, 없으면 null. */
  static String exposure(String out, String secret) {
    if (out.contains(secret)) return "FULL";
    if (secret.length() >= 10 && out.contains(secret.substring(0, 10))) return "PREFIX";
    return null;
  }

  private static String lineWith(String out, String secret) {
    String needle = out.contains(secret) ? secret : secret.substring(0, 10);
    for (String line : out.split("\\R")) {
      if (line.contains(needle)) return line.length() > 220 ? line.substring(0, 220) + "…" : line;
    }
    return "?";
  }

  /** 가짜 IdP — realm 이름이 곧 변형 id 다. 토큰·introspect·logout·JWKS·admin GET. */
  private static final class FakeIdp implements AutoCloseable {
    final Map<String, Variant> variants = new ConcurrentHashMap<>();
    private final HttpServer server;

    FakeIdp(RSAKey key) throws IOException {
      String jwks = new JWKSet(key.toPublicJWK()).toString();
      server = HttpServer.create(new InetSocketAddress(InetAddress.getLoopbackAddress(), 0), 0);
      server.createContext("/", ex -> {
        String body = new String(ex.getRequestBody().readAllBytes(), StandardCharsets.UTF_8);
        String auth = ex.getRequestHeaders().getFirst("Authorization");
        String[] p = ex.getRequestURI().getPath().split("/");
        // /realms/{v}/protocol/openid-connect/{rest...}  ·  /admin/realms/{v}/users/x
        Reply r = null;
        if (p.length >= 6 && p[1].equals("realms") && p[3].equals("protocol") && variants.containsKey(p[2])) {
          Variant v = variants.get(p[2]);
          r = switch (String.join("/", Arrays.copyOfRange(p, 5, p.length))) {
            case "token" -> v.token();
            case "token/introspect" -> v.introspect();
            case "logout" -> v.logout();
            case "certs" -> v.certs() != null ? v.certs() : json(200, jwks);
            default -> null;
          };
        } else if (p.length == 6 && p[1].equals("admin") && variants.containsKey(p[3])) {
          r = variants.get(p[3]).admin();
        }
        send(ex, r == null ? new Resp(404, "application/json", "{\"error\":\"not found\"}") : r.reply(body, auth));
      });
      server.start();
    }

    String url() {
      return "http://127.0.0.1:" + server.getAddress().getPort();
    }

    private static void send(HttpExchange ex, Resp r) throws IOException {
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
}
