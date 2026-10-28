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

  # 검사는 String 만의 것이 아니다 — 주입한 provider 는 무엇이든 돌려줄 수 있고 헤더에 실리는 것은 그 값의 글이다.
  # `is_a?(String)` 일 때만 검사하던 때 CR 든 Symbol 은 파사드에서 TransportError, `raw` 에서 Bearer 를 통째로 인용한
  # raw ArgumentError 였다(실측). String 경로와 같은 AuthError 다.
  { "a Symbol" => :to_sym.to_proc, "an object whose to_s is the token" => UnsendableTokenSpec::Texty.method(:new) }
    .each do |kind, wrap|
    { "the facade" => ->(a) { a.users.list }, "raw" => ->(a) { a.raw.get("admin/realms/r/users") } }.each do |via, call|
      it "refuses #{kind} holding CR and LF through #{via} with the String path's error, and does not quote it" do
        token = wrap.call("hSY7k-bearer-canary-a#{13.chr}#{10.chr}b")
        expect { call.call(admin(token)) }.to raise_error(KeycloakSdk::AuthError) { |e|
          expect(e.message).to eq(crlf)
          expect(spec.quoted?(e, token.to_s)).to be(false)
        }
        expect(users).not_to have_been_requested
      end
    end
  end

  # 나머지 검사도 같다 — NUL 든 Symbol 은 그대로, 끝 공백 든 Symbol 은 그 공백이 지워진 채 나갔다(실측).
  { "NUL in the middle" => ["hNL7k-bearer-canary-a#{0.chr}b", :control],
    "a trailing space" => ["hWS7k-bearer-canary-ab ", :edge] }.each do |name, (text, message)|
    it "refuses a Symbol holding #{name} with the String path's error, without sending it" do
      expect { admin(text.to_sym).users.list }.to raise_error(KeycloakSdk::AuthError, public_send(message))
      expect(users).not_to have_been_requested
    end
  end

  it "refuses a Symbol one byte past the header field limit with the String path's error, without sending it" do
    limit = Net::HTTPHeader::MAX_FIELD_LENGTH - "Bearer ".bytesize
    expect { admin(("A" * (limit + 1)).to_sym).users.list }.to raise_error(KeycloakSdk::AuthError) { |e|
      expect(e.message).to eq("admin request not sent: the access token (#{limit + 1} bytes) does not fit an " \
                              "HTTP header field (#{Net::HTTPHeader::MAX_FIELD_LENGTH} bytes with \"Bearer \")")
    }
    expect(users).not_to have_been_requested
  end

  it "refuses an object whose to_s is not valid UTF-8 with the String path's error, without sending it" do
    expect { admin(UnsendableTokenSpec::Texty.new(UnsendableTokenSpec::BAD)).users.list }
      .to raise_error(KeycloakSdk::AuthError) { |e|
        expect(e.message).to eq("admin request not sent: the access token is not valid UTF-8")
        expect(spec.quoted?(e, UnsendableTokenSpec::BAD)).to be(false)
      }
    expect(users).not_to have_been_requested
  end

  # 빈 토큰은 「Authorization: Bearer」로 나갔다 — net-http 가 "Bearer " 의 끝 공백을 `strip` 한다(실측). nil 의 글도 "" 다.
  { "nil" => nil, "an empty String" => "", "an empty Symbol" => :"" }.each do |name, token|
    it "refuses #{name} without sending Authorization: Bearer" do
      expect { admin(token).users.list }
        .to raise_error(KeycloakSdk::AuthError, "admin request not sent: the access token is empty")
      expect(users).not_to have_been_requested
    end
  end

  # 대조군 — 같은 검사를 지나는 String 이 아닌 값은 예전처럼 그 글 그대로 나간다(String 이 아니라고 거부하지 않는다).
  { "a Symbol" => :"hDX7k-bearer-ab", "an Integer" => 12_345,
    "an object whose to_s is the token" => UnsendableTokenSpec::Texty.new("hDX7k-bearer-ab") }.each do |name, token|
    it "sends #{name} as its text, unchanged" do
      expect(admin(token).users.list).to eq([])
      expect(a_request(:get, UnsendableTokenSpec::USERS)
        .with(headers: { "Authorization" => "Bearer #{token}" })).to have_been_made.once
    end
  end

  # `to_s` 가 String 이 아니어도 예전 헤더 그대로다 — 보간은 그것을 Ruby 의 기본 글(`#<Class:0x…>`)로 바꿨다. `to_s` 를
  # 그대로 쓰면 그 값이 검사에서 raw 예외가 된다. 거부는 새 정책이라 하지 않는다.
  it "sends an object whose to_s is not a String as Ruby's default text, as before" do
    expect(admin(UnsendableTokenSpec::Texty.new(nil)).users.list).to eq([])
    sent = /\ABearer #<UnsendableTokenSpec::Texty:0x\h+>\z/
    expect(a_request(:get, UnsendableTokenSpec::USERS).with { |r| r.headers["Authorization"].match?(sent) })
      .to have_been_made.once
  end

  # 검사한 글이 보낸 글이다 — provider 의 값은 글로 한 번만 바뀐다(다시 바꾸면 둘째 글은 검사를 받지 않고 나간다).
  it "checks the very text it sends, turning the provider's value into text once" do
    token = UnsendableTokenSpec::Flip.new(["hFL7k-bearer-ab", "hFL7k-bearer-a#{13.chr}b"])
    expect(admin(token).users.list).to eq([])
    expect(a_request(:get, UnsendableTokenSpec::USERS)
      .with(headers: { "Authorization" => "Bearer hFL7k-bearer-ab" })).to have_been_made.once
  end
end
