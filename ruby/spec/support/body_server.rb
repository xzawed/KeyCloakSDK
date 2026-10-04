# frozen_string_literal: true

require "socket"
require "zlib"
require "stringio"
require "objspace"

# 진짜 소켓으로 응답 본문을 흘려 주는 작은 HTTP 서버(단위 테스트용, Docker 불필요).
#
# ⚠️ **WebMock 으로는 상한의 메모리 축을 잴 수 없다.** WebMock 은 실제 연결을 허용해도 `super(request, nil)` 로
# 본문을 **통째로** 읽은 뒤에야 블록에 넘기고, 스텁은 본문 전체를 청크 하나로 준다 — net-http 가 16 KiB 씩 읽다
# 상한에서 끊기는 실제 경로가 생기지 않는다. 그래서 이 서버를 쓰는 예제는 `WebMock.disable!` 아래에서 돈다.
#
# 경로마다 응답 하나를 정한다: `route(path) { |request| [status, headers, head, pad] }` — `head` 뒤에 JSON 공백
# `pad` 바이트를 붙인다(같은 64 KiB 조각을 되풀어 써 서버 쪽 할당은 거의 없다). `framing:` 은 `:chunked`·`:length`,
# `compress:` 는 `nil`(평문)·`:when_allowed`(요청이 gzip 을 받으면 gzip)·`:always`(요청과 무관하게 gzip).
class BodyServer
  PAD = (" " * 65_536).freeze

  Request = Struct.new(:verb, :path, :headers, :body)
  Reply = Struct.new(:status, :headers, :head, :pad)

  def initialize(framing: :chunked, compress: nil)
    @framing = framing
    @compress = compress
    @routes = {}
    @lock = Mutex.new
    @seen = []
    @server = TCPServer.new("127.0.0.1", 0)
    @thread = Thread.new { serve }
  end

  def url
    "http://127.0.0.1:#{@server.addr[1]}"
  end

  def route(path, &block)
    @routes[path] = block
  end

  def requests
    @lock.synchronize { @seen.dup }
  end

  def close
    @server.close
    @thread.join(5)
  end

  # 같은 본문을 미리 gzip 해 둔다 — 측정 창 안에서 압축하지 않도록.
  def self.gzip(head, pad)
    io = StringIO.new(+"", "wb")
    gz = Zlib::GzipWriter.new(io)
    gz.write(head)
    each_pad(pad) { |piece| gz.write(piece) }
    gz.finish
    io.string
  end

  def self.each_pad(pad)
    left = pad
    while left.positive?
      n = [left, PAD.bytesize].min
      yield(n == PAD.bytesize ? PAD : PAD.byteslice(0, n))
      left -= n
    end
  end

  # 블록이 새로 잡은 메모리(바이트) — GC 를 끈 창 안에서 두 계수 중 큰 쪽.
  #  · `ObjectSpace.memsize_of_all` 은 보이는 객체만 센다 — 본문을 담은 문자열은 보이지만 zlib 의 출력 버퍼는
  #    숨은 객체라 안 보인다(실측: JWKS gzip 에서 0.35 MB, 같은 창의 malloc 계수는 18 MB · 피크 WS +23.5 MB).
  #  · `malloc_increase_bytes` 는 마지막 GC 뒤 malloc 순증가라 숨은 버퍼까지 센다. ⚠️ GC 가 돌면 0 으로 돌아가므로
  #    반드시 GC 를 끈 창 **안에서** 읽는다(창 밖에서 읽으면 다음 할당이 부른 GC 뒤의 값을 읽는다 — 실측으로 0 이 나왔다).
  def self.allocated_bytes
    GC.start
    GC.disable
    malloc = GC.stat.key?(:malloc_increase_bytes) ? -> { GC.stat(:malloc_increase_bytes) } : -> { 0 }
    objects0 = ObjectSpace.memsize_of_all
    malloc0 = malloc.call
    yield
    [ObjectSpace.memsize_of_all - objects0, malloc.call - malloc0].max
  ensure
    GC.enable
  end

  private

  def serve
    loop do
      sock = @server.accept
      handle(sock)
    rescue IOError, Errno::EBADF, Errno::EINVAL
      break # 서버가 닫혔다
    ensure
      close_quietly(sock)
    end
  end

  # ⚠️ Windows 는 상대가 끊은 소켓의 `close` 에서도 ECONNRESET 을 올린다(실측) — 그것이 서버 스레드를 죽이면 안 된다.
  def close_quietly(sock)
    sock&.close
  rescue SystemCallError, IOError
    nil
  end

  def handle(sock)
    req = read_request(sock)
    @lock.synchronize { @seen << req }
    reply = Reply.new(*@routes.fetch(req.path) { ->(_) { [404, {}, "", 0] } }.call(req))
    gzip = @compress == :always || (@compress == :when_allowed && req.headers["accept-encoding"].to_s.include?("gzip"))
    gzip ? write_gzip(sock, reply) : write_plain(sock, reply)
  rescue Errno::EPIPE, Errno::ECONNRESET, Errno::ECONNABORTED, IOError
    nil # 클라이언트가 상한에서 끊었다 — 기대한 일이다
  end

  def read_request(sock)
    method, path = sock.gets("\r\n").to_s.split
    headers = {}
    while (h = sock.gets("\r\n")) && h != "\r\n"
      k, v = h.split(":", 2)
      headers[k.strip.downcase] = v.to_s.strip
    end
    Request.new(method, path, headers, sock.read(headers["content-length"].to_i))
  end

  def base_headers(reply)
    { "Content-Type" => "application/json", "Connection" => "close" }.merge(reply.headers)
  end

  def write_gzip(sock, reply)
    bytes = self.class.gzip(reply.head.b, reply.pad)
    out = base_headers(reply).merge("Content-Encoding" => "gzip", "Content-Length" => bytes.bytesize.to_s)
    sock.write(status_line(reply.status, out), bytes)
  end

  def write_plain(sock, reply)
    head = reply.head.b
    out = base_headers(reply)
    out[@framing == :chunked ? "Transfer-Encoding" : "Content-Length"] =
      @framing == :chunked ? "chunked" : (head.bytesize + reply.pad).to_s
    sock.write(status_line(reply.status, out))
    piece(sock, head)
    self.class.each_pad(reply.pad) { |p| piece(sock, p) }
    sock.write("0\r\n\r\n") if @framing == :chunked
  end

  def piece(sock, bytes)
    return if bytes.empty?

    @framing == :chunked ? sock.write(bytes.bytesize.to_s(16), "\r\n", bytes, "\r\n") : sock.write(bytes)
  end

  def status_line(status, headers)
    "HTTP/1.1 #{status} X\r\n#{headers.map { |k, v| "#{k}: #{v}\r\n" }.join}\r\n"
  end
end
