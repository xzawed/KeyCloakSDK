package io.github.xzawed.keycloak.admin;

import java.io.FilterInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.net.Socket;
import java.net.SocketTimeoutException;
import java.util.concurrent.TimeUnit;
import javax.net.ssl.HostnameVerifier;
import javax.net.ssl.SSLContext;
import org.apache.http.config.Registry;
import org.apache.http.config.RegistryBuilder;
import org.apache.http.conn.socket.ConnectionSocketFactory;
import org.apache.http.conn.socket.PlainConnectionSocketFactory;
import org.apache.http.conn.ssl.SSLConnectionSocketFactory;
import org.apache.http.impl.conn.PoolingHttpClientConnectionManager;
import org.apache.http.protocol.HttpContext;

/**
 * admin 레인의 소켓 — 읽기마다 이 스레드가 지금 하는 교환의 마감을 본다. 상태 줄·헤더·청크 크기 줄·트레일러·본문·TLS 레코드가 모두 이
 * 읽기로 온다(TLS 는 이 위에 겹친다 — JSSE 는 레코드를 이 소켓의 스트림에서 읽는다). auth 레인의 {@code BoundedTransport.deadlined} 와 같은
 * 규칙이다 — admin 은 auth 에 기대지 않으므로(§4) 같은 규칙을 이 레인에 따로 둔다.
 *
 * <p>왜: 엔진의 엔티티 스트림({@link AdminEngine.Settled})은 읽기 하나의 앞뒤에서만 마감을 본다. 그 밖인 응답 머리와, 읽기 하나 안의 틀(청크
 * 크기 줄 · 트레일러)·TLS 레코드는 읽기마다의 타임아웃만 묶어 — 바이트를 그보다 조금 짧은 간격으로 흘리는 서버 앞에서 읽기 타임아웃 1 초에
 * 머리 7.5 초 · 청크 7.1 초 · 트레일러 7.1 초 · TLS 레코드 33.6 초가 걸렸다(실측 2026-10-29 · {@code ResponseReadDeadlineTest}). 그 소켓은
 * RESTEasy 가 지은 풀의 것이라, 같은 크기·수명·소켓 설정의 풀을 이 소켓으로 다시 짓는다({@link #pool}).
 *
 * <p>마감은 소켓이 아니라 스레드에 둔다 — 소켓은 풀에서 교환을 건너 산다. 그리고 <b>읽는 동안에만</b> 둔다({@link #arm}) — 머리는 요청을
 * 보낸 스레드가 엔진의 호출 안에서 읽고, 본문은 그것을 읽는 스레드가 읽기마다 다시 건다(소비자가 {@code raw()} 의 응답을 다른 스레드에서
 * 읽어도 같은 마감이다). 어떤 스레드에도 교환의 마감이 남지 않는다.
 */
final class AdminSockets {
  /** 이 스레드가 지금 하는 교환의 마감 — {@code {System.nanoTime() 의 마감, 그 길이(ms)}}. 보낼 때 걸고({@link #arm}) 끝이 지운다. */
  private static final ThreadLocal<long[]> DEADLINE = new ThreadLocal<>();

  /** 평문 — 맺는 것은 HttpClient 의 기본 그대로, 소켓만 이 레인의 것이다. */
  static final ConnectionSocketFactory PLAIN = new PlainSockets();

  // ⚠️ 아래 넷은 익명 클래스로 두지 않는다 — 풀이 쥐어 파사드에서 닿는 객체라, 파사드를 걷는 시험(HostilePathMatrixTest)이 그 타입을 산출물의
  // 타입 전수와 견주는데 그 전수는 익명 클래스를 뺀다(실측: AdminSockets$1–$4 「산출물 전수에 없다」 — AdminEngine 이 람다를 두지 않는 까닭과 같다).

  /** 평문 소켓 공장 — {@link #socket()} 을 맺는다. */
  private static final class PlainSockets extends PlainConnectionSocketFactory {
    @Override
    public Socket createSocket(HttpContext context) {
      return socket();
    }
  }

  /** TLS 소켓 공장 — TLS 를 얹을 평문 소켓만 {@link #socket()} 이다. */
  private static final class TlsSockets extends SSLConnectionSocketFactory {
    TlsSockets(SSLContext context, HostnameVerifier verifier) {
      super(context, verifier);
    }

    @Override
    public Socket createSocket(HttpContext context) {
      return socket();
    }
  }

  /** 입력 스트림이 읽기마다 마감을 보는 소켓({@link #deadlined}). */
  private static final class DeadlineSocket extends Socket {
    @Override
    public InputStream getInputStream() throws IOException {
      return deadlined(super.getInputStream());
    }
  }

  /** 읽기 앞뒤로 이 스레드의 마감을 보는 입력 스트림({@link #deadlined}). */
  private static final class DeadlinedStream extends FilterInputStream {
    DeadlinedStream(InputStream socket) {
      super(socket);
    }

    @Override
    public int read() throws IOException {
      long[] deadline = DEADLINE.get();
      if (deadline == null) return super.read();
      due(deadline);
      int b = super.read();
      due(deadline);
      return b;
    }

    @Override
    public int read(byte[] buffer, int offset, int length) throws IOException {
      long[] deadline = DEADLINE.get();
      if (deadline == null) return super.read(buffer, offset, length);
      due(deadline);
      int n = super.read(buffer, offset, length);
      due(deadline);
      return n;
    }

