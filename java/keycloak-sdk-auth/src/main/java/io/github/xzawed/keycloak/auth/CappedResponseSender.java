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
import java.nio.charset.Charset;
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
 * <p>상한 안의 본문은 Nimbus 와 같은 문자열로 만든다({@link #asNimbusReadsIt}) — 파서가 받는 입력이 지금과 같다. 상한을 넘으면
 * 나머지를 읽지 않고 <b>연결을 끊은 뒤</b>(교환의 클라이언트를 닫으며 — 평문은 그 자리에서 끝나고, HTTPS 는 JSSE 가 닫으며 이미 도착한 바이트를
 * 버린다) {@link TooLarge} 를 던지고, 호출부가 그 레인의 {@code KeycloakTransportException} 으로 바꾼다. SDK 가 요청하고 쥐는 것은
 * 상한+1 바이트까지다({@link #readWithinCap}). 운송은 내용 코딩을 요청하지도 풀지도 않으므로 센 바이트가 받은 바이트다.
 *
 * <p>인스턴스 상태가 없다 — 호출 하나의 스택에만 사는 값(연결·본문)을 필드로 쥐지 않는다.
 */
final class CappedResponseSender {
  private CappedResponseSender() {}

  /** Nimbus 가 본문을 쓰는 메서드({@code toHttpURLConnection} 의 {@code setDoOutput(true)}) — 나머지는 본문 없이 보낸다. */
  private static final Set<HTTPRequest.Method> WITH_BODY = EnumSet.of(HTTPRequest.Method.POST, HTTPRequest.Method.PUT);

  /** {@code request.send()} 대신 — 같은 요청·같은 응답이되 본문은 상한까지만 읽는다. {@code what} 은 넘침 메시지의 주어다. */
  static HTTPResponse send(HTTPRequest request, String what) throws IOException {
    return request.send(sameRequest -> receive(request, what));
  }

  private static HTTPResponse receive(HTTPRequest request, String what) throws IOException {
    SSLSocketFactory tls = request.getSSLSocketFactory() != null
        ? request.getSSLSocketFactory() : HTTPRequest.getDefaultSSLSocketFactory();
    HostnameVerifier verifier = request.getHostnameVerifier() != null
        ? request.getHostnameVerifier() : HTTPRequest.getDefaultHostnameVerifier();
    return BoundedTransport.exchange(toApache(request), tls, verifier, request.getConnectTimeout(), request.getReadTimeout(),
        ResponseLimits.MAX_TOKEN_RESPONSE_BYTES, (head, body) -> toNimbus(head, body, what));
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

  private static HTTPResponse toNimbus(HttpResponse head, InputStream in, String what) throws IOException {
    byte[] body = readWithinCap(in);
    if (body == null) throw new TooLarge(what);
    HTTPResponse response = new HTTPResponse(head.getStatusLine().getStatusCode());
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

  /** 상한을 넘는 응답 — 메시지는 무엇이 상한을 넘었는지만 말한다(응답을 인용하지 않는다). */
  static final class TooLarge extends IOException {
    private static final long serialVersionUID = 1L;

    TooLarge(String what) {
      super(what + " response exceeds " + ResponseLimits.MAX_TOKEN_RESPONSE_BYTES + " bytes");
    }
  }
}
