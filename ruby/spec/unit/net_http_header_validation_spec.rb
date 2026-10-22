# frozen_string_literal: true

require "spec_helper"
require_relative "../support/framing_server"

# net-http 0.10 은 **응답** 헤더 이름도 검증한다(`Net::HTTPHeader#set_field` — 제어 문자·콜론, 1,024 바이트 초과) — 걸리면
# 이름 앞 30 바이트를 인용한 `ArgumentError` 다. Faraday 어댑터가 바꾸는 목록 밖이라 SDK 경계가 감싸지 않으면 그대로
# 샌다(introspect·logout·admin — 게시본 1.3.0 + net-http 0.10.0 실측). 실소켓으로 그 경로를 밟는다. 0.9.x 는 그 검증이
# 없어 같은 응답을 받아들인다 — 어느 판이든 공개 호출은 성공하거나 SDK 오류여야 하고, 오류는 헤더 이름을 인용하지 않는다.
# 경계 자체는 판과 무관하게 `hostile_token_response_spec` 의 n1·n2 가 고정한다(webmock 으로 같은 예외를 던진다).
module NetHttpHeaderValidationSpec
  REALM = "nhv"
  OIDC = "/realms/#{REALM}/protocol/openid-connect".freeze
  TOKEN = "#{OIDC}/token".freeze
  USERS = "/admin/realms/#{REALM}/users".freeze
  CERTS = "#{OIDC}/certs".freeze
  TOKEN_BODY = %({"access_token":"AT","token_type":"Bearer","expires_in":60,"refresh_token":"rt"})
  # 서명 검증까지 가지 않는다 — 헤더의 kid 로 JWKS 를 부르는 데까지만 쓰인다.
  JWT = [%({"alg":"RS256","kid":"k1"}), %({"sub":"s"})]
        .map { |p| Base64.urlsafe_encode64(p, padding: false) }
        .push("sig").join(".")
  ID_TOKEN_BODY = %({"access_token":"AT","token_type":"Bearer","expires_in":60,"id_token":"#{JWT}"}).freeze
  # 공격 경로의 정상 본문(헤더 한 줄만 공격) — 나머지 경로는 TOKEN_BODY.
  BODIES = { USERS => "[]", CERTS => %({"keys":[{"kty":"RSA","kid":"k1"}]}) }.freeze
  CANARY = "hvN9k"
  SHAPES = {
    "a control character in a header name" => "X\x01#{CANARY}: v\r\n",
    "a header name over 1,024 bytes" => "#{CANARY}#{'K' * 2_000}: v\r\n"
  }.freeze
  # 레인 => [공격을 싣는 경로, 호출, net-http 0.10 에서 기대하는 SDK 오류]. admin REST 는 토큰을 정상으로 준 뒤 /users 가 싣는다.
  LANES = {
    "client_credentials_token" => [TOKEN, ->(kc) { kc.auth.client_credentials_token }, KeycloakSdk::AuthError],
    "introspect" => ["#{OIDC}/token/introspect", ->(kc) { kc.auth.introspect("T") }, KeycloakSdk::TransportError],
    "logout" => ["#{OIDC}/logout", ->(kc) { kc.auth.logout(refresh_token: "rt") }, KeycloakSdk::TransportError],
    "admin token" => [TOKEN, ->(kc) { kc.admin.users.list }, KeycloakSdk::TransportError],
    "admin REST" => [USERS, ->(kc) { kc.admin.users.list }, KeycloakSdk::TransportError],
    # JWKS — 둘 다 키를 받으러 certs 를 부른다(exchange_code 는 nonce 를 대조하기 전에 id_token 을 검증한다).
    "validate" => [CERTS, ->(kc) { kc.auth.validate(JWT) }, KeycloakSdk::TransportError],
    "exchange_code(expected_nonce:)" => [CERTS, lambda { |kc|
      kc.auth.exchange_code(code: "c", code_verifier: "v", redirect_uri: "https://a/cb", expected_nonce: "n")
    }, KeycloakSdk::TransportError]
  }.freeze

  module_function

  # 이 net-http 가 응답 헤더 이름을 검증하는가 — 상수(`MAX_KEY_LENGTH`)는 0.9.1 에도 있어(요청 헤더용) 동작으로 가른다.
  def validates?
    Net::HTTPResponse.new("1.1", "200", "OK").add_field("X\x01", "v")
    false
  rescue ArgumentError
    true
  end

  def response(body, extra = "")
    ["HTTP/1.1 200 X\r\nContent-Type: application/json\r\n#{extra}Content-Length: #{body.bytesize}\r\n\r\n", body]
  end
end

RSpec.describe KeycloakSdk::KeycloakClient do
  around do |example|
    WebMock.disable!
    example.run
  ensure
    WebMock.enable!
  end

  let(:spec) { NetHttpHeaderValidationSpec }
  let(:server) { FramingServer.new }

  after { server.close }

  def outcome(call)
    kc = described_class.new(KeycloakSdk::Config.new(server_url: server.url, realm: spec::REALM, client_id: "c",
                                                     client_secret: "s"))
    call.call(kc)
    nil
  rescue StandardError => e
    e
  end

  NetHttpHeaderValidationSpec::LANES.each do |lane, (path, call, error_class)|
    NetHttpHeaderValidationSpec::SHAPES.each do |shape, header|
      it "#{lane}: a response with #{shape} never escapes as a lower-library exception", :aggregate_failures do
        if [spec::USERS, spec::CERTS].include?(path)
          server.route(spec::TOKEN) { spec.response(path == spec::CERTS ? spec::ID_TOKEN_BODY : spec::TOKEN_BODY) }
        end
        server.route(path) { spec.response(spec::BODIES.fetch(path, spec::TOKEN_BODY), header) }
        error = outcome(call)
        if spec.validates? # net-http 0.10+ — 검증이 그 응답을 거부한다
          expect(error).to be_a(error_class)
          expect(error.full_message(highlight: false)).not_to include(spec::CANARY)
        else # 0.9.x — 같은 응답이 받아들여진다(admin token 레인은 /users 를 안 걸어 404 다)
          expect(error).to be_nil.or be_a(KeycloakSdk::Error)
        end
      end
    end
  end
end
