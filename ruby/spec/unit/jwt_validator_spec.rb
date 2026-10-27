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

  # 받는 토큰의 길이 상한(inbound-token-cap) — 나누기·디코드·JWKS 적재보다 먼저 거부한다.
  describe "bounded token input" do
    let(:cap) { 256_000 } # `JWT_MAX_BYTES` 는 private_constant 다 — 공개 표면을 늘리지 않는다

    # `pad` 클레임을 덧대 길이가 [length - 8, length] 인 진짜 서명 토큰(역할이 많은 사용자의 모양).
    def padded(length)
      n = (length - sign(base_claims).bytesize) * 3 / 4
      n -= 1 while sign(base_claims("pad" => "a" * n)).bytesize > length
      sign(base_claims("pad" => "a" * n))
    end

    # T1 — 디코드가 먼저 돌면 ruby-jwt 의 디코드 오류로 나와 `exceeds` 를 말하지 않는다(순서까지 고정한다).
    it "rejects a token over the cap before decoding it" do
      over = "#{'a' * (cap - 1)}.."
      expect(over.bytesize).to eq(cap + 1)
      expect { validator.validate(over) }
        .to raise_error(KeycloakSdk::TokenValidationError, "JWT validation failed: token exceeds 256000 bytes")
    end

    # ⚠️ 요청 수는 **진짜 서명** 토큰으로 잰다 — 쓰레기는 상한이 없어도 ruby-jwt 가 헤더에서 거부해 키를 찾지
    # 않으므로 「JWKS 요청 0」이 저절로 참이다. 이 토큰은 상한이 없으면 디코드되고 키를 찾고 통과한다.
    it "rejects a signed token over the cap without a JWKS request (control: a normal one fetches)" do
      over = padded(cap + 9)
      expect(over.bytesize).to be > cap
      expect { validator.validate(over) }
        .to raise_error(KeycloakSdk::TokenValidationError, "JWT validation failed: token exceeds 256000 bytes")
      expect(a_request(:get, jwks_url)).not_to have_been_made

      validator.validate(sign(base_claims)) # 같은 콜드 저장소 — 계수기가 그 적재를 본다
      expect(a_request(:get, jwks_url)).to have_been_made.once
    end

    # T2 — 상한 길이의 쓰레기는 상한이 아니라 디코더가 거부한다(`>` 이지 `>=` 가 아니다).
    it "leaves a token at the cap to the decoder" do
      at_cap = "#{'a' * (cap - 2)}.."
      expect(at_cap.bytesize).to eq(cap)
      expect { validator.validate(at_cap) }
        .to raise_error(KeycloakSdk::TokenValidationError) { |e| expect(e.message).not_to include("exceeds") }
    end

    # T3 — 상한은 정상 토큰을 거부하지 않는다.
    { "the longest bearer Keycloak 26.6 accepts by default" => 65_459, "the cap" => 256_000 }.each do |name, length|
      it "still validates a signed token padded to #{name}" do
        token = padded(length)
        expect(token.bytesize).to be_between(length - 8, length)
        expect(validator.validate(token).subject).to eq("user-1")
      end
    end

    it "leaves a value that is not a String to ruby-jwt (an SDK error, not NoMethodError)" do
      expect { validator.validate(nil) }.to raise_error(KeycloakSdk::TokenValidationError, /Nil JSON web token/)
    end
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
