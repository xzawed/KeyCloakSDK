# frozen_string_literal: true

require "socket"

# 클라이언트와 상류 서버 사이의 TCP 중계(단위 테스트용) — `trickle!` 뒤에 상류가 보낸 바이트는 `gap` 초마다 한 바이트씩
# 넘긴다(그 전은 곧바로). TLS 상류 앞에 두면 레코드 하나가 바이트 단위로 온다 — 클라이언트의 OpenSSL 은 바이트가 올
# 때마다 깨지만 레코드가 덜 와서 읽을 것이 없다(`read_nonblock` → :wait_readable). `close` 는 쉬던 중계를 곧바로 끝낸다.
class TrickleRelay
  def initialize(upstream_port, gap:)
    @upstream_port = upstream_port
    @gap = gap
    @trickle = false
    @wake = Queue.new
    @server = TCPServer.new("127.0.0.1", 0)
    @thread = Thread.new { serve }
  end

  def port
    @server.addr[1]
  end

  def trickle!
    @trickle = true
  end

  def close
    @wake.close
    @server.close
    @thread.join(5)
  end

  private

  def serve
    loop do
      client = @server.accept
      upstream = TCPSocket.new("127.0.0.1", @upstream_port)
      Thread.new { pump(client, upstream, paced: false) }
      Thread.new { pump(upstream, client, paced: true) }
    end
  rescue IOError, Errno::EBADF, Errno::EINVAL
    nil # 중계가 닫혔다
  end

  def pump(from, to, paced:)
    loop do
      chunk = from.readpartial(16_384)
      next to.write(chunk) unless paced && @trickle
      break unless trickle(chunk, to)
    end
  rescue IOError, SystemCallError
    nil # 어느 한쪽이 끊었다(EOFError 도 IOError 다)
  ensure
    [from, to].each { |sock| close_quietly(sock) }
  end

  # `chunk` 를 한 간격에 한 바이트씩 넘긴다(첫 바이트는 곧바로 — 바이트 사이만 쉰다) — 중계가 닫혀 깼으면 거짓.
  def trickle(chunk, to)
    chunk.each_byte.with_index.all? do |byte, at|
      next false if at.positive? && woken?

      to.write(byte.chr)
      true
    end
  end

  # 한 간격을 쉰다 — 중계가 닫혀 깨면 참.
  def woken?
    @wake.pop(timeout: @gap)
    @wake.closed?
  end

  def close_quietly(sock)
    sock.close
  rescue SystemCallError, IOError
    nil
  end
end
