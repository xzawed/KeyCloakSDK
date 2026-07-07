# frozen_string_literal: true

require "spec_helper"

RSpec.describe KeycloakSdk::JwksStore do
  subject(:store) { described_class.new(jwks_url: jwks_url, http: http, min_refetch: 1000.0) }

  let(:config) { KeycloakSdk::Config.new(server_url: "https://k", realm: "r", client_id: "c") }
  let(:http) { KeycloakSdk::Http.build(config) { |f| f.response :json } }
  let(:jwks_url) { "https://k/realms/r/protocol/openid-connect/certs" }
  let(:body) { { keys: [{ kty: "RSA", kid: "k1", n: "AQAB", e: "AQAB" }] }.to_json }

  it "fetches once (cold) and caches subsequent non-forced reads" do
    stub = stub_request(:get, jwks_url).to_return(status: 200, body: body,
                                                  headers: { "Content-Type" => "application/json" })
    3.times { store.key_set }
    expect(store.key_set["keys"].first["kid"]).to eq("k1")
    expect(stub).to have_been_requested.once
  end

  it "rate-limits forced re-fetches (unresolved kid) within the window" do
    stub = stub_request(:get, jwks_url).to_return(status: 200, body: body,
                                                  headers: { "Content-Type" => "application/json" })
    store.key_set                    # cold load (no stamp)
    store.key_set(force: true)       # 1st forced → allowed → stamp + fetch
    store.key_set(force: true)       # within window → rate-limited → serve stale, no fetch
    expect(stub).to have_been_requested.times(2)
  end

  it "raises TransportError on non-200" do
    stub_request(:get, jwks_url).to_return(status: 500, body: "err")
    expect { store.key_set }.to raise_error(KeycloakSdk::TransportError)
  end

  it "raises TransportError on malformed body" do
    stub_request(:get, jwks_url).to_return(status: 200, body: { nope: 1 }.to_json,
                                           headers: { "Content-Type" => "application/json" })
    expect { store.key_set }.to raise_error(KeycloakSdk::TransportError)
  end

  it "raises TransportError on connection failure" do
    stub_request(:get, jwks_url).to_raise(Faraday::ConnectionFailed.new("refused"))
    expect { store.key_set }.to raise_error(KeycloakSdk::TransportError)
  end

  it "raises TransportError (not a raw Faraday::SSLError) on TLS verification failure" do
    stub_request(:get, jwks_url).to_raise(Faraday::SSLError.new("cert verify failed"))
    expect { store.key_set }.to raise_error(KeycloakSdk::TransportError)
  end

  it "keeps the rate-limit gate stamped even when a forced re-fetch fails (bounded flood, nil cache)" do
    stub = stub_request(:get, jwks_url).to_return(status: 500, body: "err")
    # cold-cache forced fetch fails but must stamp the gate at the decision point
    expect { store.key_set(force: true) }.to raise_error(KeycloakSdk::TransportError)
    # a second forced call within the min_refetch window is rate-limited -> NO further network hit
    store.key_set(force: true)
    expect(stub).to have_been_requested.once
  end

  it "allows a forced re-fetch once the cooldown has elapsed" do
    fast_store = described_class.new(jwks_url: jwks_url, http: http, min_refetch: 0.0)
    stub = stub_request(:get, jwks_url).to_return(status: 200, body: body,
                                                  headers: { "Content-Type" => "application/json" })
    fast_store.key_set(force: true) # cold forced load -> stamp + fetch
    fast_store.key_set(force: true) # cooldown (0.0) already elapsed -> refetch_allowed? true -> fetch again
    expect(stub).to have_been_requested.times(2)
  end

  it "raises TransportError on non-Hash body (array)" do
    stub_request(:get, jwks_url).to_return(status: 200, body: [1, 2, 3].to_json,
                                           headers: { "Content-Type" => "application/json" })
    expect { store.key_set }.to raise_error(KeycloakSdk::TransportError)
  end
end
