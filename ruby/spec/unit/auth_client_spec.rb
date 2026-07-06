# frozen_string_literal: true

require "spec_helper"

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
end
