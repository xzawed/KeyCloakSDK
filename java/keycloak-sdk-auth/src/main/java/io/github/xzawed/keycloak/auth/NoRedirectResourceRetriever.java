package io.github.xzawed.keycloak.auth;
import com.nimbusds.jose.jwk.JWKSet;
import com.nimbusds.jose.jwk.source.JWKSourceBuilder;
import com.nimbusds.jose.util.DefaultResourceRetriever;
import com.nimbusds.jose.util.Resource;
import java.io.IOException;
import java.net.URI;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.Map;
import java.util.Objects;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.FutureTask;
import javax.net.ssl.HttpsURLConnection;
import org.apache.http.Header;
import org.apache.http.client.methods.HttpGet;

/**
 * JWKS 조회 전용 리트리버 — 3xx를 따라가지 않고, 응답의 틀과 본문에 한도를 건다.
 *
 * <p>Nimbus의 기본 리트리버는 {@code HttpURLConnection}의 기본 동작(리다이렉트 추종)을 그대로
 * 쓴다. 즉 JWKS 엔드포인트가 예상 밖 3xx를 반환하면 SDK가 공격자가 고른 URL을 가져와 **그 응답을
 * 서명 검증용 키 집합으로 사용한다**. 타임아웃만 주입하고 이 플래그를 두면 SSRF 표면이 남는다.
 * 그래서 조회({@link #fetch})는 {@link BoundedTransport} 로 직접 하고 리다이렉트를 따르는 길을 두지 않는다 — 3xx 는 조회 실패로
 * 표면화되고, 상위 {@code JWKSourceBuilder}가 그것을 조회 실패로 처리한다 — 조용히 엉뚱한 키를 쓰는 것보다 낫다.
 *
 * <p>⚠️ 이것은 SDK가 스스로 보내는 요청에 대한 것이다. OIDC authorization-code의
 * {@code redirect_uri}는 브라우저 front-channel 개념이라 무관하다.
 * Kotlin 자매 SDK도 같은 지점을 같은 방식으로 막는다.
 *
 * <p>⚠️ <b>응답 크기 상한(3번째 인자)을 반드시 넘긴다.</b> 이것을 빼면
 * {@code DefaultResourceRetriever(int,int)}가 sizeLimit을 <b>0(무제한)</b>으로 넣는다(바이트코드
 * 실측: 2-arg 생성자가 {@code iconst_0}을 밀어 3-arg를 호출한다). 그런데 우리가 리트리버를
 * 주입하지 않았다면 {@code JWKSourceBuilder}는 자기 리트리버를 {@code (500, 500, 51200)}으로
 * 만든다 — 즉 <b>하드닝을 주입하는 행위 자체가 Nimbus의 51200바이트 상한을 지운다</b>. 그
 * 상태에서는 JWKS 엔드포인트(또는 그 자리를 차지한 무엇)가 무제한 응답을 흘려 메모리를 채울 수
 * 있다. 상한은 Nimbus 의 {@code BoundedInputStream} 과 같은 셈으로 집행한다({@link #fetch}).
 *
 * <p>값은 하드코딩하지 않고 {@link JWKSourceBuilder#DEFAULT_HTTP_SIZE_LIMIT}을 참조한다 — 우리가
 * 잃은 바로 그 값이고, 두 번째 정의 자리를 만들지 않는다.
 *
 * <p>⚠️ 운송이 HttpURLConnection 이던 때는 본문 상한을 넘은 청크 응답을 닫으며 쌓인 바이트를 풀었고(리눅스에서 끝없는 1 바이트
 * 청크 본문 하나에 조회가 30 초 넘게 돌아오지 않았다) 짧은 본문 뒤 트레일러를 한도 없이 담았다(한 줄 1 MiB 에 4–5 초 — 실측
 * {@code ResponseFramingBoundsTest}). 그 둘은 이제 {@link BoundedTransport} 가 끊고 묶는다. TLS 근원은 HttpURLConnection 의
 * 전역 기본값({@code HttpsURLConnection.getDefaultSSLSocketFactory()}·검증기 — 조회 때마다 읽는다)으로 Nimbus 의 기본 리트리버가
 * 쓰던 그대로다.
 */
final class NoRedirectResourceRetriever extends DefaultResourceRetriever {
  NoRedirectResourceRetriever(int connectTimeoutMs, int readTimeoutMs) {
    super(connectTimeoutMs, readTimeoutMs, JWKSourceBuilder.DEFAULT_HTTP_SIZE_LIMIT);
  }

  // 200 + {"keys":[]} 를 조회 실패로 돌린다 — Nimbus 캐시는 파싱에 성공한 집합이면 빈 것도 올려
  // 좋은 키를 덮는다(JwksEmptyKeysetTest). 판정은 배열 길이가 아니라 Nimbus 가 **실제로 올릴
  // 집합**의 크기다(같은 파서). 파싱 자체가 실패하면 판정을 Nimbus 에 그대로 맡긴다.
  @Override
  public Resource retrieveResource(URL url) throws IOException {
    Resource res = fetchToCompletion(url);
    JWKSet parsed;
    try {
      parsed = JWKSet.parse(res.getContent());
    } catch (java.text.ParseException e) {
      return res;
    }
    if (parsed.getKeys().isEmpty()) {
      throw new IOException("JWKS response contains no keys");
    }
    return res;
  }

