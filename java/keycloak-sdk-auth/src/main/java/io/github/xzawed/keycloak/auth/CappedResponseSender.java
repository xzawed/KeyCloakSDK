package io.github.xzawed.keycloak.auth;

import com.nimbusds.common.contenttype.ContentType;
import com.nimbusds.oauth2.sdk.http.HTTPRequest;
import com.nimbusds.oauth2.sdk.http.HTTPResponse;
import io.github.xzawed.keycloak.core.ResponseLimits;
import java.io.BufferedReader;
import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.net.URI;
import java.nio.ByteBuffer;
import java.nio.CharBuffer;
import java.nio.charset.Charset;
import java.nio.charset.CharsetDecoder;
import java.nio.charset.CoderResult;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.util.EnumSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import javax.net.ssl.HostnameVerifier;
import javax.net.ssl.SSLSocketFactory;
import org.apache.http.HttpResponse;
import org.apache.http.client.methods.HttpEntityEnclosingRequestBase;
import org.apache.http.client.methods.HttpRequestBase;
import org.apache.http.entity.ByteArrayEntity;

/**
 * Nimbus {@code HTTPRequest.send()} 와 같은 일을 하되 응답 본문을 {@link ResponseLimits#MAX_TOKEN_RESPONSE_BYTES} 까지만 읽는
 * 송신 — {@link AuthClient} 의 토큰(세 그랜트)·introspection·logout 요청이 전부 {@link #send} 로 나간다.
 *
 * <p>왜: Nimbus 의 {@code send()} 는 본문을 readLine 고리로 끝까지 담는다(크기 설정이 없다) — 쓸 수 있는 토큰 뒤에 JSON 공백
 * 32 MiB 를 붙인 응답을 다섯 레인이 받아들였고 호출 하나가 약 235 MB 를 할당했다(실측 — {@code TokenResponseCapTest}). 오류
 * 상태의 본문도 같은 고리였다.
 *
 * <p>운송은 {@link BoundedTransport} 다 — JDK 의 HttpURLConnection 은 트레일러에 한도가 없었고 상한을 넘은 청크 본문을 닫으며 쌓인
 * 바이트를 제곱 비용으로 풀었다(그 클래스 설명). 요청은 Nimbus 가 이 요청으로 HttpURLConnection 에 실었을 그대로 만든다({@link
 * #toApache}): 메서드·URL·헤더 표(제한 헤더는 HttpURLConnection 처럼 버린다)·POST/PUT 의 Content-Type 과 본문(플랫폼 기본 문자셋 —
 * Nimbus 의 {@code OutputStreamWriter} 와 같다)·연결/읽기 타임아웃. TLS 근원은 이 요청의 소켓 팩토리와 검증기이고, 없으면 Nimbus 의
 * 기본값이다({@code HTTPRequest.getDefaultSSLSocketFactory()} — Nimbus 가 클래스 초기화 때 잡아 둔 값, 오늘 그대로). ⚠️ 리다이렉트는
 * 요청의 플래그와 무관하게 따르지 않는다 — 모든 호출부가 {@code AuthClient.applyTimeouts} 로 끄는 값이고(SSRF 하드닝), 이 송신은
 * 그것을 따르는 길을 아예 두지 않는다. 요청의 프록시({@code HTTPRequest.setProxy})는 보지 않는다 — SDK 가 설정하지 않는 값이고,
 * 시스템 프록시({@code http(s).proxyHost})는 따른다.
 *
 * <p>상한 안의 본문은 Nimbus 와 같은 문자열로 만든다({@link #asNimbusReadsIt}) — 파서가 받는 입력이 지금과 같다. 그 본문은 EOF 까지
 * 읽으므로 연결은 운송의 풀로 돌아가 다음 호출이 다시 쓴다(HttpURLConnection 의 keep-alive 처럼). 상한을 넘으면 나머지를 읽지 않고
 * <b>그 연결을 끊은 뒤</b>(풀에 돌려주지 않는다 — 평문은 그 자리에서 끝나고, HTTPS 는 JSSE 가 닫으며 이미 도착한 바이트를 버린다)
 * {@link TooLarge} 를 던지고, 호출부가 그 레인의 {@code KeycloakTransportException} 으로 바꾼다. SDK 가 요청하고 쥐는 것은 상한+1
 * 바이트까지다({@link #readWithinCap}). 운송은 내용 코딩을 요청하지도 풀지도 않으므로 센 바이트가 받은 바이트다. 그 본문을 읽는 동안
 * 연결에서 받는 틀(청크 머리·트레일러 포함)은 상한의 8 배까지다({@code BoundedTransport.wireBounded}).
 *
 * <p>인스턴스 상태가 없다 — 호출 하나의 스택에만 사는 값(연결·본문)을 필드로 쥐지 않는다.
 */
