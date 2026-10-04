package io.github.xzawed.keycloak.auth;

import com.nimbusds.oauth2.sdk.http.HTTPRequest;
import com.nimbusds.oauth2.sdk.http.HTTPResponse;
import io.github.xzawed.keycloak.core.ResponseLimits;
import java.io.BufferedReader;
import java.io.ByteArrayInputStream;
import java.io.Closeable;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.Map;

/**
 * Nimbus {@code HTTPRequest.send()} 와 같은 일을 하되 응답 본문을 {@link ResponseLimits#MAX_TOKEN_RESPONSE_BYTES} 까지만 읽는
 * 송신 — {@link AuthClient} 의 토큰(세 그랜트)·introspection·logout 요청이 전부 {@link #send} 로 나간다.
 *
 * <p>왜: Nimbus 의 {@code send()} 는 본문을 readLine 고리로 끝까지 담는다(크기 설정이 없다) — 쓸 수 있는 토큰 뒤에 JSON 공백
 * 32 MiB 를 붙인 응답을 다섯 레인이 받아들였고 호출 하나가 약 235 MB 를 할당했다(실측 — {@code TokenResponseCapTest}). 오류
 * 상태의 본문도 같은 고리였다.
 *
 * <p>⚠️ 송신기({@code HTTPRequestSender})는 그 요청을 붙잡아 두고 그 요청의 {@code toHttpURLConnection()} 으로 연결을 연다 —
 * Nimbus 가 넘기는 {@code ReadOnlyHTTPRequest} 에는 {@code followRedirects}·TLS 설정(호스트 이름 검증기·소켓 팩토리)이 없어 그것으로
 * 연결을 새로 지으면 SSRF 하드닝({@code AuthClient.applyTimeouts})을 잃는다. 연결 조립·타임아웃·요청 본문 쓰기는 Nimbus 그대로이고
 * 바뀌는 것은 읽기뿐이다.
 *
 * <p>상한 안의 본문은 Nimbus 와 같은 문자열로 만든다({@link #asNimbusReadsIt}) — 파서가 받는 입력이 지금과 같다. 상한을 넘으면
 * 나머지를 읽지 않고 스트림을 닫은 뒤 {@link TooLarge} 를 던지고, 호출부가 그 레인의 {@code KeycloakTransportException} 으로
 * 바꾼다. SDK 가 요청하는 것은 상한+1 바이트까지다({@link #readWithinCap}). 그 아래 JDK 운송은 소켓을 8 KiB
 * {@code BufferedInputStream} 으로 읽으므로 한 번에 그만큼 더 받아 둘 수 있고, 닫을 때는 이미 도착해 있는 바이트만 막힘 없이 소비한
 * 뒤(청크 본문 {@code hurry()}) 연결을 끊는다 — Content-Length 가 512 KiB 를 넘는 본문은 비우지 않고 끊는다. HttpURLConnection 은
 * 내용 코딩을 풀지 않으므로 센 바이트가 받은 바이트다.
 *
 * <p>인스턴스 상태가 없다 — 호출 하나의 스택에만 사는 값(연결·본문)을 필드로 쥐지 않는다.
 */
final class CappedResponseSender {
  private CappedResponseSender() {}

  /** {@code request.send()} 대신 — 같은 연결·같은 응답이되 본문은 상한까지만 읽는다. {@code what} 은 넘침 메시지의 주어다. */
  static HTTPResponse send(HTTPRequest request, String what) throws IOException {
    return request.send(sameRequest -> receive(request, what));
  }

  private static HTTPResponse receive(HTTPRequest request, String what) throws IOException {
    HttpURLConnection conn = request.toHttpURLConnection();
    OutputStream out = null;
    InputStream in = null;
    try {
      int status;
      try {
        if (conn.getDoOutput()) out = conn.getOutputStream();
        in = conn.getInputStream();
        status = conn.getResponseCode();
      } catch (IOException e) {
        // 4xx·5xx 면 getInputStream 이 던진다 — 상태가 있으면 본문은 오류 스트림에 있다(Nimbus send() 와 같다)
        status = conn.getResponseCode();
        if (status == -1) throw e;
        in = conn.getErrorStream();
      }
      byte[] body = in == null ? new byte[0] : readWithinCap(in);
      if (body == null) throw new TooLarge(what);
      HTTPResponse response = new HTTPResponse(status);
      response.setStatusMessage(conn.getResponseMessage());
      for (Map.Entry<String, List<String>> header : conn.getHeaderFields().entrySet()) {
        // 상태 줄은 이름 없는 항목으로 온다 — Nimbus send() 와 send(sender) 둘 다 건너뛴다
        if (header.getKey() != null) response.setHeader(header.getKey(), header.getValue().toArray(new String[0]));
      }
      response.setBody(asNimbusReadsIt(body));
      return response;
    } finally {
      closeQuietly(in);
      closeQuietly(out);
    }
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

  // Nimbus closeStreams 와 같이 닫기의 실패는 버린다 — 결과(응답이든 그 실패든)는 이미 정해졌다.
  private static void closeQuietly(Closeable stream) {
    if (stream == null) return;
    try {
      stream.close();
    } catch (IOException ignored) {
      // 버린다
    }
  }

  /** 상한을 넘는 응답 — 메시지는 무엇이 상한을 넘었는지만 말한다(응답을 인용하지 않는다). */
  static final class TooLarge extends IOException {
    private static final long serialVersionUID = 1L;

    TooLarge(String what) {
      super(what + " response exceeds " + ResponseLimits.MAX_TOKEN_RESPONSE_BYTES + " bytes");
    }
  }
}
