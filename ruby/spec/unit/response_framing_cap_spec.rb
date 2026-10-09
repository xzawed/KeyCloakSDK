# frozen_string_literal: true

require "spec_helper"
require_relative "../support/body_server"
require_relative "../support/framing_server"

# 응답 **틀**(상태 줄·헤더 줄·청크 크기/확장 줄·트레일러)의 상한(response-framing-unbounded).
#
# 본문 상한(`read_capped`, 1 MiB)은 `on_data` 로 넘어오는 **본문 바이트**만 본다. net-http 는 그 앞뒤로 틀을 한도 없이
# 읽는다 — 헤더 줄과 트레일러는 `readuntil("\n", true)`/`readline`, 청크 크기/확장 줄도 `readline` 이다. 그래서 다음 넷이
# 상한 밖이었다(2026-10-09 실측, 가짜 IdP · 원시 TCP · 16 MiB · auth·admin 같다):
#   F1 헤더 한 줄 16 MiB → 수락 · +67 MB · F2 청크 확장 16 MiB → 수락 · +50 MB
#   F3a 4 KiB 트레일러 줄 4096 개 → 수락 · +32–46 MB · F3b 트레일러 한 줄 16 MiB → 수락 · +50 MB
#
# 수정은 SDK 전용 어댑터(`Http::BoundedNetHttp`)가 소켓에 줄 상한 하나(`MAX_LINE`)와 응답당 틀 바이트 예산 하나
# (`MAX_FRAMING_BYTES`)를 건다 — 어느 틀 줄도 `MAX_LINE` 를 넘을 수 없고(F1·F2·F3b), 한 응답의 틀 전체가
# `MAX_FRAMING_BYTES` 를 넘을 수 없다(F3a). 넘으면 상수 메시지의 `TransportError` 이고 연결은 닫힌다(비우지 않는다).
#
# ⚠️ WebMock 은 틀을 못 짠다 — 실제 소켓(`FramingServer`)으로 바이트 그대로 보낸다. 할당은 `BodyServer.allocated_bytes`
# (GC 끈 창)로 잰다. 「읽은 바이트」는 서버가 소켓에 넘긴 바이트(`server.written`)로 본다 — 커널 송신 버퍼 탓에 클라이언트가
# 읽은 것보다 크지만, 16 MiB 전부를 넘겼는지 아닌지는 가른다(Go·Java 가 같은 오라클을 쓴다).
module ResponseFramingCapSpec
  REALM = "frm"
  OIDC = "/realms/#{REALM}/protocol/openid-connect".freeze
  TOKEN = "#{OIDC}/token".freeze
  INTROSPECT = "#{OIDC}/token/introspect".freeze
  CERTS = "#{OIDC}/certs".freeze
  LOGOUT = "#{OIDC}/logout".freeze
  USERS = "/admin/realms/#{REALM}/users".freeze

  ATTACK = 16 * 1_048_576 # 16 MiB
  # 수정 뒤 상한(실측 대조군 근거는 아래 예제 · 커밋 메시지):
  #   MAX_LINE 8,192 = Java MessageConstraints 줄 한도. Keycloak 26.6 의 가장 긴 응답 틀 줄 85 B(Go 실측)의 ×96.
  #   MAX_FRAMING_BYTES 65,536 = .NET 헤더+트레일러 한도 · Go 머리 블록 한도와 같다. Keycloak 머리 블록 ≤339 B,
  #   브라우저 로그인 최대 3,018 B(둘 다 Go 실측) — SDK 가 받는 것의 ×19 이상이라 기본 서버 응답을 거부하지 않는다.
  # ⚠️ 시험의 신탁 — SDK 상수(private)와 같은지는 `http_framing_pins_spec` 이 따로 본다. 여기서 SDK 상수를 쓰면
  # 상수가 없을 때(수정 전) 모든 예제가 죽어 「수락했다」는 진짜 결함이 가려진다(token_response_cap_spec 과 같은 규율).
  MAX_LINE = 8_192
  MAX_FRAMING = 65_536
  LINE_MSG = "HTTP response framing line exceeds #{MAX_LINE} bytes".freeze
  TOTAL_MSG = "HTTP response framing exceeds #{MAX_FRAMING} bytes".freeze

  JSON_HEADERS = "Content-Type: application/json\r\n"
  # 레인별 공격을 싣는 엔드포인트(admin_rest 만 토큰 뒤 /users).
  ATTACK_ROUTE = {
    "cc" => TOKEN, "refresh" => TOKEN, "exchange_code" => TOKEN, "introspect" => INTROSPECT,
    "admin_token" => TOKEN, "admin_rest" => USERS
  }.freeze

  module_function

  def config(server, **over)
    KeycloakSdk::Config.new(server_url: server, realm: REALM, client_id: "c", client_secret: "s", **over)
  end

  def client(server, **over)
    KeycloakSdk::KeycloakClient.new(config(server, **over))
  end

  # 쓸 수 있는 토큰 응답 본문(평문, Content-Length).
  def token_body
    %({"access_token":"AT","token_type":"Bearer","expires_in":1,"refresh_token":"rt","scope":"openid"})
  end

  def introspect_body
    %({"active":true,"sub":"s","username":"u","client_id":"c"})
  end

  # Content-Length 평문 응답을 조각 Enumerator 로.
  def plain(body, status: 200, extra_headers: "")
    head = "HTTP/1.1 #{status} X\r\n#{JSON_HEADERS}#{extra_headers}Content-Length: #{body.bytesize}\r\n\r\n"
    [head, body]
  end

  # ── 틀 공격 넷 — 각 조각 Enumerator 를 돌려준다(서버가 소켓에 그대로 쓴다) ──────────────────────────

  # F1 — 한 헤더 줄이 `pad` 바이트. 그 뒤 정상 본문.
  def f1_header_line(body, pad)
    pieces = ["HTTP/1.1 200 X\r\n#{JSON_HEADERS}", "X-Pad: "]
    FramingServer.repeat(pad).each { |p| pieces << p }
    pieces << "\r\nContent-Length: #{body.bytesize}\r\n\r\n"
    pieces << body
    pieces
  end

  # F2 — 청크 크기 줄의 확장이 `pad` 바이트("1;<pad>\r\n" + 데이터 + 0 청크).
  def f2_chunk_ext(body, pad)
    pieces = ["HTTP/1.1 200 X\r\n#{JSON_HEADERS}Transfer-Encoding: chunked\r\n\r\n",
              "#{body.bytesize.to_s(16)};"]
    FramingServer.repeat(pad).each { |p| pieces << p }
    pieces << "\r\n#{body}\r\n0\r\n\r\n"
    pieces
  end

  # 정상 청크 본문 + 트레일러. `trailer_pieces` 는 "\r\n" 로 끝나는 트레일러 줄들(없으면 빈 트레일러).
  def chunked_with_trailers(body, trailer_pieces)
    pieces = ["HTTP/1.1 200 X\r\n#{JSON_HEADERS}Transfer-Encoding: chunked\r\n\r\n",
              "#{body.bytesize.to_s(16)}\r\n#{body}\r\n0\r\n"]
    trailer_pieces.each { |p| pieces << p }
    pieces << "\r\n"
    pieces
  end

  # F3a — 4 KiB 트레일러 줄 `count` 개. ⚠️ 같은 줄 하나를 되풀어 낸다(미리 `count` 개를 만들면 측정 창 안에서 서버
  # 스레드가 16 MiB 를 할당해 **클라이언트** 할당 측정을 오염시킨다 — `FramingServer.repeat` 과 같은 이유).
  def f3a_many_trailers(body, count, line_bytes: 4096)
    name = "X-Trailer: "
    line = "#{name}#{'a' * (line_bytes - name.bytesize - 2)}\r\n".freeze
    trailer = Enumerator.new { |y| count.times { y << line } }
    chunked_with_trailers(body, trailer)
  end

  # F3b — 트레일러 한 줄이 `pad` 바이트.
  def f3b_one_trailer(body, pad)
    trailer = Enumerator.new do |y|
      y << "X-Trailer: "
      FramingServer.repeat(pad).each { |p| y << p }
      y << "\r\n"
    end
    chunked_with_trailers(body, trailer)
  end

  # 레인 — cc·refresh·exchange_code·introspect·admin(토큰·REST). 넷 다 같은 `Http.build` 커넥션을 쓴다.
  LANES = %w[cc refresh exchange_code introspect admin_token admin_rest].freeze

  # 틀 공격 넷 — `[이름 => [->(spec, body) { 조각들 }, 기대 메시지]]`. 한 줄 공격 셋(F1·F2·F3b)은 줄 상한 메시지,
  # 작은 줄 다수(F3a)는 응답 누적 메시지. 둘 다 바이트를 싣지 않는 상수다.
  SHAPES = {
    "F1 a 16 MiB header line" => [->(s, body) { s.f1_header_line(body, ATTACK) }, LINE_MSG],
    "F2 a 16 MiB chunk extension" => [->(s, body) { s.f2_chunk_ext(body, ATTACK) }, LINE_MSG],
    "F3a 4096 trailer lines of 4 KiB" => [->(s, body) { s.f3a_many_trailers(body, 4096) }, TOTAL_MSG],
    "F3b a 16 MiB trailer line" => [->(s, body) { s.f3b_one_trailer(body, ATTACK) }, LINE_MSG]
  }.freeze

  # 레인의 공격을 받는 본문 모양.
  def body_for(lane)
    case lane
    when "introspect" then introspect_body
    when "admin_rest" then "[]"
    else token_body
    end
  end
