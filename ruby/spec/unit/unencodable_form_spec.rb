# frozen_string_literal: true

require "spec_helper"
require_relative "../support/unsendable"

# 토큰을 폼 본문에 싣는 auth 호출(introspect·refresh·logout). Faraday 의 폼 인코더(`Faraday::Utils.escape`)는 잘못된
# UTF-8 에서 raw ArgumentError 를 낸다(실측: logout 은 요청 0 건에 raw) — 고쳐 쓰지 않고 요청 없이 SDK 오류로 거부한다.
# 헤더에 못 싣는 문자(LF·NUL·U+00FF 위)는 퍼센트 인코딩돼 그대로 간다.
RSpec.describe KeycloakSdk::AuthClient do
  let(:kc) { KeycloakSdk::KeycloakClient.new(UnsendableTokenSpec.config) }

  describe "a token that is not valid UTF-8" do
    let(:any_oidc) { stub_request(:any, /#{Regexp.escape(UnsendableTokenSpec::OIDC)}/).to_return(status: 200) }

    before { any_oidc }

    it "introspect refuses it without a request" do
      expect { kc.auth.introspect(UnsendableTokenSpec::BAD) }
        .to raise_error(KeycloakSdk::AuthError, "introspection failed: token is not valid UTF-8")
      expect(any_oidc).not_to have_been_requested
    end

    it "logout refuses it without a request" do
      expect { kc.auth.logout(refresh_token: UnsendableTokenSpec::BAD) }
        .to raise_error(KeycloakSdk::AuthError, "logout failed: refresh_token is not valid UTF-8")
      expect(any_oidc).not_to have_been_requested
    end

    # 이미 SDK 오류였지만 「unusable token response (ArgumentError)」라는 틀린 말이었다 — 응답이 아니라 입력이다.
    it "refresh refuses it without a request" do
      expect { kc.auth.refresh(refresh_token: UnsendableTokenSpec::BAD) }
        .to raise_error(KeycloakSdk::AuthError, "refresh failed: refresh_token is not valid UTF-8")
      expect(any_oidc).not_to have_been_requested
    end
  end

  # 헤더 사례 탐침의 auth 쪽 — 고쳐 쓰지 않았는가 = 서버가 받은 값이 보낸 토큰과 바이트까지 같은가.
  { "LF" => 10.chr, "NUL" => 0.chr, "U+0100" => [0x100].pack("U") }.each do |name, ch|
    it "sends a token holding #{name} in the form body unchanged (introspect · refresh · logout)" do
      token = "fB#{name[0]}7k-form-canary-a#{ch}b"
      seen = []
      stub_request(:post, %r{#{Regexp.escape(UnsendableTokenSpec::OIDC)}/(token|token/introspect|logout)\z})
        .to_return do |req|
          form = URI.decode_www_form(req.body).to_h
          seen << (form["token"] || form["refresh_token"])
          { status: 200, headers: UnsendableTokenSpec::JSON_TYPE,
            body: { active: true, access_token: "AT", token_type: "Bearer", expires_in: 300 }.to_json }
        end
      kc.auth.introspect(token)
      kc.auth.refresh(refresh_token: token)
      kc.auth.logout(refresh_token: token)
      expect(seen.map(&:b)).to eq([token.b] * 3)
    end
  end
end
