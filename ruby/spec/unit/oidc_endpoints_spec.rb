# frozen_string_literal: true

require "spec_helper"

RSpec.describe KeycloakSdk::OidcEndpoints do
  subject(:ep) { described_class.new("https://kc.example.com", "demo") }

  it "assembles conventional realm URLs (no network)" do
    expect(ep.issuer).to eq("https://kc.example.com/realms/demo")
    expect(ep.authorization).to eq("https://kc.example.com/realms/demo/protocol/openid-connect/auth")
    expect(ep.token).to eq("https://kc.example.com/realms/demo/protocol/openid-connect/token")
    expect(ep.introspection).to eq("https://kc.example.com/realms/demo/protocol/openid-connect/token/introspect")
    expect(ep.end_session).to eq("https://kc.example.com/realms/demo/protocol/openid-connect/logout")
    expect(ep.jwks).to eq("https://kc.example.com/realms/demo/protocol/openid-connect/certs")
  end

  # 엔드포인트만 경로 세그먼트로 인코딩하고 issuer는 iss 비교용으로 raw realm을 유지한다.
  {
    "my realm" => "my%20realm",
    "réalm" => "r%C3%A9alm",
    "A-b_c.d~e9!" => "A-b_c.d~e9%21"
  }.each do |realm, encoded|
    it "percent-encodes realm #{realm.inspect} in endpoints and keeps the issuer raw" do
      endpoints = described_class.new("https://kc.example.com", realm)
      oidc = "https://kc.example.com/realms/#{encoded}/protocol/openid-connect"
      expect(endpoints.issuer).to eq("https://kc.example.com/realms/#{realm}")
      expect(endpoints.authorization).to eq("#{oidc}/auth")
      expect(endpoints.token).to eq("#{oidc}/token")
      expect(endpoints.introspection).to eq("#{oidc}/token/introspect")
      expect(endpoints.end_session).to eq("#{oidc}/logout")
      expect(endpoints.jwks).to eq("#{oidc}/certs")
    end
  end
end
