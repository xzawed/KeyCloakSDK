# frozen_string_literal: true

require "spec_helper"
require "jwt"
require "openssl"

# 호스트 앱이 건 `Rack::OAuth2.http_config` 곁에서 SDK 의 요청 레인이 그대로 도는가.
#
# rack-oauth2 의 HTTP 설정은 프로세스 전역이고 먼저 건 쪽이 이긴다(`@@http_config ||= block` — 2.3.0 oauth2.rb:55-57).
# rack-oauth2 가 요청에 쓰는 연결은 `Rack::OAuth2.http_client` 하나이고(`Client#access_token!`·`#revoke!`·
# `AccessToken#get` 등), 그것을 만들 때마다 그 블록을 부른다(oauth2.rb:50). 여기서 호스트 블록은 불릴 때마다
# 기록하고 요청마다 터지는 어댑터(스텁 없는 Faraday 테스트 어댑터)를 꽂는다 — SDK 요청이 하나라도 그 연결을 탔다면
# 기록이 남고 그 요청은 터진다. 아래 대조군 둘이 그 탐침이 살아 있음을 보인다.
module HostHttpConfigSpec
  SERVER = "https://kc.example.com"
  OIDC = "#{SERVER}/realms/demo/protocol/openid-connect".freeze
  JSON_TYPE = { "Content-Type" => "application/json" }.freeze
  REALM_KEY = OpenSSL::PKey::RSA.generate(2048)

  # 레인 — 부르는 법(클라이언트, realm 키로 서명한 토큰)과 기대값. 요청을 보내는 공개 진입점 전부에 네트워크 없는
  # 인가 URL 과 OAuth 오류(`Rack::OAuth2::Client::Error` 를 만드는 자리) 하나를 더했다.
  LANES = {
    "auth.create_authorization_request" =>
      [->(kc, _) { kc.auth.create_authorization_request(redirect_uri: "https://app/cb").url.split("?").first },
       "#{OIDC}/auth"],
    "auth.client_credentials_token" => [->(kc, _) { kc.auth.client_credentials_token.access_token }, "AT"],
    "auth.access_token" => [->(kc, _) { kc.auth.access_token }, "AT"],
    "auth.refresh" => [->(kc, _) { kc.auth.refresh(refresh_token: "RT").access_token }, "AT"],
    "auth.refresh refused with 400 invalid_grant" =>
      [->(kc, _) { outcome { kc.auth.refresh(refresh_token: "revoked") } },
       [KeycloakSdk::AuthError, "refresh failed: invalid_grant (HTTP 400)"]],
    "auth.exchange_code with expected_nonce (id_token verified via JWKS)" =>
      [lambda { |kc, _|
        kc.auth.exchange_code(code: "c", code_verifier: "v", redirect_uri: "https://app/cb",
                              expected_nonce: "n-abc").access_token
      }, "AT"],
    "auth.introspect" => [->(kc, _) { kc.auth.introspect("AT").active? }, true],
    "auth.logout" => [->(kc, _) { kc.auth.logout(refresh_token: "RT") }, nil],
    "auth.validate (JWKS)" => [->(kc, token) { kc.auth.validate(token).claims["sub"] }, "user-1"],
    "admin.users.list (token provider + admin REST)" => [->(kc, _) { kc.admin.users.list }, [{ "id" => "u1" }]]
  }.freeze

  module_function

  def id_token
    now = Time.now.to_i
    JWT.encode({ "sub" => "user-1", "iss" => "#{SERVER}/realms/demo", "aud" => "app", "exp" => now + 300,
                 "iat" => now, "nonce" => "n-abc" }, REALM_KEY, "RS256", { kid: "realm-key" })
  end

  def outcome
    [:ok, yield]
  rescue KeycloakSdk::Error => e
    [e.class, e.message]
  end
end

RSpec.describe KeycloakSdk::KeycloakClient do
  let(:spec) { HostHttpConfigSpec }

  context "with a host's Rack::OAuth2.http_config that records each build and fails every request" do
    let(:host_runs) { [] }

    # 클라이언트를 만들기 **전에** 건다 — 그래야 SDK 가 등록하든 말든(먼저 이기는 쪽은 호스트) 전역은 이 블록이다.
    before do
      runs = host_runs
      Rack::OAuth2.reset_http_config!
      Rack::OAuth2.http_config do |faraday|
        runs << :built
        faraday.adapter :test, Faraday::Adapter::Test::Stubs.new
      end
      allow(Rack::OAuth2).to receive(:http_client).and_call_original
    end

    after { Rack::OAuth2.reset_http_config! }

    context "with every SDK request lane" do
      let(:client) do
        described_class.new(KeycloakSdk::Config.new(server_url: spec::SERVER, realm: "demo", client_id: "app",
                                                    client_secret: "sekret"))
      end

      before do
        json = spec::JSON_TYPE
        stub_request(:post, "#{spec::OIDC}/token")
          .to_return(status: 200, headers: json, body: { access_token: "AT", token_type: "Bearer", expires_in: 300,
                                                         refresh_token: "RT", id_token: spec.id_token }.to_json)
        stub_request(:post, "#{spec::OIDC}/token").with(body: hash_including("refresh_token" => "revoked"))
                                                  .to_return(status: 400, headers: json,
                                                             body: { error: "invalid_grant" }.to_json)
        stub_request(:post, "#{spec::OIDC}/token/introspect")
          .to_return(status: 200, headers: json, body: { active: true }.to_json)
        stub_request(:post, "#{spec::OIDC}/logout").to_return(status: 204)
        stub_request(:get, "#{spec::OIDC}/certs")
          .to_return(status: 200, headers: json,
                     body: { keys: [JWT::JWK.new(spec::REALM_KEY, kid: "realm-key").export] }.to_json)
        stub_request(:get, "#{spec::SERVER}/admin/realms/demo/users")
          .to_return(status: 200, headers: json, body: [{ id: "u1" }].to_json)
      end

      after { client.close }

      HostHttpConfigSpec::LANES.each do |lane, (call, want)|
        it "runs #{lane} without building rack-oauth2's connection", :aggregate_failures do
          expect(call.call(client, spec.id_token)).to eq(want)
          expect(host_runs).to be_empty
          expect(Rack::OAuth2).not_to have_received(:http_client)
        end
      end
    end

    # 대조군 — 탐침이 살아 있다: rack-oauth2 자신의 토큰 요청은 연결을 만들며 호스트 블록을 부르고, 꽂힌 어댑터에서 터진다.
    it "sees rack-oauth2's own token request go through the host block (control)", :aggregate_failures do
      rack = Rack::OAuth2::Client.new(identifier: "app", secret: "sekret", token_endpoint: "#{spec::OIDC}/token")
      expect { rack.access_token! }.to raise_error(Faraday::Adapter::Test::Stubs::NotFound)
      expect(host_runs).to eq([:built])
      expect(Rack::OAuth2).to have_received(:http_client).once
    end

    # 대조군 — SDK 가 응답에서 만드는 `AccessToken::Bearer`(`oauth_token`)는 연결을 만들지 않고, 그것으로 요청할 때만 만든다.
    it "builds no connection for a Bearer the SDK constructs, only for a request made with it (control)",
       :aggregate_failures do
      bearer = Rack::OAuth2::AccessToken::Bearer.new(access_token: "AT", token_type: "bearer")
      expect(host_runs).to be_empty
      expect { bearer.get("#{spec::SERVER}/anything") }.to raise_error(Faraday::Adapter::Test::Stubs::NotFound)
      expect(host_runs).to eq([:built])
    end
  end
end
