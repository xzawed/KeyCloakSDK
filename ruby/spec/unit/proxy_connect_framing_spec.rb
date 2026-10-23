# frozen_string_literal: true

require "spec_helper"
require "openssl"
require_relative "../support/framing_server"

# 프록시 CONNECT 응답의 틀 상한(등록부 `ruby-framing-proxy-connect-unbounded`). HTTPS 대상을 프록시로 부르면 net-http 는
# `connect` 안에서 프록시 소켓 위에 **지역** `BufferedIO` 를 만들어 CONNECT 응답을 읽는다 — `on_connect`(=`BoundedReads`)
# 보다 앞이다. 상한은 그 BufferedIO 가 읽는 소켓 하나(`timeouted_connect` 의 TCP 소켓 · TLS 프록시면 첫
# `ssl_socket_connect` 의 SSLSocket)의 `read_nonblock` 에 건다. 셋으로 잰다 — (A) 읽기 계수기 그 자체(각본 IO · 경계값),
# (B) 어느 소켓에 거는가(net-http 의 소켓 여는 자리를 대역으로), (C) 실제 소켓(공개 표면 + Faraday 가 읽는 프록시 환경변수).
module ProxyConnectFramingSpec
  STATUS = "HTTP/1.1 200 Connection established\r\n"
  # (C) 대상 — RFC 5737 TEST-NET-1. 직접 닿지 않는다: 프록시가 CONNECT 에 답한다. ⚠️ 127.0.0.1 을 쓰면 안 된다 —
  # `URI::Generic#find_proxy` 가 루프백 대상에는 환경변수 프록시를 쓰지 않는다(그러면 프록시를 안 탄다).
  TARGET = "192.0.2.1:9"
  PROXY_ENV = %w[http_proxy HTTP_PROXY https_proxy HTTPS_PROXY no_proxy NO_PROXY].freeze

  # `read_nonblock(len, buf = nil, exception:)` 가 각본대로 조각(String · :wait_readable · nil)을 돌려주는 소켓 대역.
  # buf 가 오면 상류 IO 처럼 그 버퍼를 채워 그대로 돌려준다(BufferedIO 의 `rv.equal?(tmp)` 경로).
  class ScriptedIO
    def initialize(*chunks)
      @chunks = chunks
    end

    def read_nonblock(_len, buf = nil, exception: true) # rubocop:disable Lint/UnusedMethodArgument
      chunk = @chunks.shift
      return chunk unless chunk.is_a?(String)

      buf ? buf.replace(chunk) : chunk.dup
    end
  end

  module_function

  def framing = KeycloakSdk::Http.const_get(:ConnectFraming)

  # 계수기를 건 각본 IO.
  def armed(*chunks)
    io = ScriptedIO.new(*chunks)
    io.extend(framing)
    io.kcsdk_arm_connect_framing!
    io
  end

  # 각본을 끝까지 읽는다(BufferedIO 의 호출 모양 그대로).
  def drain(io, reads) = Array.new(reads) { io.read_nonblock(16_384, nil, exception: false) }

  def line_msg = KeycloakSdk::Http.const_get(:FRAMING_LINE_MSG)
  def total_msg = KeycloakSdk::Http.const_get(:FRAMING_TOTAL_MSG)

  # `bytes` 바이트짜리 헤더 줄(CRLF 포함).
  def header(bytes, name = "X-Pad") = "#{name}: #{'a' * (bytes - name.size - 4)}\r\n"
end

