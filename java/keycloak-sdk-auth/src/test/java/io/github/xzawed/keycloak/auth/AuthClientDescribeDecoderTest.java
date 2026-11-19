package io.github.xzawed.keycloak.auth;

import static org.junit.jupiter.api.Assertions.assertEquals;

import com.nimbusds.oauth2.sdk.http.HTTPRequest;
import java.net.URL;
import java.util.Locale;
import org.junit.jupiter.api.Test;

/**
 * {@code AuthClient.describe} 의 되울림 디코더와 그 둘레 — 인코딩된 되울림을 푼 바이트로 맞추는 {@code maskDecoded} 의 이스케이프
 * 읽기({@code unescapeAt} · {@code unitAt} · {@code entityAt} · {@code hexByte} · {@code hexDigit} · {@code digit}), 보낸 값
 * 모으기({@code sentValues} · {@code sentSecrets}), 연속 규칙의 말줄임표({@code maskRun}). 단위 미도달 장부
 * ({@code scripts/unit-unreached.json})가 단위 시험이 안 닿는다고 적었던 갈래를 민다(등록부 coverage-omit-hides-security-paths).
 *
 * <p>⚠️ 되울림은 SDK 가 꼴로 늘어놓지 않는 인코딩({@code %uXXXX} · HTML 숫자 참조)으로 싣는다 — 늘어놓는 꼴(폼 · 퍼센트 인코딩)이면
 * 그대로 가리기({@code String.replace})가 먼저 가려, 디코더가 틀려도 이 시험이 초록이다. 메시지는 통째로 대조한다: 되울림은
 * {@code ***} 이고, 이스케이프가 아니거나 못 푸는 글자는 그대로 남으며, 그 바로 옆의 되울림도 가려진다(잘못 읽은 이스케이프가
 * 되울림의 첫 글자를 삼키면 바늘이 빗나간다). 인코더는 이 시험이 따로 만든다. 서로게이트는 {@code (char)} 와
 * {@code Character.toChars} 로 만든다 — 편집 도구가 소스의 유니코드 이스케이프를 글자로 풀어 쓴다(등록부 함정 (aa)).
 */
class AuthClientDescribeDecoderTest {
  private static final String PREFIX = "Bad credentials: ";
  /** 보낸 시크릿 — 비 ASCII 하나(é, UTF-8 두 바이트)를 품는다. */
  private static final String SECRET = "sec-ret-0001é";
  private static final String REFRESH = "rt-9f8e7d6c5b4a39281706";
  /** 짝 없는 high 서로게이트 U+D83D. */
  private static final char HIGH = (char) 0xD83D;
  /** U+1F600 — UTF-16 으로는 서로게이트 둘(D83D · DE00). */
  private static final String EMOJI = new String(Character.toChars(0x1F600));

  private static HTTPRequest sent(String body, String authorization) throws Exception {
    HTTPRequest req = new HTTPRequest(HTTPRequest.Method.POST, new URL("http://idp/token"));
    if (body != null) req.setBody(body);
    if (authorization != null) req.setAuthorization(authorization);
    return req;
  }

  /** 클라이언트 시크릿 {@code secret} 하나만 보낸 요청(본문에 비밀 파라미터가 없다)의 사유. */
  private static String describe(String description, String secret) throws Exception {
    return AuthClient.describe(description, sent("grant_type=client_credentials", null), secret.toCharArray());
  }

  /** 모든 UTF-16 코드 단위를 {@code %uXXXX} 로 — .NET {@code UrlEncodeUnicode} 류. */
  private static String units(String v) {
    StringBuilder out = new StringBuilder();
    for (char c : v.toCharArray()) out.append(String.format(Locale.ROOT, "%%u%04X", (int) c));
    return out.toString();
  }

