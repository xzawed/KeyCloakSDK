# frozen_string_literal: true

require "spec_helper"
require "jwt"
require "openssl"

# 공개 `AuthClient#validate` 의 종류 판정(등록부 access-token-typ-deny-list) — Keycloak 자신의 리소스 쪽 검사처럼 허용
# 목록이다: 페이로드 typ 이 ASCII 대소문자를 무시하고 Bearer 나 DPoP 와 같은 String 일 때만 받는다. 기본 설정(기대 aud =
# client_id)에서 typ 이 없는 realm 서명 JWT — JARM 인가 응답(aud = client_id) — 가 접근 토큰으로 받아들여지던 틈이다.
# 검증기 칸은 `jwt_validator_spec.rb` 다. ⚠️ 검증기 · 키 저장소는 목이 아니라 파사드가 조립한 **실물**이다.
RSpec.describe KeycloakSdk::AuthClient, "#validate — access token kind (typ allow-list)" do
  let(:client) do
    KeycloakSdk::KeycloakClient.new(
      KeycloakSdk::Config.new(server_url: "https://kc.example.com", realm: "demo", client_id: "app",
                              client_secret: "sekret")
    )
  end
  let(:realm_key) { OpenSSL::PKey::RSA.generate(2048) }
  let(:not_access) { "JWT validation failed: not an access token (typ is not Bearer or DPoP)" }

  before do
    stub_request(:get, "https://kc.example.com/realms/demo/protocol/openid-connect/certs")
      .to_return(status: 200, body: { keys: [JWT::JWK.new(realm_key, kid: "realm-key").export] }.to_json,
                 headers: { "Content-Type" => "application/json" })
  end

  after { client.close }

  # realm 키로 서명한 접근 토큰 모양 — `drop` 의 클레임은 뺀다(nil 은 JSON null 로 남는다).
  def token(drop: [], **over)
    now = Time.now.to_i
    claims = { "sub" => "user-1", "iss" => "https://kc.example.com/realms/demo", "aud" => "app", "typ" => "Bearer",
               "exp" => now + 300, "iat" => now }.merge(over.transform_keys(&:to_s))
    JWT.encode(claims.except(*drop), realm_key, "RS256", { kid: "realm-key" })
  end

  %w[Bearer bearer DPoP dpop].each do |typ|
    it "accepts typ #{typ.inspect}" do
      vt = client.auth.validate(token("typ" => typ))
      expect([vt.subject, vt.audience, vt.claims["typ"]]).to eq(["user-1", ["app"], typ])
    end
  end

  it "refuses a JARM authorization response (no typ · code · state · aud the client_id) with the constant message" do
    jarm = token("code" => "c0de-from-the-browser-url", "state" => "st-1", drop: %w[typ sub])
    expect { client.auth.validate(jarm) }.to raise_error(KeycloakSdk::TokenValidationError, not_access)
  end

  it "refuses a token without typ with the constant message" do
    expect { client.auth.validate(token(drop: ["typ"])) }
      .to raise_error(KeycloakSdk::TokenValidationError, not_access)
  end

  ["at+jwt", "CANARY-TYP-7c2e", 1, nil, ["Bearer"]].each do |typ|
    it "refuses typ #{typ.inspect} with the constant message (the value is not echoed)" do
      expect { client.auth.validate(token("typ" => typ)) }
        .to raise_error(KeycloakSdk::TokenValidationError, not_access)
    end
  end

  %w[ID Refresh Offline Logout Serialized-ID].each do |typ|
    it "keeps today's message for the known kind #{typ}" do
      want = "JWT validation failed: not an access token (typ \"#{typ}\")"
      expect { client.auth.validate(token("typ" => typ)) }.to raise_error(KeycloakSdk::TokenValidationError, want)
    end
  end
end
