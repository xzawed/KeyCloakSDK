# frozen_string_literal: true

require "spec_helper"

RSpec.describe KeycloakSdk::KeycloakClient do
  subject(:client) { described_class.new(config) }

  let(:config) do
    KeycloakSdk::Config.new(server_url: "https://kc.example.com", realm: "demo",
                            client_id: "app", client_secret: "sekret")
  end

  it "builds the auth facade eagerly" do
    expect(client.auth).to be_a(KeycloakSdk::AuthClient)
  end

  it "builds the admin facade lazily and memoizes it" do
    expect(client.admin).to be_a(KeycloakSdk::Admin::AdminClient)
    expect(client.admin).to equal(client.admin)
  end

  it "wires admin with a dedicated caching ClientCredentialsTokenProvider, not the AuthClient (§4)" do
    allow(KeycloakSdk::ClientCredentialsTokenProvider).to receive(:new).and_call_original
    client.admin
    expect(KeycloakSdk::ClientCredentialsTokenProvider).to have_received(:new)
      .with(config: kind_of(KeycloakSdk::Config), http: anything)
  end

  it "responds to close" do
    expect { client.close }.not_to raise_error
  end
end
