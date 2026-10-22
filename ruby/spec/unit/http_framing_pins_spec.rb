# frozen_string_literal: true

require "spec_helper"
require "stringio"
require "socket"
require "uri"
require_relative "../support/framing_server"

# `Http::BoundedReads`/`BoundedTransport` 가 기대는 **net-protocol/net-http 의 모양**을 핀으로 고정하고(바뀌면 시끄럽게
# 실패), `BoundedReads` 의 경계 동작을 소켓 수준에서 직접 재며, 틀 상한이 net-http 의 실제 경로(Content-Length·chunked·
# 1xx·프록시)에서 선다는 것을 보인다. 이 핀이 없으면 상류가 `readuntil`/`readline` 이나 `@rbuf` 를 바꿨을 때
# `response_framing_cap_spec` 이 **조용히** 공허해진다(내 override 가 안 불리거나 내부가 달라 깨진다).
module HttpFramingPinsSpec
  TOKEN = "/realms/frm/protocol/openid-connect/token"

  # (C3) 대조 사례 — `[데이터, 위치 인자, 키워드]`. 원판이 `limit:` 을 받으면(0.3.0+) 그 뜻도 대조한다.
  PARITY_CASES = [
    ["HTTP/1.1 200 OK\r\nX: y\r\n", ["\n"], {}], ["HTTP/1.1 200 OK\r\nX: y\r\n", ["\n", true], {}],
    ["no-terminator", ["\n", true], {}], ["no-terminator", ["\n"], {}], ["", ["\n", true], {}]
  ].freeze
  PARITY_LIMIT_CASES = [
    ["abc\nrest", ["\n"], { limit: 4 }], ["abcd\nrest", ["\n"], { limit: 4 }],
    ["#{'a' * 200}\n", ["\n"], { limit: 100 }], ["a" * 200, ["\n", true], { limit: 100 }],
    ["a" * 100, ["\n", true], { limit: 10 }], ["x\n", ["\n"], { limit: 0 }], ["x\n", ["\n"], { limit: "1" }]
  ].freeze
  UPSTREAM_TAKES_LIMIT = Net::BufferedIO.instance_method(:readuntil).parameters.include?(%i[key limit])

  module_function

  # StringIO 위의 BufferedIO 에 BoundedReads 를 extend 한 것(직접 단위 시험용).
  def bounded_over(data)
    io = Net::BufferedIO.new(StringIO.new(data.b))
    io.extend(KeycloakSdk::Http.const_get(:BoundedReads))
    io.kcsdk_reset_framing!
    io
  end
end