    /** 마감이 지났으면 읽기 타임아웃과 같은 타입으로 — 메시지는 마감의 길이뿐이다(응답을 인용하지 않는다 · 엔진의 스트림과 같은 문구). */
    private static void due(long[] deadline) throws SocketTimeoutException {
      if (System.nanoTime() - deadline[0] >= 0) {
        throw new SocketTimeoutException(AdminEngine.LATE + deadline[1] + " ms of sending the request");
      }
    }
  }

  private AdminSockets() {
  }

  /**
   * 이 스레드에 교환의 마감을 건다 — {@code sentAtNanos} 부터 {@code readTimeoutMillis}. 0 은 「끝없이」(읽기 타임아웃이 없다)라 마감도 두지
   * 않는다. 앞서 걸려 있던 것을 돌려준다 — 건 쪽이 끝에서 {@link #restore} 로 되돌린다.
   *
   * <p>⚠️ 마감은 <b>읽는 동안에만</b> 스레드에 둔다 — 머리는 엔진의 호출 안({@link AdminEngine#invoke} 가 끝에서 되돌린다), 본문은 엔진의
   * 스트림의 읽기·닫기 하나마다(그 스트림이 읽는 스레드에서 다시 건다). 교환 하나에 걸어 두고 스트림이 닫힐 때 지우던 첫 판은, 응답을 닫지
   * 않거나 다른 스레드에서 닫으면 보낸 스레드에 지난 마감을 남겼다 — 그 스레드의 다음 admin 호출이 새 연결의 TLS 핸드셰이크에서 곧바로
   * 실패했다(독립 검토의 실측: 열어 둠 46 ms · 다른 스레드에서 닫음 8 ms).
   */
  static long[] arm(long sentAtNanos, int readTimeoutMillis) {
    long[] previous = DEADLINE.get();
    if (readTimeoutMillis > 0) {
      DEADLINE.set(new long[] {sentAtNanos + TimeUnit.MILLISECONDS.toNanos(readTimeoutMillis), readTimeoutMillis});
    } else {
      DEADLINE.remove();
    }
    return previous;
  }

  /** 지금 이 스레드에 걸린 마감(없으면 null) — 걸기 전의 것을 쥐어 두었다가 {@link #restore} 로 되돌린다. */
  static long[] current() {
    return DEADLINE.get();
  }

  /** 앞서 걸려 있던 마감으로 되돌린다({@code null} 이면 지운다). */
  static void restore(long[] previous) {
    if (previous == null) {
      DEADLINE.remove();
    } else {
      DEADLINE.set(previous);
    }
  }

  /** 이 스레드의 마감을 지운다. */
  static void disarm() {
    DEADLINE.remove();
  }

  /** TLS — 검증기·근원은 RESTEasy 가 고른 그대로, TLS 를 얹을 평문 소켓만 이 레인의 것이다. */
  static ConnectionSocketFactory tls(SSLContext context, HostnameVerifier verifier) {
    return new TlsSockets(context, verifier);
  }

  /**
   * RESTEasy 가 지은 풀({@code built})과 같은 크기 · 경로당 크기 · 소켓 설정 · 쉰 뒤 검사 간격과, 빌더의 연결 수명({@code ttlMillis})으로 이
   * 레인의 소켓을 쓰는 풀을 짓는다. TLS 근원은 RESTEasy 의 기본 분기와 같은 것({@code tls} — 빌더에 준 것이 없으면
   * {@link SSLContext#getDefault()})이다. 지은 풀은 쓰이지 않으므로 닫는 것은 부르는 쪽이다.
   */
  static PoolingHttpClientConnectionManager pool(PoolingHttpClientConnectionManager built, SSLContext tls,
                                                 HostnameVerifier verifier, long ttlMillis) {
    Registry<ConnectionSocketFactory> sockets = RegistryBuilder.<ConnectionSocketFactory>create()
        .register("http", PLAIN)
        .register("https", tls(tls, verifier))
        .build();
    PoolingHttpClientConnectionManager pool =
        new PoolingHttpClientConnectionManager(sockets, null, null, null, ttlMillis, TimeUnit.MILLISECONDS);
    pool.setMaxTotal(built.getMaxTotal());
    pool.setDefaultMaxPerRoute(built.getDefaultMaxPerRoute());
    pool.setDefaultSocketConfig(built.getDefaultSocketConfig());
    pool.setValidateAfterInactivity(built.getValidateAfterInactivity());
    return pool;
  }

  /** 이 레인의 소켓 — JDK 의 기본 소켓이되 그 입력 스트림이 읽기마다 마감을 본다({@link #deadlined}). */
  static Socket socket() {
    return new DeadlineSocket();
  }

  /**
   * 소켓의 입력 스트림 — 읽기 앞뒤로 이 스레드의 마감({@link #arm})을 본다: 마감 뒤에 읽기를 시작하지 않고, 마감 뒤에 끝난 읽기의 결과를 쓰지
   * 않는다(그 바이트로 응답을 끝내지 않는다). 읽기 하나는 지금처럼 읽기 타임아웃이 묶으므로 최악은 마감 + 읽기 타임아웃 하나다. 마감이 없는
   * 스레드의 읽기는 그대로다.
   */
  static InputStream deadlined(InputStream socket) {
    return new DeadlinedStream(socket);
  }
}
