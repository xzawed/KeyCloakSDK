# frozen_string_literal: true

require "spec_helper"

RSpec.describe KeycloakSdk::Config do
  def config_error_for(url)
    described_class.new(server_url: url, realm: "demo", client_id: "app")
    raise "expected ConfigError for #{url.inspect}"
  rescue KeycloakSdk::ConfigError => e
    e
  end

  def valid(**over)
    described_class.new(
      server_url: "https://kc.example.com/", realm: "demo", client_id: "app",
      client_secret: "sekret", **over
    )
  end

  it "strips a trailing slash from server_url" do
    expect(valid.server_url).to eq("https://kc.example.com")
  end

  # ⚠️ 슬래시 **여러 개**를 함께 고정한다. 구현이 정규식 `%r{/+\z}`에서 선형 트림으로 바뀌었는데,
  # 단일 슬래시만 검사하면 "하나만 지우는" 구현으로 퇴화해도 통과한다(내부 슬래시 보존도 함께).
  it "strips all trailing slashes but keeps interior ones" do
    build = lambda do |url|
      described_class.new(server_url: url, realm: "demo", client_id: "app").server_url
    end
    expect(build.call("https://kc.example.com////")).to eq("https://kc.example.com")
    expect(build.call("https://kc.example.com/auth//")).to eq("https://kc.example.com/auth")
    expect(build.call("https://kc.example.com")).to eq("https://kc.example.com")
  end

  it "defaults scopes/timeouts/clock_skew" do
    c = described_class.new(server_url: "https://k", realm: "r", client_id: "c")
    expect(c.scopes).to eq(["openid"])
    expect(c.connect_timeout).to eq(10)
    expect(c.read_timeout).to eq(10)
    expect(c.clock_skew).to eq(30)
    expect(c.jwks_min_refetch).to eq(30.0)
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

  # 상대·비-http·파싱 불가·범위 밖 포트는 요청 시점의 RuntimeError "No Host Info" /
  # URI::InvalidURIError가 아니라 생성 시 ConfigError. 메시지는 입력을 되울리지 않는다.
  # "http://" 는 host가 빈 URI::HTTP라 "missing host" 분기를 탄다(스펙의 네 사유 중 하나).
  {
    "kc.example.com" => "scheme must be http or https",
    "http://kc example.com" => "unparseable",
    "ftp://kc.example.com" => "scheme must be http or https",
    "http://127.0.0.1:65536" => "port out of range",
    "http://" => "missing host"
  }.each do |url, reason|
    it "rejects server_url #{url.inspect} without echoing it" do
      error = config_error_for(url)
      expect(error).to be_a(KeycloakSdk::ConfigError)
      expect(error.message).to start_with("server_url must be an absolute http(s) URL: ")
      expect(error.message).to end_with(reason)
      expect(error.message).not_to include(url)
    end
  end

  [
    "http://keycloak_server:8080",
    "https://kc.example.com/auth",
    "http://127.0.0.1:8080",
    "HTTP://kc.example.com",
    "http://127.0.0.1:65535"
  ].each do |url|
    it "accepts absolute server_url #{url.inspect}" do
      config = described_class.new(server_url: url, realm: "demo", client_id: "app")
      expect(config.server_url).to eq(url)
    end
  end
end