RSpec.describe KeycloakSdk::Http do # response framing bound — net-http shape pins
  # ── (A) 상류 모양 핀 — BoundedReads/BoundedTransport 가 기대는 내부가 그대로인가 ──────────────────
  describe "net-protocol BufferedIO shape the hook relies on" do
    let(:io) { Net::BufferedIO.new(StringIO.new("".b)) }

    # 아는 모양은 둘이다 — 0.2.x(위치 인자 둘)와 0.3.0+(`limit:` 키워드 — net-http 0.10 이 그것으로 부른다). 셋째 모양이
    # 나오면 여기서 운다(훅이 그 모양을 못 받으면 SDK 의 HTTP 호출이 전부 ArgumentError 다 — 0.4.0 에서 실제로 그랬다).
    it "reads framing through readuntil and readline (the methods the hook overrides)" do
      expect(Net::BufferedIO.instance_method(:readuntil).parameters)
        .to eq([%i[req terminator], %i[opt ignore_eof]])
        .or eq([%i[req terminator], %i[opt ignore_eof], %i[key limit]])
      expect(Net::BufferedIO.instance_method(:readline).parameters).to eq([])
    end

    it "the hook takes both upstream call shapes (positional ignore_eof and the limit: keyword)" do
      hooked = HttpFramingPinsSpec.bounded_over("")
      expect(hooked.method(:readuntil).parameters).to eq([%i[req terminator], %i[opt ignore_eof], %i[key limit]])
      expect(hooked.method(:readline).parameters).to eq([])
    end

    it "buffers into @rbuf / @rbuf_offset and fills via private rbuf_fill / rbuf_consume" do
      io.instance_variable_set(:@rbuf, +"") # 존재 확인
      expect(io.instance_variables).to include(:@rbuf, :@rbuf_offset)
      expect(Net::BufferedIO.private_instance_methods).to include(:rbuf_fill, :rbuf_consume)
    end

    it "net-http opens the socket through private on_connect and runs begin_transport per request" do
      expect(Net::HTTP.private_instance_methods).to include(:on_connect, :begin_transport)
    end
  end

  # ── (B) SDK 상한·메시지가 교차언어 값인가(= response_framing_cap_spec 의 신탁과 같은가) ─────────────
  describe "the SDK framing constants" do
    let(:http) { described_class }

    it "pins the per-line and per-response byte limits to the cross-language values" do
      expect(http.const_get(:MAX_FRAMING_LINE_BYTES)).to eq(8_192)
      expect(http.const_get(:MAX_FRAMING_BYTES)).to eq(65_536)
    end

    it "pins constant messages that do not quote bytes (literal oracle)" do
      expect(http.const_get(:FRAMING_LINE_MSG)).to eq("HTTP response framing line exceeds 8192 bytes")
      expect(http.const_get(:FRAMING_TOTAL_MSG)).to eq("HTTP response framing exceeds 65536 bytes")
    end
  end

  # ── (C) BoundedReads 경계 동작(소켓 수준 직접) ───────────────────────────────────────────────────
  describe "BoundedReads line and response budgets" do
    let(:line_msg) { described_class.const_get(:FRAMING_LINE_MSG) }
    let(:total_msg) { described_class.const_get(:FRAMING_TOTAL_MSG) }

    it "accepts a line of exactly MAX_FRAMING_LINE_BYTES (incl. terminator)" do
      io = HttpFramingPinsSpec.bounded_over("#{'a' * 8_190}\r\n") # 8,192 바이트
      expect(io.readuntil("\n", true).bytesize).to eq(8_192)
    end

    it "refuses a line one byte over the limit, before buffering it whole" do
      io = HttpFramingPinsSpec.bounded_over("#{'a' * 8_191}\r\nrest")
      expect { io.readuntil("\n", true) }.to raise_error(KeycloakSdk::TransportError, line_msg)
    end

    it "refuses once the response's framing total crosses MAX_FRAMING_BYTES (small lines)" do
      line = "#{'a' * 4_094}\r\n" # 4,096 바이트
      io = HttpFramingPinsSpec.bounded_over(line * 20) # 16 줄 ≈ 65,536 에서 넘는다
      error = nil
      begin
        17.times { io.readuntil("\n", true) }
      rescue KeycloakSdk::TransportError => e
        error = e
      end
      expect(error&.message).to eq(total_msg)
    end

    # 경계 그 자체 — 위 시험은 「어딘가에서 넘는다」만 본다(`>` 를 `>=` 로 바꾼 변이가 통과했다 · Grok 변이 레그).
    it "accepts a response whose framing totals exactly MAX_FRAMING_BYTES and refuses one byte more" do
      line = "#{'a' * 4_094}\r\n" # 4,096 바이트
      io = HttpFramingPinsSpec.bounded_over("#{line * 16}\n") # 16 줄 = 65,536 바이트, 그다음 1 바이트 줄
      16.times { io.readuntil("\n", true) }
      expect { io.readuntil("\n", true) }.to raise_error(KeycloakSdk::TransportError, total_msg)
    end

    it "resets the response budget on kcsdk_reset_framing! (keep-alive reuse)" do
      line = "#{'a' * 4_094}\r\n"
      io = HttpFramingPinsSpec.bounded_over(line * 40)
      15.times { io.readuntil("\n", true) } # 60 KiB — 아직 상한 아래
      io.kcsdk_reset_framing!
      expect { 15.times { io.readuntil("\n", true) } }.not_to raise_error # 리셋 뒤 다시 60 KiB 가 통과한다
    end

    it "returns the partial line on EOF when ignore_eof is true, and raises otherwise" do
      expect(HttpFramingPinsSpec.bounded_over("partial-no-terminator").readuntil("\n", true))
        .to eq("partial-no-terminator")
      expect { HttpFramingPinsSpec.bounded_over("partial").readuntil("\n") }.to raise_error(EOFError)
    end

    it "reads a whole short line through readline (status / chunk-size / trailer path)" do
      expect(HttpFramingPinsSpec.bounded_over("HTTP/1.1 200 OK\r\n").readline).to eq("HTTP/1.1 200 OK")
    end
  end

  # ── (C2) `limit:` — net-http 0.10 이 모든 틀 줄을 `readuntil("\n", ignore_eof, limit: 1 MiB)` 로 읽는다 ─────────
  describe "the limit: keyword net-http 0.10 passes" do
    let(:line_msg) { described_class.const_get(:FRAMING_LINE_MSG) }

    # net-protocol 0.2.x 에는 이 예외가 없다(0.3.0 이 들였다) — 잠긴 레인에서도 같은 갈래를 밟도록 그때만 세운다.
    before do
      stub_const("Net::ReadLimitExceeded", Class.new(Net::ProtocolError)) unless defined?(Net::ReadLimitExceeded)
    end

    it "keeps the SDK line bound under net-http's 1 MiB limit" do
      io = HttpFramingPinsSpec.bounded_over("#{'a' * 8_191}\r\nrest")
      expect { io.readuntil("\n", true, limit: 1_048_576) }.to raise_error(KeycloakSdk::TransportError, line_msg)
    end

    it "returns a line within both bounds unchanged" do
      expect(HttpFramingPinsSpec.bounded_over("HTTP/1.1 200 OK\r\n").readuntil("\n", false, limit: 1_048_576))
        .to eq("HTTP/1.1 200 OK\r\n")
    end

    it "keeps upstream's meaning for a tighter limit: it counts the terminator and consumes nothing" do
      io = HttpFramingPinsSpec.bounded_over("abcd\nabc\n")
      expect { io.readuntil("\n", false, limit: 4) }
        .to raise_error(Net::ReadLimitExceeded, "exceeded the 4 byte read limit")
      expect(io.readuntil("\n", false, limit: 5)).to eq("abcd\n")
      expect(io.readuntil("\n", false, limit: 4)).to eq("abc\n")
    end

    it "applies a tighter limit while the line is still being filled" do
      io = HttpFramingPinsSpec.bounded_over("a" * 200)
      expect { io.readuntil("\n", true, limit: 100) }.to raise_error(Net::ReadLimitExceeded)
    end

    it "lets the SDK bound win when it and the caller's limit both trip" do
      io = HttpFramingPinsSpec.bounded_over("#{'a' * 8_191}\r\n")
      expect { io.readuntil("\n", false, limit: 100) }.to raise_error(KeycloakSdk::TransportError, line_msg)
    end

    it "rejects an invalid limit the way upstream does" do
      [0, -1, "1", 1.5].each do |bad|
        expect { HttpFramingPinsSpec.bounded_over("x\n").readuntil("\n", false, limit: bad) }
          .to raise_error(ArgumentError, /\Alimit must be a positive Integer, got /)
      end
    end
  end

  # ── (C3) 상한 안에서는 설치된 원판과 같다 — 원판의 뜻이 바뀌면 시끄럽게 실패한다 ───────────────────────────
  describe "parity with the installed upstream readuntil inside the SDK bounds" do
    # 값 또는 예외(클래스·메시지)와, 그 뒤 소켓에 남은 바이트.
    def outcome(io, pos, kwargs)
      result = begin
        [:returned, io.readuntil(*pos, **kwargs)]
      rescue StandardError => e
        [:raised, e.class, e.message]
      end
      result << io.read_all
    end

    it "returns or raises what upstream does, and leaves the same bytes unread" do
      cases = HttpFramingPinsSpec::PARITY_CASES
      cases += HttpFramingPinsSpec::PARITY_LIMIT_CASES if HttpFramingPinsSpec::UPSTREAM_TAKES_LIMIT
      cases.each do |data, pos, kwargs|
        expected = outcome(Net::BufferedIO.new(StringIO.new(data.b)), pos, kwargs)
        expect(outcome(HttpFramingPinsSpec.bounded_over(data), pos, kwargs))
          .to eq(expected), "#{data[0, 20].inspect} #{pos} #{kwargs}"
      end
    end
  end

  # ── (D) net-http 의 실제 경로에서 상한이 선다 ─────────────────────────────────────────────────────
  describe "real net-http code paths" do
    around do |example|
      WebMock.disable!
      example.run
    ensure
      WebMock.enable!
    end

    let(:server) { FramingServer.new }
    let(:token) { %({"access_token":"AT","token_type":"Bearer","expires_in":1}) }

    after { server.close }

    def cc_client(url, **over)
      KeycloakSdk::KeycloakClient.new(
        KeycloakSdk::Config.new(server_url: url, realm: "frm", client_id: "c", client_secret: "s", **over)
      )
    end

    it "bounds a Content-Length response with an over-long header line" do
      server.route(HttpFramingPinsSpec::TOKEN) do
        pieces = ["HTTP/1.1 200 X\r\nContent-Type: application/json\r\n", "X-Pad: "]
        FramingServer.repeat(16 * 1_048_576).each { |p| pieces << p }
        pieces << "\r\nContent-Length: #{token.bytesize}\r\n\r\n" << token
        pieces
      end
      expect { cc_client(server.url).auth.client_credentials_token }
        .to raise_error(KeycloakSdk::TransportError, described_class.const_get(:FRAMING_LINE_MSG))
    end

    it "bounds a chunked response whose chunk-size line carries a huge extension" do
      server.route(HttpFramingPinsSpec::TOKEN) do
        pieces = ["HTTP/1.1 200 X\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n",
                  "#{token.bytesize.to_s(16)};"]
        FramingServer.repeat(16 * 1_048_576).each { |p| pieces << p }
        pieces << "\r\n#{token}\r\n0\r\n\r\n"
        pieces
      end
      expect { cc_client(server.url).auth.client_credentials_token }
        .to raise_error(KeycloakSdk::TransportError, described_class.const_get(:FRAMING_LINE_MSG))
    end

    it "accepts a normal Content-Length response (the bound does not fire on real framing)" do
      head = "HTTP/1.1 200 X\r\nContent-Type: application/json\r\nContent-Length: #{token.bytesize}\r\n\r\n"
      server.route(HttpFramingPinsSpec::TOKEN) { [head, token] }
      expect(cc_client(server.url).auth.client_credentials_token.access_token).to eq("AT")
    end

    # 1xx — 한 요청 안에서 net-http 가 read_new 를 여러 번 돈다(모두 같은 틀 예산을 나눈다).
    it "accepts a few 1xx interim responses before the final 200" do
      server.route(HttpFramingPinsSpec::TOKEN) do
        ["HTTP/1.1 100 Continue\r\nX-A: 1\r\n\r\n" * 3,
         "HTTP/1.1 200 X\r\nContent-Type: application/json\r\nContent-Length: #{token.bytesize}\r\n\r\n", token]
      end
      expect(cc_client(server.url).auth.client_credentials_token.access_token).to eq("AT")
    end

    it "bounds a flood of 1xx interim responses (they share the response framing budget)" do
      server.route(HttpFramingPinsSpec::TOKEN) do
        flood = Enumerator.new do |y|
          # 각 100-continue 가 큰 헤더 한 줄 — 누적 틀이 예산을 넘는다.
          20.times { y << "HTTP/1.1 100 Continue\r\nX-Pad: #{'a' * 7_000}\r\n\r\n" }
          y << "HTTP/1.1 200 X\r\nContent-Type: application/json\r\nContent-Length: #{token.bytesize}\r\n\r\n"
          y << token
        end
        flood
      end
      expect { cc_client(server.url).auth.client_credentials_token }
        .to raise_error(KeycloakSdk::TransportError, described_class.const_get(:FRAMING_TOTAL_MSG))
    end

    # 프록시 — Faraday 의 proxy 옵션. net-http 는 프록시에 절대 URI 를 보내고 응답을 같은 @socket(상한 걸린)에서 읽는다.
    it "bounds an over-long header line even when routed through a Faraday proxy" do
      cfg = KeycloakSdk::Config.new(server_url: "http://kc.invalid", realm: "frm", client_id: "c")
      conn = described_class.build(cfg)
      conn.proxy = server.url
      # 프록시는 절대 URI 로 라우트된다.
      server.route("http://kc.invalid/x") do
        pieces = ["HTTP/1.1 200 X\r\nContent-Type: application/json\r\n", "X-Pad: "]
        FramingServer.repeat(16 * 1_048_576).each { |p| pieces << p }
        pieces << "\r\nContent-Length: 2\r\n\r\n" << "{}"
        pieces
      end
      expect { conn.get("http://kc.invalid/x") }
        .to raise_error(KeycloakSdk::TransportError, described_class.const_get(:FRAMING_LINE_MSG))
      expect(server.requests.last.path).to eq("http://kc.invalid/x") # 절대 URI = 프록시 경로를 탔다
    end

    # begin_transport 가 요청마다 틀 예산을 0 으로 되돌리는가 — keep-alive 로 연결을 **재사용**할 때만 드러난다
    # (새 연결마다 on_connect 가 이미 리셋하므로). 응답 하나는 예산 바로 아래(~54 KiB), 둘을 더하면 넘는다.
    # ⚠️ connections == 1 을 함께 단언한다 — 재사용이 아니면(연결 둘) on_connect 리셋이 대신해 이 시험이 공허해진다.
    it "resets the framing budget per request across a reused keep-alive connection (begin_transport)" do
      ka = FramingServer.new(keep_alive: true)
      big = (1..9).map { |i| "X-H#{i}: #{'a' * 6_000}\r\n" }.join # 9 줄 × ~6 KiB ≈ 54 KiB < 65,536, 각 줄 < 8,192
      ka.route("/a") { ["HTTP/1.1 200 X\r\n#{big}Content-Length: 2\r\n\r\n", "{}"] }
      uri = URI(ka.url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.singleton_class.prepend(described_class.const_get(:BoundedTransport))
      http.start
      begin
        codes = [http.request(Net::HTTP::Get.new("/a")).code, http.request(Net::HTTP::Get.new("/a")).code]
        expect(codes).to eq(%w[200 200])
        expect(ka.connections).to eq(1) # 한 연결을 재사용했다(아니면 시험이 공허하다)
      ensure
        http.finish
        ka.close
      end
    end

    it "accepts a normal response through a Faraday proxy" do
      cfg = KeycloakSdk::Config.new(server_url: "http://kc.invalid", realm: "frm", client_id: "c")
      conn = described_class.build(cfg)
      conn.proxy = server.url
      server.route("http://kc.invalid/y") { ["HTTP/1.1 200 X\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n", "{}"] }
      expect(conn.get("http://kc.invalid/y").status).to eq(200)
    end
  end
end
