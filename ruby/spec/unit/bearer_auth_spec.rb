# frozen_string_literal: true

require "spec_helper"
require_relative "../support/unsendable"

# admin 레인의 헤더 경계 — net-http 가 헤더에 실을 수 없는 Bearer 는 보내기 전에 SDK 오류로, 토큰을 찍지 않고 거부한다.
# 고쳐 쓰지 않는다: net-http 가 말없이 고쳐 보낼 Bearer(끝의 NUL·공백·탭 — `strip`)와 헤더 값에 올 수 없는 Bearer
# (NUL·그 밖의 C0·DEL · 앞뒤 공백·탭)도 거부하고, 헤더 값에 올 수 있는 것(가운데 공백·탭 · U+00FF 위 문자)은
# 그대로 보낸다(판정은 서버).
RSpec.describe KeycloakSdk::Admin::BearerAuth do
  let(:spec) { UnsendableTokenSpec }
  let(:users) do
    stub_request(:get, UnsendableTokenSpec::USERS).to_return(status: 200, headers: UnsendableTokenSpec::JSON_TYPE,
                                                             body: "[]")
  end
  let(:crlf) { "admin request not sent: the access token holds CR or LF, which an HTTP header cannot carry" }
  let(:control) do
    "admin request not sent: the access token holds NUL, DEL or another control character, which an HTTP header " \
      "cannot carry"
  end
  let(:edge) do
    "admin request not sent: the access token starts or ends with a space or tab, which an HTTP header cannot carry"
  end

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

  # net-http 의 `initialize_http_header` 는 헤더 값을 `strip` 한다(0.9.1 header.rb:195) — 끝의 공백·탭(과 NUL·VT·FF)은
  # 말없이 지워진 채 나갔다(실측: 「Bearer <토큰>」에서 마지막 바이트가 빠졌다). 앞의 공백·탭은 그대로 나가지만
  # 받는 쪽이 `Bearer` 뒤의 공백으로 접는다(RFC 9110 §11.4 `1*SP`) — 어느 쪽이든 서버가 보는 것은 다른 토큰이다.
  { "a trailing space" => ->(t) { "#{t} " }, "a trailing tab" => ->(t) { "#{t}\t" },
    "a leading space" => ->(t) { " #{t}" }, "a leading tab" => ->(t) { "\t#{t}" } }.each do |name, build|
    it "refuses a bearer with #{name} without sending it, and does not quote it" do
      token = build.call("hWS7k-bearer-canary-ab")
      expect { admin(token).users.list }.to raise_error(KeycloakSdk::AuthError) { |e|
        expect(e.message).to eq(edge)
        expect(spec.quoted?(e, token)).to be(false)
      }
      expect(users).not_to have_been_requested
    end
  end

  # 공백뿐인 토큰은 TokenSet 의 「비지 않았다」를 지나 「Authorization: Bearer」로 나갔다(실측) — 같은 거부다.
  it "refuses a bearer that is only a space without sending it" do
    expect { admin(" ").users.list }.to raise_error(KeycloakSdk::AuthError, edge)
    expect(users).not_to have_been_requested
  end

  # RFC 9110 §5.5 — 헤더 값의 글자는 field-vchar(VCHAR · obs-text)·SP·HTAB 뿐이다. net-http 는 NUL·그 밖의 C0·DEL 을
  # 가운데·앞이면 그대로, 끝이면(NUL·VT·FF) 지운 채 보냈다(실측). 받는 쪽은 거부·치환·통과로 갈린다.
  { "in the middle" => ->(t, c) { "#{t[0, 10]}#{c}#{t[10..]}" }, "at the end" => ->(t, c) { "#{t}#{c}" },
    "at the start" => ->(t, c) { "#{c}#{t}" } }.each do |where, build|
    it "refuses a bearer holding NUL #{where} without sending it, and does not quote it" do
      token = build.call("hNL7k-bearer-canary-ab", 0.chr)
      expect { admin(token).users.list }.to raise_error(KeycloakSdk::AuthError) { |e|
        expect(e.message).to eq(control)
        expect(spec.quoted?(e, token)).to be(false)
      }
      expect(users).not_to have_been_requested
    end

    it "refuses a bearer holding DEL or any C0 control but HTAB, CR and LF #{where} without sending it" do
      codes = (0x01..0x1F).to_a - [0x09, 0x0A, 0x0D] + [0x7F]
      refused = codes.select do |code|
        admin(build.call("hCT7k-bearer-canary-ab", code.chr)).users.list
        false
      rescue KeycloakSdk::AuthError => e
        e.message == control
      end
      expect(codes - refused).to eq([])
      expect(users).not_to have_been_requested
    end
  end

  # 대조군 — 헤더 값에 올 수 있는 Bearer 는 고치지 않고 그대로 보낸다(가운데의 공백·탭은 field-content 가 허락한다).
  { "a JWT" => "eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJ4In0.c2ln", "a space in the middle" => "hDX7k-bearer-a b",
    "a tab in the middle" => "hDX7k-bearer-a\tb", "U+0100" => "hDX7k-bearer-a#{[0x100].pack('U')}b",
    "U+4E2D" => "hDX7k-bearer-a#{[0x4E2D].pack('U')}b" }.each do |name, token|
    it "sends a bearer holding #{name} unchanged" do
      expect(admin(token).users.list).to eq([])
      expect(a_request(:get, UnsendableTokenSpec::USERS)
        .with { |r| r.headers["Authorization"].b == "Bearer #{token}".b }).to have_been_made.once
    end
  end
end
