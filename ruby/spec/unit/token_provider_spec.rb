# frozen_string_literal: true

require "spec_helper"

RSpec.describe KeycloakSdk::ClientCredentialsTokenProvider do
  subject(:provider) { described_class.new(config: config, http: http) }

  let(:config) do
    KeycloakSdk::Config.new(server_url: "https://kc.example.com", realm: "demo",
                            client_id: "svc", client_secret: "sekret", clock_skew: 30)
  end
  let(:http) do
    KeycloakSdk::Http.build(config) do |f|
      f.request :url_encoded
      f.response :json
    end
  end
  let(:token_url) { "https://kc.example.com/realms/demo/protocol/openid-connect/token" }

  it "fetches a client-credentials token and returns the access_token string" do
    stub = stub_request(:post, token_url)
           .with(body: hash_including("grant_type" => "client_credentials", "client_id" => "svc",
                                      "client_secret" => "sekret", "scope" => "openid"))
           .to_return(status: 200, body: { access_token: "AT1", expires_in: 300, token_type: "Bearer" }.to_json,
                      headers: { "Content-Type" => "application/json" })
    expect(provider.access_token).to eq("AT1")
    expect(stub).to have_been_requested.once
  end

  it "caches the token until near expiry (single network call)" do
    stub = stub_request(:post, token_url)
           .to_return(status: 200, body: { access_token: "AT1", expires_in: 300, token_type: "Bearer" }.to_json,
                      headers: { "Content-Type" => "application/json" })
    3.times { provider.access_token }
    expect(stub).to have_been_requested.once
  end

  it "raises AuthError with oauth_error on 401" do
    stub_request(:post, token_url)
      .to_return(status: 401, body: { error: "invalid_client" }.to_json,
                 headers: { "Content-Type" => "application/json" })
    expect { provider.access_token }.to raise_error(KeycloakSdk::AuthError) { |e| expect(e.oauth_error).to eq("invalid_client") }
  end

  it "raises TransportError on connection failure" do
    stub_request(:post, token_url).to_raise(Faraday::ConnectionFailed.new("refused"))
    expect { provider.access_token }.to raise_error(KeycloakSdk::TransportError)
  end
end
