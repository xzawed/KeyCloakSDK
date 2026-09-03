# frozen_string_literal: true

require "spec_helper"
require "base64"
require "digest"
require "uri"

# ⚠️ `CGI.parse` 를 쓰지 않는다 — **Ruby 4.0 에서 사라졌다**(`undefined method 'parse' for class CGI`).
# CI 에 4.0 레그를 넣자마자 이 두 예제가 그것으로 죽었다. SDK 본체(`lib/`)는 CGI 를 전혀 쓰지
# 않으므로 라이브러리는 4.0 에서 멀쩡하고, 깨진 것은 **테스트뿐**이었다.
# `URI.decode_www_form` 은 3.2~4.0 전부에서 stdlib 이고 같은 것을 돌려준다(키당 값 배열).
def query_params(url)
  URI.decode_www_form(URI(url).query).each_with_object({}) { |(k, v), h| (h[k] ||= []) << v }
end

RSpec.describe KeycloakSdk::AuthClient do
  subject(:auth) { described_class.new(config: config, http: http, jwt_validator: jwt_validator) }

  let(:config) do
    KeycloakSdk::Config.new(server_url: "https://kc.example.com", realm: "demo",
                            client_id: "app", client_secret: "sekret", scopes: %w[openid email])
  end
  let(:http) do
    KeycloakSdk::Http.build(config) do |f|
      f.request :url_encoded
      f.response :json
    end
  end
  let(:jwt_validator) { instance_double(KeycloakSdk::JwtValidator) }
  let(:introspect_url) { "https://kc.example.com/realms/demo/protocol/openid-connect/token/introspect" }
  let(:logout_url) { "https://kc.example.com/realms/demo/protocol/openid-connect/logout" }

  def token_url
    "https://kc.example.com/realms/demo/protocol/openid-connect/token"
  end

  describe "#create_authorization_request (offline, PKCE S256)" do
    it "builds an authorization URL with S256 challenge and returns a masked verifier" do
      req = auth.create_authorization_request(redirect_uri: "https://app/cb", state: "st-123")
      expect(req.url).to include("code_challenge_method=S256")
      expect(req.url).to include("code_challenge=")
      expect(req.url).to include("state=st-123")
      expect(req.state).to eq("st-123")
      expect(req.code_verifier).to be_a(String)
      expect(req.inspect).not_to include(req.code_verifier)
    end

    # 부정/정확성 테스트(PR6): challenge가 "존재"만이 아니라 base64url(sha256(verifier))로
    # 정확히 파생되는지 검증한다 — 잘못 파생하면 Keycloak이 invalid_grant로 거부한다.
    it "derives the S256 code_challenge as base64url(sha256(code_verifier))" do
      req = auth.create_authorization_request(redirect_uri: "https://app/cb")
      expected = Base64.urlsafe_encode64(Digest::SHA256.digest(req.code_verifier), padding: false)
      expect(query_params(req.url)["code_challenge"]).to eq([expected])
    end

    it "always issues a nonce and puts it on the authorization URL" do
      req = auth.create_authorization_request(redirect_uri: "https://app/cb")
      expect(req.nonce).to be_a(String)
      expect(req.nonce).not_to be_empty
      expect(query_params(req.url)["nonce"]).to eq([req.nonce])
    end

    it "issues a different nonce on every call" do
      a = auth.create_authorization_request(redirect_uri: "https://app/cb")
      b = auth.create_authorization_request(redirect_uri: "https://app/cb")
      expect(a.nonce).not_to eq(b.nonce)
    end
  end

  describe "#introspect" do
    it "posts to the introspection endpoint and parses the result" do
      stub_request(:post, introspect_url)
        .with(body: hash_including("token" => "AT", "client_id" => "app"))
        .to_return(status: 200, body: { active: true, username: "u", client_id: "app" }.to_json,
                   headers: { "Content-Type" => "application/json" })
      r = auth.introspect("AT")
      expect(r.active?).to be(true)
      expect(r.username).to eq("u")
    end

    it "raises TransportError on connection failure" do
      stub_request(:post, introspect_url).to_raise(Faraday::ConnectionFailed.new("x"))
      expect { auth.introspect("AT") }.to raise_error(KeycloakSdk::TransportError)
    end
  end

  describe "#logout" do
    it "posts refresh_token to end_session and returns nil" do
      stub_request(:post, logout_url).with(body: hash_including("refresh_token" => "RT"))
                                     .to_return(status: 204, body: "")
      expect(auth.logout(refresh_token: "RT")).to be_nil
    end
  end

  describe "#validate" do
    it "delegates to the JwtValidator" do
      vt = instance_double(KeycloakSdk::ValidatedToken)
      allow(jwt_validator).to receive(:validate).with("tok").and_return(vt)
      expect(auth.validate("tok")).to be(vt)
    end
  end

  describe "#exchange_code" do
    it "populates id_token and scope from the token response" do
      stub_request(:post, token_url)
        .to_return(status: 200, body: {
          access_token: "AT", token_type: "Bearer", expires_in: 300,
          refresh_token: "RT", id_token: "the-id-token", scope: "openid email"
        }.to_json, headers: { "Content-Type" => "application/json" })

      ts = auth.exchange_code(code: "c", code_verifier: "v", redirect_uri: "https://app/cb")
      expect(ts.access_token).to eq("AT")
      expect(ts.id_token).to eq("the-id-token")
      expect(ts.scope).to eq("openid email")
    end

    context "with expected_nonce (OIDC nonce replay protection)" do
      def stub_token_with_id_token(id_token: "the-id-token")
        body = { access_token: "AT", token_type: "Bearer", expires_in: 300 }
        body[:id_token] = id_token unless id_token.nil?
        stub_request(:post, token_url)
          .to_return(status: 200, body: body.to_json,
                     headers: { "Content-Type" => "application/json" })
      end

      it "validates the id_token and accepts a matching nonce" do
        stub_token_with_id_token
        vt = instance_double(KeycloakSdk::ValidatedToken, claims: { "nonce" => "n-abc" })
        allow(jwt_validator).to receive(:validate).with("the-id-token").and_return(vt)

        ts = auth.exchange_code(code: "c", code_verifier: "v",
                                redirect_uri: "https://app/cb", expected_nonce: "n-abc")
        expect(ts.access_token).to eq("AT")
        expect(jwt_validator).to have_received(:validate).with("the-id-token")
      end

      it "rejects a mismatched nonce" do
        stub_token_with_id_token
        vt = instance_double(KeycloakSdk::ValidatedToken, claims: { "nonce" => "attacker" })
        allow(jwt_validator).to receive(:validate).with("the-id-token").and_return(vt)

        expect do
          auth.exchange_code(code: "c", code_verifier: "v",
                             redirect_uri: "https://app/cb", expected_nonce: "n-abc")
        end.to raise_error(KeycloakSdk::AuthError, /nonce/)
      end

      it "rejects an id_token whose signature/claims fail validation" do
        stub_token_with_id_token
        allow(jwt_validator).to receive(:validate) do
          raise KeycloakSdk::TokenValidationError, "bad signature"
        end

        expect do
          auth.exchange_code(code: "c", code_verifier: "v",
                             redirect_uri: "https://app/cb", expected_nonce: "n-abc")
        end.to raise_error(KeycloakSdk::AuthError, /id_token/)
      end

      it "rejects a response missing the id_token when a nonce is expected" do
        stub_token_with_id_token(id_token: nil)

        expect do
          auth.exchange_code(code: "c", code_verifier: "v",
                             redirect_uri: "https://app/cb", expected_nonce: "n-abc")
        end.to raise_error(KeycloakSdk::AuthError, /id_token/)
      end

      it "skips id_token validation when no nonce is expected" do
        stub_token_with_id_token
        allow(jwt_validator).to receive(:validate)
        ts = auth.exchange_code(code: "c", code_verifier: "v", redirect_uri: "https://app/cb")
        expect(ts.access_token).to eq("AT")
        expect(jwt_validator).not_to have_received(:validate)
      end
    end
  end

  describe "#client_credentials_token" do
    it "sends the configured scope to the token endpoint" do
      cc_config = KeycloakSdk::Config.new(
        server_url: "https://kc.example.com", realm: "demo",
        client_id: "app", client_secret: "sekret", scopes: %w[openid custom-scope]
      )
      cc_auth = described_class.new(config: cc_config, http: http, jwt_validator: jwt_validator)
      stub = stub_request(:post, token_url)
             .with(body: hash_including("scope" => "openid custom-scope"))
             .to_return(status: 200, body: {
               access_token: "AT", token_type: "Bearer", expires_in: 300
             }.to_json, headers: { "Content-Type" => "application/json" })

      ts = cc_auth.client_credentials_token
      expect(stub).to have_been_requested
      expect(ts.access_token).to eq("AT")
    end
  end

  describe "rack-oauth2 timeout configuration" do
    it "configures rack-oauth2 timeouts from Config on construction (not a require-time hardcode)" do
      # http_config를 캡처해 블록을 직접 검증한다 — 전역 Rack::OAuth2.http_client에 의존하면
      # 테스트 순서/Faraday 버전에 취약(전역 상태). 블록에 가짜 conn을 넘겨 config 값 반영을 확인.
      captured = nil
      allow(Rack::OAuth2).to receive(:http_config) { |&blk| captured = blk }
      described_class.new(
        config: KeycloakSdk::Config.new(server_url: "https://kc", realm: "r", client_id: "c",
                                        connect_timeout: 3, read_timeout: 7),
        http: http, jwt_validator: jwt_validator
      )
      options = Struct.new(:open_timeout, :timeout).new
      conn = Struct.new(:options).new(options)
      captured.call(conn)
      expect(options.open_timeout).to eq(3)
      expect(options.timeout).to eq(7)
    end
  end
end