  /**
   * 조회 하나 — Nimbus {@code DefaultResourceRetriever.retrieveResource} 가 HttpURLConnection 으로 하던 일을 {@link
   * BoundedTransport} 로: GET · 이 리트리버의 헤더(제한 헤더는 버린다) · 연결/읽기 타임아웃 · 2xx 가 아니면 실패 · 본문은 UTF-8 ·
   * Content-Type 은 마지막 값. 상한은 {@code BoundedInputStream} 과 같은 셈이다 — 읽은 바이트가 상한에 <b>닿으면</b> 넘침이다
   * (정확히 51,200 바이트도 거부된다 — Nimbus 대조 {@code TransportParityTest}). 상한까지만 요청하고, 넘치면 나머지를 읽지
   * 않고 끊는다. 비-2xx 의 메시지는 상태 코드만 싣는다(이유 문구는 응답 바이트다). 끝까지 읽은 연결은 auth 레인과 같은 풀로 돌아간다
   * — Nimbus 의 기본 리트리버는 조회마다 연결을 끊었다({@code disconnectAfterUse}).
   */
  Resource fetch(URL url) throws IOException {
    HttpGet get = new HttpGet(URI.create(url.toString()));
    BoundedTransport.addHeaders(get, Objects.requireNonNullElse(getHeaders(), Map.of()));
    BoundedTransport.addJdkDefaults(get, url);
    int limit = getSizeLimit();
    return BoundedTransport.exchange(get, HttpsURLConnection.getDefaultSSLSocketFactory(),
        HttpsURLConnection.getDefaultHostnameVerifier(), getConnectTimeout(), getReadTimeout(), limit, (head, body) -> {
          int status = head.getStatusLine().getStatusCode();
          if (status / 100 != 2) throw new IOException("JWKS endpoint returned HTTP " + status);
          byte[] content = body.readNBytes(limit);
          if (content.length >= limit) throw new IOException("Exceeded configured input limit of " + limit + " bytes");
          Header type = head.getLastHeader("Content-Type");
          return new Resource(new String(content, StandardCharsets.UTF_8), type == null ? null : type.getValue());
        });
  }

  /**
   * 조회를 SDK 의 플랫폼 스레드에서 끝까지 돌리고, 호출자는 인터럽트와 무관하게 그 끝을 기다린 뒤 인터럽트 표시를 되살린다.
   *
   * <p>왜: Nimbus {@code RateLimitedJWKSetSource} 는 강제 재조회를 하기로 정한 <b>뒤</b> 창의 크레딧을 쓰고 그다음 이 메서드를
   * 부른다 — 되돌리지 않는다. 조회가 호출자 스레드에서 돌던 때 JDK 21 가상 스레드의 인터럽트는 소켓 읽기를 끊었고(「Closed by
   * interrupt」), 크레딧은 썼는데 캐시는 안 차서 창이 닫힐 때까지 회전한 진짜 키가 {@code RateLimitReachedException} 으로 거부됐다
   * (같은 조회를 기다리던 다른 호출자도). 플랫폼 스레드의 블로킹 읽기는 인터럽트를 무시하므로 그쪽의 결과 — 조회가 끝나고 캐시가
   * 차며 인터럽트 표시는 남는다 — 를 모든 호출자에게 준다({@code JwksCancellationTest}). 캐시는 Nimbus 가 이 메서드를 부른 호출자의
   * 스택에서 채우므로 호출자는 끝을 기다려야 한다. 기다림은 이 리트리버의 연결·읽기 타임아웃(과 51,200 바이트 상한)이 묶는다.
   *
   * <p>⚠️ 취소에서 크레딧을 되돌리는 것으로 고치지 않는다 — 위조 kid 검증을 취소할 때마다 IdP 요청 하나가 된다(Python 실측 10 대 1).
   * 실패한 조회(503 등)는 지금처럼 그대로 실패로 올라가 창을 쓴다(의도된 동작). 조회 스레드는 데몬이고 조회가 끝나면 끝난다 —
   * {@code KeycloakClient.close()} 가 기다릴 것이 없다.
   */
  private Resource fetchToCompletion(URL url) throws IOException {
    FutureTask<Resource> fetch = new FutureTask<>(() -> fetch(url));
    Thread fetcher = new Thread(fetch, "keycloak-sdk-jwks-fetch");
    fetcher.setDaemon(true);
    fetcher.start();
    boolean interrupted = false;
    try {
      while (true) {
        try {
          return fetch.get();
        } catch (InterruptedException e) {
          interrupted = true; // 창은 이미 썼다 — 조회가 끝날 때까지 기다린다
        } catch (ExecutionException e) {
          throw rethrow(e.getCause());
        }
      }
    } finally {
      if (interrupted) Thread.currentThread().interrupt();
    }
  }

  /** 조회가 던진 것을 그대로 — 조회는 IOException 만 선언하므로 그 밖의 검사 예외는 없다. */
  static IOException rethrow(Throwable cause) {
    if (cause instanceof RuntimeException unchecked) throw unchecked;
    if (cause instanceof Error error) throw error;
    return (IOException) cause;
  }
}
