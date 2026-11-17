# frozen_string_literal: true

require "spec_helper"
require "jwt"
require "openssl"

# 공개 id_token 검증 — `AuthClient#validate_id_token`(등록부 id-token-validator-not-public). 교환이 nonce 를 견주기 **전에**
# 돌리는 그 검사다(같은 `JwtValidator#validate_id_token` 하나): 서명(`validate` 와 같은 키 저장소) · alg 핀 · 길이 상한 · iss ·
# aud ∋ client_id(`expected_audience` 가 아니다) · exp · 클록 스큐 · 종류(payload typ 이 정확히 "ID") · azp(OIDC Core
# §3.1.3.7 4–5 단계). nonce 는 보지 않는다. 실패는 `validate` 와 같은 TokenValidationError 다.
# ⚠️ 검증기·키 저장소는 목이 아니라 파사드가 조립한 **실물**이다 — 키 저장소의 공유는 실물로만 잴 수 있다.
RSpec.describe KeycloakSdk::AuthClient, "#validate_id_token" do
  let(:config) do
    KeycloakSdk::Config.new(server_url: "https://kc.example.com", realm: "demo", client_id: "app",
                            client_secret: "sekret")
  end
  let(:client) { KeycloakSdk::KeycloakClient.new(config) }
  let(:realm_key) { OpenSSL::PKey::RSA.generate(2048) }
  let(:not_id_token) { 'JWT validation failed: not an id_token (typ is not "ID")' }

  before do
    stub_request(:get, certs_url)
      .to_return(status: 200, body: { keys: [JWT::JWK.new(realm_key, kid: "realm-key").export] }.to_json,
                 headers: { "Content-Type" => "application/json" })
  end

  after { client.close }

  def certs_url
    "https://kc.example.com/realms/demo/protocol/openid-connect/certs"
  end

  # Keycloak 이 내는 id_token 모양 — typ "ID", aud 와 azp 가 client_id. `drop` 의 클레임은 뺀다(nil 은 JSON null 로 남는다).
  def id_token(drop: [], **over)
    now = Time.now.to_i
    claims = { "sub" => "user-1", "iss" => "https://kc.example.com/realms/demo", "aud" => "app", "typ" => "ID",
               "azp" => "app", "exp" => now + 300, "iat" => now, "nonce" => "n-abc" }.merge(over.transform_keys(&:to_s))
    JWT.encode(claims.except(*drop), realm_key, "RS256", { kid: "realm-key" })
  end

  def exchange(token, via: client)
    stub_request(:post, "https://kc.example.com/realms/demo/protocol/openid-connect/token")
      .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                 body: { access_token: "AT", token_type: "Bearer", expires_in: 300, id_token: token }.to_json)
    via.auth.exchange_code(code: "c", code_verifier: "v", redirect_uri: "https://app/cb", expected_nonce: "n-abc")
  end

  it "accepts the id_token Keycloak issues and returns its claims" do
    vt = client.auth.validate_id_token(id_token)
    expect(vt).to be_a(KeycloakSdk::ValidatedToken)
    expect([vt.subject, vt.issuer, vt.audience]).to eq(["user-1", "https://kc.example.com/realms/demo", ["app"]])
    expect(vt.claims.slice("typ", "azp", "nonce")).to eq("typ" => "ID", "azp" => "app", "nonce" => "n-abc")
  end

  # 이 규칙이 닫는 틈 — aud 에 client_id 가 있고 azp 가 client_id 인 접근 토큰은 종류 말고는 id_token 검사를 전부 지난다.
  it "refuses an access token issued to the client (typ Bearer) with the constant message" do
    token = id_token("typ" => "Bearer", "aud" => %w[app account])
    expect(client.auth.validate(token).audience).to eq(%w[app account]) # 전제: 접근 검증은 받는다
    expect { client.auth.validate_id_token(token) }
      .to raise_error(KeycloakSdk::TokenValidationError, not_id_token) { |e| expect(e.cause).to be_nil }
  end

  it "refuses a token without typ" do
    expect { client.auth.validate_id_token(id_token(drop: ["typ"])) }
      .to raise_error(KeycloakSdk::TokenValidationError, not_id_token)
  end

  # 허용 목록 — "ID" 와 (대소문자 · 공백까지) 다른 문자열과 문자열이 아닌 값은 전부 거부다. 문구는 상수다 — 토큰이 고른
  # typ 를 싣지 않는다(토큰이 고른 문자열 칸의 값이 문구에 없다).
  refused_typs = ["bearer", "id", "ID ", "", "Refresh", "Serialized-ID", "CANARY-TYP-0f3a", 1, nil, ["ID"],
                  { "typ" => "ID" }]
  refused_typs.each do |typ|
    it "refuses typ #{typ.inspect} with the constant message" do
      expect { client.auth.validate_id_token(id_token("typ" => typ)) }
        .to raise_error(KeycloakSdk::TokenValidationError, not_id_token)
    end
  end

  it "refuses a back-channel logout token (typ Logout · aud the client_id · no azp · exp)" do
    logout = id_token("typ" => "Logout", "sid" => "s-1",
                      "events" => { "http://schemas.openid.net/event/backchannel-logout" => {} },
                      drop: %w[azp nonce])
    expect { client.auth.validate_id_token(logout) }.to raise_error(KeycloakSdk::TokenValidationError, not_id_token)
  end

  {
    "several audiences without azp" => [{ "aud" => %w[app evil] }, %w[azp],
                                        "azp is required when aud has more than one value"],
    "azp another client" => [{ "azp" => "evil" }, [], "azp does not match the client id"],
    "a wrong issuer" => [{ "iss" => "https://evil.example" }, [], "Invalid issuer"],
    "an expired token (outside the 30s skew)" => [{ "exp" => Time.now.to_i - 40 }, [], "Signature has expired"]
  }.each do |name, (over, drop, reason)|
    it "keeps the exchange's check: refuses #{name}" do
      expect { client.auth.validate_id_token(id_token(drop: drop, **over)) }
        .to raise_error(KeycloakSdk::TokenValidationError, /\AJWT validation failed: #{Regexp.escape(reason)}/)
    end
  end

  context "with an expected_audience override" do
    let(:config) do
      KeycloakSdk::Config.new(server_url: "https://kc.example.com", realm: "demo", client_id: "app",
                              client_secret: "sekret", expected_audience: "my-api")
    end

    it "holds aud to the client_id, not the override" do
      expect { client.auth.validate_id_token(id_token("aud" => "my-api")) }
        .to raise_error(KeycloakSdk::TokenValidationError, /Invalid audience\. Expected app,/)
      expect(client.auth.validate_id_token(id_token).audience).to eq(["app"]) # 대조: aud = client_id 는 받는다
    end
  end

  describe "one path with the exchange" do
    # 교환과 공개 메서드는 같은 함수다 — 종류 규칙이 교환에도 걸리고, 교환의 대응(invalid id_token)은 그대로다.
    [{ drop: ["typ"] }, { "typ" => "Bearer" }].each do |shape|
      it "refuses #{shape.inspect} in the exchange too, mapped to invalid id_token" do
        token = id_token(**shape)
        mapped = "authorization_code exchange failed: invalid id_token: #{not_id_token}"
        expect { exchange(token) }.to raise_error(KeycloakSdk::AuthError, mapped)
        expect { client.auth.validate_id_token(token) }.to raise_error(KeycloakSdk::TokenValidationError, not_id_token)
      end
    end

    it "shares the key store with validate and the exchange (one JWKS fetch)" do
      client.auth.validate_id_token(id_token)
      client.auth.validate(id_token("typ" => "Bearer"))
      exchange(id_token)
      client.auth.validate_id_token(id_token)
      expect(a_request(:get, certs_url)).to have_been_made.once
    end

    # 대조군 — 저장소가 둘이면 같은 순서가 두 번 받는다. 위 「once」 가 두 번째 저장소를 볼 수 있다는 증거다.
    it "fetches twice when a second store exists (control)" do
      other = KeycloakSdk::KeycloakClient.new(config)
      client.auth.validate_id_token(id_token)
      other.auth.validate_id_token(id_token)
      expect(a_request(:get, certs_url)).to have_been_made.twice
    ensure
      other&.close
    end
  end
end
