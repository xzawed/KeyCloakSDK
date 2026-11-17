# frozen_string_literal: true

require "spec_helper"
require "jwt"
require "openssl"

# 코드 교환의 id_token — 종류(typ)와 권한 부여 당사자(azp). `validate` 는 접근 토큰이 아닌 종류(ID · Refresh · Offline ·
# Logout · Serialized-ID)를 거부한다(`jwt_validator_spec.rb`). 교환이 검증하는 id_token 은 Keycloak 이 typ "ID" 로 적으므로
# 그 검사를 받지 않고, 대신 azp 를 client_id 와 견준다(OIDC Core §3.1.3.7 4–5 단계: aud 가 여럿이면 azp 가 있어야 하고,
# azp 가 있으면 client_id 여야 한다).
# ⚠️ 검증기는 목이 아니라 파사드가 조립한 **실물**이다 — `auth_client_spec.rb` 의 nonce 예제는 `instance_double` 검증기라
# 검사를 건너뛰는 변이를 못 본다.
RSpec.describe KeycloakSdk::AuthClient, "#exchange_code — id_token type and authorized party" do
  let(:client) do
    KeycloakSdk::KeycloakClient.new(
      KeycloakSdk::Config.new(server_url: "https://kc.example.com", realm: "demo",
                              client_id: "app", client_secret: "sekret")
    )
  end
  let(:realm_key) { OpenSSL::PKey::RSA.generate(2048) }

  before do
    stub_request(:get, "https://kc.example.com/realms/demo/protocol/openid-connect/certs")
      .to_return(status: 200, body: { keys: [JWT::JWK.new(realm_key, kid: "realm-key").export] }.to_json,
                 headers: { "Content-Type" => "application/json" })
  end

  after { client.close }

  # Keycloak 이 내는 모양 — typ "ID", aud 와 azp 가 client_id. 값이 nil 인 클레임은 뺀다.
  def id_token(**over)
    now = Time.now.to_i
    claims = { "sub" => "user-1", "iss" => "https://kc.example.com/realms/demo", "aud" => "app", "typ" => "ID",
               "azp" => "app", "exp" => now + 300, "iat" => now, "nonce" => "n-abc" }.merge(over.transform_keys(&:to_s))
    JWT.encode(claims.compact, realm_key, "RS256", { kid: "realm-key" })
  end

  def exchange(token)
    stub_request(:post, "https://kc.example.com/realms/demo/protocol/openid-connect/token")
      .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                 body: { access_token: "AT", token_type: "Bearer", expires_in: 300, id_token: token }.to_json)
    client.auth.exchange_code(code: "c", code_verifier: "v", redirect_uri: "https://app/cb", expected_nonce: "n-abc")
  end

  it "accepts the id_token Keycloak issues, typed ID" do
    expect(exchange(id_token).access_token).to eq("AT")
  end

  it "refuses that id_token on the access path (validate)" do
    expect { client.auth.validate(id_token) }
      .to raise_error(KeycloakSdk::TokenValidationError, 'JWT validation failed: not an access token (typ "ID")')
  end

  {
    "one audience without azp" => { "azp" => nil },
    "several audiences with azp the client_id" => { "aud" => %w[app other-client] }
  }.each do |name, over|
    it "accepts #{name}" do
      expect(exchange(id_token(**over)).access_token).to eq("AT")
    end
  end

  # 둘째 칸은 python 재현이 통과시킨 모양이다(aud ["web","evil"] · azp "evil").
  {
    "one audience, azp another client" => [{ "azp" => "evil" }, "azp does not match the client id"],
    "several audiences, azp another client" => [{ "aud" => %w[app evil], "azp" => "evil" },
                                                "azp does not match the client id"],
    "several audiences without azp" => [{ "aud" => %w[app evil], "azp" => nil },
                                        "azp is required when aud has more than one value"]
  }.each do |name, (over, reason)|
    it "refuses #{name}" do
      expect { exchange(id_token(**over)) }
        .to raise_error(KeycloakSdk::AuthError,
                        "authorization_code exchange failed: invalid id_token: JWT validation failed: #{reason}")
    end
  end
end
