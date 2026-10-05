# frozen_string_literal: true

require "spec_helper"
require "jwt"
require "openssl"
require "base64"
require_relative "../support/unsendable"

# 검증 경로의 디코드 경계 — 잘못된 UTF-8 토큰과 잘못된 UTF-8 로 풀리는 JWKS 는 raw 예외가 아니라 SDK 오류다.
# 잠긴 json 3.0.2 도 날 잘못된 UTF-8 바이트(0xFF)는 받아들인다 — JWKS 의 n·e 가 그러면 ruby-jwt 의 base64 가 검증 중에
# raw ArgumentError 를 냈다(실측).
RSpec.describe KeycloakSdk::JwtValidator do
  let(:key) { OpenSSL::PKey::RSA.generate(2048) }
  let(:jwks_url) { "#{UnsendableTokenSpec::OIDC}/certs" }
  let(:validator) do
    config = KeycloakSdk::Config.new(server_url: UnsendableTokenSpec::SERVER, realm: "r", client_id: "c")
    store = KeycloakSdk::JwksStore.new(jwks_url: jwks_url, http: KeycloakSdk::Http.build(config))
    described_class.from_config(config: config, jwks_store: store)
  end

  def jwk_text(n_suffix = "")
    enc = ->(bn) { Base64.urlsafe_encode64(bn.to_s(2), padding: false) }
    %({"keys":[{"kty":"RSA","kid":"k1","use":"sig","alg":"RS256","n":"#{enc.call(key.n)}#{n_suffix}",) +
      %("e":"#{enc.call(key.e)}"}]})
  end

  def signed
    now = Time.now.to_i
    JWT.encode({ iss: "#{UnsendableTokenSpec::SERVER}/realms/r", aud: "c", sub: "u-1", iat: now, exp: now + 300 },
               key, "RS256", { kid: "k1" })
  end

  # ruby-jwt 는 맨 먼저 토큰을 `split` 한다 — 잘못된 UTF-8 이면 raw ArgumentError(실측, 수정 전).
  it "rejects a token that is not valid UTF-8 with TokenValidationError" do
    expect { validator.validate(UnsendableTokenSpec::BAD) }
      .to raise_error(KeycloakSdk::TokenValidationError, "JWT validation failed: token is not valid UTF-8")
  end

  it "refuses a JWKS that is not valid UTF-8 as unparsable, instead of letting ruby-jwt raise" do
    stub_request(:get, jwks_url).to_return(status: 200, headers: UnsendableTokenSpec::JSON_TYPE,
                                           body: [jwk_text(0xFF.chr)].join.b)
    expect { validator.validate(signed) }
      .to raise_error(KeycloakSdk::TransportError, "JWKS response unparsable (JSON::ParserError)")
  end

  it "still validates against a clean JWKS (control)" do
    stub_request(:get, jwks_url).to_return(status: 200, headers: UnsendableTokenSpec::JSON_TYPE, body: jwk_text)
    expect(validator.validate(signed).subject).to eq("u-1")
  end
end
