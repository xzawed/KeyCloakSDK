# frozen_string_literal: true

require "spec_helper"
require "jwt"
require "openssl"

# rubocop:disable-next RSpec/MultipleMemoizedHelpers -- fixture-heavy hardening spec (RSA key/kid/config/http/store)
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

  describe "expected_audience (stock realms do not put client_id in a client-credentials aud)" do
    let(:api_audience) { "my-api" } # resource aud, distinct from client_id

    context "when unset" do
      it "keeps client_id as the expected aud" do
        expect(validator.validate(sign(base_claims)).audience).to include(audience)
        expect { validator.validate(sign(base_claims("aud" => api_audience))) }
          .to raise_error(KeycloakSdk::TokenValidationError)
      end
    end

    context "when set" do
      let(:config) do
        KeycloakSdk::Config.new(server_url: "https://kc.example.com", realm: "demo",
                                client_id: audience, clock_skew: 30, expected_audience: api_audience)
      end

      it "expects that value instead of client_id" do
        expect(validator.validate(sign(base_claims("aud" => [api_audience, "account"]))).audience)
          .to include(api_audience)
        expect { validator.validate(sign(base_claims)) } # aud carries client_id only
          .to raise_error(KeycloakSdk::TokenValidationError)
      end

      # id_token 경로 — OIDC Core §2·§3.1.3.7 의 `aud` 는 client_id 다. 재정의는 액세스 토큰(리소스 서버)의 것이다.
      it "checks a per-call audience instead of the override" do
        expect(validator.validate(sign(base_claims), audience: audience).audience).to eq([audience])
        expect { validator.validate(sign(base_claims("aud" => api_audience)), audience: audience) }
          .to raise_error(KeycloakSdk::TokenValidationError, /audience/i)
      end

      it "shares one key cache between the default and a per-call audience" do
        validator.validate(sign(base_claims("aud" => api_audience)))
        validator.validate(sign(base_claims), audience: audience)
        expect(a_request(:get, jwks_url)).to have_been_made.once
      end
    end
  end

  # ⚠️ ruby-jwt 는 `aud: nil` 이면 aud 검사를 **통째로 건너뛴다**(3.3.0 실측: 다른 aud 를 통과시킨다).
  # 생성자와 같은 fail-closed 가드가 호출별 audience 에도 있어야 한다.
  describe "per-call audience guard" do
    [nil, "", "  "].each do |blank|
      it "raises ConfigError for audience: #{blank.inspect} before any JWKS request" do
        token = sign(base_claims("aud" => "someone-else"))
        expect { validator.validate(token, audience: blank) }.to raise_error(KeycloakSdk::ConfigError, /audience/)
        expect(a_request(:get, jwks_url)).not_to have_been_made
      end
    end
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

  describe "constructor guards (defense-in-depth against silent verify_iss/verify_aud no-ops)" do
    it "raises ConfigError when issuer is nil" do
      expect do
        described_class.new(issuer: nil, audience: audience, jwks_store: jwks_store)
      end.to raise_error(KeycloakSdk::ConfigError, /issuer/)
    end

    it "raises ConfigError when audience is nil" do
      expect do
        described_class.new(issuer: issuer, audience: nil, jwks_store: jwks_store)
      end.to raise_error(KeycloakSdk::ConfigError, /audience/)
    end
  end

  describe "JWKS nil-guard (rate-limited cold-cache forced refetch)" do
    let(:double_store) { instance_double(KeycloakSdk::JwksStore) }
    let(:double_validator) do
      described_class.new(issuer: issuer, audience: audience, jwks_store: double_store)
    end

    it "raises TokenValidationError (not NoMethodError) when a forced refetch returns nil" do
      allow(double_store).to receive(:key_set).with(force: false).and_return({ "keys" => [] })
      allow(double_store).to receive(:key_set).with(force: true).and_return(nil)

      expect { double_validator.validate(sign(base_claims)) }
        .to raise_error(KeycloakSdk::TokenValidationError)
    end
  end
end
