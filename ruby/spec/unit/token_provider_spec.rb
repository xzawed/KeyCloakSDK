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

  # 캐시 계약(등록부 tokenprovider-cache-contract-untested) — 위 예제는 「다시 받는다」를 보지 않는다(만료를 안 보는 변이에도
  # 초록이었다). expires_in 이 clock_skew(30)보다 짧으면 받자마자 만료다 — 둘째 호출이 새로 받는다. 스큐를 빼지 않으면 1 번이다.
  it "refetches once the cached token is within the clock skew of expiry" do
    stub = stub_request(:post, token_url)
           .to_return(status: 200, body: { access_token: "AT1", expires_in: 20, token_type: "Bearer" }.to_json,
                      headers: { "Content-Type" => "application/json" })
    2.times { provider.access_token }
    expect(stub).to have_been_requested.twice
  end

  # 동시 호출은 한 번의 부여로 합쳐진다(single-flight — 잠금을 쥔 채 받는다). 느린 IdP 앞에서 여덟 스레드가 함께 물어도 부여는
  # 1 번이다 — 잠금이 없으면 각자 받는다(뮤텍스를 뺀 변이에도 이 파일은 초록이었다).
  it "shares one grant among concurrent callers (single-flight)" do
    stub = stub_request(:post, token_url).to_return do
      sleep 0.2
      { status: 200, body: { access_token: "AT1", expires_in: 300, token_type: "Bearer" }.to_json,
        headers: { "Content-Type" => "application/json" } }
    end
    threads = Array.new(8) { Thread.new { provider.access_token } }
    expect(threads.map(&:value)).to all(eq("AT1"))
    expect(stub).to have_been_requested.once
  end

  # 실패를 캐시하지 않는다 — 실패한 부여 뒤의 호출은 다시 묻는다(Grok 레그).
  it "does not cache a failed grant — the next call asks again" do
    stub = stub_request(:post, token_url)
           .to_return({ status: 500, body: "down" },
                      { status: 200, body: { access_token: "AT2", expires_in: 300, token_type: "Bearer" }.to_json,
                        headers: { "Content-Type" => "application/json" } })
    expect { provider.access_token }.to raise_error(KeycloakSdk::Error)
    expect(provider.access_token).to eq("AT2")
    expect(stub).to have_been_requested.twice
  end

  # 만료 시각을 모르는 토큰(expires_in 없음)은 만료로 친다 — 매 호출이 다시 받는다(TokenSet#expired? 의 규칙).
  # 이전엔 60 초를 짐작해 붙들었다.
  it "fetches a token without expires_in again on every call" do
    stub = stub_request(:post, token_url)
           .to_return(status: 200, body: { access_token: "AT1", token_type: "Bearer" }.to_json,
                      headers: { "Content-Type" => "application/json" })
    2.times { provider.access_token }
    expect(stub).to have_been_requested.twice
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

  # 성공 상태가 OAuth `error` 를 실은 응답(등록부 auth-2xx-error-code-divergent) — 오류 상태(위 401)와 같은 AuthError · 같은
  # 메시지 꼴 · 같은 코드이고, 실린 토큰은 돌려주지도 캐시하지도 않는다: 다음 호출이 다시 묻는다. 수정 전(실측): B1 은 코드 없는
  # 「token response has no usable access_token」, B2 는 그 토큰을 돌려주고 캐시했다(admin 이 그것으로 요청을 보냈다).
  describe "a success-status OAuth error (success_status_oauth_error)" do
    let(:json) { { "Content-Type" => "application/json" } }
    let(:fresh) do
      { status: 200, body: { access_token: "AT2", expires_in: 300, token_type: "Bearer" }.to_json, headers: json }
    end

    {
      "B1" => '{"error":"invalid_grant","error_description":"d"}',
      "B2 with a token" => '{"error":"invalid_grant","access_token":"eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ4In0.' \
                           'c2lnbmF0dXJlLXZhbHVl","token_type":"Bearer","expires_in":300}'
    }.each do |name, body|
      it "fails on HTTP 200 #{name} as on an error status and caches nothing (success-status OAuth error)" do
        stub = stub_request(:post, token_url).to_return({ status: 200, body: body, headers: json }, fresh)
        expect { provider.access_token }.to raise_error(KeycloakSdk::AuthError) do |e|
          expect([e.message, e.oauth_error])
            .to eq(["client-credentials token request failed: HTTP 200", "invalid_grant"])
        end
        expect(provider.access_token).to eq("AT2")
        expect(stub).to have_been_requested.twice
      end
    end

    # 대조군 — 비지 않은 JSON 문자열이 아닌 `error`(수 · 객체 · 배열 · "" · null)는 예전처럼 보지 않는다: 토큰을 쓰고 캐시한다.
    [400, { "code" => "invalid_grant" }, ["invalid_grant"], "", nil].each do |error|
      it "ignores an error member #{error.inspect} on HTTP 200, as before (success-status OAuth error control)" do
        stub = stub_request(:post, token_url)
               .to_return(status: 200, headers: json,
                          body: { error: error, access_token: "AT1", expires_in: 300, token_type: "Bearer" }.to_json)
        expect(Array.new(2) { provider.access_token }).to eq(%w[AT1 AT1])
        expect(stub).to have_been_requested.once
      end
    end
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
