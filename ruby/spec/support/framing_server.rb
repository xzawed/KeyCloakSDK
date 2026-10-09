# frozen_string_literal: true

require "openssl"
require "socket"

# 응답을 바이트 그대로 쓰는 HTTP 서버(단위 테스트용, Docker 불필요) — 응답 틀(상태 줄·헤더 줄·청크 크기 줄·트레일러)을
# 바이트 단위로 짠다. `BodyServer` 는 본문만 짤 수 있어 틀의 공격 모양을 만들지 못한다.
#
# `route(path) { |request| pieces }` — `pieces` 는 `each` 로 바이트 문자열을 내는 것(배열·Enumerator)이다. 16 MiB 를 미리
# 만들지 않도록 같은 조각을 되풀어 낸다(`FramingServer.repeat`). 프록시로 받은 요청의 `path` 는 절대 URI 다.
# `keep_alive: true` 면 연결 하나에서 요청을 계속 읽는다(아니면 응답 하나 뒤에 닫는다). `tls:` 에 SSLContext 를 주면 TLS 로 받는다.
# `written` 은 서버가 소켓에 넘긴 바이트다 — 커널 버퍼가 받아 준 것까지라 클라이언트가 읽은 바이트보다 크거나 같다.
class FramingServer
  PIECE = ("a" * 16_384).b.freeze

  Request = Struct.new(:verb, :path, :headers, :body, :connection)

  def initialize(keep_alive: false, tls: nil)
    @keep_alive = keep_alive
    @tls = tls
    @routes = {}
    @lock = Mutex.new
    @seen = []
    @connections = 0
    @written = 0
    @server = TCPServer.new("127.0.0.1", 0)
    @thread = Thread.new { serve }
  end

  def port
    @server.addr[1]
  end

  def url
    "#{@tls ? 'https' : 'http'}://127.0.0.1:#{port}"
  end

  def route(path, &block)
    @routes[path] = block
  end

  def requests
    @lock.synchronize { @seen.dup }
  end

  def connections
    @lock.synchronize { @connections }
  end

  def written
    @lock.synchronize { @written }
  end

  def close
    @server.close
    @thread.join(5)
  end

  # `total` 바이트 — 같은 16 KiB 조각(기본은 "a")을 되풀어 낸다(서버 쪽 할당이 거의 없다).
  def self.repeat(total, piece = PIECE)
    Enumerator.new do |y|
      left = total
      while left.positive?
        n = [left, piece.bytesize].min
        y << (n == piece.bytesize ? piece : piece.byteslice(0, n))
        left -= n
      end
    end
  end

  # 시험용 자체 서명 인증서(127.0.0.1) 의 서버 쪽 SSLContext.
  def self.tls_context
    key = OpenSSL::PKey::RSA.new(2048)
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = 1
    cert.subject = cert.issuer = OpenSSL::X509::Name.parse("/CN=127.0.0.1")
    cert.public_key = key.public_key
    cert.not_before = Time.now - 60
    cert.not_after = Time.now + 3600
    cert.sign(key, OpenSSL::Digest.new("SHA256"))
    OpenSSL::SSL::SSLContext.new.tap do |ctx|
      ctx.cert = cert
      ctx.key = key
    end
  end

  private

  def serve
    loop do
      sock = accept
      conn = @lock.synchronize { @connections += 1 }
      handle(sock, conn)
    rescue IOError, Errno::EBADF, Errno::EINVAL
      break # 서버가 닫혔다
    rescue OpenSSL::SSL::SSLError, SystemCallError
      next # TLS 악수 중에 클라이언트가 끊었다
    ensure
      close_quietly(sock)
    end
  end

  def accept
    raw = @server.accept
    return raw unless @tls

    OpenSSL::SSL::SSLSocket.new(raw, @tls).tap do |s|
      s.sync_close = true
      s.accept
    end
  end

  # ⚠️ Windows 는 상대가 끊은 소켓의 `close` 에서도 ECONNRESET 을 올린다(BodyServer 와 같은 실측) — 서버 스레드를 죽이면 안 된다.
  def close_quietly(sock)
    sock&.close
  rescue SystemCallError, IOError, OpenSSL::SSL::SSLError
    nil
  end

  def handle(sock, conn)
    loop do
      req = read_request(sock, conn) or break
      @lock.synchronize { @seen << req }
      reply = @routes.fetch(req.path) { ->(_) { ["HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n"] } }
      reply.call(req).each { |piece| write(sock, piece) }
      break unless @keep_alive
    end
  rescue Errno::EPIPE, Errno::ECONNRESET, Errno::ECONNABORTED, IOError, OpenSSL::SSL::SSLError
    nil # 클라이언트가 틀 한도에서 끊었다 — 기대한 일이다
  end

  def write(sock, piece)
    sock.write(piece)
    @lock.synchronize { @written += piece.bytesize }
  end

  def read_request(sock, conn)
    line = sock.gets("\r\n") or return
    verb, path = line.split
    headers = {}
    while (h = sock.gets("\r\n")) && h != "\r\n"
      k, v = h.split(":", 2)
      headers[k.strip.downcase] = v.to_s.strip
    end
    Request.new(verb, path, headers, sock.read(headers["content-length"].to_i), conn)
  end
end
