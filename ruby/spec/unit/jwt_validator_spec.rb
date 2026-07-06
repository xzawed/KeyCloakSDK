# frozen_string_literal: true

require "spec_helper"
require "jwt"
require "openssl"

# rubocop:disable RSpec/MultipleMemoizedHelpers -- fixture-heavy hardening spec (RSA key/kid/config/http/store)
RSpec.describe KeycloakSdk::JwtValidator do
  subject(:validator) { described_class.from_config(config: config, jwks_store: jwks_store) }

  let(:rsa) { OpenSSL::PKey::RSA.generate(2048) }
  let(:kid) { "test-key-1" }
  let(:issuer) { "https://kc.example.com/realms/demo" }
  let(:audience) { "app" }
  let(:jwks_url) { "https://kc.example.com/realms/demo/protocol/openid-connect/certs" }
  let(:config) do
    KeycloakSdk::Config.new(server_url: "https://kc.example.com", realm: "demo",
                            client_id: audience, clock_skew: 30)
  end
  let(:http) { KeycloakSdk::Http.build(config) { |f| f.response :json } }
  let(:jwks_store) { KeycloakSdk::JwksStore.new(jwks_url: jwks_url, http: http) }

  def jwk_hash
    JWT::JWK.new(rsa, kid: kid).export # public JWK
  end

  def stub_jwks
    stub_request(:get, jwks_url).to_return(status: 200, body: { keys: [jwk_hash] }.to_json,
                                           headers: { "Content-Type" => "application/json" })
  end

  def sign(claims, key: rsa, alg: "RS256", header: { kid: kid })
    JWT.encode(claims, key, alg, header)
  end

  def base_claims(**over)
    now = Time.now.to_i
    { "sub" => "user-1", "iss" => issuer, "aud" => audience, "exp" => now + 300,
      "iat" => now }.merge(over.transform_keys(&:to_s))
  end

  before { stub_jwks }

  it "accepts a valid RS256 token and maps claims" do
    vt = validator.validate(sign(base_claims))
    expect(vt).to be_a(KeycloakSdk::ValidatedToken)
    expect(vt.subject).to eq("user-1")
    expect(vt.issuer).to eq(issuer)
    expect(vt.audience).to include(audience)
  end

  it "accepts an array aud containing our client_id" do
    vt = validator.validate(sign(base_claims("aud" => ["other-svc", audience])))
    expect(vt.audience).to include(audience)
  end

  it "rejects alg:none" do
    tok = JWT.encode(base_claims, nil, "none")
    expect { validator.validate(tok) }.to raise_error(KeycloakSdk::TokenValidationError)
  end

  it "rejects alg-confusion (HS256 with public modulus as secret is impossible)" do
    tok = JWT.encode(base_claims, "secret", "HS256", { kid: kid })
    expect { validator.validate(tok) }.to raise_error(KeycloakSdk::TokenValidationError)
  end

  it "rejects a wrong issuer" do
    expect { validator.validate(sign(base_claims("iss" => "https://evil.example"))) }
      .to raise_error(KeycloakSdk::TokenValidationError)
  end

  it "rejects an aud that lacks our client_id" do
    expect { validator.validate(sign(base_claims("aud" => "someone-else"))) }
      .to raise_error(KeycloakSdk::TokenValidationError)
  end

  it "rejects an expired token" do
    expect { validator.validate(sign(base_claims("exp" => Time.now.to_i - 100))) }
      .to raise_error(KeycloakSdk::TokenValidationError)
  end

  it "rejects a token missing exp (required_claims)" do
    claims = base_claims
    claims.delete("exp")
    expect { validator.validate(sign(claims)) }.to raise_error(KeycloakSdk::TokenValidationError)
  end

  it "rejects a not-yet-valid token (nbf in the future)" do
    expect { validator.validate(sign(base_claims("nbf" => Time.now.to_i + 300))) }
      .to raise_error(KeycloakSdk::TokenValidationError)
  end

  it "rejects a bad signature WITHOUT re-fetching JWKS (known kid)" do
    other = OpenSSL::PKey::RSA.generate(2048)
    tok = sign(base_claims, key: other) # different key, same kid
    expect { validator.validate(tok) }.to raise_error(KeycloakSdk::TokenValidationError)
    expect(a_request(:get, jwks_url)).to have_been_made.once # cold load only, no forged-sig re-fetch
  end

  it "honors clock skew (30s): 20s-expired passes, 40s-expired fails" do
    expect(validator.validate(sign(base_claims("exp" => Time.now.to_i - 20))))
      .to be_a(KeycloakSdk::ValidatedToken)
    expect { validator.validate(sign(base_claims("exp" => Time.now.to_i - 40))) }
      .to raise_error(KeycloakSdk::TokenValidationError)
  end
end
# rubocop:enable RSpec/MultipleMemoizedHelpers