  /** JS {@code escape} — 알파벳·숫자와 {@code @*_+-./} 는 그대로, U+00FF 까지는 {@code %XX}, 그 위는 코드 단위마다 {@code %uXXXX}. */
  private static String jsEscape(String v) {
    StringBuilder out = new StringBuilder();
    for (char c : v.toCharArray()) {
      if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || "@*_+-./".indexOf(c) >= 0) {
        out.append(c);
      } else {
        out.append(String.format(Locale.ROOT, c <= 0xFF ? "%%%02X" : "%%u%04X", (int) c));
      }
    }
    return out.toString();
  }

  /** 코드 포인트마다 HTML 16진 숫자 참조 — {@code x} 는 {@code x} 또는 {@code X}. */
  private static String hexReferences(String v, char x) {
    StringBuilder out = new StringBuilder();
    v.codePoints().forEach(cp -> out.append("&#").append(x).append(Integer.toHexString(cp).toUpperCase(Locale.ROOT)).append(';'));
    return out.toString();
  }

  /** 코드 포인트마다 일곱 자리(앞을 0 으로 채운) 10진 숫자 참조 — {@code entityAt} 이 읽는 가장 긴 숫자 열이다. */
  private static String sevenDigitReferences(String v) {
    StringBuilder out = new StringBuilder();
    v.codePoints().forEach(cp -> out.append(String.format(Locale.ROOT, "&#%07d;", cp)));
    return out.toString();
  }

  @Test void surrogatesInPercentU_decodeToTheBytesOfTheSentValue() throws Exception {
    // JS escape 는 BMP 밖 글자를 서로게이트 둘(%uD83D%uDE00)로 쓴다 — 둘을 이어 한 글자의 UTF-8(네 바이트)로 풀어야 보낸 값과 맞는다.
    String pair = "kc-" + EMOJI + "-secret-0002";
    assertEquals(PREFIX + "***", describe(PREFIX + jsEscape(pair), pair));
    // 짝 없는 high 서로게이트 — 디코더와 바늘이 같은 규칙(UTF-8 이 그 자리에 ? 를 쓴다)으로 바이트를 만든다. 뒤가 이스케이프가
    // 아니어도(%uD83DA) · 낮은 서로게이트가 아닌 단위여도(%uD83D%u0041) 그 하나만 ? 로 풀고, 뒤 글자는 제 것으로 읽는다.
    String lone = "kc-" + HIGH + "A-secret-0003";
    assertEquals(PREFIX + "***", describe(PREFIX + jsEscape(lone), lone));
    assertEquals(PREFIX + "***", describe(PREFIX + units(lone), lone));
  }

  @Test void htmlNumericReferences_hexAndSevenDigits_decodeToTheBytesOfTheSentValue() throws Exception {
    // &#xHH; · &#XHH;(16진 — x 의 대소문자는 가리지 않는다)와, 앞을 0 으로 채운 일곱 자리 10진(entityAt 이 읽는 가장 긴 열).
    assertEquals(PREFIX + "***", describe(PREFIX + hexReferences(SECRET, 'x'), SECRET));
    assertEquals(PREFIX + "***", describe(PREFIX + hexReferences(SECRET, 'X'), SECRET));
    assertEquals(PREFIX + "***", describe(PREFIX + sevenDigitReferences(SECRET), SECRET));
  }

  @Test void malformedPercentEscapes_areKeptVerbatim_andTheEchoBesideThemIsStillMasked() throws Exception {
    String echo = units(SECRET);
    // %4 뒤가 16진이 아니다(%) — 바이트도 %u 도 아니니 % 한 글자만 넘기고, 바로 뒤의 되울림을 처음부터 읽는다.
    assertEquals(PREFIX + "%4***", describe(PREFIX + "%4" + echo, SECRET));
    // %u 뒤 넷 중 16진이 아닌 글자가 있다.
    assertEquals(PREFIX + "***%u12zz", describe(PREFIX + echo + "%u12zz", SECRET));
    // 글 끝에서 잘린 이스케이프 — 남은 글자보다 길게 읽지 않는다(% 뒤 둘 · %u 뒤 넷이 모자란다).
    assertEquals(PREFIX + "*** at 100%", describe(PREFIX + echo + " at 100%", SECRET));
    assertEquals(PREFIX + "*** %u00", describe(PREFIX + echo + " %u00", SECRET));
  }

  @Test void malformedHtmlReferences_areKeptVerbatim_andTheEchoBesideThemIsStillMasked() throws Exception {
    String echo = units(SECRET);
    String[][] cases = {
        {"R&D " + echo, "R&D ***"},               // & 뒤가 # 가 아니다 — 이름 참조도 풀지 않는다
        {echo + " R&D", "*** R&D"},               // 글 끝 세 글자 안의 &
        {"&#;" + echo, "&#;***"},                 // 숫자가 없다
        {"&#x;" + echo, "&#x;***"},               // 16진 숫자가 없다
        {"&#1a;" + echo, "&#1a;***"},             // 10진 참조 안의 16진 글자
        {"&#00000065;" + echo, "&#00000065;***"}, // 여덟 자리 — 일곱 자리에서 멈추고, 그 뒤가 ; 가 아니다
        {"&#1114112;" + echo, "&#1114112;***"},   // U+10FFFF 너머(10진)
        {"&#x110000;" + echo, "&#x110000;***"},   // U+10FFFF 너머(16진)
        {echo + " &#123", "*** &#123"},           // ; 없이 글이 끝난다
    };
    for (String[] c : cases) assertEquals(PREFIX + c[1], describe(PREFIX + c[0], SECRET), c[1]);
  }

  @Test void ellipsisAroundARun_isKept_andTheRunIsJudgedWithoutIt() throws Exception {
    HTTPRequest req = sent("grant_type=refresh_token&refresh_token=" + REFRESH, null);
    // 통째 되울림 뒤의 말줄임표 — 가린 자리(***) 뒤에 점만 남은 연속은 몸통이 비어 그대로 둔다.
    assertEquals("rejected ***...", AuthClient.describe("rejected " + REFRESH + "...", req, null));
    // 앞 말줄임표는 떼고 잰다 — 토큰 모양의 몸통 · 보낸 토큰의 꼬리(10 자 창을 나눈다)를 가리고 점은 남긴다.
    assertEquals("rejected ...***", AuthClient.describe("rejected ...ZeF-0123456789abcdef", req, null));
    assertEquals("rejected ...***", AuthClient.describe("rejected ..." + REFRESH.substring(10), req, null));
  }

  @Test void requestWithoutBody_masksWhatItsAuthorizationSent() throws Exception {
    // 본문 없는 요청 — 보낸 비밀은 Authorization 과 시크릿뿐이다. Basic 자격(base64)과, 그것을 푼 userinfo 의 시크릿을 가린다.
    HTTPRequest req = sent(null, "Basic YzpzZWNyZXQ=");
    assertEquals("bad *** for c:***", AuthClient.describe("bad YzpzZWNyZXQ= for c:secret", req, "secret".toCharArray()));
  }

  @Test void emptySentValueOrEchoForm_isNotASecret_andProseIsKept() throws Exception {
    // 빈 값은 보낸 비밀이 아니다 — 빈 문자열을 가리면(String.replace) 글자 사이마다 *** 가 박힌다. 빈 refresh_token · 빈 시크릿.
    HTTPRequest refresh = sent("grant_type=refresh_token&refresh_token=", null);
    assertEquals("Token is not active", AuthClient.describe("Token is not active", refresh, new char[0]));
    // 비 ASCII 뿐인 시크릿은 RFC 6749 §5.2 밖 글자를 지운 꼴(Nimbus 가 설명에 하는 일)이 빈 문자열이다 — 그 꼴만 버리고 나머지 꼴로 가린다.
    HTTPRequest cc = sent("grant_type=client_credentials", null);
    assertEquals("Token is not active", AuthClient.describe("Token is not active", cc, "비밀번호".toCharArray()));
    assertEquals(PREFIX + "***", AuthClient.describe(PREFIX + "비밀번호", cc, "비밀번호".toCharArray()));
  }
}