RSpec.describe KeycloakSdk::Http do # proxy CONNECT reply framing bound
  let(:spec) { ProxyConnectFramingSpec }

  # ── (A) 읽기 계수기 — 각본 IO 위에서 경계값을 직접 ──────────────────────────────────────────────────
  describe "the CONNECT reply reader" do
    it "accepts a CONNECT line of exactly MAX_FRAMING_LINE_BYTES (incl. CRLF) and refuses one byte more" do
      ok = spec.armed(spec::STATUS, spec.header(8_192), "\r\n")
      expect { spec.drain(ok, 3) }.not_to raise_error
      expect(ok.kcsdk_connect_framing_armed?).to be(false)
      over = spec.armed(spec::STATUS, spec.header(8_193), "\r\n")
      expect { spec.drain(over, 3) }.to raise_error(KeycloakSdk::TransportError, spec.line_msg)
    end

    # 줄이 읽기 경계에 걸쳐도 같은 줄이다 — 그리고 종단 문자가 오기 **전에** 8,192 를 넘으면 그 읽기에서 끊는다.
    it "counts a line across reads and refuses it before its terminator arrives" do
      split = spec.header(8_192)
      ok = spec.armed(spec::STATUS + split[0, 5_000], split[5_000..], "\r\n")
      expect { spec.drain(ok, 3) }.not_to raise_error
      held = spec.armed(spec::STATUS, "a" * 8_192, "\n") # 8,192 바이트, 아직 "\n" 없음 — 여기까지는 받는다
      expect { spec.drain(held, 2) }.not_to raise_error
      expect { spec.drain(held, 1) }.to raise_error(KeycloakSdk::TransportError, spec.line_msg) # 종단 문자도 센다
      long = spec.armed(spec::STATUS, "a" * 8_193)
      expect { spec.drain(long, 2) }.to raise_error(KeycloakSdk::TransportError, spec.line_msg)
    end

    it "accepts a CONNECT reply whose framing totals exactly MAX_FRAMING_BYTES and refuses one byte more" do
      lines = spec.header(4_096) * 15 # 61,440
      ok = spec.armed(spec::STATUS + lines, spec.header(65_536 - spec::STATUS.bytesize - 61_440 - 2), "\r\n")
      expect { spec.drain(ok, 3) }.not_to raise_error
      expect(ok.kcsdk_connect_framing_armed?).to be(false)
      over = spec.armed(spec::STATUS + lines, spec.header(65_537 - spec::STATUS.bytesize - 61_440 - 2), "\r\n")
      expect { spec.drain(over, 3) }.to raise_error(KeycloakSdk::TransportError, spec.total_msg)
    end

    it "refuses many short lines on the response total, not on any one line" do
      chunks = [spec::STATUS] + Array.new(399) { spec.header(205) }
      many = spec.armed(*chunks)
      expect { spec.drain(many, 400) }.to raise_error(KeycloakSdk::TransportError, spec.total_msg)
    end

    it "ends the header block at CRLF CRLF and at LF LF" do
      crlf = spec.armed("#{spec::STATUS}X: y\r\n\r\n")
      lf = spec.armed("HTTP/1.1 200 Connection established\nX: y\n\n")
      spec.drain(crlf, 1)
      spec.drain(lf, 1)
      expect([crlf.kcsdk_connect_framing_armed?, lf.kcsdk_connect_framing_armed?]).to eq([false, false])
    end

    # 줄의 CR|LF 가 두 읽기로 갈려도 빈 줄이 아니다 — 그리고 빈 줄 자체가 갈려도("\r" | "\n") 빈 줄이다.
    it "treats a CR | LF split as one terminator and still finds a blank line split across reads" do
      io = spec.armed("#{spec::STATUS}X: y\r", "\nZ: w\r\n\r", "\n#{'j' * 20_000}")
      spec.drain(io, 1)
      expect(io.kcsdk_connect_framing_armed?).to be(true)
      spec.drain(io, 1)
      expect(io.kcsdk_connect_framing_armed?).to be(true) # "\r" 하나 — 아직 빈 줄이 끝나지 않았다
      expect(spec.drain(io, 1)).to eq(["\n#{'j' * 20_000}"]) # 빈 줄 뒤 20,000 B — 그대로, 세지 않는다
      expect(io.kcsdk_connect_framing_armed?).to be(false)
    end

    it "does not take a blank first line as the end of the block" do
      io = spec.armed("\r\n", "a" * 8_193)
      expect { spec.drain(io, 2) }.to raise_error(KeycloakSdk::TransportError, spec.line_msg)
    end

    it "returns bytes after the blank line unchanged and stops counting for the rest of that socket" do
      head = "#{spec::STATUS}\r\n#{'x' * 16_000}"
      io = spec.armed(head, "y" * 70_000, "z" * 9_000)
      expect(spec.drain(io, 3)).to eq([head, "y" * 70_000, "z" * 9_000])
      expect(io.kcsdk_connect_framing_armed?).to be(false)
    end

    it "passes :wait_readable, :wait_writable and EOF (nil) through untouched and keeps its count across them" do
      io = spec.armed("#{spec::STATUS}X: #{'a' * 5_000}", :wait_readable, :wait_writable, nil, "#{'a' * 3_188}\r\n")
      expect(spec.drain(io, 4)[1..]).to eq([:wait_readable, :wait_writable, nil])
      expect { spec.drain(io, 1) }.to raise_error(KeycloakSdk::TransportError, spec.line_msg) # 3+5,000+3,188+2 = 8,193
    end

    it "keeps the upstream call shape: the given buffer comes back as the same object, exception: defaults to true" do
      io = spec.armed(spec::STATUS, "a" * 8_193)
      buf = +""
      expect(io.read_nonblock(16_384, buf, exception: false)).to equal(buf)
      expect { io.read_nonblock(16_384) }.to raise_error(KeycloakSdk::TransportError, spec.line_msg)
    end
  end

  # ── (B) 어느 소켓에 거는가 — net-http 의 소켓 여는 세 자리를 대역으로(그 대역은 훅 **아래** 싱글턴에 있다) ───────────
  describe "which socket the CONNECT bound is armed on" do
    # 훅을 건 Net::HTTP — 소켓 여는 상류 셋은 대역이고 만든 소켓을 종류별로 모은다.
    def hooked(http)
      sockets = Hash.new { |h, k| h[k] = [] }
      http.define_singleton_method(:timeouted_connect) { |_addr, _port| Object.new.tap { |s| sockets[:tcp] << s } }
      http.define_singleton_method(:ssl_socket_connect) { |_sock, _timeout| nil }
      stub_connect(http, sockets)
      http.singleton_class.prepend(KeycloakSdk::Http.const_get(:BoundedTransport))
      sockets
    end

    # net-http `connect` 의 소켓 순서만 남긴 대역: TCP → (TLS 프록시면) 프록시 TLS → (HTTPS 면) 대상 TLS.
    def stub_connect(http, sockets)
      http.define_singleton_method(:connect) do
        timeouted_connect("127.0.0.1", 8080)
        next unless use_ssl?

        tls_proxy = proxy? && instance_variable_get(:@proxy_use_ssl)
        ssl_socket_connect(Object.new.tap { |s| sockets[:proxy_tls] << s }, nil) if tls_proxy
        ssl_socket_connect(Object.new.tap { |s| sockets[:origin_tls] << s }, nil)
      end
    end

    def armed_map(sockets)
      sockets.transform_values { |list| list.map { |s| s.is_a?(spec.framing) && s.kcsdk_connect_framing_armed? } }
    end

    def http(proxy: nil, tls_proxy: nil, use_ssl: true)
      Net::HTTP.new("192.0.2.1", 9, proxy, proxy && 8080, nil, nil, nil, tls_proxy).tap { |h| h.use_ssl = use_ssl }
    end

    it "arms the TCP socket for a plain HTTP proxy to an HTTPS target, and never the origin TLS socket" do
      h = http(proxy: "127.0.0.1")
      sockets = hooked(h)
      h.send(:connect)
      expect(armed_map(sockets)).to eq(tcp: [true], origin_tls: [false])
    end

    # 첫 `ssl_socket_connect` 가 프록시와의 TLS 다 — 둘째(대상)는 건드리지 않는다. 연결마다 다시 첫째부터다.
    it "arms only the proxy TLS socket for an HTTPS proxy, once per connect" do
      h = http(proxy: "127.0.0.1", tls_proxy: true)
      sockets = hooked(h)
      2.times { h.send(:connect) }
      expect(armed_map(sockets)).to eq(tcp: [false, false], proxy_tls: [true, true], origin_tls: [false, false])
    end

    it "arms nothing without a proxy, or for a plain-HTTP target (that reply is @socket's, already bounded)" do
      direct = http
      direct_sockets = hooked(direct)
      direct.send(:connect)
      plain = http(proxy: "127.0.0.1", use_ssl: false)
      plain_sockets = hooked(plain)
      plain.send(:connect)
      expect([armed_map(direct_sockets), armed_map(plain_sockets)])
        .to eq([{ tcp: [false], origin_tls: [false] }, { tcp: [false] }])
    end

    it "hands back what the upstream socket calls return" do
      h = http(proxy: "127.0.0.1")
      sockets = hooked(h)
      h.define_singleton_method(:ssl_socket_connect) { |_sock, _timeout| :connected }
      expect(h.send(:ssl_socket_connect, Object.new, nil)).to eq(:connected)
      expect(h.send(:timeouted_connect, "127.0.0.1", 8080)).to equal(sockets[:tcp].last)
    end
  end

  # ── (C) 실제 소켓 — 공개 표면(client_credentials_token) + Faraday 가 읽는 프록시 환경변수 ──────────────────────
  describe "a real proxy reached through the environment Faraday honours" do
    around do |example|
      saved = spec::PROXY_ENV.to_h { |k| [k, ENV.fetch(k, nil)] }
      WebMock.disable!
      example.run
    ensure
      WebMock.enable!
      saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    end

    let(:proxy) { FramingServer.new }

    after { proxy.close }

    # 프록시를 환경변수로 걸고 공개 호출 하나 — 난 오류를 돌려준다(돌아오면 nil).
    def call_through(proxy_url, scheme: "https")
      ENV.delete("no_proxy")
      ENV.delete("NO_PROXY")
      ENV["#{scheme}_proxy"] = proxy_url
      cfg = KeycloakSdk::Config.new(server_url: "#{scheme}://#{spec::TARGET}", realm: "frm", client_id: "c",
                                    client_secret: "s", connect_timeout: 5, read_timeout: 5)
      KeycloakSdk::KeycloakClient.new(cfg).auth.client_credentials_token
      nil
    rescue KeycloakSdk::Error => e
      e
    end

    def connect_reply(*pieces) = proxy.route(spec::TARGET) { pieces }

    it "refuses a CONNECT reply with a 100,000-byte header line" do
      connect_reply("#{spec::STATUS}X-Pad: #{'a' * 100_000}\r\n\r\n")
      error = call_through(proxy.url)
      expect([error.class, error&.message]).to eq([KeycloakSdk::TransportError, spec.line_msg])
      expect(proxy.requests.map { |r| [r.verb, r.path] }).to eq([["CONNECT", spec::TARGET]]) # 프록시를 탔다
    end

    it "refuses a CONNECT reply of 400 short header lines (~82 KB)" do
      connect_reply(spec::STATUS, *Array.new(400) { |i| spec.header(205, "X-H#{i}") }, "\r\n")
      error = call_through(proxy.url)
      expect([error.class, error&.message]).to eq([KeycloakSdk::TransportError, spec.total_msg])
    end

    # 대조 — 정상 CONNECT 응답은 지나가고 대상과의 TLS 악수에서 실패한다(프록시가 닫는다). 빈 줄 뒤 같은 쓰기의
    # 바이트도 세지 않는다(그 바이트는 net-http 가 버린다).
    it "lets a well-formed CONNECT reply through to the TLS handshake (a non-framing TransportError)" do
      connect_reply("#{spec::STATUS}\r\n", "j" * 20_000)
      error = call_through(proxy.url)
      expect(error).to be_a(KeycloakSdk::TransportError)
      expect(error.message).not_to eq(spec.line_msg)
      expect(error.message).not_to eq(spec.total_msg)
      expect(error.message).to include("SSL_connect") # 실패한 자리는 대상과의 TLS 악수다
    end

    # 대조 — 평문 대상의 프록시 응답은 같은 @socket(BoundedReads)으로 읽힌다. CONNECT 훅 없이도 이미 상한이 선다.
    it "still bounds a plain-HTTP target's proxied reply through the existing hook" do
      proxy.route("http://#{spec::TARGET}/realms/frm/protocol/openid-connect/token") do
        ["HTTP/1.1 200 X\r\nX-Pad: #{'a' * 100_000}\r\n\r\n"]
      end
      error = call_through(proxy.url, scheme: "http")
      expect([error.class, error&.message]).to eq([KeycloakSdk::TransportError, spec.line_msg])
      expect(proxy.requests.map(&:verb)).to eq(["POST"]) # CONNECT 없이 절대 URI 로
    end

    it "refuses an over-long CONNECT reply from an HTTPS proxy (the proxy's TLS socket is bounded)" do
      tls_proxy = FramingServer.new(tls: FramingServer.tls_context)
      tls_proxy.route(spec::TARGET) { ["#{spec::STATUS}X-Pad: #{'a' * 100_000}\r\n\r\n"] }
      error = call_through(tls_proxy.url)
      expect([error.class, error&.message]).to eq([KeycloakSdk::TransportError, spec.line_msg])
      expect(tls_proxy.requests.map(&:verb)).to eq(["CONNECT"])
    ensure
      tls_proxy&.close
    end
  end
end
