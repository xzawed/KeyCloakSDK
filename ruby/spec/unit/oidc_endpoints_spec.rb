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
end
