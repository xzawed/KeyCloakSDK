# frozen_string_literal: true

require "spec_helper"
require "jwt"
require_relative "../support/framing_server"
require_relative "../support/paced_server"
require_relative "../support/trickle_relay"

# SDK 가 스스로 읽는 응답은 요청을 보낸 때부터 요청 타임아웃(읽기 타임아웃) 안에 다 읽힌다 — 등록부
# response-read-deadline-divergent(ruby). 읽기 타임아웃은 읽기 하나를 묶을 뿐이다. 공개 API(`KeycloakClient`, 읽기
# 타임아웃 1 초)와 루프백의 날 소켓 서버(`PacedServer`)로 레인 셋(auth 토큰 · JWKS · admin)을 잰다:
#   흘리기 — 머리와 본문 앞부분을 곧바로, 마지막 10 바이트를 0.7 초마다 하나씩(읽기 타임아웃은 한 번도 차지 않는다) →
#     마감 1 초 + 읽기 타임아웃 하나 1 초 + 여유 1 초 안에 읽기 타임아웃과 같은 오류(TransportError ← Net::ReadTimeout)다.
#     여유 1 초는 다른 빌드가 함께 도는 기계의 스레드 깨움 지연을 덮고, 그래도 수정 전(7 초 넘어 성공)과 4 초 넘게 떨어진다.
#   멈춤(대조) — 머리와 5 바이트 뒤 침묵 → 지금처럼 읽기 타임아웃(1 초 남짓)에 실패한다.
#   건강(대조) — 상한 바로 아래 본문을 0.15 초 간격 네 조각으로(마감 안) → 성공한다(거짓 마감 없음).
#   TLS — 본문 레코드의 바이트를 흘린다(`TrickleRelay`): OpenSSL 은 레코드가 다 올 때까지 읽을 것이 없어, 버퍼 채우기
#     하나(`rbuf_fill`) 안에서 기다림이 이어진다 — 마감은 그 안의 읽기 시도마다 봐야 선다.
# 수정 전(실측 2026-10-29, 이 파일을 수정 전 코드에 — Windows · Ruby 3.4.10 · net-http 0.10.0): 흘리기 셋 7,069–7,128 ms
# 뒤 성공 · TLS 22,929 ms 뒤 성공 · 멈춤 1,033–1,086 ms · 건강 500–543 ms. 수정 뒤: 흘리기 1,434–1,488 ms · TLS 1,105 ms.
module ResponseReadDeadlineSpec
  READ_TIMEOUT = 1
  GAP = 0.7 * READ_TIMEOUT # 읽기 타임아웃의 0.7 배 — 읽기 하나는 끝까지 차지 않는다
  TAIL = 10 # 흘리는 꼬리 바이트 — 수정 전에는 바이트마다 간격 하나(7 초 남짓)가 걸렸다
  BOUND = READ_TIMEOUT + READ_TIMEOUT + 1.0 # 마감 + 마감 직전에 시작한 읽기 하나 + 여유
  HOLD = 30 # 멈춘 서버가 붙드는 시간 — 시험이 끝나면 서버를 닫아 풀어 준다
  CAP = 1_048_576 # 토큰 응답 상한(아홉 언어 같은 값)
  JWKS_CAP = 51_200
  ACCESS_TOKEN = "AT-deadline"
  REALM = "r"
  OIDC = "/realms/#{REALM}/protocol/openid-connect".freeze
  PATHS = { "auth" => "#{OIDC}/token", "jwks" => "#{OIDC}/certs", "admin" => "/admin/realms/#{REALM}/users/x" }.freeze
  KEY = OpenSSL::PKey::RSA.generate(2048)

  # 레인 — 공개 API 로 부르는 법과 성공했을 때의 값.
  CALLS = {
    "auth" => ->(kc, _) { kc.auth.client_credentials_token.access_token },
    "jwks" => ->(kc, token) { kc.auth.validate(token).claims["sub"] },
    "admin" => ->(kc, _) { kc.admin.users.get("x") }
  }.freeze
  EXPECTED = { "auth" => ACCESS_TOKEN, "jwks" => "s", "admin" => { "id" => "x", "username" => "alice" } }.freeze

  module_function

  def head(length) = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{length}\r\n\r\n"

  def whole(body) = [[0, head(body.bytesize) + body]]

  def trickle(body)
    cut = body.bytesize - TAIL
    [[0, head(body.bytesize) + body.byteslice(0, cut)]] + body.byteslice(cut, TAIL).chars.map { |c| [GAP, c] }
  end

  def stall(body) = [[0, head(body.bytesize) + body.byteslice(0, 5)], [HOLD, ""]]

  def healthy(body)
    step = (body.bytesize + 3) / 4
    parts = (0...body.bytesize).step(step).map { |at| body.byteslice(at, step) }
    [[0, head(body.bytesize) + parts.first]] + parts.drop(1).map { |part| [0.15, part] }
  end

  # `doc` 의 JSON 뒤에 공백(JSON 이 허용하는 뒤 공백)을 붙여 정확히 `size` 바이트로.
  def padded(doc, size)
    text = doc.to_json
    text + (" " * (size - text.bytesize))
  end

  # 레인마다 쓸 수 있는 본문 — 건강 대조는 상한 바로 아래(토큰·admin 은 토큰 응답 상한, JWKS 는 JWKS 상한).
  def bodies(healthy)
    {
      "auth" => padded({ access_token: ACCESS_TOKEN, token_type: "Bearer", expires_in: 300 }, healthy ? CAP - 64 : 200),
      "jwks" => padded({ keys: [JWT::JWK.new(KEY, kid: "k1").export] }, healthy ? JWKS_CAP - 64 : 1000),
      "admin" => padded({ id: "x", username: "alice" }, healthy ? CAP - 64 : 100)
    }
  end

  # 재는 레인의 경로만 `shape` 로, 나머지(admin 의 자체 그랜트 등)는 곧바로 답한다.
  def serve(server, lane, shape, healthy: false)
    bodies(healthy).each do |name, body|
      server.route(PATHS.fetch(name), name == lane ? public_send(shape, body) : whole(body))
    end
  end

  def config(url)
    KeycloakSdk::Config.new(server_url: url, realm: REALM, client_id: "c", client_secret: "s3cret",
                            read_timeout: READ_TIMEOUT)
  end

  def signed(url)
    claims = { iss: "#{url}/realms/#{REALM}", aud: "c", sub: "s", exp: Time.now.to_i + 600 }
    JWT.encode(claims, KEY, "RS256", { kid: "k1" })
  end

  def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  # [결과 또는 SDK 오류, 걸린 초] — 공개 API 로 레인 하나를 부른다. admin 생성(네트워크 없음)은 재지 않는다.
  def call(server, lane)
    kc = KeycloakSdk::KeycloakClient.new(config(server.url))
    kc.admin
    token = signed(server.url)
    started = monotonic
    result = begin
      CALLS.fetch(lane).call(kc, token)
    rescue KeycloakSdk::Error => e
      e
    end
    [result, monotonic - started]
  ensure
    kc&.close
  end

  # TLS 서버와 그 앞의 중계 — 본문 레코드(머리 뒤)부터 바이트를 흘린다. [서버, 중계].
  def tls_trickle
    tls = FramingServer.new(tls: FramingServer.tls_context)
    relay = TrickleRelay.new(tls.port, gap: GAP)
    body = { keys: [] }.to_json
    tls.route("/certs") do
      Enumerator.new do |y|
        y << head(body.bytesize)
        sleep 0.3 # 머리 레코드가 중계를 다 지난 뒤부터 흘린다
        relay.trickle!
        y << body
      end
    end
    [tls, relay]
  end

  # SDK 의 읽기 경로(`Http.read_capped` — 토큰·JWKS 가 쓰는 그것)로 TLS 응답을 읽는다 — [결과 또는 Faraday 오류,
  # 걸린 초]. 인증서 검증은 여기서 재는 것이 아니라 끈다.
  def read_over_tls(port)
    url = "https://127.0.0.1:#{port}"
    conn = KeycloakSdk::Http.build(config(url))
    conn.ssl.verify = false
    started = monotonic
    got = begin
      KeycloakSdk::Http.read_capped(conn, :get, "#{url}/certs", max_bytes: JWKS_CAP, what: "JWKS")
    rescue Faraday::Error => e
      e
    end
    [got, monotonic - started]
  end

  # 측정 줄 — `KCSDK_MEASURE=1` 일 때만 리포터로 낸다(평소 실행은 조용하다).
  def note(line)
    RSpec.configuration.reporter.message(line) if ENV["KCSDK_MEASURE"]
  end
