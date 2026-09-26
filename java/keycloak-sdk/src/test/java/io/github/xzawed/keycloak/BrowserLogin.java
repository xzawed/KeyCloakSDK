package io.github.xzawed.keycloak;

import static org.junit.jupiter.api.Assertions.fail;

import com.nimbusds.common.contenttype.ContentType;
import com.nimbusds.oauth2.sdk.http.HTTPRequest;
import com.nimbusds.oauth2.sdk.http.HTTPResponse;
import io.github.xzawed.keycloak.auth.AuthorizationUrlRequest;
import java.io.IOException;
import java.io.UncheckedIOException;
import java.net.URI;
import java.net.URLDecoder;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * 브라우저 없는 로그인 — 실제 Keycloak 로그인 폼을 HTTP 로 채워 인가 코드를 받는다
 * ({@code python/tests/integration/browser_login.py} 의 세 걸음을 그대로 옮겼다).
 *
 * <ol>
 *   <li>SDK 가 만든 인가 URL 을 GET 한다(로그인 페이지 + 인증 세션 쿠키 — 쿠키는 2 에서 직접 되싣는다).
 *   <li>{@code <form id="kc-form-login">} 의 {@code action} 에 사용자명·비밀번호를 POST 하되 <b>리다이렉트는
 *       따라가지 않는다</b> — redirect_uri 에는 아무것도 떠 있지 않다. 302 의 {@code Location} 이 곧 콜백이다.
 *   <li>{@code Location} 에서 {@code code}·{@code state} 를 꺼내고, {@code state} 가 SDK 가 발급한 값인지 확인한다.
 * </ol>
 *
 * <p>폼을 못 찾거나 상태 코드가 틀리면 받은 HTML 앞부분을 실어 실패한다 — 테마가 바뀌었을 때 원인이 바로 보이게.
 *
 * <p>⚠️ 전송은 {@code java.net.http.HttpClient} 가 아니라 Nimbus {@link HTTPRequest} 다 — {@code AuthFlowIT} 와 같은
 * 이유(이 모듈은 테스트까지 {@code --release 17} 이라 {@code HttpClient.close()} 가 없다). {@code HttpURLConnection}
 * 위라서 기본 {@code CookieHandler} 가 없으면 쿠키를 저장하지도 싣지도 않는다 — 되싣기는 전부 여기서 한다.
 */
final class BrowserLogin {
  static final String LOGIN_FORM_ID = "kc-form-login";

  private static final Pattern FORM_TAG = Pattern.compile("<form\\b[^>]*>", Pattern.CASE_INSENSITIVE);
  private static final Pattern ATTRIBUTE =
      Pattern.compile("([A-Za-z_:][-A-Za-z0-9_:.]*)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)')");
  private static final Pattern ENTITY = Pattern.compile("&(#[xX][0-9A-Fa-f]+|#[0-9]+|amp|quot|apos|lt|gt);");

  private BrowserLogin() {}

  /** {@code request}(SDK 의 {@code createAuthorizationRequest} 결과)로 로그인해 인가 코드를 돌려준다. */
  static String login(AuthorizationUrlRequest request, URI redirectUri, String username, String password) {
    return login(request.getAuthorizationUrl(), request.getState(), redirectUri, username, password);
  }

  /**
   * 인가 URL 을 직접 받는 형태 — {@link #withoutQueryParameter} 로 고친 URL 에 쓴다. {@code expectedState} 는 SDK 가
   * 그 URL 에 실은 CSRF 값이다.
   */
  static String login(URI authorizationUrl, String expectedState, URI redirectUri, String username,
      String password) {
    HTTPRequest get = new HTTPRequest(HTTPRequest.Method.GET, authorizationUrl);
    get.setFollowRedirects(false);
    HTTPResponse page = send(get);
    if (page.getStatusCode() != 200) {
      fail("login page did not render:\n" + snippet(authorizationUrl, page));
    }
    String action = loginFormAction(page.getBody());
    if (action == null) {
      fail("no <form id=\"" + LOGIN_FORM_ID + "\"> in the login page:\n" + snippet(authorizationUrl, page));
    }
    // ⚠️ 쿠키 저장소에 맡기지 말고 **직접 되싣는다.** Keycloak 26 은 http 에서도 로그인 쿠키에 `Secure` 를 단다.
    // 브라우저는 localhost 를 안전한 출처로 봐서 보내지만, RFC 6265 대로 사는 저장소(java.net.CookieManager 등)는
    // http 요청에 싣지 않아 POST 가 400 "Restart login cookie not found" 로 끝난다(python 파일럿 실측).
    String cookies = cookieHeader(page);
    if (cookies.isEmpty()) {
      fail("login page set no cookies — the POST cannot carry the auth session:\n" + snippet(authorizationUrl, page));
    }
    URI actionUri = URI.create(action);
    HTTPRequest post = new HTTPRequest(HTTPRequest.Method.POST, actionUri);
    post.setFollowRedirects(false);
    post.setEntityContentType(ContentType.APPLICATION_URLENCODED);
    post.setHeader("Cookie", cookies);
    post.setBody("username=" + URLEncoder.encode(username, StandardCharsets.UTF_8)
        + "&password=" + URLEncoder.encode(password, StandardCharsets.UTF_8));
    HTTPResponse answer = send(post);

    if (answer.getStatusCode() != 302) {
      fail("login POST did not redirect:\n" + snippet(actionUri, answer));
    }
    URI location = answer.getLocation();
    if (location == null) {
      fail("login POST redirected without a Location:\n" + snippet(actionUri, answer));
    }
    String landed = location.getScheme() + "://" + location.getRawAuthority() + location.getRawPath();
    if (!landed.equals(redirectUri.toString())) {
      fail("login redirected somewhere else: " + location);
    }
    Map<String, List<String>> query = parseQuery(location.getRawQuery());
    // state 는 SDK 가 인가 URL 에 실은 CSRF 값이다 — 서버가 그대로 되돌려야 한다.
    if (!List.of(expectedState).equals(query.get("state"))) {
      fail("state mismatch: sent " + expectedState + ", got " + query.get("state"));
    }
    List<String> codes = query.get("code");
    if (codes == null || codes.size() != 1 || codes.get(0).isEmpty()) {
      fail("no single authorization code in the callback: " + location);
    }
    return codes.get(0);
  }

