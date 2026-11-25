# frozen_string_literal: true

require "spec_helper"
require "base64"
require "digest"
require "uri"

# ⚠️ `CGI.parse` 를 쓰지 않는다 — **Ruby 4.0 에서 사라졌다**(`undefined method 'parse' for class CGI`).
# CI 에 4.0 레그를 넣자마자 이 두 예제가 그것으로 죽었다. SDK 본체(`lib/`)는 CGI 를 전혀 쓰지
# 않으므로 라이브러리는 4.0 에서 멀쩡하고, 깨진 것은 **테스트뿐**이었다.
# `URI.decode_www_form` 은 3.2~4.0 전부에서 stdlib 이고 같은 것을 돌려준다(키당 값 배열).
def query_params(url)
  URI.decode_www_form(URI(url).query).each_with_object({}) { |(k, v), h| (h[k] ||= []) << v }
end

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

  def token_url
    "https://kc.example.com/realms/demo/protocol/openid-connect/token"
  end

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

    # 부정/정확성 테스트(PR6): challenge가 "존재"만이 아니라 base64url(sha256(verifier))로
    # 정확히 파생되는지 검증한다 — 잘못 파생하면 Keycloak이 invalid_grant로 거부한다.
    it "derives the S256 code_challenge as base64url(sha256(code_verifier))" do
      req = auth.create_authorization_request(redirect_uri: "https://app/cb")
      expected = Base64.urlsafe_encode64(Digest::SHA256.digest(req.code_verifier), padding: false)
      expect(query_params(req.url)["code_challenge"]).to eq([expected])
    end

    it "always issues a nonce and puts it on the authorization URL" do
      req = auth.create_authorization_request(redirect_uri: "https://app/cb")
      expect(req.nonce).to be_a(String)
      expect(req.nonce).not_to be_empty
      expect(query_params(req.url)["nonce"]).to eq([req.nonce])
    end

    it "issues a different nonce on every call" do
      a = auth.create_authorization_request(redirect_uri: "https://app/cb")
      b = auth.create_authorization_request(redirect_uri: "https://app/cb")
      expect(a.nonce).not_to eq(b.nonce)
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

    # Keycloak 의 logout 성공은 204 뿐이다 — 가로챈 200 로그인 페이지 · 그 밖의 2xx · 3xx 는 로그아웃이 아니다
    # (등록부 logout-2xx-html-false-success · 판정 2026-11-12). 본문은 판정에 쓰지 않는다.
    # 205 · 206 · 4xx · 5xx 와 정확한 문구 — 실행 레그가 살린 편집(205 · 404 수용 · 502 · 504 를 TransportError 로)을 잡는다.
    [[200, "text/html", "<html>login</html>"], [200, "application/json", "{}"], [200, nil, ""],
     [201, nil, ""], [202, nil, ""], [205, nil, ""], [206, nil, ""], [302, "text/html", ""],
     [400, "application/json", '{"error":"invalid_grant"}'], [401, nil, ""],
     [404, "text/html", "<html>Not Found</html>"], [500, nil, ""],
     [502, "text/html", "<html>Bad Gateway</html>"], [503, nil, ""],
     [504, "text/html", "<html>Gateway Timeout</html>"]].each do |status, type, body|
      it "raises AuthError naming the status on HTTP #{status} #{type.inspect} #{body.inspect}" do
        headers = type ? { "Content-Type" => type } : {}
        stub_request(:post, logout_url).to_return(status: status, headers: headers, body: body)
        expect { auth.logout(refresh_token: "RT") }
          .to raise_error(KeycloakSdk::AuthError, "logout failed: HTTP #{status}")
      end
    end
  end

  describe "#validate" do
    # audience 를 넘기지 않는다 — 넘기면 검증기가 가진 `expected_audience` 재정의를 덮는다(액세스 토큰의 것).
    it "delegates to the JwtValidator" do
      vt = instance_double(KeycloakSdk::ValidatedToken)
      allow(jwt_validator).to receive(:validate).with("tok").and_return(vt)
      expect(auth.validate("tok")).to be(vt)
    end
  end

  # 공개 id_token 검증 — 교환과 같은 `JwtValidator#validate_id_token` 하나에 설정의 client_id 로 위임한다(실물 검증기로 재는
  # 판정은 `validate_id_token_spec.rb`). `expected_audience` 재정의는 id_token 에 걸리지 않는다.
  describe "#validate_id_token" do
    it "delegates to JwtValidator#validate_id_token with the configured client_id" do
      vt = instance_double(KeycloakSdk::ValidatedToken)
      allow(jwt_validator).to receive(:validate_id_token).with("id-tok", client_id: "app").and_return(vt)
      expect(auth.validate_id_token("id-tok")).to be(vt)
    end

    it "uses the client_id even when expected_audience is overridden" do
      overridden = KeycloakSdk::Config.new(server_url: "https://kc.example.com", realm: "demo", client_id: "app",
                                           client_secret: "sekret", expected_audience: "my-api")
      vt = instance_double(KeycloakSdk::ValidatedToken)
      allow(jwt_validator).to receive(:validate_id_token).with("id-tok", client_id: "app").and_return(vt)
      expect(described_class.new(config: overridden, http: http, jwt_validator: jwt_validator)
                            .validate_id_token("id-tok")).to be(vt)
    end

    it "lets the validator's TokenValidationError through unchanged (the type validate raises)" do
      allow(jwt_validator).to receive(:validate_id_token).and_raise(KeycloakSdk::TokenValidationError, "nope")
      expect { auth.validate_id_token("id-tok") }.to raise_error(KeycloakSdk::TokenValidationError, "nope")
    end
  end

  describe "#exchange_code" do
    it "populates id_token and scope from the token response" do
      stub_request(:post, token_url)
        .to_return(status: 200, body: {
          access_token: "AT", token_type: "Bearer", expires_in: 300,
          refresh_token: "RT", id_token: "the-id-token", scope: "openid email"
        }.to_json, headers: { "Content-Type" => "application/json" })

      ts = auth.exchange_code(code: "c", code_verifier: "v", redirect_uri: "https://app/cb")
      expect(ts.access_token).to eq("AT")
      expect(ts.id_token).to eq("the-id-token")
      expect(ts.scope).to eq("openid email")
    end

    context "with expected_nonce (OIDC nonce replay protection)" do
      def stub_token_with_id_token(id_token: "the-id-token")
        body = { access_token: "AT", token_type: "Bearer", expires_in: 300 }
        body[:id_token] = id_token unless id_token.nil?
        stub_request(:post, token_url)
          .to_return(status: 200, body: body.to_json,
                     headers: { "Content-Type" => "application/json" })
      end

      # id_token 경로(`validate_id_token`) — `validate` 는 접근 토큰 검증이라 id_token 을 typ("ID")으로 거부한다.
      it "validates the id_token and accepts a matching nonce" do
        stub_token_with_id_token
        vt = instance_double(KeycloakSdk::ValidatedToken, claims: { "nonce" => "n-abc" })
        allow(jwt_validator).to receive(:validate_id_token).with("the-id-token", client_id: "app").and_return(vt)

        ts = auth.exchange_code(code: "c", code_verifier: "v",
                                redirect_uri: "https://app/cb", expected_nonce: "n-abc")
        expect(ts.access_token).to eq("AT")
        expect(jwt_validator).to have_received(:validate_id_token).with("the-id-token", client_id: "app")
      end

      # OIDC Core §3.1.3.7 — id_token `aud` 는 client_id 다. `expected_audience` 는 액세스 토큰(`#validate`)의 것이다.
      it "checks the id_token against the client_id even when expected_audience is overridden" do
        overridden = KeycloakSdk::Config.new(server_url: "https://kc.example.com", realm: "demo", client_id: "app",
                                             client_secret: "sekret", expected_audience: "my-api")
        stub_token_with_id_token
        vt = instance_double(KeycloakSdk::ValidatedToken, claims: { "nonce" => "n-abc" })
        allow(jwt_validator).to receive(:validate_id_token).with("the-id-token", client_id: "app").and_return(vt)

        described_class.new(config: overridden, http: http, jwt_validator: jwt_validator)
                       .exchange_code(code: "c", code_verifier: "v", redirect_uri: "https://app/cb",
                                      expected_nonce: "n-abc")
        expect(jwt_validator).to have_received(:validate_id_token).with("the-id-token", client_id: "app")
      end

      it "rejects a mismatched nonce" do
        stub_token_with_id_token
        vt = instance_double(KeycloakSdk::ValidatedToken, claims: { "nonce" => "attacker" })
        allow(jwt_validator).to receive(:validate_id_token).with("the-id-token", client_id: "app").and_return(vt)

        expect do
          auth.exchange_code(code: "c", code_verifier: "v",
                             redirect_uri: "https://app/cb", expected_nonce: "n-abc")
        end.to raise_error(KeycloakSdk::AuthError, /nonce/)
      end

      it "rejects an id_token whose signature/claims fail validation" do
        stub_token_with_id_token
        allow(jwt_validator).to receive(:validate_id_token) do
          raise KeycloakSdk::TokenValidationError, "bad signature"
        end

        expect do
          auth.exchange_code(code: "c", code_verifier: "v",
                             redirect_uri: "https://app/cb", expected_nonce: "n-abc")
        end.to raise_error(KeycloakSdk::AuthError, /id_token/)
      end

      it "rejects a response missing the id_token when a nonce is expected" do
        stub_token_with_id_token(id_token: nil)

        expect do
          auth.exchange_code(code: "c", code_verifier: "v",
                             redirect_uri: "https://app/cb", expected_nonce: "n-abc")
        end.to raise_error(KeycloakSdk::AuthError, /id_token/)
      end

      it "skips id_token validation when no nonce is expected" do
        stub_token_with_id_token
        allow(jwt_validator).to receive(:validate)
        allow(jwt_validator).to receive(:validate_id_token)
        ts = auth.exchange_code(code: "c", code_verifier: "v", redirect_uri: "https://app/cb")
        expect(ts.access_token).to eq("AT")
        expect(jwt_validator).not_to have_received(:validate)
        expect(jwt_validator).not_to have_received(:validate_id_token)
      end
    end
  end

  describe "#client_credentials_token" do
    it "sends the configured scope to the token endpoint" do
      cc_config = KeycloakSdk::Config.new(
        server_url: "https://kc.example.com", realm: "demo",
        client_id: "app", client_secret: "sekret", scopes: %w[openid custom-scope]
      )
      cc_auth = described_class.new(config: cc_config, http: http, jwt_validator: jwt_validator)
      stub = stub_request(:post, token_url)
             .with(body: hash_including("scope" => "openid custom-scope"))
             .to_return(status: 200, body: {
               access_token: "AT", token_type: "Bearer", expires_in: 300
             }.to_json, headers: { "Content-Type" => "application/json" })

      ts = cc_auth.client_credentials_token
      expect(stub).to have_been_requested
      expect(ts.access_token).to eq("AT")
    end

    # realm "my realm"을 그대로 token URL에 넣으면 URI::InvalidURIError가 SDK 경계를 뚫는다.
    # 퍼센트 인코딩된 URL로 요청이 나가야 하고, 나오는 예외는 KeycloakSdk::Error뿐이어야 한다.
    it "requests the percent-encoded token URL when the realm contains a space" do
      cc_config = KeycloakSdk::Config.new(
        server_url: "https://kc.example.com", realm: "my realm",
        client_id: "app", client_secret: "sekret"
      )
      cc_auth = described_class.new(config: cc_config, http: http, jwt_validator: jwt_validator)
      encoded = "https://kc.example.com/realms/my%20realm/protocol/openid-connect/token"
      stub = stub_request(:post, encoded)
             .to_return(status: 200, body: {
               access_token: "AT", token_type: "Bearer", expires_in: 300
             }.to_json, headers: { "Content-Type" => "application/json" })

      ts = cc_auth.client_credentials_token
      expect(stub).to have_been_requested
      expect(ts.access_token).to eq("AT")
    end

    # rack-oauth2 의 응답 규칙(`oauth_token`)은 token_type 이 bearer(대소문자 무시)인 응답만 토큰으로 받는다 — token_type 이
    # 없거나(nil 의 `&.`) 다른 종류면 쓸 수 없는 응답이고, 실린 토큰은 돌려주지 않는다.
    { "no token_type" => { access_token: "AT", expires_in: 300 },
      "token_type mac" => { access_token: "AT", token_type: "mac", expires_in: 300 } }.each do |name, body|
      it "fails on a token response with #{name}, returning no token" do
        stub = stub_request(:post, token_url).to_return(status: 200, body: body.to_json,
                                                        headers: { "Content-Type" => "application/json" })
        expect { auth.client_credentials_token }.to raise_error(KeycloakSdk::AuthError) do |e|
          expect([e.message, e.oauth_error])
            .to eq(["client-credentials failed: unusable token response (RuntimeError)", nil])
        end
        expect(stub).to have_been_requested.once
      end
    end

    # `expires_in` 이 없으면 만료를 모르는 토큰이다 — `expires_at` 도 nil 이고, 모르는 만료는 만료다(`TokenSet#expired?`).
    it "returns a token set with no expiry when the response has no expires_in" do
      body = { access_token: "AT", token_type: "Bearer" }.to_json
      stub = stub_request(:post, token_url).to_return(status: 200, body: body,
                                                      headers: { "Content-Type" => "application/json" })
      ts = auth.client_credentials_token
      expect([ts.access_token, ts.expires_in, ts.expires_at, ts.expired?]).to eq(["AT", nil, nil, true])
      expect(stub).to have_been_requested.once
    end
  end

  # 그랜트의 필수 값(`code` · `refresh_token`)이 비면 보내지 않는다 — rack-oauth2 의 `attr_required` 와 같은 「비었다」: nil 이거나
  # 빈 값이다(`empty?` 가 없는 값은 nil 일 때만 · 공백뿐인 문자열은 비지 않았다). rack-oauth2 의 그랜트가 그 검사를 하던 때는
  # 이 경계 밖에서 raw `AttrRequired::AttrMissing` 으로 샜다.
  describe "a grant whose required value is missing" do
    {
      "refresh" => ["refresh failed: refresh_token is required", ->(a, v) { a.refresh(refresh_token: v) }],
      "exchange_code" => ["authorization_code exchange failed: code is required", lambda { |a, v|
        a.exchange_code(code: v, code_verifier: "v", redirect_uri: "https://app/cb")
      }]
    }.each do |lane, (message, call)|
      { "nil" => nil, "an empty String" => "" }.each do |name, value|
        it "refuses #{lane} with #{name} for its required value, without sending it" do
          stub = stub_request(:post, token_url)
          expect { call.call(auth, value) }.to raise_error(KeycloakSdk::AuthError, message)
          expect(stub).not_to have_been_requested
        end
      end
    end

    # 대조군 — `empty?` 가 없는 값은 nil 이 아니면 비지 않았다: 그 글로 보낸다.
    it "sends a refresh_token that has no empty? (an Integer) as its text" do
      stub = stub_request(:post, token_url).with(body: hash_including("refresh_token" => "12345"))
                                           .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                                                      body: { access_token: "AT", token_type: "Bearer",
                                                              expires_in: 300 }.to_json)
      expect(auth.refresh(refresh_token: 12_345).access_token).to eq("AT")
      expect(stub).to have_been_requested.once
    end
  end

  # 성공 상태가 OAuth `error` 를 실은 응답(등록부 auth-2xx-error-code-divergent · 아홉 언어 같은 규칙) — 레인이 성공으로 받는
  # 상태라도 본문이 `error` 가 비지 않은 문자열인 JSON 객체면 오류 상태의 그 응답과 같은 AuthError · 같은 메시지 꼴 · 같은
  # 코드(`OAuthErrorCode.carried`)이고, 본문의 나머지(access_token · active)는 쓰지 않는다. 수정 전(실측): 그랜트의 B1 은 코드
  # 없는 「unusable token response (RuntimeError)」, B2 는 실린 토큰을 돌려줬고, introspection 의 B2 는 active=true 였다.
  # 보내는 비밀은 코드와 겹치지 않게 골랐다 — 겹치면 코드를 뺀다(`oauth_error_code_echo_spec`).
  describe "a success-status OAuth error (success_status_oauth_error)" do
    token_bodies = {
      "B1" => '{"error":"invalid_grant","error_description":"d"}',
      "B2 with a token" => '{"error":"invalid_grant","access_token":"eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ4In0.' \
                           'c2lnbmF0dXJlLXZhbHVl","token_type":"Bearer","expires_in":300}'
    }
    introspection_bodies = {
      "B1" => '{"error":"invalid_token"}',
      "B2 with active" => '{"error":"invalid_token","active":true}'
    }

    def answer(url, body)
      stub_request(:post, url).to_return(status: 200, body: body, headers: { "Content-Type" => "application/json" })
    end

    # B2 의 토큰 — 오류의 어느 표현에도 없어야 한다.
    def jwt
      "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ4In0.c2lnbmF0dXJlLXZhbHVl"
    end

    {
      "client_credentials_token" => ["client-credentials", lambda(&:client_credentials_token)],
      "access_token" => ["client-credentials", lambda(&:access_token)],
      "refresh" => ["refresh", ->(a) { a.refresh(refresh_token: "RT-opaque-refresh") }],
      "exchange_code" => ["authorization_code exchange", lambda { |a|
        a.exchange_code(code: "AUTH-CODE-1234", code_verifier: "pkce-verifier-0123456789-abcdefghijklmnopqrstuvwxyz",
                        redirect_uri: "https://app/cb")
      }]
    }.each do |lane, (operation, call)|
      token_bodies.each do |name, body|
        it "fails #{lane} on HTTP 200 #{name} as on an error status, no token returned (success-status OAuth error)" do
          answer(token_url, body)
          expect { call.call(auth) }.to raise_error(KeycloakSdk::AuthError) do |e|
            expect([e.message, e.oauth_error]).to eq(["#{operation} failed: invalid_grant (HTTP 200)", "invalid_grant"])
            expect(e.full_message(highlight: false)).not_to include(jwt)
          end
        end
      end
    end

    introspection_bodies.each do |name, body|
      it "fails introspect on HTTP 200 #{name} with the code, never active (success-status OAuth error)" do
        answer(introspect_url, body)
        expect { auth.introspect("AT-introspected-token") }.to raise_error(KeycloakSdk::AuthError) do |e|
          expect([e.message, e.oauth_error]).to eq(["introspection failed: HTTP 200", "invalid_token"])
        end
      end
    end

    # 문자열이 아닌 `error`(수 · 객체 · 배열 · 불리언)도 오류를 이름한다 — 오류 상태처럼 실패하고 코드는 싣지 않는다(등록부
    # token-response-residual-divergence A · 예전에는 대조군이었다: 토큰을 쓰고 활성으로 읽었다).
    [400, { "code" => "invalid_grant" }, ["invalid_grant"], true, false].each do |error|
      it "fails on HTTP 200 with an error member #{error.inspect} that is no String (success-status OAuth error)" do
        answer(token_url, { error: error, access_token: "AT", token_type: "Bearer", expires_in: 300 }.to_json)
        answer(introspect_url, { error: error, active: true }.to_json)
        expect { auth.client_credentials_token }.to raise_error(KeycloakSdk::AuthError) do |e|
          expect([e.message, e.oauth_error])
            .to eq(["client-credentials failed: non-standard error code (HTTP 200)", nil])
        end
        expect { auth.introspect("AT-introspected-token") }.to raise_error(KeycloakSdk::AuthError) do |e|
          expect([e.message, e.oauth_error]).to eq(["introspection failed: HTTP 200", nil])
        end
      end
    end

    # 대조군 — null 이거나 "" 인 `error` 는 예전처럼 보지 않는다.
    ["", nil].each do |error|
      it "ignores an error member #{error.inspect} on HTTP 200, as before (success-status OAuth error control)" do
        answer(token_url, { error: error, access_token: "AT", token_type: "Bearer", expires_in: 300 }.to_json)
        answer(introspect_url, { error: error, active: true }.to_json)
        expect(auth.client_credentials_token.access_token).to eq("AT")
        expect(auth.introspect("AT-introspected-token").active?).to be(true)
      end
    end
  end

  # 그랜트 메시지에서 싣지 않은 코드의 자리(등록부 auth-error-message-misnames) — 그 응답이 코드를 보냈는가만 말한다. `error` 가
  # 없거나 비었으면(객체가 아닌 본문 포함) 「no OAuth error code」, 보냈으나 `OAuthErrorCode.carried` 가 뺀 값이면
  # 「non-standard error code」 다. 수정 전: 코드 없는 503 HTML 도 후자였다(rack-oauth2 의 'Unknown' 을 서버의 코드처럼 읽었다).
  # 시크릿 `sekret` 은 코드 모양이다 — 그 되울림은 모양이 아니라 겹침이 뺀다.
  describe "a grant error response that carries no code to show (auth-error-message-misnames)" do
    json = "application/json"
    none = "no OAuth error code"
    withheld = "non-standard error code"
    {
      "503 HTML" => [503, "text/html", "<html><body>503 Service Unavailable</body></html>", none, nil],
      "503 empty body" => [503, json, "", none, nil],
      "400 JSON without error" => [400, json, '{"error_description":"d"}', none, nil],
      "400 JSON error null" => [400, json, '{"error":null}', none, nil],
      "400 JSON error empty" => [400, json, '{"error":""}', none, nil],
      "400 JSON error not code-shaped" => [400, json, '{"error":"Invalid-Grant"}', withheld, nil],
      "400 JSON error a number" => [400, json, '{"error":400}', withheld, nil],
      "401 JSON error echoing the client secret" => [401, json, '{"error":"sekret"}', withheld, nil],
      "400 JSON invalid_grant (control)" => [400, json, '{"error":"invalid_grant"}', "invalid_grant", "invalid_grant"]
    }.each do |name, (status, type, body, shown, code)|
      {
        "client_credentials_token" => ["client-credentials", lambda(&:client_credentials_token)],
        "refresh" => ["refresh", ->(a) { a.refresh(refresh_token: "RT-opaque-refresh") }],
        "exchange_code" => ["authorization_code exchange", lambda { |a|
          a.exchange_code(code: "AUTH-CODE-1234", code_verifier: "pkce-verifier-0123456789-abcdefghijklmnopqrstuvwxyz",
                          redirect_uri: "https://app/cb")
        }]
      }.each do |lane, (operation, call)|
        it "says #{shown.inspect} on #{lane} for #{name}" do
          stub_request(:post, token_url).to_return(status: status, body: body, headers: { "Content-Type" => type })
          expect { call.call(auth) }.to raise_error(KeycloakSdk::AuthError) do |e|
            expect([e.message, e.oauth_error]).to eq(["#{operation} failed: #{shown} (HTTP #{status})", code])
          end
        end
      end
    end
  end

  # rack-oauth2 의 HTTP 설정은 프로세스 전역이고 먼저 건 쪽이 이긴다(`@@http_config ||= block`) — SDK 가 걸면 호스트
  # 앱이 나중에 건 블록이 조용히 버려진다. SDK 의 요청은 그 연결을 타지 않으므로(`host_http_config_spec.rb`) 걸지 않는다.
  describe "rack-oauth2's process-global http_config" do
    before { Rack::OAuth2.reset_http_config! }
    after { Rack::OAuth2.reset_http_config! }

    it "is left to the host: a block set after constructing the client is the one rack-oauth2 uses",
       :aggregate_failures do
      described_class.new(
        config: KeycloakSdk::Config.new(server_url: "https://kc", realm: "r", client_id: "c",
                                        connect_timeout: 3, read_timeout: 7),
        http: http, jwt_validator: jwt_validator
      )
      host_ran = []
      Rack::OAuth2.http_config { |conn| host_ran << (conn.options.timeout = 42) }
      conn = Rack::OAuth2.http_client
      expect(host_ran).to eq([42])
      expect([conn.options.open_timeout, conn.options.timeout]).to eq([nil, 42]) # Config 의 3·7 이 아니다
    end
  end
end