end

RSpec.describe KeycloakSdk::Http do
  let(:spec) { ResponseFramingCapSpec }
  let(:server) { FramingServer.new(keep_alive: false) }
  let(:kc) { spec.client(server.url) }

  # 실제 소켓 — WebMock 은 틀을 못 짠다.
  around do |example|
    WebMock.disable!
    example.run
  ensure
    WebMock.enable!
  end

  after { server.close }

  # 레인 하나를 호출한다 — 「값」을 돌려주거나 raise 한다. admin 두 레인: admin_token 은 토큰 요청이 공격을 싣고
  # (admin 호출 전에 막힌다), admin_rest 는 정상 토큰 뒤 /users 응답이 싣는다.
  def lane_call(name)
    case name
    when "cc" then kc.auth.client_credentials_token.access_token
    when "refresh" then kc.auth.refresh(refresh_token: "rt").access_token
    when "exchange_code" then kc.auth.exchange_code(code: "c", code_verifier: "v", redirect_uri: "https://a/cb").access_token
    when "introspect" then kc.auth.introspect("T").active
    else kc.admin.users.list # admin_token · admin_rest
    end
  end

  # 공격 응답을 공격 엔드포인트에 건다(admin_rest 는 토큰을 먼저 정상으로 건다).
  def arm(lane, attack)
    server.route(spec::TOKEN) { spec.plain(spec.token_body) } if lane == "admin_rest"
    server.route(spec::ATTACK_ROUTE.fetch(lane)) { attack }
  end

  # 정상(대조군) 응답 — 공격 엔드포인트에 `extra_headers` 를 단 쓸 수 있는 응답을 건다. admin 레인은 토큰·/users 를 함께.
  def arm_ok(lane, extra_headers: "")
    server.route(spec::TOKEN) { spec.plain(spec.token_body) }
    server.route(spec::USERS) { spec.plain("[]") } if lane.start_with?("admin")
    server.route(spec::ATTACK_ROUTE.fetch(lane)) { spec.plain(spec.body_for(lane), extra_headers: extra_headers) }
  end

  def measure(name)
    error = nil
    value = nil
    bytes = BodyServer.allocated_bytes do
      value = lane_call(name)
    rescue StandardError => e
      error = e
    end
    [bytes, value, error]
  end

  # ── F1 헤더 줄 · F2 청크 확장 · F3a 트레일러 다수 · F3b 트레일러 한 줄 ──────────────────────────
  ResponseFramingCapSpec::LANES.each do |lane|
    context "with the #{lane} lane" do
      ResponseFramingCapSpec::SHAPES.each do |shape_name, (build, message)|
        it "refuses #{shape_name} with a bounded TransportError", :aggregate_failures do
          arm(lane, build.call(spec, spec.body_for(lane)))
          bytes, _, error = measure(lane)
          expect(error).to be_a(KeycloakSdk::TransportError)
          expect(error.message).to eq(message)            # 상수 메시지 — 바이트를 싣지 않는다
          expect(bytes).to be < 8 * 1_048_576             # 상한 없이 읽던 때는 32–67 MB
          expect(server.written).to be < 2 * 1_048_576    # 16 MiB 전부를 넘기지 못했다
        end
      end

      it "accepts a normal Keycloak-like response (<= 9 short headers)" do
        arm_ok(lane, extra_headers: (1..6).map { |i| "X-H#{i}: v#{i}\r\n" }.join)
        _, value, error = measure(lane)
        expect(error).to be_nil
        expect(value).not_to be_nil
      end
    end
  end

  # ── 경계 대조군 — 상한 **바로 아래**는 받아들인다 ──────────────────────────────────────────────
  context "with boundary-value responses on the cc lane" do
    it "accepts a header line of exactly MAX_LINE bytes" do
      body = spec.token_body
      name = "X-Pad: "
      val = "a" * (ResponseFramingCapSpec::MAX_LINE - name.bytesize - 2) # 줄 전체(CRLF 포함) = MAX_LINE
      head = "HTTP/1.1 200 X\r\n#{ResponseFramingCapSpec::JSON_HEADERS}#{name}#{val}\r\n" \
             "Content-Length: #{body.bytesize}\r\n\r\n"
      server.route(spec::TOKEN) { [head, body] }
      expect(kc.auth.client_credentials_token.access_token).to eq("AT")
    end

    it "accepts a header block just under MAX_FRAMING_BYTES total" do
      body = spec.token_body
      # 7 KiB 줄 여덟 = ~57 KiB < 65,536(각 줄 ≤ MAX_LINE).
      big = (1..8).map { |i| "X-H#{i}: #{'a' * 7000}\r\n" }.join
      head = "HTTP/1.1 200 X\r\n#{ResponseFramingCapSpec::JSON_HEADERS}#{big}Content-Length: #{body.bytesize}\r\n\r\n"
      server.route(spec::TOKEN) { [head, body] }
      expect(kc.auth.client_credentials_token.access_token).to eq("AT")
    end

    it "accepts a chunked body with a few small trailer lines" do
      body = spec.token_body
      server.route(spec::TOKEN) { spec.f3a_many_trailers(body, 4, line_bytes: 300) }
      expect(kc.auth.client_credentials_token.access_token).to eq("AT")
    end

    # ⚠️ 틀 예산은 **청크 크기 줄도** 센다(본문 중에 읽히는 것 포함) — 그래서 큰 본문을 **아주 잘게**(줄당 수십 바이트)
    # 쪼개 보내면 거부된다. 하지만 Keycloak·주류 리버스 프록시는 KiB 단위로 청크한다(nginx proxy_buffer 4–8 KiB) —
    # 현실적인 다청크 응답은 청크 크기 줄의 틀이 작아 통과한다. 여기서 증명한다: ~256 KiB 토큰을 8 KiB 청크 32 개로.
    it "accepts a realistically chunked multi-chunk body (many KiB-sized chunks, small framing)" do
      token = %({"access_token":"#{'A' * 256_000}","token_type":"Bearer","expires_in":1})
      pieces = ["HTTP/1.1 200 X\r\n#{ResponseFramingCapSpec::JSON_HEADERS}Transfer-Encoding: chunked\r\n\r\n"]
      off = 0
      while off < token.bytesize
        slice = token.byteslice(off, 8_192)
        pieces << "#{slice.bytesize.to_s(16)}\r\n#{slice}\r\n"
        off += 8_192
      end
      pieces << "0\r\n\r\n"
      server.route(spec::TOKEN) { pieces }
      expect(kc.auth.client_credentials_token.access_token.bytesize).to eq(256_000)
    end
  end
end
