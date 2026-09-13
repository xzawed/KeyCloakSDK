# frozen_string_literal: true

require "spec_helper"

RSpec.describe KeycloakSdk do
  describe KeycloakSdk::TokenSet do
    let(:body) do
      { "access_token" => "AT", "token_type" => "Bearer", "expires_in" => "300",
        "refresh_token" => "RT", "id_token" => "IT", "scope" => "openid email" }
    end

    it "parses a token response and computes expires_at" do
      ts = described_class.from_response(body, received_at: 1000.0)
      expect(ts.access_token).to eq("AT")
      expect(ts.expires_in).to eq(300)
      expect(ts.expires_at).to eq(1300.0)
    end

    it "computes expired? with skew" do
      ts = described_class.from_response(body, received_at: 1000.0)
      expect(ts.expired?(now: 1290.0)).to be(false)
      expect(ts.expired?(now: 1290.0, skew: 30)).to be(true) # 1290 >= 1300-30
      expect(ts.expired?(now: 1301.0)).to be(true)
    end

    it "masks tokens in inspect" do
      s = described_class.from_response(body, received_at: 0.0).inspect
      expect(s).to include("***")
      expect(s).not_to include("AT")
      expect(s).not_to include("RT")
    end

    it "leaves expires_at nil when expires_in is absent from the response" do
      ts = described_class.from_response({ "access_token" => "AT" }, received_at: 1000.0)
      expect(ts.expires_in).to be_nil
      expect(ts.expires_at).to be_nil
    end

    # ⚠️ 이 예제는 한때 "is never expired" + `be(false)` 였다 — **결함을 고정하고 있었다.**
    # 자매 여덟은 전부 만료 시각 미상을 "만료됨"으로 읽는다(fail-safe · Java 의 M.6).
    it "is expired (fail-safe) when expires_at is nil" do
      ts = described_class.from_response({ "access_token" => "AT" }, received_at: 1000.0)
      expect(ts.expired?).to be(true)
    end

    it "prints nil (unmasked) for absent refresh_token/id_token in inspect" do
      s = described_class.from_response({ "access_token" => "AT" }, received_at: 0.0).inspect
      expect(s).to include("refresh_token=nil")
      expect(s).to include("id_token=nil")
    end

    # ⚠️ **존재 검사는 타입 검사가 아니다.** 예전에는 `body["access_token"]` 을 그대로 담아
    # 숫자·해시·nil 이 `access_token` 이 됐다. 소비자는 그것을 Bearer 로 실어 보내고 매번
    # 401 을 받는다 — 조용한 반복 실패다. 아홉 언어 전수 측정에서 다섯이 이 부류였다.
    [12_345, nil, { "a" => 1 }, [], ""].each do |bad|
      it "rejects a non-string access_token (#{bad.inspect})" do
        expect do
          described_class.from_response({ "access_token" => bad }, received_at: 0.0)
        end.to raise_error(KeycloakSdk::AuthError)
      end
    end

    it "rejects a response with no access_token at all" do
      expect do
        described_class.from_response({ "token_type" => "Bearer" }, received_at: 0.0)
      end.to raise_error(KeycloakSdk::AuthError)
    end

    # ⚠️ **팩토리만 지키면 우회된다.** `AuthClient#to_token_set` 은 `from_response` 가 아니라
    # `TokenSet.new` 을 직접 부른다(독립 레그가 지목한 구멍) — 그래서 검증이 생성자에 있고,
    # 이 테스트가 그 자리를 못박는다.
    it "rejects a bad access_token even when constructed directly (factory bypass)" do
      expect do
        described_class.new(access_token: nil, token_type: "Bearer", expires_in: 300,
                            refresh_token: nil, id_token: nil, scope: nil, expires_at: nil)
      end.to raise_error(KeycloakSdk::AuthError)
    end
  end

  describe KeycloakSdk::IntrospectionResult do
    it "parses active and exposes active?" do
      r = described_class.from_response({ "active" => true, "username" => "u", "client_id" => "c" })
      expect(r.active?).to be(true)
      expect(r.username).to eq("u")
    end
  end

  describe KeycloakSdk::AuthorizationRequest do
    it "masks code_verifier in inspect" do
      s = described_class.new(url: "https://x?code_challenge=abc", state: "st",
                              code_verifier: "verysecret", nonce: "n-public").inspect
      expect(s).to include("***")
      expect(s).not_to include("verysecret")
      expect(s).to include("n-public")
    end
  end

  # ⚠️ `pp`/`pretty_inspect` 는 `inspect` 와 **같은 계급의 표시 경로**다. 그런데 `Data` 타입은
  # PP 가 멤버를 직접 찍어 `inspect` 재정의를 **건너뛴다**(실측 2026-09-12: `ts.pretty_inspect`
  # 가 access_token 원문을 찍었다. 일반 클래스인 `Config` 는 PP 가 `inspect` 로 폴백해 안전하다).
  # 즉 이것은 「바닥 밖」이 아니라 **바닥 안의 구멍**이다.
  describe "pretty-print (pp / pretty_inspect)" do
    it "TokenSet 이 토큰 셋을 원문으로 찍지 않는다" do
      ts = KeycloakSdk::TokenSet.new(access_token: "RAW-AT", token_type: "Bearer", expires_in: 60,
                                     refresh_token: "RAW-RT", id_token: "RAW-ID",
                                     scope: nil, expires_at: nil)
      out = ts.pretty_inspect
      expect(out).not_to include("RAW-AT")
      expect(out).not_to include("RAW-RT")
      expect(out).not_to include("RAW-ID")
      expect(out).to include("***")
    end

    it "AuthorizationRequest 가 code_verifier 를 원문으로 찍지 않는다" do
      ar = KeycloakSdk::AuthorizationRequest.new(url: "http://x", state: "s",
                                                 code_verifier: "RAW-VERIFIER", nonce: "n")
      out = ar.pretty_inspect
      expect(out).not_to include("RAW-VERIFIER")
      expect(out).to include("***")
    end
  end
end