final class CappedResponseSender {
  private CappedResponseSender() {}

  /** Nimbus 가 본문을 쓰는 메서드({@code toHttpURLConnection} 의 {@code setDoOutput(true)}) — 나머지는 본문 없이 보낸다. */
  private static final Set<HTTPRequest.Method> WITH_BODY = EnumSet.of(HTTPRequest.Method.POST, HTTPRequest.Method.PUT);

  /** {@code request.send()} 대신 — 같은 요청·같은 응답이되 본문은 상한까지만 읽는다. {@code what} 은 넘침 메시지의 주어다. */
  static HTTPResponse send(HTTPRequest request, String what) throws IOException {
    return request.send(sameRequest -> receive(request, what, false));
  }

  /**
   * {@link #send} 와 같되 <b>2xx 본문은 UTF-8 이어야 한다</b> — 아니면 {@link NotUtf8}(끝까지 온 응답을 쓸 수 없다 — 호출부가 그 레인의
   * 인증 오류로 바꾼다). 토큰(세 그랜트)·introspection 이 이것을 지난다 — 그 2xx 본문은 JSON 이고 RFC 8259 §8.1 은 UTF-8 이다.
   * ⚠️ Nimbus 와 같은 디코딩({@link #asNimbusReadsIt})은 잘못된 바이트를 U+FFFD 로 바꿔 <b>받아들였다</b> — IdP 가 내지 않은 토큰
   * (ok · U+FFFD 둘 · vc)·바뀐 클레임이 성공으로 나갔다(실측 — {@code TokenResponseClassTest}). 오류 상태의 본문은 보지 않는다
   * (판정은 상태가 한다 — 사유 문구는 지금처럼 읽는다). 선언된 charset 도 보지 않는다(RFC 8259 §11 — application/json 에는 효과가
   * 없다). logout 은 본문을 쓰지 않으므로 {@link #send} 다. 유효한 UTF-8 은 지금과 같은 문자열이다.
   */
  static HTTPResponse sendStrict(HTTPRequest request, String what) throws IOException {
    return request.send(sameRequest -> receive(request, what, true));
  }

  private static HTTPResponse receive(HTTPRequest request, String what, boolean strict) throws IOException {
    SSLSocketFactory tls = request.getSSLSocketFactory() != null
        ? request.getSSLSocketFactory() : HTTPRequest.getDefaultSSLSocketFactory();
    HostnameVerifier verifier = request.getHostnameVerifier() != null
        ? request.getHostnameVerifier() : HTTPRequest.getDefaultHostnameVerifier();
    return BoundedTransport.exchange(toApache(request), tls, verifier, request.getConnectTimeout(), request.getReadTimeout(),
        ResponseLimits.MAX_TOKEN_RESPONSE_BYTES, (head, body) -> toNimbus(head, body, what, strict));
  }

  /**
   * Nimbus {@code toHttpURLConnection()} 이 HttpURLConnection 에 싣는 그대로의 요청. ⚠️ 본문을 싣는 요청에 Content-Type 이 없을 때
   * HttpURLConnection 이 덧붙이는 {@code application/x-www-form-urlencoded} 는 따라하지 않는다 — SDK 의 요청은 모두 그것을 단다.
   */
  static HttpRequestBase toApache(HTTPRequest request) {
    String method = request.getMethod().name();
    boolean withBody = WITH_BODY.contains(request.getMethod());
    HttpRequestBase out;
    if (withBody) {
      HttpEntityEnclosingRequestBase enclosing = new HttpEntityEnclosingRequestBase() {
        @Override public String getMethod() {
          return method;
        }
      };
      // 본문이 없어도 본문을 싣는 요청이다 — HttpURLConnection 처럼 Content-Length: 0
      if (request.getBody() != null) enclosing.setEntity(new ByteArrayEntity(request.getBody().getBytes(Charset.defaultCharset())));
      out = enclosing;
    } else {
      out = new HttpRequestBase() {
        @Override public String getMethod() {
          return method;
        }
      };
    }
    out.setURI(URI.create(request.getURL().toString()));
    BoundedTransport.addHeaders(out, request.getHeaderMap());
    if (withBody) {
      ContentType type = request.getEntityContentType();
      if (type != null) out.setHeader("Content-Type", type.toString()); // Nimbus 의 setRequestProperty — 표의 값을 대신한다
    }
    BoundedTransport.addJdkDefaults(out, request.getURL());
    return out;
  }

