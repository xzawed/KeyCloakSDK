package io.github.xzawed.keycloak.auth;
import com.nimbusds.jose.jwk.JWKSet;
import com.nimbusds.jose.jwk.source.JWKSourceBuilder;
import com.nimbusds.jose.util.DefaultResourceRetriever;
import com.nimbusds.jose.util.Resource;
import java.io.IOException;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.FutureTask;

/**
 * JWKS 조회 전용 {@link DefaultResourceRetriever} — 3xx를 따라가지 않는다.
 *
 * <p>Nimbus의 기본 리트리버는 {@code HttpURLConnection}의 기본 동작(리다이렉트 추종)을 그대로
 * 쓴다. 즉 JWKS 엔드포인트가 예상 밖 3xx를 반환하면 SDK가 공격자가 고른 URL을 가져와 **그 응답을
 * 서명 검증용 키 집합으로 사용한다**. 타임아웃만 주입하고 이 플래그를 두면 SSRF 표면이 남는다.
 *
 * <p>{@code openConnection}은 Nimbus가 실제로 쓰는 유일한 확장점이라 여기서 한 번만 막으면
 * 모든 조회 경로가 덮인다. 리다이렉트를 만나면 추종 대신 3xx가 그대로 표면화되고, 상위
 * {@code JWKSourceBuilder}가 그것을 조회 실패로 처리한다 — 조용히 엉뚱한 키를 쓰는 것보다 낫다.
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
 * 있다. 상한은 {@code BoundedInputStream}으로 집행된다.
 *
 * <p>값은 하드코딩하지 않고 {@link JWKSourceBuilder#DEFAULT_HTTP_SIZE_LIMIT}을 참조한다 — 우리가
 * 잃은 바로 그 값이고, 두 번째 정의 자리를 만들지 않는다.
 */
final class NoRedirectResourceRetriever extends DefaultResourceRetriever {
  NoRedirectResourceRetriever(int connectTimeoutMs, int readTimeoutMs) {
    super(connectTimeoutMs, readTimeoutMs, JWKSourceBuilder.DEFAULT_HTTP_SIZE_LIMIT);
  }

  // ⚠️ 캐스트가 안전한 이유: 이 메서드의 반환 타입 자체가 HttpURLConnection이라 Nimbus는 HTTP(S)
  // URL에 대해서만 이것을 호출한다(비-HTTP는 retrieveResource가 여기 오기 전에 처리한다 — file:
  // URL로 실측). 방어적 instanceof 분기를 두면 어떤 테스트로도 도달할 수 없는 죽은 가지가 되어
  // 커버리지 게이트만 떨어뜨린다. 상위 클래스와 같은 계약을 그대로 따른다.
  @Override
  protected HttpURLConnection openConnection(URL url) throws IOException {
    HttpURLConnection con = (HttpURLConnection) url.openConnection();
    con.setInstanceFollowRedirects(false); // SSRF 하드닝 — 인스턴스 단위로만 끈다(전역 상태 불변)
    return con;
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
    FutureTask<Resource> fetch = new FutureTask<>(() -> super.retrieveResource(url));
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
