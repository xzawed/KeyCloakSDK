# frozen_string_literal: true

require "spec_helper"
require "jwt"
require "openssl"

# 키 집합의 수명(아홉 언어 공통 · 판정 2026-10-29). 성공한 JWKS 적재로 얻은 집합은 그 적재가 끝난 때부터 300 초만 쓴다 —
# 그 뒤는 **콜드 캐시와 같다**: 다음 검증이 같은 단일 비행·실패 백오프로 다시 받고, 그 적재가 실패하면 거부한다(낡은 키
# 폴백 없음). 수명 전에는 예전처럼 미해결 kid 의 강제 재조회만 받고, 그것이 성공하면 수명이 다시 시작한다.
# 시계는 stdlib 의 단조 시계를 스텁한다(대상 객체가 아니라 — RSpec/SubjectStub). 토큰의 exp 는 벽시계라 움직이지 않는다.
# rubocop:disable-next RSpec/MultipleMemoizedHelpers -- 두 RSA 키 · 가짜 IdP 상태 · 시계 상자가 각각 한 자리다
RSpec.describe KeycloakSdk::JwtValidator do
  subject(:validator) { described_class.from_config(config: config, jwks_store: store) }

  let(:config) { KeycloakSdk::Config.new(server_url: "https://kc.example.com", realm: "demo", client_id: "app") }
  let(:jwks_url) { "https://kc.example.com/realms/demo/protocol/openid-connect/certs" }
  let(:store) { KeycloakSdk::JwksStore.new(jwks_url: jwks_url, http: KeycloakSdk::Http.build(config)) }
  let(:keys) { { "k1" => OpenSSL::PKey::RSA.generate(2048), "k2" => OpenSSL::PKey::RSA.generate(2048) } }
  let(:idp) { { status: 200, kids: %w[k1] } } # IdP 가 지금 내주는 것
  let(:clock) { { now: 1000.0 } }

  before do
    allow(Process).to receive(:clock_gettime).and_call_original
    allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC) { clock[:now] }
    stub_request(:get, jwks_url).to_return { |_req| idp_response }
  end

  def idp_response
    return { status: idp[:status], body: '{"error":"temporarily_unavailable"}' } unless idp[:status] == 200

    jwks = { keys: idp[:kids].map { |kid| JWT::JWK.new(keys.fetch(kid), kid: kid).export } }
    { status: 200, body: jwks.to_json, headers: { "Content-Type" => "application/json" } }
  end

  def token(kid)
    claims = { "sub" => "u-#{kid}", "iss" => "https://kc.example.com/realms/demo", "aud" => "app",
               "exp" => Time.now.to_i + 600 }
    JWT.encode(claims, keys.fetch(kid), "RS256", { kid: kid })
  end

  def advance(seconds) = clock[:now] += seconds

  def fetches = a_request(:get, jwks_url)

  it "T1 — 정상 IdP: 299 초에는 받지 않고 301 초에는 그 검증이 정확히 한 번 받는다" do
    expect(validator.validate(token("k1")).subject).to eq("u-k1") # 적재 — t0
    advance(299)
    expect(validator.validate(token("k1")).subject).to eq("u-k1")
    expect(fetches).to have_been_made.once
    advance(2) # t0 + 301
    expect(validator.validate(token("k1")).subject).to eq("u-k1")
    expect(fetches).to have_been_made.twice
  end

  it "T2 — 수명 뒤 IdP 장애: 거부되고, 백오프 창 안에서는 IdP 에 가지 않으며, 복구 뒤 한 번 받고 통과한다" do
    validator.validate(token("k1")) # t0
    idp[:status] = 503
    advance(301)
    expect { validator.validate(token("k1")) }.to raise_error(KeycloakSdk::TransportError, /HTTP 503/)
    expect(fetches).to have_been_made.twice # 적재 + 시도 한 번
    3.times { expect { validator.validate(token("k1")) }.to raise_error(KeycloakSdk::TransportError, /backing off/) }
    expect(fetches).to have_been_made.twice
    idp[:status] = 200
    advance(10) # 백오프 상한(5 초) 너머
    expect(validator.validate(token("k1")).subject).to eq("u-k1")
    expect(fetches).to have_been_made.times(3)
  end

  it "T3 — 빠진 키: 301 초의 k1 토큰은 다시 받은 뒤 거부되고 k2 토큰은 통과한다" do
    idp[:kids] = %w[k1 k2]
    expect(validator.validate(token("k1")).subject).to eq("u-k1") # t0 — 두 키
    idp[:kids] = %w[k2] # IdP 가 k1 을 거뒀다
    advance(301)
    expect { validator.validate(token("k1")) }.to raise_error(KeycloakSdk::TokenValidationError)
    expect(validator.validate(token("k2")).subject).to eq("u-k2")
  end

  it "T4 — 강제 재조회가 수명을 다시 시작한다: 100 초의 재조회 뒤 350 초에는 받지 않고 401 초에 받는다" do
    validator.validate(token("k1")) # t0
    idp[:kids] = %w[k1 k2] # k2 가 회전해 들어왔다
    advance(100)
    expect(validator.validate(token("k2")).subject).to eq("u-k2") # 미해결 kid → 강제 재조회
    expect(fetches).to have_been_made.twice
    advance(250) # t0 + 350 — 재조회로부터 250 초
    expect(validator.validate(token("k1")).subject).to eq("u-k1")
    expect(fetches).to have_been_made.twice
    advance(51) # 재조회로부터 301 초
    expect(validator.validate(token("k2")).subject).to eq("u-k2")
    expect(fetches).to have_been_made.times(3)
  end
end