  private static HTTPResponse toNimbus(HttpResponse head, InputStream in, String what, boolean strict) throws IOException {
    byte[] body = readWithinCap(in);
    if (body == null) throw new TooLarge(what);
    int status = head.getStatusLine().getStatusCode();
    if (strict && status >= 200 && status < 300 && !isUtf8(body)) throw new NotUtf8(what);
    if (strict && status >= 200 && status < 300 && holdsUnpairedSurrogate(body)) {
      throw new NotUtf8(what, "holds an unpaired surrogate escape");
    }
    HTTPResponse response = new HTTPResponse(status);
    response.setStatusMessage(head.getStatusLine().getReasonPhrase());
    for (Map.Entry<String, List<String>> header : BoundedTransport.grouped(head).entrySet()) {
      response.setHeader(header.getKey(), header.getValue().toArray(new String[0]));
    }
    response.setBody(asNimbusReadsIt(body));
    return response;
  }

  /**
   * 상한+1 바이트까지만 읽는다(넘침을 알아챌 한 바이트) — 넘치면 null. {@code readNBytes(int)} 는 남은 길이 너머를 요청하지 않고 JDK
   * 기본 조각(17: 8 KiB · 21: 16 KiB)으로 <b>읽은 만큼만</b> 할당한다 — 작은 본문은 작은 배열이고, 넘치는 본문도 상한의 약 두
   * 배(읽은 조각 + 그것을 이은 배열)다. 상한만 한 버퍼를 미리 잡지 않는다(그러면 요청 하나하나가 상한을 할당한다).
   */
  static byte[] readWithinCap(InputStream in) throws IOException {
    byte[] body = in.readNBytes(ResponseLimits.MAX_TOKEN_RESPONSE_BYTES + 1);
    return body.length > ResponseLimits.MAX_TOKEN_RESPONSE_BYTES ? null : body;
  }

  /**
   * Nimbus {@code send()} 가 본문을 만드는 그대로 — UTF-8 로 줄 단위로 읽어 줄마다 {@code line.separator} 를 붙인다(마지막 줄
   * 뒤에도). 빈 본문은 null(본문 없음). 그래서 상한 안의 본문은 파서에 예전과 같은 문자열로 간다({@code CappedResponseSenderTest} 가
   * Nimbus 의 {@code send()} 와 대조한다).
   */
  static String asNimbusReadsIt(byte[] body) throws IOException {
    BufferedReader reader = new BufferedReader(new InputStreamReader(new ByteArrayInputStream(body), StandardCharsets.UTF_8));
    String separator = System.getProperty("line.separator");
    StringBuilder text = new StringBuilder();
    for (String line = reader.readLine(); line != null; line = reader.readLine()) {
      text.append(line).append(separator);
    }
    return text.length() == 0 ? null : text.toString();
  }

  /**
   * 엄격한 UTF-8 인가 — 잘못된 바이트(끝에서 잘린 열 · 겹침 꼴 · 서로게이트 포함)를 대체하지 않고 보고하는 디코더로 잰다. 입력의 끝을
   * 알리고 디코딩하므로 잘린 마지막 열도 여기서 보고된다(UTF-8 디코더는 비울 상태가 없다). 디코딩한 글자는 버린다(고정 4 KiB 버퍼 —
   * 본문만 한 글자 배열을 따로 잡지 않는다). BOM 은 UTF-8 의 유효한 바이트다(지금처럼 파서가 판정한다). ASCII 뿐인 본문(토큰 응답은
   * 대개 그렇다)은 디코더도 버퍼도 잡지 않고 참이다. admin 가드 {@code TokenResponseGuard.isUtf8} 이 쌍둥이다(두 모듈은 서로를 모른다).
   */
  static boolean isUtf8(byte[] body) {
    if (isAscii(body)) return true;
    CharsetDecoder decoder = StandardCharsets.UTF_8.newDecoder()
        .onMalformedInput(CodingErrorAction.REPORT)
        .onUnmappableCharacter(CodingErrorAction.REPORT);
    ByteBuffer in = ByteBuffer.wrap(body);
    CharBuffer out = CharBuffer.allocate(4096);
    CoderResult result;
    do {
      out.clear(); // 넘침 — 디코딩한 글자는 쓰지 않는다
      result = decoder.decode(in, out, true);
    } while (result.isOverflow());
    return !result.isError();
  }

