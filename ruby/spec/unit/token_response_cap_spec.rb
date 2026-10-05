# frozen_string_literal: true

require "spec_helper"
require_relative "../support/body_server"

# 토큰·introspection·logout 응답 본문의 상한(wave 4 · token-response-size-unbounded).
#
# 다섯 레인이 본문을 통째로 읽었다 — 쓸 수 있는 토큰 뒤에 JSON 공백 32 MiB 를 붙인 응답을 전부 받아들였고
# 프로세스 피크가 +86 MB 였다(2026-10-05 실측, 가짜 IdP · 레인마다 새 프로세스). 상한은 1 MiB 이고 Keycloak 26.6
# 이 기본 설정으로 받는 가장 긴 Bearer(65,459 바이트)의 16 배다 — 서버가 받는 토큰은 거부하지 않는다.
# logout 은 본문을 쓰지 않지만 읽었다 — 16 MiB 본문을 받아들였고 할당이 ~50 MB 였다(아래 logout 예제).
module TokenResponseCapSpec
  # ⚠️ 시험의 신탁(oracle)이다 — SDK 상수와 같은지는 한 예제가 따로 본다. 여기서 SDK 상수를 쓰면 상수가
  # 없을 때(수정 전) 모든 예제가 NameError 로 죽어 「본문을 받아들였다」는 진짜 결함이 가려진다.
  CAP = 1_048_576
  CONTROL_BEARER = 65_459 # Keycloak 26.6 기본 설정의 가장 긴 Bearer(2026-10-03 실측)
  REALM = "cap"
  OIDC = "/realms/#{REALM}/protocol/openid-connect".freeze
  TOKEN = "#{OIDC}/token".freeze
  INTROSPECT = "#{OIDC}/token/introspect".freeze
  JWKS = "#{OIDC}/certs".freeze
  USERS = "/admin/realms/#{REALM}/users".freeze
  LOGOUT = "#{OIDC}/logout".freeze
  LOGOUT_REFUSED = "logout response exceeds #{CAP} bytes".freeze
  JSON_TYPE = { "Content-Type" => "application/json" }.freeze

  # 레인 — 부르는 법과, 성공했을 때 돌려받은 「값의 길이」(토큰·클레임·admin 이 보낸 Bearer).
  LANES = {
    "auth.client_credentials_token" => {
      path: TOKEN, call: ->(kc, _) { kc.auth.client_credentials_token.access_token.bytesize }
    },
    "auth.refresh" => { path: TOKEN, call: ->(kc, _) { kc.auth.refresh(refresh_token: "rt").access_token.bytesize } },
    "auth.exchange_code" => {
      path: TOKEN,
      call: lambda { |kc, _|
        kc.auth.exchange_code(code: "c", code_verifier: "v", redirect_uri: "https://app/cb").access_token.bytesize
      }
    },
    "admin token (users.list)" => { path: TOKEN, admin: true, call: ->(kc, _) { kc.admin.users.list.first } },
    "auth.introspect" => { path: INTROSPECT, introspection: true,
                           call: ->(kc, len) { kc.auth.introspect("T" * len).claims["big"].bytesize } }
  }.freeze

  module_function

  def client(server)
    KeycloakSdk::KeycloakClient.new(KeycloakSdk::Config.new(server_url: server, realm: REALM, client_id: "c",
                                                            client_secret: "s"))
  end

  # 쓸 수 있는 응답 — 값(토큰 또는 클레임) 길이 `len`.
  def head(lane, len)
    if LANES.fetch(lane)[:introspection]
      { active: true, sub: "s", username: "u", client_id: "c", big: "B" * len }.to_json
    else
      { access_token: "A" * len, token_type: "Bearer", expires_in: 300, refresh_token: "rt", scope: "openid" }.to_json
    end
  end

  # 쓸 수 있는 응답을 JSON 공백으로 정확히 `total` 바이트까지 부풀린다.
  def padded(lane, total, len: 64)
    text = head(lane, len)
    text + (" " * (total - text.bytesize))
  end

  def message(lane)
    "#{LANES.fetch(lane)[:introspection] ? 'introspection' : 'token'} response exceeds #{CAP} bytes"
  end

  # logout 응답 — 2xx 는 빈 객체, 그 밖은 Keycloak 의 오류 본문 모양. logout 은 본문을 쓰지 않는다(상태만 본다).
  def logout_head(status) = status < 300 ? "{}" : { error: "invalid_grant" }.to_json

  # logout 의 결과 — 성공이면 [:ok, 돌려준 값], SDK 오류면 [클래스, 메시지].
  def logout_outcome(client)
    [:ok, client.auth.logout(refresh_token: "rt")]
  rescue KeycloakSdk::Error => e
    [e.class, e.message]
  end
