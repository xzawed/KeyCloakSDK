# frozen_string_literal: true

require "spec_helper"
require "securerandom"
require "uri"

# 인가 요청의 redirect_uri — RFC 6749 §3.1.2 가 금하는 값은 URL 에 싣지 않는다(등록부
# `authz-request-redirect-unvalidated`). 예전에는 `create_authorization_request` 가 어떤 값이든 실었다(`cb` ·
# `https://app/cb#f` · nil 은 redirect_uri 없는 URL). 규칙은 순서대로 셋이다:
#   R1 절대 URI — scheme 과 `:` 로 시작한다. String 이 아닌 값(nil 포함)도 R1 이다.
#   R2 fragment 없음 — `#` 가 어디에도 없다. 빈 fragment(`https://app/cb#`)도 fragment 다.
#   R3 Keycloak 이 읽는 URI — 서버는 `java.net.URI.create` 가 던지는 값을 거부한다(RFC 3986 §2). 바이트가 UTF-8 로
#      읽히지 않는 값도 R3 이다. ⚠️ 어느 정규식도 던지지 않는다 — 깨진 문자열에 정규식을 걸면 ArgumentError,
#      ASCII 호환이 아닌 인코딩(UTF-16)이면 Encoding::CompatibilityError 다(수정 전에는 둘 다 raw 로 샜다).
# 위반은 ConfigError 이고 메시지는 입력을 인용하지 않는다. 받은 값은 고쳐 쓰지 않는다 — 교환이 같은 문자열을 그대로
# 보낸다(고쳐 쓰면 두 요청이 갈린다).
module AuthzRedirectUriSpec
  NOT_ABSOLUTE = "invalid redirect_uri: not an absolute URI (RFC 6749 §3.1.2)"
  FRAGMENT = "invalid redirect_uri: a fragment is not allowed (RFC 6749 §3.1.2)"
  NOT_VALID = "invalid redirect_uri: not a valid URI (RFC 3986 §2)"
  # R3 의 글자 — U+0000-U+0020, U+007F-U+00A0, java.net.URI 가 거부하는 유니코드 공백 구분자 열일곱, 그리고 아홉 개
  # (33 + 34 + 17 + 9).
  SPACE_SEPARATORS = [0x1680, *0x2000..0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000].freeze
  R3_CHARS = ([*0x00..0x20, *0x7F..0xA0, *SPACE_SEPARATORS].map { |c| c.chr(Encoding::UTF_8) } +
              %w[" < > \\ ^ ` { | }]).freeze
end

RSpec.describe KeycloakSdk::AuthClient, "#create_authorization_request redirect_uri" do
  let(:config) do
    KeycloakSdk::Config.new(server_url: "https://kc.example.com", realm: "demo", client_id: "app",
                            client_secret: "sekret")
  end
  let(:auth) do
    described_class.new(config: config, http: KeycloakSdk::Http.build(config),
                        jwt_validator: instance_double(KeycloakSdk::JwtValidator))
  end
  let(:not_absolute) { AuthzRedirectUriSpec::NOT_ABSOLUTE }
  let(:fragment) { AuthzRedirectUriSpec::FRAGMENT }
  let(:not_valid) { AuthzRedirectUriSpec::NOT_VALID }

  def raised(value)
    auth.create_authorization_request(redirect_uri: value)
    nil
  rescue KeycloakSdk::ConfigError => e
    e
  end

  def refusal(value) = raised(value)&.message

  def sent_redirect_uri(value)
    url = auth.create_authorization_request(redirect_uri: value).url
    URI.decode_www_form(URI(url).query).filter_map { |k, v| v if k == "redirect_uri" }
  end

  # `cb#f` · `cb\xFF` 는 순서의 증명이다 — R1 이 R2·R3 보다 앞이다.
  [*["", "cb", "/cb", "//app/cb", "not a url", "cb#f", "cb\xFF"].map { |v| [v.inspect, v] },
   ["nil", nil], ["the Integer 42", 42], ["a Symbol", :"https://app/cb"], ["a URI object", URI("https://app/cb")],
   ["a UTF-16 String", "https://app/cb".encode("UTF-16LE")]].each do |what, value|
    it "refuses #{what} as not an absolute URI" do
      expect(refusal(value)).to eq(not_absolute)
    end
  end

  # `https://app/c b#f` · `https://app/c\xFF#f` 는 순서의 증명이다 — R2 가 R3 보다 앞이다.
  ["https://app/cb#", "https://app/cb#f", "https://app/c b#f", "https://app/c\xFF#f"].each do |value|
    it "refuses #{value.inspect} for its fragment" do
      expect(refusal(value)).to eq(fragment)
    end
  end

  [*["https://app/c b", "https://app/cb\n", "https://app/c\\b", "https://app/c%zz", "https://app/c\u{A0}b",
     "https://app/c%2", "https://app/c%", "https://app/c%g0", "https://app/c\xFFb", "https://app/c\u{3000}b",
     "https://app/c\u{2028}b"].map { |v| [v.inspect, v] },
   ["a binary String whose bytes are not UTF-8", "https://app/c\xFFb".b],
   ["an ISO-8859-1 String (its bytes are not UTF-8)", "https://app/c\xFCb".dup.force_encoding("ISO-8859-1")]]
    .each do |what, value|
    it "refuses #{what} as a URI Keycloak cannot parse" do
      expect(refusal(value)).to eq(not_valid)
    end
  end

  it "refuses every character Keycloak refuses (R3), both ends of each range included" do
    chars = AuthzRedirectUriSpec::R3_CHARS
    expect(chars.size).to eq(93) # 빈 집합이면 아래 단언이 공허하게 통과한다
    missed = chars.reject { |ch| refusal("https://app/c#{ch}b") == not_valid }
    expect(missed.map { |ch| format("U+%04X", ch.ord) }).to eq([])
  end

  {
    "cb-CANARY-7d1f" => AuthzRedirectUriSpec::NOT_ABSOLUTE,
    "https://app/CANARY#f" => AuthzRedirectUriSpec::FRAGMENT,
    "https://app/CANARY b" => AuthzRedirectUriSpec::NOT_VALID
  }.each do |value, message|
    it "does not quote #{value.inspect} in its message" do
      error = raised(value)
      expect(error&.message).to eq(message)
      expect(error.full_message(highlight: false)).not_to include("CANARY")
    end
  end

  ["https://app/cb", "https://app/cb?x=1", "myapp:/cb", "com.example.app:/oauth2redirect", "HTTP://LOCALHOST/cb",
   "https://app/c%20b", "https://app/c\u{FC}b", "https://app/cb?x=[1]", "https://app/c'b", "https://app/c+*!b",
   "https://app/c~b", "https://app/c\u{A1}b", "https://app/c%2Fb", "https://app/c\u{200B}b",
   "https://app/c\u{3001}b"].each do |value|
    it "carries #{value.inspect} exactly as given" do
      expect(sent_redirect_uri(value)).to eq([value])
    end
  end

  it "refuses before the body generates anything" do
    # state·nonce 의 기본값은 인자를 묶을 때 계산된다(Ruby 의 기본 인자) — 그래서 둘을 넘기고 본문만 잰다.
    allow(SecureRandom).to receive(:urlsafe_base64).and_call_original
    expect { auth.create_authorization_request(redirect_uri: "cb", state: "s", nonce: "n") }
      .to raise_error(KeycloakSdk::ConfigError, not_absolute)
    expect(SecureRandom).not_to have_received(:urlsafe_base64)
  end
end