  private static boolean isAscii(byte[] body) {
    for (byte b : body) {
      if (b < 0) return false;
    }
    return true;
  }

  /**
   * JSON 텍스트가 짝 없는 UTF-16 서로게이트의 {@code \\u} 이스케이프를 품는가 — 문자열 값이든 멤버 이름이든(RFC 8259 §8.2 의 문법은
   * 싣지만 I-JSON §2.1 은 금한다). 그 값은 어떤 UTF-8 로도 보낼 수 없다: 받아 둔 refresh token 을 다시 보내면 {@code ?}({@code %3F})로
   * 바뀌어 나갔다(등록부 token-response-class-residue 판정 Q2, 2026-11-11 실측). 엄격한 UTF-8 인 바이트를 그대로 훑는다 — 이스케이프는
   * ASCII 이고 여러 바이트 글자의 바이트는 {@code "} 나 {@code \} 와 겹치지 않는다. 이스케이프된 역슬래시 뒤의 {@code u} 는 이스케이프가
   * 아니다. 형식이 틀린 이스케이프는 여기서 판정하지 않는다(파서가 거부한다). admin 가드 {@code TokenResponseGuard} 가 쌍둥이다.
   */
  static boolean holdsUnpairedSurrogate(byte[] json) {
    boolean inString = false;
    for (int i = 0; i < json.length; i++) {
      byte b = json[i];
      if (!inString) {
        inString = b == '"';
      } else if (b == '"') {
        inString = false;
      } else if (b == '\\' && i + 1 < json.length) {
        if (json[i + 1] != 'u') {
          i++; // 두 글자 이스케이프 — 이스케이프된 글자를 건너뛴다
          continue;
        }
        int unit = hex4(json, i + 2);
        if (unit < 0) return false;
        i += 5;
        if (unit >= 0xDC00 && unit <= 0xDFFF) return true; // 앞에 높은 서로게이트가 없는 낮은 서로게이트
        if (unit >= 0xD800 && unit <= 0xDBFF) {
          int low = i + 2 < json.length && json[i + 1] == '\\' && json[i + 2] == 'u' ? hex4(json, i + 3) : -1;
          if (low < 0xDC00 || low > 0xDFFF) return true;
          i += 6;
        }
      }
    }
    return false;
  }

  /** {@code at} 의 16진 넷(대소문자 무관)의 값, 아니면 -1. */
  private static int hex4(byte[] json, int at) {
    if (at + 4 > json.length) return -1;
    int value = 0;
    for (int k = at; k < at + 4; k++) {
      int digit = Character.digit(json[k], 16);
      if (digit < 0) return -1;
      value = value << 4 | digit;
    }
    return value;
  }

  /** 상한을 넘는 응답 — 메시지는 무엇이 상한을 넘었는지만 말한다(응답을 인용하지 않는다). */
  static final class TooLarge extends IOException {
    private static final long serialVersionUID = 1L;

    TooLarge(String what) {
      super(what + " response exceeds " + ResponseLimits.MAX_TOKEN_RESPONSE_BYTES + " bytes");
    }
  }

  /**
   * 끝까지 왔으나 2xx 본문이 UTF-8 이 아니거나 UTF-8 로 보낼 수 없는 값({@link #holdsUnpairedSurrogate})을 품은 응답({@link #sendStrict})
   * — 전송 실패가 아니다(그 레인의 인증 오류다). 메시지는 무엇이 왜 쓸 수 없는지만 말한다(응답을 인용하지 않는다).
   */
  static final class NotUtf8 extends IOException {
    private static final long serialVersionUID = 1L;

    NotUtf8(String what) {
      this(what, "is not valid UTF-8");
    }

    NotUtf8(String what, String why) {
      super(what + " response " + why);
    }
  }
}
