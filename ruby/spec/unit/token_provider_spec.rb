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

  # 기본 `inspect` 는 인스턴스 변수를 전부 찍는다. 이 클래스는 **원시 액세스 토큰 문자열**을
  # `@cached` 에 들고 있어(`ts.access_token`, TokenSet 이 아니다) 형제들의 마스킹이 닿지 않는다.
  # 실측(2026-09-12): `p provider` 가 `@cached="AT-CENSUS-TOKEN-…"` 를 원문으로 찍었다.
  # `Config`·`TokenSet` 은 `inspect` 를 재정의하는데 이 타입만 없던 것이 원인이다.
  describe "#inspect" do
    let(:config) do
      KeycloakSdk::Config.new(server_url: "http://kc:8080", realm: "r",
                              client_id: "c", client_secret: "SECRET-CENSUS")
    end
    let(:provider) { described_class.new(config: config, http: Faraday.new) }

    it "캐시된 액세스 토큰을 원문으로 찍지 않는다" do
      provider.instance_variable_set(:@cached, "AT-CENSUS-TOKEN")
      expect(provider.inspect).not_to include("AT-CENSUS-TOKEN")
    end

    it "토큰을 들고 있다는 사실은 남긴다(디버깅 가능해야 한다)" do
      provider.instance_variable_set(:@cached, "AT-CENSUS-TOKEN")
      expect(provider.inspect).to include("***")
    end

    # 대조군 — 캐시가 비었을 때 `***` 를 찍으면 「토큰이 있다」는 거짓 신호가 된다.
    it "캐시가 비면 nil 로 구분된다" do
      expect(provider.inspect).to include("cached=nil")
    end

    it "중첩 config 의 시크릿도 새지 않는다" do
      provider.instance_variable_set(:@cached, "AT-CENSUS-TOKEN")
      expect(provider.inspect).not_to include("SECRET-CENSUS")
    end

    it "to_s 도 같은 계약이다" do
      provider.instance_variable_set(:@cached, "AT-CENSUS-TOKEN")
      expect(provider.to_s).not_to include("AT-CENSUS-TOKEN")
    end
  end
end
