# frozen_string_literal: true

require "spec_helper"
require "jwt"
require "openssl"

# README 가 링크하는 examples/quickstart.rb 를 **가짜 서버에 대고 실제로 돌린다**. rubocop 은 문법 · 린트만 보고, Ruby 는
# 동적이라 이름이 바뀐 메서드를 부르는 예제도 정적으로는 통과한다(등록부 readme-quickstarts-ungated). 실서버 없이 예제의
# 경로 전부 — 토큰 · 자체 강화 검증 · introspect · admin 생성 · 삭제 · close — 를 탄다.
RSpec.describe KeycloakSdk::KeycloakClient, ".new driven by examples/quickstart.rb" do
  let(:origin) { "http://localhost:8080" }
  let(:realm_url) { "#{origin}/realms/it-realm" }
  let(:key) { OpenSSL::PKey::RSA.generate(2048) }
  let(:json) { { "Content-Type" => "application/json" } }
  let(:example) { File.expand_path("../../examples/quickstart.rb", __dir__) }

  # 예제는 KC_* 가 없으면 기본값을 쓴다 — 실행 환경의 값이 새어 들어오지 않게 비우고 되돌린다.
  around do |ex|
    saved = ENV.to_h.slice("KC_URL", "KC_REALM", "KC_CLIENT_ID", "KC_CLIENT_SECRET")
    saved.each_key { |k| ENV.delete(k) }
    ex.run
  ensure
    saved&.each { |k, v| ENV[k] = v }
  end

  before do
    now = Time.now.to_i
    # Keycloak 의 접근 토큰 모양 — typ "Bearer"(접근 토큰 검증은 Bearer · DPoP 만 받는다).
    claims = { "sub" => "svc", "iss" => realm_url, "aud" => "it-client", "typ" => "Bearer", "exp" => now + 300,
               "iat" => now }
    token = JWT.encode(claims, key, "RS256", { kid: "k1" })
    stub_request(:get, "#{realm_url}/protocol/openid-connect/certs")
      .to_return(status: 200, headers: json, body: { keys: [JWT::JWK.new(key, kid: "k1").export] }.to_json)
    stub_request(:post, "#{realm_url}/protocol/openid-connect/token")
      .to_return(status: 200, headers: json,
                 body: { access_token: token, token_type: "Bearer", expires_in: 300 }.to_json)
    stub_request(:post, "#{realm_url}/protocol/openid-connect/token/introspect")
      .to_return(status: 200, headers: json, body: { active: true }.to_json)
    stub_request(:post, "#{origin}/admin/realms/it-realm/users")
      .to_return(status: 201, headers: { "Location" => "#{origin}/admin/realms/it-realm/users/u-1" })
    stub_request(:delete, "#{origin}/admin/realms/it-realm/users/u-1").to_return(status: 204)
  end

  it "runs end to end against canned Keycloak responses" do
    expect { load example }
      .to output(/expires_in=300.*validated: sub=svc.*introspection active=true.*created user u-1.*deleted user/m)
      .to_stdout
  end
end
