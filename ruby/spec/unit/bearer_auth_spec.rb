# frozen_string_literal: true

require "spec_helper"
require_relative "../support/unsendable"

# admin 레인의 헤더 경계 — net-http 가 헤더에 실을 수 없는 Bearer 는 보내기 전에 SDK 오류로, 토큰을 찍지 않고 거부한다.
# 고쳐 쓰지 않는다: net-http 가 막지 않는 NUL·U+00FF 위 문자는 그대로 보낸다(판정은 서버).
RSpec.describe KeycloakSdk::Admin::BearerAuth do
  let(:spec) { UnsendableTokenSpec }
  let(:users) do
    stub_request(:get, UnsendableTokenSpec::USERS).to_return(status: 200, headers: UnsendableTokenSpec::JSON_TYPE,
                                                             body: "[]")
  end
  let(:crlf) { "admin request not sent: the access token holds CR or LF, which an HTTP header cannot carry" }

  def admin(token)
    KeycloakSdk::Admin::AdminClient.new(config: spec.config, token_provider: UnsendableTokenSpec::Fixed.new(token))
  end

  before { users }

  { "LF" => 10.chr, "CR" => 13.chr, "CRLF" => "#{13.chr}#{10.chr}" }.each do |name, ch|
    it "refuses a bearer holding #{name} without sending it, and does not quote it" do
      token = "hD#{name[0]}7k-bearer-canary-a#{ch}b"
      expect { admin(token).users.list }.to raise_error(KeycloakSdk::AuthError) { |e|
        expect(e.message).to eq(crlf)
        expect(spec.quoted?(e, token)).to be(false)
      }
      expect(users).not_to have_been_requested
    end
  end

  it "refuses a bearer that is not valid UTF-8 without sending it" do
    expect { admin(UnsendableTokenSpec::BAD).users.list }.to raise_error(KeycloakSdk::AuthError) { |e|
      expect(e.message).to eq("admin request not sent: the access token is not valid UTF-8")
      expect(spec.quoted?(e, UnsendableTokenSpec::BAD)).to be(false)
    }
    expect(users).not_to have_been_requested
  end

  # net-http 의 `MAX_FIELD_LENGTH`(65,536)는 "Bearer " 를 포함한 값의 길이다 — 토큰 65,529 바이트가 마지막으로 실린다.
  it "refuses a bearer one byte past the HTTP client's header field limit, and sends one at the limit" do
    limit = Net::HTTPHeader::MAX_FIELD_LENGTH - "Bearer ".bytesize
    expect { admin("A" * (limit + 1)).users.list }.to raise_error(KeycloakSdk::AuthError) { |e|
      expect(e.message).to eq("admin request not sent: the access token (#{limit + 1} bytes) does not fit an " \
                              "HTTP header field (#{Net::HTTPHeader::MAX_FIELD_LENGTH} bytes with \"Bearer \")")
    }
    expect(users).not_to have_been_requested
    expect(admin("A" * limit).users.list).to eq([])
    expect(a_request(:get, UnsendableTokenSpec::USERS)
      .with { |r| r.headers["Authorization"].bytesize == Net::HTTPHeader::MAX_FIELD_LENGTH }).to have_been_made.once
  end

  { "NUL" => 0.chr, "U+0100" => [0x100].pack("U"), "U+4E2D" => [0x4E2D].pack("U") }.each do |name, ch|
    it "sends a bearer holding #{name} unchanged" do
      token = "hDX7k-bearer-a#{ch}b"
      expect(admin(token).users.list).to eq([])
      expect(a_request(:get, UnsendableTokenSpec::USERS)
        .with { |r| r.headers["Authorization"].b == "Bearer #{token}".b }).to have_been_made.once
    end
  end
end
