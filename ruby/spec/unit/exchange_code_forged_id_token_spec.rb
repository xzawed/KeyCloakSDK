# frozen_string_literal: true

require "spec_helper"
require "jwt"
require "openssl"

# 위조 id_token — nonce 는 맞고 iss·aud·exp 도 맞지만, realm JWKS 밖의 키로 RS256 서명했다. 실서버는 자기 키로만
# 서명하므로 이 토큰을 만들 수 없다 — 통합(`spec/integration/code_exchange_spec.rb`)이 못 덮는 자리를 여기서 고정한다.
# ⚠️ 검증기는 목이 아니라 **실물**(파사드가 조립한 JwtValidator·JwksStore)이다. `auth_client_spec.rb` 의 nonce 예제는
# `instance_double` 검증기라 「서명 검증을 건너뛰는」 변이를 못 본다.
RSpec.describe KeycloakSdk::AuthClient, "#exchange_code with a forged RS256 id_token" do
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

  def exchange_with_id_token(id_token)
    stub_request(:post, "https://kc.example.com/realms/demo/protocol/openid-connect/token")
      .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                 body: { access_token: "AT", token_type: "Bearer", expires_in: 300, id_token: id_token }.to_json)
    client.auth.exchange_code(code: "c", code_verifier: "v", redirect_uri: "https://app/cb", expected_nonce: "n-abc")
  end

  def id_token(key, kid)
    now = Time.now.to_i
    claims = { "sub" => "user-1", "iss" => "https://kc.example.com/realms/demo", "aud" => "app",
               "exp" => now + 300, "iat" => now, "nonce" => "n-abc" }
    JWT.encode(claims, key, "RS256", { kid: kid })
  end

  # 대조군 — 같은 클레임을 realm 키로 서명하면 통과한다. 아래 거부가 클레임이 아니라 **키** 때문임을 보인다.
  it "accepts the same claims signed by the realm key (control)" do
    expect(exchange_with_id_token(id_token(realm_key, "realm-key")).access_token).to eq("AT")
  end

  it "rejects a forged signature under the realm's kid" do
    forged = id_token(OpenSSL::PKey::RSA.generate(2048), "realm-key")
    expect { exchange_with_id_token(forged) }
      .to raise_error(KeycloakSdk::AuthError, /\Aauthorization_code exchange failed: invalid id_token: /)
  end

  it "rejects a forged signature under a kid the JWKS does not have" do
    forged = id_token(OpenSSL::PKey::RSA.generate(2048), "forger-key")
    expect { exchange_with_id_token(forged) }
      .to raise_error(KeycloakSdk::AuthError, /\Aauthorization_code exchange failed: invalid id_token: /)
  end
end
