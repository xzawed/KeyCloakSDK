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

  # ⚠️ **못 읽는 원소 하나가 키셋 전체를 버리면 안 된다**(RFC 7517 §5). ruby-jwt 의 `JWT::JWK::Set` 은 모르는 kty 만
  # 건너뛰고, `n` 이 빠진 RSA · kty 없는 원소 · 숫자/null/배열 원소 하나로 키셋 전체를 `JWT::JWKError` 로 거부해 같은 키셋의
  # 정상 키로 서명한 토큰까지 거부됐다(등록부 jwks-unsupported-key-rejects-set). 못 읽는 원소를 **앞**에 둔다.
  describe "JWKS 의 못 읽는 원소" do
    {
      "n 이 빠진 RSA" => { "kty" => "RSA", "kid" => "missingn", "e" => "AQAB" },
      "kty 없는 원소" => { "kid" => "nokty" },
      "숫자 원소" => 1,
      "null 원소" => nil,
      "배열 원소" => [],
      # ⚠️ 아래 둘은 `JWT::JWKError` 가 아닌 예외다(`NoMethodError` · `OpenSSL::PKey::EC::Point::Error`) — 잡는 범위를
      # 좁히면 키셋 전체가 다시 실패한다.
      "n 이 숫자인 RSA(kid 없음)" => { "kty" => "RSA", "n" => 123, "e" => "AQAB" },
      "곡선 위에 없는 EC 점" => { "kty" => "EC", "crv" => "P-256", "kid" => "ec", "x" => "AAAA", "y" => "AAAA" }
    }.each do |name, bad|
      it "#{name} 은 건너뛰고 정상 키로 서명한 토큰이 통과한다" do
        stub_request(:get, jwks_url).to_return(status: 200, body: { keys: [bad, jwk_hash] }.to_json,
                                               headers: { "Content-Type" => "application/json" })
        expect(validator.validate(sign(base_claims)).subject).to eq("user-1")
      end
    end

    # ⚠️ kid 가 있으면 ruby-jwt 는 키 재료를 검증 때까지 미룬다 — 같은 kid 의 기형 키가 앞에 오면 그것이 골라져 날것의
    # `NoMethodError` 가 샜다. 거를 때 재료까지 읽어야 한다(`verify_key`).
    it "같은 kid 의 기형 키가 앞에 있어도 정상 키로 서명한 토큰이 통과한다" do
      bad = { "kty" => "RSA", "kid" => kid, "n" => 123, "e" => "AQAB" }
      stub_request(:get, jwks_url).to_return(status: 200, body: { keys: [bad, jwk_hash] }.to_json,
                                             headers: { "Content-Type" => "application/json" })
      expect(validator.validate(sign(base_claims)).subject).to eq("user-1")
    end
  end

  # ⚠️ **JWKS 의 대칭(`oct`) 키는 검증 키가 아니다** — JWKS 는 공개 문서라 그 안의 대칭 키는 비밀이 아니다. HS256 을 허용한
  # 설정에서 그 키로 서명한 위조 토큰이 통과했다(등록부 jwks-oct-key-usable-with-hs · 아홉 언어 실측은 PR 본문). Keycloak 은
  # oct 를 내지 않는다. kid 없는 칸은 수정 전에도 거부됐다(ruby-jwt 는 kid 로 키를 고른다) — 아홉 언어가 같은 세 모양을 잰다.
  describe "JWKS 의 대칭(oct) 키 — HS256 을 허용한 설정" do
    subject(:hs_validator) { described_class.from_config(config: hs_config, jwks_store: jwks_store) }

    let(:hs_config) do
      KeycloakSdk::Config.new(server_url: "https://kc.example.com", realm: "demo", client_id: audience,
                              clock_skew: 30, signature_algorithms: %w[RS256 HS256])
    end
    let(:secret) { OpenSSL::Random.random_bytes(32) }

    {
      "kid · alg" => [{ "kid" => "hk", "alg" => "HS256", "use" => "sig" }, "hk"],
      "alg 없음" => [{ "kid" => "hk" }, "hk"],
      "kid 없음" => [{ "alg" => "HS256", "use" => "sig" }, nil]
    }.each do |name, (member, oct_kid)|
      it "#{name}: 그 키로 서명한 위조 토큰은 거부되고 같은 키셋의 RSA 토큰은 통과한다" do
        oct = { "kty" => "oct", "k" => [secret].pack("m0").tr("+/", "-_").delete("=") }.merge(member)
        stub_request(:get, jwks_url).to_return(status: 200, body: { keys: [oct, jwk_hash] }.to_json,
                                               headers: { "Content-Type" => "application/json" })
        forged = JWT.encode(base_claims("sub" => "attacker"), secret, "HS256", oct_kid ? { kid: oct_kid } : {})
        expect { hs_validator.validate(forged) }.to raise_error(KeycloakSdk::TokenValidationError)
        expect(hs_validator.validate(sign(base_claims)).subject).to eq("user-1")
      end
    end

    # 고정 — HS 를 허용해도 RSA 공개키 바이트를 HMAC 비밀로 쓴 RS→HS 혼동은 거부된다. 지금은 키를 찾기 전의 HS 거부가
    # 먼저 받는다(아래 「허용된 HS — 키를 찾기 전에 거부」) — 그 뒤의 ruby-jwt 키 종류 · alg 결합은 이 경로에서 닿지 않는
    # 겹친 방어다.
    { "SPKI PEM" => :to_pem, "SPKI DER" => :to_der }.each do |name, encoding|
      it "RSA 공개키(#{name})를 HMAC 비밀로 쓴 토큰은 거부된다" do
        secret = rsa.public_key.public_send(encoding)
        forged = JWT.encode(base_claims("sub" => "attacker"), secret, "HS256", { kid: kid })
        expect { hs_validator.validate(forged) }.to raise_error(KeycloakSdk::TokenValidationError)
      end
    end
  end

  # ⚠️ HS(대칭) 서명은 설정이 허용해도 **키를 찾기 전에** 거부한다(등록부 hs-refusal-rests-on-libraries) — 검증 키는
  # JWKS(공개 문서)에서만 오므로 HMAC 비밀이 될 수 있는 것은 공개된 값뿐이다. kid 는 JWKS 의 RSA 키를 가리키고 저장소는
  # 콜드라 키 조회는 곧 JWKS 요청이다. ruby-jwt 의 핀은 헤더 alg 를 대소문자 없이 견주므로(`valid_alg?` 의 `casecmp`)
  # `hs256` 도 허용된 HS 다. 허용 목록 밖의 HS 는 지금의 길과 문구(ruby-jwt 의 핀)에 남는다.
  describe "허용된 HS — 키를 찾기 전에 거부" do
    subject(:hs_validator) { described_class.from_config(config: hs_config, jwks_store: jwks_store) }

    let(:hs_config) do
      KeycloakSdk::Config.new(server_url: "https://kc.example.com", realm: "demo", client_id: audience,
                              clock_skew: 30, signature_algorithms: %w[RS256 HS256 HS384 HS512])
    end

    def b64url(str)
      [str].pack("m0").tr("+/", "-_").delete("=")
    end

    # 그 alg 로 HMAC 서명한 위조 토큰 — 헤더 alg 를 적힌 그대로 두려고 직접 조립한다(ruby-jwt 는 정규 이름으로 고친다).
    def forged_hs(alg)
      parts = [{ "alg" => alg, "typ" => "JWT", "kid" => kid }, base_claims("sub" => "attacker")]
      input = parts.map { |part| b64url(part.to_json) }.join(".")
      mac = OpenSSL::HMAC.digest(alg.upcase.sub("HS", "SHA"), OpenSSL::Random.random_bytes(64), input)
      "#{input}.#{b64url(mac)}"
    end

    %w[HS256 HS384 HS512 hs256].each do |alg|
      it "#{alg}: JWKS 를 부르지 않고 거부한다 — 같은 검증기의 RS256 토큰은 통과하고 그때 부른다", :aggregate_failures do
        want = "JWT validation failed: algorithm not allowed: #{alg} (a JWKS holds public keys only)"
        expect { hs_validator.validate(forged_hs(alg)) }
          .to raise_error(KeycloakSdk::TokenValidationError, want) { |e| expect(e.cause).to be_nil }
        expect(a_request(:get, jwks_url)).not_to have_been_made
        # 허용 목록 밖이면 지금의 문구 그대로다(ruby-jwt 의 핀).
        expect { validator.validate(forged_hs(alg)) }
          .to raise_error(KeycloakSdk::TokenValidationError, "JWT validation failed: Expected a different algorithm")
        expect(hs_validator.validate(sign(base_claims)).subject).to eq("user-1")
        expect(a_request(:get, jwks_url)).to have_been_made.once
      end
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
