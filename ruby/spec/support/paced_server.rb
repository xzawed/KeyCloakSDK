# frozen_string_literal: true

require "socket"

# 응답을 시간 맞춰 쓰는 HTTP 서버(단위 테스트용, Docker 불필요) — 경로마다 `[쉴 초, 쓸 바이트]` 조각 목록을 정하고
# 요청이 오면 그대로 쓴다(`route(path, pieces)`). 읽기 마감 시험이 바이트를 읽기 타임아웃보다 짧은 간격으로 흘린다.
# 연결마다 스레드 하나이고 연결 하나에 요청 여럿을 받는다. `close` 는 쉬고 있는 조각을 그 자리에서 깨워 끝낸다 —
# 멈춘 응답이 시험 정리를 붙들지 않는다. 쿼리는 경로에서 뗀다.
class PacedServer
  NOT_FOUND = [[0, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n"]].freeze

  def initialize
    @routes = {}
    @wake = Queue.new # 닫으면(`close`) 쉬던 조각이 곧바로 깬다
    @server = TCPServer.new("127.0.0.1", 0)
    @thread = Thread.new { serve }
  end

  def url
    "http://127.0.0.1:#{@server.addr[1]}"
  end

  def route(path, pieces)
    @routes[path] = pieces
  end

  def close
    @wake.close
    @server.close
    @thread.join(5)
  end

  private

  def serve
    loop { Thread.new(@server.accept) { |sock| exchanges(sock) } }
  rescue IOError, Errno::EBADF, Errno::EINVAL
    nil # 서버가 닫혔다
  end

  def exchanges(sock)
    while (path = read_request(sock))
      break unless write_reply(sock, @routes.fetch(path, NOT_FOUND))
    end
  rescue SystemCallError, IOError
    nil # 클라이언트가 끊었다 — 마감이 작동한 증거다
  ensure
    close_quietly(sock)
  end

  # 조각을 차례로 쓴다 — 쉬다가 서버가 닫혀 깼으면 거짓.
  def write_reply(sock, pieces)
    pieces.all? do |pause, bytes|
      next false if pause.positive? && woken?(pause)

      sock.write(bytes)
      true
    end
  end

  # 요청 하나를 읽고 그 경로(쿼리 앞)를 돌려준다 — 연결이 끝났으면 nil.
  def read_request(sock)
    line = sock.gets("\r\n")
    return unless line

    length = 0
    while (header = sock.gets("\r\n")) && header != "\r\n"
      name, value = header.split(":", 2)
      length = value.to_i if name.strip.casecmp?("content-length")
    end
    sock.read(length)
    line.split[1].to_s.split("?").first
  end

  # `seconds` 를 쉰다 — 서버가 닫혀 깨면 참.
  def woken?(seconds)
    @wake.pop(timeout: seconds)
    @wake.closed?
  end

  # ⚠️ Windows 는 상대가 끊은 소켓의 `close` 에서도 ECONNRESET 을 올린다(BodyServer 와 같은 실측).
  def close_quietly(sock)
    sock&.close
  rescue SystemCallError, IOError
    nil
  end
end