  /** 인가 URL 에서 파라미터 하나만 뺀다(나머지는 인코딩 그대로) — 예: nonce 를 빼 서버가 nonce 없는 id_token 을 서명하게. */
  static URI withoutQueryParameter(URI url, String name) {
    List<String> kept = new ArrayList<>();
    for (String pair : url.getRawQuery().split("&")) {
      String key = pair.contains("=") ? pair.substring(0, pair.indexOf('=')) : pair;
      if (!URLDecoder.decode(key, StandardCharsets.UTF_8).equals(name)) {
        kept.add(pair);
      }
    }
    return URI.create(url.getScheme() + "://" + url.getRawAuthority() + url.getRawPath() + "?" + String.join("&", kept));
  }

  static Map<String, List<String>> parseQuery(String rawQuery) {
    Map<String, List<String>> out = new LinkedHashMap<>();
    if (rawQuery == null) {
      return out;
    }
    for (String pair : rawQuery.split("&")) {
      int eq = pair.indexOf('=');
      String key = URLDecoder.decode(eq < 0 ? pair : pair.substring(0, eq), StandardCharsets.UTF_8);
      String value = eq < 0 ? "" : URLDecoder.decode(pair.substring(eq + 1), StandardCharsets.UTF_8);
      out.computeIfAbsent(key, k -> new ArrayList<>()).add(value);
    }
    return out;
  }

  /** {@code <form id="kc-form-login">} 의 action — 속성 값의 {@code &amp;} 등 문자 참조는 푼다. 없으면 null. */
  static String loginFormAction(String html) {
    if (html == null) {
      return null;
    }
    Matcher form = FORM_TAG.matcher(html);
    while (form.find()) {
      Map<String, String> attributes = new LinkedHashMap<>();
      Matcher attribute = ATTRIBUTE.matcher(form.group());
      while (attribute.find()) {
        String value = attribute.group(2) != null ? attribute.group(2) : attribute.group(3);
        attributes.put(attribute.group(1).toLowerCase(java.util.Locale.ROOT), unescape(value));
      }
      if (LOGIN_FORM_ID.equals(attributes.get("id"))) {
        return attributes.get("action");
      }
    }
    return null;
  }

  private static String unescape(String value) {
    Matcher entity = ENTITY.matcher(value);
    StringBuilder out = new StringBuilder();
    while (entity.find()) {
      String name = entity.group(1);
      String text;
      if (name.startsWith("#x") || name.startsWith("#X")) {
        text = new String(Character.toChars(Integer.parseInt(name.substring(2), 16)));
      } else if (name.startsWith("#")) {
        text = new String(Character.toChars(Integer.parseInt(name.substring(1))));
      } else {
        text = Map.of("amp", "&", "quot", "\"", "apos", "'", "lt", "<", "gt", ">").get(name);
      }
      entity.appendReplacement(out, Matcher.quoteReplacement(text));
    }
    entity.appendTail(out);
    return out.toString();
  }

  /** 받은 {@code Set-Cookie} 전부를 {@code name=value} 로 이어 붙인다(속성 — Secure·Path 등 — 은 버린다). */
  private static String cookieHeader(HTTPResponse page) {
    List<String> pairs = new ArrayList<>();
    List<String> setCookies = page.getHeaderValues("Set-Cookie");
    if (setCookies != null) {
      for (String setCookie : setCookies) {
        int end = setCookie.indexOf(';');
        pairs.add((end < 0 ? setCookie : setCookie.substring(0, end)).trim());
      }
    }
    return String.join("; ", pairs);
  }

  private static HTTPResponse send(HTTPRequest request) {
    try {
      return request.send();
    } catch (IOException e) {
      throw new UncheckedIOException("browser login transport failure: " + request.getURI(), e);
    }
  }

  private static String snippet(URI url, HTTPResponse response) {
    String body = response.getBody() == null ? "" : response.getBody();
    return "HTTP " + response.getStatusCode() + " " + url + "\n" + body.substring(0, Math.min(1500, body.length()));
  }
}
