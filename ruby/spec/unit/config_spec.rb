# frozen_string_literal: true

require "spec_helper"

RSpec.describe KeycloakSdk::Config do
  def valid(**over)
    described_class.new(
      server_url: "https://kc.example.com/", realm: "demo", client_id: "app",
      client_secret: "sekret", **over
    )
  end

  it "strips a trailing slash from server_url" do
    expect(valid.server_url).to eq("https://kc.example.com")
  end

  it "defaults scopes/timeouts/clock_skew" do
    c = described_class.new(server_url: "https://k", realm: "r", client_id: "c")
    expect(c.scopes).to eq(["openid"])
    expect(c.connect_timeout).to eq(10)
    expect(c.read_timeout).to eq(10)
    expect(c.clock_skew).to eq(30)
    expect(c.jwks_min_refetch).to eq(10.0)
    expect(c.client_secret).to be_nil
  end

  it "keeps a configured jwks_min_refetch and rejects a negative one" do
    expect(valid(jwks_min_refetch: 60).jwks_min_refetch).to eq(60)
    expect { valid(jwks_min_refetch: -1) }.to raise_error(KeycloakSdk::ConfigError)
  end

  it "defaults expected_audience to nil (= client_id) and keeps a configured one" do
    expect(valid.expected_audience).to be_nil
    expect(valid(expected_audience: "my-api").expected_audience).to eq("my-api")
  end

  it "is frozen and immutable" do
    expect(valid).to be_frozen
  end

  it "masks client_secret in inspect and to_s" do
    s = valid.inspect
    expect(s).to include("***")
    expect(s).not_to include("sekret")
    expect(valid.to_s).not_to include("sekret")
  end

  %i[server_url realm client_id].each do |field|
    it "raises ConfigError when #{field} is missing" do
      expect { valid(field => nil) }.to raise_error(KeycloakSdk::ConfigError)
    end

    it "raises ConfigError when #{field} is blank" do
      expect { valid(field => "  ") }.to raise_error(KeycloakSdk::ConfigError)
    end
  end

  it "rejects a non-positive timeout" do
    expect { valid(connect_timeout: 0) }.to raise_error(KeycloakSdk::ConfigError)
  end

  it "defaults signature_algorithms to RS256" do
    c = described_class.new(server_url: "https://k", realm: "r", client_id: "c")
    expect(c.signature_algorithms).to eq(["RS256"])
  end

  it "keeps configured signature_algorithms" do
    c = described_class.new(server_url: "https://k", realm: "r", client_id: "c",
                            signature_algorithms: %w[ES256 RS256])
    expect(c.signature_algorithms).to eq(%w[ES256 RS256])
  end

  it "rejects empty signature_algorithms" do
    expect { valid(signature_algorithms: []) }.to raise_error(KeycloakSdk::ConfigError)
  end
end