end

RSpec.describe KeycloakSdk::Http do # response read deadline
  let(:spec) { ResponseReadDeadlineSpec }
  let(:server) { PacedServer.new }

  around do |example|
    WebMock.disable!
    example.run
  ensure
    WebMock.enable!
  end

  after { server.close }

  ResponseReadDeadlineSpec::PATHS.each_key do |lane|
    it "fails a trickled #{lane} response at the deadline with the read-timeout error" do
      spec.serve(server, lane, :trickle)
      got, took = spec.call(server, lane)
      spec.note("  [ReadDeadline] #{lane} trickle -> #{got.class} | #{(took * 1000).round} ms")
      expect(got).to be_a(KeycloakSdk::TransportError)
      expect(got.message).to include("Net::ReadTimeout")
      expect(got.message).not_to include(ResponseReadDeadlineSpec::ACCESS_TOKEN, "alice")
      expect(took).to be < ResponseReadDeadlineSpec::BOUND
    end

    it "still fails a stalled #{lane} response at the read timeout (control)" do
      spec.serve(server, lane, :stall)
      got, took = spec.call(server, lane)
      spec.note("  [ReadDeadline] #{lane} stall -> #{got.class} | #{(took * 1000).round} ms")
      expect(got).to be_a(KeycloakSdk::TransportError)
      expect(got.message).to include("Net::ReadTimeout")
      timeout = ResponseReadDeadlineSpec::READ_TIMEOUT
      expect(took).to be_between(0.8 * timeout, timeout + 1)
    end

    it "reads a healthy #{lane} response just under the cap whole (control: no false deadline)" do
      spec.serve(server, lane, :healthy, healthy: true)
      got, took = spec.call(server, lane)
      spec.note("  [ReadDeadline] #{lane} healthy -> #{got.class} | #{(took * 1000).round} ms")
      expect(got).to eq(ResponseReadDeadlineSpec::EXPECTED.fetch(lane))
    end
  end

  # TLS — 본문 레코드의 바이트를 0.7 초마다 하나씩(`TrickleRelay`).
  it "fails a TLS response whose record bytes trickle, at the deadline" do
    tls, relay = spec.tls_trickle
    got, took = spec.read_over_tls(relay.port)
    spec.note("  [ReadDeadline] TLS record trickle -> #{got.class} | #{(took * 1000).round} ms")
    expect(got).to be_a(Faraday::TimeoutError)
    expect(got.message).to include("Net::ReadTimeout")
    expect(took).to be < ResponseReadDeadlineSpec::BOUND
  ensure
    relay&.close
    tls&.close
  end
end