end

RSpec.describe KeycloakSdk::Http do
  let(:spec) { TokenResponseCapSpec }

  it "declares the token-response cap once, as 1 MiB (the cross-language value)" do
    expect(described_class::TOKEN_RESPONSE_MAX_BYTES).to eq(TokenResponseCapSpec::CAP)
  end

  # ── WebMock: 경계값 · 상태 무관 · admin REST 는 상한 밖 · Accept-Encoding ─────────────────────────────
  context "with a stubbed IdP" do
    let(:server) { "https://kc.cap.test" }
    let(:kc) { spec.client(server) }

    # admin 레인의 「값」은 admin 엔드포인트가 받은 Bearer 의 길이다 — 그 토큰을 실제로 썼다는 증거.
    def stub_admin
      stub_request(:get, "#{server}#{TokenResponseCapSpec::USERS}").to_return do |req|
        { status: 200, headers: TokenResponseCapSpec::JSON_TYPE,
          body: [req.headers["Authorization"].bytesize - "Bearer ".bytesize].to_json }
      end
    end

    def stub_lane(lane, body, status: 200)
      stub_request(:post, "#{server}#{TokenResponseCapSpec::LANES.fetch(lane)[:path]}")
        .to_return(status: status, headers: TokenResponseCapSpec::JSON_TYPE, body: body)
    end

    TokenResponseCapSpec::LANES.each do |lane, cfg|
      context "with #{lane}" do
        let(:admin_stub) { stub_admin }

        before { admin_stub }

        it "accepts Keycloak 26.6's largest default bearer (65,459 bytes)" do
          len = TokenResponseCapSpec::CONTROL_BEARER
          stub_lane(lane, spec.head(lane, len))
          expect(cfg[:call].call(kc, len)).to eq(len)
        end

        it "accepts a usable response padded to exactly the cap (1,048,576 bytes)" do
          stub_lane(lane, spec.padded(lane, TokenResponseCapSpec::CAP))
          expect(cfg[:call].call(kc, 64)).to eq(64)
        end

        it "refuses a usable response padded to one byte past the cap, with the SDK's TransportError" do
          stub_lane(lane, spec.padded(lane, TokenResponseCapSpec::CAP + 1))
          expect { cfg[:call].call(kc, 64) }
            .to raise_error(KeycloakSdk::TransportError, spec.message(lane))
          expect(admin_stub).not_to have_been_requested # admin: 토큰이 없으니 admin 요청도 없다
        end

        # ⚠️ 200 만 겨누면 오류 응답의 거대 본문이 그대로 들어온다(JWKS 상한이 같은 축을 이미 지킨다).
        it "caps an error response's body too" do
          stub_lane(lane, { error: "invalid_grant" }.to_json + (" " * TokenResponseCapSpec::CAP), status: 400)
          expect { cfg[:call].call(kc, 64) }.to raise_error(KeycloakSdk::TransportError, spec.message(lane))
        end

        # ⚠️ net-http 는 Accept-Encoding 이 없으면 gzip 을 청하고 풀어 준다 — 그 inflater 는 상한에서 끊겨도 지금
        # 읽은 압축 조각을 끝까지 푼다(16 KiB 조각 하나가 ~16 MiB, 실측). SDK 가 직접 읽는 요청은 identity 를 청한다.
        it "asks for an unencoded body (Accept-Encoding: identity)" do
          stub = stub_request(:post, "#{server}#{cfg[:path]}")
                 .with(headers: { "Accept-Encoding" => "identity" })
                 .to_return(status: 200, headers: TokenResponseCapSpec::JSON_TYPE, body: spec.head(lane, 64))
          cfg[:call].call(kc, 64)
          expect(stub).to have_been_requested.once
        end
      end
    end

    it "asks the JWKS endpoint for an unencoded body too" do
      stub = stub_request(:get, "#{server}#{TokenResponseCapSpec::JWKS}")
             .with(headers: { "Accept-Encoding" => "identity" })
             .to_return(status: 200, headers: TokenResponseCapSpec::JSON_TYPE, body: { keys: [{ kid: "k" }] }.to_json)
      KeycloakSdk::JwksStore.new(jwks_url: "#{server}#{TokenResponseCapSpec::JWKS}", http: Faraday.new).key_set
      expect(stub).to have_been_requested.once
    end

    # ⚠️ 대조군 — admin REST 응답(사용자 목록 등)은 정당하게 크다. 상한은 토큰·introspection 응답에만 건다.
    it "does not cap admin REST responses" do
      stub_lane("admin token (users.list)", spec.head("admin token (users.list)", 64))
      big = Array.new(60_000) { |i| { id: "user-#{i}", username: "user-#{i}" } }.to_json
      stub_request(:get, "#{server}#{TokenResponseCapSpec::USERS}")
        .to_return(status: 200, headers: TokenResponseCapSpec::JSON_TYPE, body: big)
      expect(big.bytesize).to be > 2 * TokenResponseCapSpec::CAP
      expect(kc.admin.users.list.size).to eq(60_000)
    end
  end

  # ── 진짜 소켓: 할당이 상한에 묶이는가 · net-http 의 16 KiB 청크로도 경계가 정확한가 · gzip ─────────────
  context "with a real socket (WebMock disabled — it buffers whole bodies)" do
    around do |example|
      WebMock.disable!
      example.run
    ensure
      WebMock.enable!
    end

    let(:body_server) { BodyServer.new }
    let(:kc) { spec.client(body_server.url) }

    after { body_server.close }

    # admin 엔드포인트는 받은 Bearer 의 길이를 돌려준다(WebMock 쪽과 같은 「값」).
    def serve(lane, pad:, len: 64)
      body_server.route(TokenResponseCapSpec::LANES.fetch(lane)[:path]) { [200, {}, spec.head(lane, len), pad] }
      body_server.route(TokenResponseCapSpec::USERS) do |r|
        [200, {}, [r.headers["authorization"].bytesize - "Bearer ".bytesize].to_json, 0]
      end
    end

    # 재기 전에 같은 레인을 작은 본문으로 한 번 돌린다(다른 클라이언트로 — admin 토큰 캐시가 재는 호출을 비우지
    # 않게). ⚠️ 프로세스의 첫 실제 요청은 한 번뿐인 비용을 문다 — net-http 의 연결 시간 제한이 쓰는 Timeout 의
    # 백그라운드 스레드 등. 실측: 2 KiB 본문의 첫 요청 1.07 MB, 데운 뒤 0.01 MB. 그대로 재면 예제 하나만 돌릴 때 진다.
    # 돌려주는 값은 그때까지 서버가 받은 요청 수다(그 뒤의 요청만 보려고).
    def warm_up(lane)
      serve(lane, pad: 0)
      TokenResponseCapSpec::LANES.fetch(lane)[:call].call(spec.client(body_server.url), 64)
      body_server.requests.size
    end

    def measure(lane, client)
      error = nil
      value = nil
      bytes = BodyServer.allocated_bytes do
        value = TokenResponseCapSpec::LANES.fetch(lane)[:call].call(client, 64)
      rescue StandardError => e
        error = e
      end
      [bytes, value, error]
    end

    TokenResponseCapSpec::LANES.each_key do |lane|
      context "with #{lane}" do
        it "refuses a 16 MiB body while allocating a bounded amount", :aggregate_failures do
          seen = warm_up(lane)
          serve(lane, pad: 16 * 1_048_576)
          bytes, _, error = measure(lane, kc)
          expect(error).to be_a(KeycloakSdk::TransportError)
          expect(error&.message).to eq(spec.message(lane))
          expect(bytes).to be < 8 * TokenResponseCapSpec::CAP # 상한 없이 읽던 때는 ~50 MiB 를 넘는다
          expect(body_server.requests.drop(seen).map(&:path)).not_to include(TokenResponseCapSpec::USERS)
        end

        # 버퍼를 상한만큼 미리 잡으면(`String.new(capacity: …)`) 작은 응답도 1 MiB 를 문다 — 읽은 만큼만 자라야 한다.
        it "allocates in proportion to a ~2 KiB body, nowhere near the cap", :aggregate_failures do
          warm_up(lane)
          serve(lane, pad: 2_000)
          bytes, value, error = measure(lane, kc)
          expect([value, error]).to eq([64, nil])
          expect(bytes).to be < TokenResponseCapSpec::CAP / 4
        end
      end
    end

    # net-http 는 16 KiB 씩 넘긴다 — 누적 판정이 청크 경계와 무관하게 정확한가(WebMock 은 본문을 한 청크로 준다).
    { "chunked" => :chunked, "Content-Length" => :length }.each do |name, framing|
      it "draws the line exactly at the cap across 16 KiB reads (#{name})" do
        server = BodyServer.new(framing: framing)
        lane = "auth.client_credentials_token"
        client = spec.client(server.url)
        exact = TokenResponseCapSpec::CAP - spec.head(lane, 64).bytesize
        server.route(TokenResponseCapSpec::TOKEN) { [200, {}, spec.head(lane, 64), exact] }
        expect(client.auth.client_credentials_token.access_token.bytesize).to eq(64)
        server.route(TokenResponseCapSpec::TOKEN) { [200, {}, spec.head(lane, 64), exact + 1] }
        expect { client.auth.client_credentials_token }.to raise_error(KeycloakSdk::TransportError, spec.message(lane))
      ensure
        server&.close
      end

      # ── logout — 본문을 쓰지 않지만 읽는다. 같은 상한이다: 정확히 상한이면 지금과 같고(2xx 는 nil · 그 밖은 기존
      # AuthError), 한 바이트라도 넘으면 상태와 무관하게 TransportError. 16 KiB 읽기의 두 틀 모두에서 본다.
      context "with auth.logout over #{name}" do
        let(:body_server) { BodyServer.new(framing: framing) }

        def serve_logout(status, pad)
          body_server.route(TokenResponseCapSpec::LOGOUT) { [status, {}, spec.logout_head(status), pad] }
        end

        def measure_logout(client)
          error = nil
          bytes = BodyServer.allocated_bytes do
            client.auth.logout(refresh_token: "rt")
          rescue StandardError => e
            error = e
          end
          [bytes, error]
        end

        it "draws the line exactly at the cap, at any status" do
          seen = [200, 302, 400, 500].to_h do |status|
            exact = TokenResponseCapSpec::CAP - spec.logout_head(status).bytesize
            outcomes = [exact, exact + 1].map do |pad|
              serve_logout(status, pad)
              spec.logout_outcome(kc)
            end
            [status, outcomes]
          end
          refused = [KeycloakSdk::TransportError, TokenResponseCapSpec::LOGOUT_REFUSED]
          expect(seen).to eq(200 => [[:ok, nil], refused],
                             302 => [[KeycloakSdk::AuthError, "logout failed: HTTP 302"], refused],
                             400 => [[KeycloakSdk::AuthError, "logout failed: HTTP 400"], refused],
                             500 => [[KeycloakSdk::AuthError, "logout failed: HTTP 500"], refused])
        end

        it "refuses a 16 MiB body while allocating a bounded amount", :aggregate_failures do
          serve_logout(200, 0)
          spec.logout_outcome(spec.client(body_server.url)) # 데운다 — `warm_up` 과 같은 이유
          serve_logout(200, 16 * 1_048_576)
          bytes, error = measure_logout(kc)
          expect(error).to be_a(KeycloakSdk::TransportError)
          expect(error&.message).to eq(TokenResponseCapSpec::LOGOUT_REFUSED)
          expect(bytes).to be < 8 * TokenResponseCapSpec::CAP # 상한 없이 읽던 때는 ~50 MB(실측 50,429,852–50,784,359)
        end
      end
    end

    # 상한은 읽기만 바꾼다 — 보내는 것은 그대로다(같은 커넥션 · 같은 폼, 클라이언트 인증은 폼 안이고 Basic 은 없다).
    # 바뀐 헤더는 Accept-Encoding 하나다: net-http 기본값(gzip;q=1.0,deflate;q=0.6,identity;q=0.3) → identity.
    context "with auth.logout's request" do
      let(:body_server) { BodyServer.new(framing: :length) }

      it "still succeeds on an empty 204 or 200" do
        outcomes = [204, 200].map do |status|
          body_server.route(TokenResponseCapSpec::LOGOUT) { [status, {}, "", 0] }
          spec.logout_outcome(kc)
        end
        expect(outcomes).to eq([[:ok, nil], [:ok, nil]])
      end

      it "sends the same form and client auth, asking for an unencoded body" do
        body_server.route(TokenResponseCapSpec::LOGOUT) { [204, {}, "", 0] }
        kc.auth.logout(refresh_token: "rt")
        req = body_server.requests.last
        expect([req.verb, req.path, req.body])
          .to eq(["POST", TokenResponseCapSpec::LOGOUT, "client_id=c&client_secret=s&refresh_token=rt"])
        expect(req.headers).to eq("user-agent" => "Faraday v#{Faraday::VERSION}",
                                  "content-type" => "application/x-www-form-urlencoded",
                                  "accept-encoding" => "identity", "accept" => "*/*",
                                  "host" => body_server.url.delete_prefix("http://"), "content-length" => "44")
      end

      it "does not follow a redirect" do
        body_server.route(TokenResponseCapSpec::LOGOUT) { [302, { "Location" => "/elsewhere" }, "", 0] }
        expect(spec.logout_outcome(kc)).to eq([KeycloakSdk::AuthError, "logout failed: HTTP 302"])
        expect(body_server.requests.map(&:path)).to eq([TokenResponseCapSpec::LOGOUT])
      end

      # 시간을 재지 않는다 — 서버는 1 초 뒤에 답하므로 ReadTimeout 이 났다면 Config 의 0.2 초가 걸린 것이다(기본 10 초).
      it "keeps the Config read timeout" do
        body_server.route(TokenResponseCapSpec::LOGOUT) do
          sleep 1
          [204, {}, "", 0]
        end
        slow = KeycloakSdk::KeycloakClient.new(
          KeycloakSdk::Config.new(server_url: body_server.url, realm: TokenResponseCapSpec::REALM, client_id: "c",
                                  client_secret: "s", read_timeout: 0.2)
        )
        expect { slow.auth.logout(refresh_token: "rt") }
          .to raise_error(KeycloakSdk::TransportError, /\Alogout transport error: Net::ReadTimeout/)
      end
    end

    # 서버가 gzip 을 허락받으면 압축하는 흔한 모양 — 32 MiB 공백이 선로에서 ~32 KB 다.
    context "when the server compresses whatever the client accepts" do
      let(:body_server) { BodyServer.new(compress: :when_allowed) }

      it "gets an unencoded token response and stays bounded", :aggregate_failures do
        lane = "auth.client_credentials_token"
        warm_up(lane)
        serve(lane, pad: 32 * 1_048_576)
        bytes, _, error = measure(lane, kc)
        expect(error).to be_a(KeycloakSdk::TransportError)
        expect(body_server.requests.last.headers["accept-encoding"]).to eq("identity")
        expect(bytes).to be < 8 * TokenResponseCapSpec::CAP
      end

      # 수정 전 JWKS 상한(51,200)은 지켜졌지만 inflater 가 +24 MB 를 잡았다(실측) — identity 로 사라진다.
      it "gets an unencoded JWKS response and stays bounded", :aggregate_failures do
        warm_up("auth.client_credentials_token")
        body_server.route(TokenResponseCapSpec::JWKS) { [200, {}, '{"keys":[]}', 32 * 1_048_576] }
        config = KeycloakSdk::Config.new(server_url: body_server.url, realm: "r", client_id: "c")
        store = KeycloakSdk::JwksStore.new(jwks_url: "#{body_server.url}#{TokenResponseCapSpec::JWKS}",
                                           http: described_class.build(config))
        error = nil
        bytes = BodyServer.allocated_bytes do
          store.key_set
        rescue StandardError => e
          error = e
        end
        expect(error&.message).to eq("JWKS response exceeds 51200 bytes")
        expect(body_server.requests.last.headers["accept-encoding"]).to eq("identity")
        expect(bytes).to be < 8 * TokenResponseCapSpec::CAP
      end
    end

    # identity 를 무시하고 gzip 을 보내는 서버 — net-http 는 풀지 않고(그 헤더를 SDK 가 보냈으므로) 본문은 JSON 이
    # 아니다. 받아들이지 않고 SDK 오류로 닫힌다(실패 쪽으로).
    context "when the server compresses even though identity was asked for" do
      let(:body_server) { BodyServer.new(compress: :always) }

      it "fails closed with the SDK's TransportError" do
        serve("auth.client_credentials_token", pad: 0)
        expect { kc.auth.client_credentials_token }.to raise_error(KeycloakSdk::TransportError)
      end
    end
  end
end
