# frozen_string_literal: true

require "spec_helper"
require "jwt"
require "openssl"

# `expected_audience` 재정의 아래의 코드 교환. id_token `aud` 는 **client_id** 로 검사한다 — OIDC Core §2·§3.1.3.7
# 이 id_token `aud` 에 client_id 를 MUST 로 요구하고, 재정의는 액세스 토큰(리소스 서버)의 것이라 `validate` 만 쓴다.
# ⚠️ 검증기·키 저장소는 목이 아니라 파사드가 조립한 **실물**이다 — 키 캐시·재조회 제한의 공유는 실물로만 잴 수 있다.
RSpec.describe KeycloakSdk::AuthClient, "#exchange_code under an expected_audience override" do
  let(:realm_key) { OpenSSL::PKey::RSA.generate(2048) }
  let(:config) do
    KeycloakSdk::Config.new(server_url: "https://kc.example.com", realm: "demo", client_id: "app",
                            client_secret: "sekret", expected_audience: "my-api")
  end
  let(:client) { KeycloakSdk::KeycloakClient.new(config) }

  before do
    stub_request(:get, certs_url)
      .to_return(status: 200, body: { keys: [JWT::JWK.new(realm_key, kid: "realm-key").export] }.to_json,
                 headers: { "Content-Type" => "application/json" })
  end

  after { client.close }

  def certs_url
    "https://kc.example.com/realms/demo/protocol/openid-connect/certs"
  end

  def claims(**over)
    now = Time.now.to_i
    { "sub" => "user-1", "iss" => "https://kc.example.com/realms/demo", "aud" => "app",
      "exp" => now + 300, "iat" => now, "nonce" => "n-abc" }.merge(over.transform_keys(&:to_s))
  end

  def sign(payload, kid: "realm-key")
    JWT.encode(payload, realm_key, "RS256", { kid: kid })
  end

  def exchange(id_token)
    stub_request(:post, "https://kc.example.com/realms/demo/protocol/openid-connect/token")
      .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                 body: { access_token: "AT", token_type: "Bearer", expires_in: 300, id_token: id_token }.to_json)
    client.auth.exchange_code(code: "c", code_verifier: "v", redirect_uri: "https://app/cb", expected_nonce: "n-abc")
  end

  def invalid_id_token(reason)
    raise_error(KeycloakSdk::AuthError, /\Aauthorization_code exchange failed: invalid id_token: .*#{reason}/i)
  end

  # 거부 메시지가 **client_id 를 기대했다**고 말해야 한다 — 재정의(my-api)를 기대한 거부와 가른다.
  def wrong_audience
    invalid_id_token("Invalid audience\\. Expected app,")
  end

  describe "the id_token audience is the client_id, not the override" do
    it "accepts an id_token whose aud is the client_id" do
      expect(exchange(sign(claims)).access_token).to eq("AT")
    end

    it "accepts an id_token whose aud lists the client_id beside the override" do
      expect(exchange(sign(claims("aud" => %w[my-api app]))).access_token).to eq("AT")
    end

    it "rejects an id_token whose aud is only the override" do
      expect { exchange(sign(claims("aud" => "my-api"))) }.to wrong_audience
    end

    it "rejects an id_token whose aud lacks the client_id" do
      expect { exchange(sign(claims("aud" => %w[my-api account]))) }.to wrong_audience
    end
  end

  describe "access token validation keeps the override" do
    it "accepts the override's audience and rejects a token for the client_id only" do
      expect(client.auth.validate(sign(claims("aud" => "my-api"))).audience).to eq(["my-api"])
      expect { client.auth.validate(sign(claims)) }
        .to raise_error(KeycloakSdk::TokenValidationError, /Invalid audience\. Expected my-api,/)
    end
  end

  # 재정의 아래에서도 나머지 id_token 검사(iss · 알고리즘 핀 · exp/클록 스큐 · nonce)는 그대로다.
  # 모두 aud=client_id 인 토큰이라, 거부는 오디언스가 아니라 각 클레임 때문이다(메시지로 가른다).
  describe "the other id_token checks are unchanged under the override" do
    it "rejects a wrong issuer" do
      expect { exchange(sign(claims("iss" => "https://evil.example"))) }.to invalid_id_token("Invalid issuer")
    end

    it "rejects an HS256 id_token (algorithm pin)" do
      hs256 = JWT.encode(claims, "shared-secret", "HS256", { kid: "realm-key" })
      expect { exchange(hs256) }.to invalid_id_token("Expected a different algorithm")
    end

    it "rejects an unsigned id_token (alg none)" do
      expect { exchange(JWT.encode(claims, nil, "none")) }.to invalid_id_token("Expected a different algorithm")
    end

    it "honours the 30s clock skew: 20s-expired passes, 40s-expired fails" do
      expect(exchange(sign(claims("exp" => Time.now.to_i - 20))).access_token).to eq("AT")
      expect { exchange(sign(claims("exp" => Time.now.to_i - 40))) }.to invalid_id_token("Signature has expired")
    end

    it "rejects an id_token without exp" do
      expect { exchange(sign(claims.except("exp"))) }.to invalid_id_token("Missing required claim exp")
    end

    it "rejects a mismatched nonce" do
      expect { exchange(sign(claims("nonce" => "attacker"))) }
        .to raise_error(KeycloakSdk::AuthError, "authorization_code exchange failed: unexpected nonce")
    end

    it "rejects an id_token without a nonce" do
      expect { exchange(sign(claims.except("nonce"))) }
        .to raise_error(KeycloakSdk::AuthError, "authorization_code exchange failed: unexpected nonce")
    end
  end

  # 키 저장소는 하나다 — 캐시 · 미해결 kid 재조회 제한(30초 창) · 콜드 캐시 실패 백오프를 두 토큰이 나눠 쓴다.
  describe "one JWKS cache, refetch limit and backoff for both tokens" do
    it "adds no JWKS fetch when an access token is validated after the exchange" do
      exchange(sign(claims))
      client.auth.validate(sign(claims("aud" => "my-api")))
      expect(a_request(:get, certs_url)).to have_been_made.once
    end

    it "builds exactly one JwksStore" do
      allow(KeycloakSdk::JwksStore).to receive(:new).and_call_original
      exchange(sign(claims))
      client.auth.validate(sign(claims("aud" => "my-api")))
      expect(KeycloakSdk::JwksStore).to have_received(:new).once
    end

    # 대조군 — 저장소가 둘이면 같은 순서가 두 번 받는다. 위 「once」 가 두 번째 저장소를 볼 수 있다는 증거다.
    it "fetches twice when a second store exists (control)" do
      other = KeycloakSdk::KeycloakClient.new(config)
      exchange(sign(claims))
      other.auth.validate(sign(claims("aud" => "my-api")))
      expect(a_request(:get, certs_url)).to have_been_made.twice
    ensure
      other&.close
    end

    it "shares the unresolved-kid refetch window between validate and the exchange" do
      expect { client.auth.validate(sign(claims("aud" => "my-api"), kid: "rotated-1")) }
        .to raise_error(KeycloakSdk::TokenValidationError)
      expect { exchange(sign(claims, kid: "rotated-2")) }.to invalid_id_token("Could not find public key for kid")
      expect(a_request(:get, certs_url)).to have_been_made.twice # 콜드 로드 + 창 안의 재조회 1건
    end

    # ⚠️ **시계 스텁을 떼지 말 것 — 실시간 monotonic 에서는 이 단언이 러너 속도를 잰다.** 첫 실패의 창은
    # 0.2초 × jitter[0.5, 1.0) 라 0.1초까지 좁고, 교환이 실패를 기록한 뒤 `validate` 의 백오프 검사 전에 RSA
    # 서명이 끼어 있다. 그 사이 정지가 창을 넘으면 `validate` 가 IdP 로 다시 나가 `HTTP 503` 으로 깨진다.
    # 저장소가 읽는 시계(인자 하나의 `CLOCK_MONOTONIC`)만 멈춘다 — jitter 의 나노초 호출은 원본으로 흐른다.
    it "shares the cold-cache failure backoff between the exchange and validate" do
      allow(Process).to receive(:clock_gettime).and_call_original
      allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC).and_return(1000.0)
      stub_request(:get, certs_url).to_return(status: 503)
      expect { exchange(sign(claims)) }.to raise_error(KeycloakSdk::TransportError, /HTTP 503/)
      expect { client.auth.validate(sign(claims("aud" => "my-api"))) }
        .to raise_error(KeycloakSdk::TransportError, /backing off/)
      expect(a_request(:get, certs_url)).to have_been_made.once
      # 스텁이 실제로 읽혔는가 — 저장소가 인자 둘의 꼴로 읽으면 스텁을 비켜 가 실시간으로 돌아간다(실측: 그 변이에
      # `sleep 0.25` 를 끼우면 `HTTP 503`). 그때 이 예제는 조용히 다시 벽시계에 매달린다.
      expect(Process).to have_received(:clock_gettime).with(Process::CLOCK_MONOTONIC).at_least(:once)
    end
  end
end
