# frozen_string_literal: true

require "spec_helper"
require "securerandom"
require "uri"

# 인가 요청의 redirect_uri — RFC 6749 §3.1.2 가 금하는 값은 URL 에 싣지 않는다(등록부
# `authz-request-redirect-unvalidated`). 예전에는 `create_authorization_request` 가 어떤 값이든 실었다(`cb` ·
# `https://app/cb#f` · nil 은 redirect_uri 없는 URL). 규칙은 순서대로 넷이다:
#   R1 절대 URI — scheme 과 `:` 로 시작한다. String 이 아닌 값(nil 포함)도 R1 이다.
#   R2 fragment 없음 — `#` 가 어디에도 없다. 빈 fragment(`https://app/cb#`)도 fragment 다.
#   R3 Keycloak 이 읽는 URI — 서버는 `java.net.URI.create` 가 던지는 값을 거부한다(RFC 3986 §2). 바이트가 UTF-8 로
#      읽히지 않는 값도 R3 이다. ⚠️ 어느 정규식도 던지지 않는다 — 깨진 문자열에 정규식을 걸면 ArgumentError,
#      ASCII 호환이 아닌 인코딩(UTF-16)이면 Encoding::CompatibilityError 다(수정 전에는 둘 다 raw 로 샜다).
#   R4 R3 를 지나도 서버가 던지는 값(문구는 R3 와 같다) — scheme 의 `:` 뒤가 빔(R4a) · `?` 앞 경로나 authority 의 괄호
#      호스트 밖의 `[`·`]`(R4b) · `//` 뒤가 빔(R4c) · 괄호 호스트가 IPv6 주소가 아님(R4d) · 그 포트가 Java int 를
#      넘음(R4e). 등록부 `redirect-uri-r3-narrower-than-keycloak` · `redirect-uri-create-residuals`.
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

  # é — 편집 도구가 이스케이프를 글자로 바꾸지 않게 코드로 만든다.
  E_ACUTE = 0xE9.chr(Encoding::UTF_8)
  # `java.net.URI.create` 의 판정(JDK 21.0.8 실측 83 행) — 값과, JDK 가 받는가. 거부 행의 주석은 JDK 의 메시지다.
  URI_CREATE = [
    ["https://", false], # Expected authority
    ["myapp://", false], # Expected authority
    ["https:///", true],
    ["https:///cb", true],
    ["https://?x=1", true],
    ["https://u@/cb", true],
    ["https://:80/cb", true],
    ["https://@/cb", true],
    ["https:/", true],
    ["https://[::1]/cb", true],
    ["https://[zz]/cb", false], # Malformed IPv6 address
    ["https://[v1.x]/cb", false], # Malformed IPv6 address
    ["https://[::1::2]/cb", false], # Expected hex digits or IPv4 address
    ["https://[1:2:3:4:5:6:7:8:9]/cb", false], # IPv6 address too long
    ["https://[1:2:3:4:5:6:7:8]/cb", true],
    ["https://[1:2:3:4:5:6:7::]/cb", true],
    ["https://[::1:2:3:4:5:6:7]/cb", true],
    ["https://[1:2:3:4:5:6:7:8::]/cb", false], # Malformed IPv6 address
    ["https://[::1:2:3:4:5:6:7:8]/cb", false], # Malformed IPv6 address
    ["https://[1:2:3:4:5:6:7]/cb", false], # IPv6 address too short
    ["https://[::]/cb", true],
    ["https://[:]/cb", false], # Malformed IPv6 address
    ["https://[:::]/cb", false], # Expected hex digits or IPv4 address
    ["https://[1:::2]/cb", false], # Expected hex digits or IPv4 address
    ["https://[::1:]/cb", false], # Expected digits for an IPv6 address
    ["https://[:1::2]/cb", false], # Malformed IPv6 address
    ["https://[1::2:]/cb", false], # Expected digits for an IPv6 address
    ["https://[12345::]/cb", false], # IPv6 hexadecimal digit sequence too long
    ["https://[ABCD::EF]/cb", true],
    ["https://[abcd:EF01::]/cb", true],
    ["https://[0001:2:3:4:5:6:7:8]/cb", true],
    ["https://[::ffff:1.2.3.4]/cb", true],
    ["https://[::1.2.3.4]/cb", true],
    ["https://[1.2.3.4]/cb", false], # Malformed IPv6 address
    ["https://[::ffff:01.2.3.4]/cb", true],
    ["https://[::ffff:0001.2.3.4]/cb", true],
    ["https://[::ffff:00000000255.2.3.4]/cb", true],
    ["https://[::ffff:256.2.3.4]/cb", false], # Malformed IPv4 address
    ["https://[::ffff:1.2.3]/cb", false], # Malformed IPv4 address
    ["https://[::ffff:1.2.3.4.5]/cb", false], # Malformed IPv4 address
    ["https://[::ffff:1.2.3.]/cb", false], # Malformed IPv4 address
    ["https://[::ffff:.1.2.3]/cb", false], # Expected digits for an IPv6 address
    ["https://[::ffff:1..2.3]/cb", false], # Malformed IPv4 address
    ["https://[1:2:3:4:5:6:1.2.3.4]/cb", true],
    ["https://[1:2:3:4:5:6:7:1.2.3.4]/cb", false], # IPv6 address too long
    ["https://[1:2:3:4:5:1.2.3.4]/cb", false], # IPv6 address too short
    ["https://[1::1.2.3.4]/cb", true],
    ["https://[1:2:3:4:5::1.2.3.4]/cb", true],
    ["https://[1:2:3:4:5:6::1.2.3.4]/cb", false], # Malformed IPv6 address
    ["https://[::1.2.3.4:5]/cb", false], # Expected hex digits or IPv4 address
    ["https://[1.2.3.4::]/cb", false], # Malformed IPv6 address
    ["https://[::99999999999.2.3.4]/cb", false], # NumberFormatException
    ["https://[::1.2.3.9999999999999]/cb", false], # NumberFormatException
    ["https://[fe80::1%eth0]/cb", true],
    ["https://[fe80::1%25eth0]/cb", true],
    ["https://[fe80::1%25]/cb", true],
    ["https://[fe80::1%]/cb", false], # scope id expected
    ["https://[fe80::1%25en-1]/cb", false], # Illegal character in scope id
    ["https://[fe80::1%25a_b.c]/cb", true],
    ["https://[fe80::1%25a%25b]/cb", false], # Illegal character in scope id
    ["https://[fe80::1%25a~b]/cb", false], # Illegal character in scope id
    ["https://[fe80::1%25#{E_ACUTE}]/cb", false], # Illegal character in scope id
    ["https://[%25::1]/cb", false], # Malformed IPv6 address
    ["https://[::1%1]/cb", true],
    ["https://[::1%zz]/cb", true],
    ["https://[::1]:/cb", true],
    ["https://[::1]:8443/cb", true],
    ["https://[::1]:2147483647/cb", true],
    ["https://[::1]:2147483648/cb", false], # Malformed port number
    ["https://[::1]:00000000000000000080/cb", true],
    ["https://[::1]:99999999999/cb", false], # Malformed port number
    ["https://h:99999999999/cb", true],
    ["https://u@[::1]:8443/cb", true],
    ["https://u:p@[::1]/cb", true],
    ["https://a@b@[::1]/cb", false], # Illegal character in hostname
    ["https://[::1]", true],
    ["https://[::1]?x=[1]", true],
    ["myapp://[::1]/cb", true],
    ["myapp://[zz]/cb", false], # Malformed IPv6 address
    ["https://my_host/cb", true],
    ["https://999.1.1.1/cb", true],
    ["https://host:abc/cb", true],
    ["https://h#{E_ACUTE}/cb", true]
  ].freeze
  # 일부러 다른 셋 — JDK 는 받지만 R3 가 거부한다: zone id 의 `%` 뒤가 16진 두 자리가 아니다. RFC 6874 §2 는 URI 에서 그
  # `%` 를 `%25` 로 쓴다(`[fe80::1%25eth0]` 는 둘 다 받는다).
  ZONE_ID_R3 = ["https://[fe80::1%eth0]/cb", "https://[::1%1]/cb", "https://[::1%zz]/cb"].freeze

  # 표의 한 행을 이 SDK 가 싣는가 — JDK 가 받고, zone id 셋이 아니다.
  def self.carried?(value, jdk_reads) = jdk_reads && !ZONE_ID_R3.include?(value)

  # `to_s` 가 그 값인 객체 — rack-oauth2 는 값을 `to_s` 로 실었다(그래서 `URI(...)` 가 동작했다).
  Shown = Struct.new(:shown) do
    def to_s = shown
  end

  # 값은 절대 URI 지만 `to_s` 는 상대 URI 다 — 조립이 싣는 것은 `to_s` 다.
  class ShowsRelative < String
    def to_s = "cb"
  end

  # 값은 상대 URI 지만 `to_s` 는 절대 URI 다.
  class ShowsAbsolute < String
    def to_s = "https://app/shown"
  end
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

  # `cb#f` · `cb\xFF` · `1x:` 는 순서의 증명이다 — R1 이 R2·R3·R4 보다 앞이다(`1x:` 는 R4 도 거부한다).
  [*["", "cb", "/cb", "//app/cb", "not a url", "cb#f", "cb\xFF", "1x:"].map { |v| [v.inspect, v] },
   ["a UTF-16 String", "https://app/cb".encode("UTF-16LE")]].each do |what, value|
    it "refuses #{what} as not an absolute URI" do
      expect(refusal(value)).to eq(not_absolute)
    end
  end

  # 값은 rack-oauth2 가 하던 대로 `to_s` 로 바꾼 그 문자열로 검사한다 — 검사한 것이 곧 싣는 것이다. nil 은 "" 가 된다
  # (예전에는 redirect_uri 없는 URL 이 나갔다 — 실측).
  [["nil", nil, AuthzRedirectUriSpec::NOT_ABSOLUTE],
   ["the Integer 42", 42, AuthzRedirectUriSpec::NOT_ABSOLUTE],
   ["an object whose to_s is relative", AuthzRedirectUriSpec::Shown.new("cb"), AuthzRedirectUriSpec::NOT_ABSOLUTE],
   ["an object whose to_s is not a String", AuthzRedirectUriSpec::Shown.new(42), AuthzRedirectUriSpec::NOT_ABSOLUTE],
   ["an object whose to_s has a fragment", AuthzRedirectUriSpec::Shown.new("https://app/cb#f"),
    AuthzRedirectUriSpec::FRAGMENT],
   ["an object whose to_s has a space", AuthzRedirectUriSpec::Shown.new("https://app/c b"),
    AuthzRedirectUriSpec::NOT_VALID],
   ["a String whose to_s is relative", AuthzRedirectUriSpec::ShowsRelative.new("https://app/cb"),
    AuthzRedirectUriSpec::NOT_ABSOLUTE]].each do |what, value, message|
    it "checks #{what} as the string the URL would carry" do
      expect(refusal(value)).to eq(message)
    end
  end

  # URI 객체·Symbol 은 예전에도 실렸다(`to_s`). `to_s` 가 String 하위 타입을 돌려주면 그 값 자체를 평범한 String 으로
  # 만들어 검사하고 싣는다 — 하위 타입의 `to_s` 를 조립이 다시 부르면 검사하지 않은 값이 나간다.
  [["a URI object", URI("https://app/cb"), "https://app/cb"],
   ["a Symbol", :"https://app/cb", "https://app/cb"],
   ["a String whose to_s is absolute", AuthzRedirectUriSpec::ShowsAbsolute.new("cb"), "https://app/shown"],
   ["an object whose to_s is such a String",
    AuthzRedirectUriSpec::Shown.new(AuthzRedirectUriSpec::ShowsRelative.new("https://app/cb")),
    "https://app/cb"]].each do |what, value, sent|
    it "carries #{what} as its string" do
      expect(sent_redirect_uri(value)).to eq([sent])
    end
  end

  # `https://app/c b#f` · `https://app/c\xFF#f` · `https://app/c[b#f` 는 순서의 증명이다 — R2 가 R3·R4 보다 앞이다.
  ["https://app/cb#", "https://app/cb#f", "https://app/c b#f", "https://app/c\xFF#f",
   "https://app/c[b#f"].each do |value|
    it "refuses #{value.inspect} for its fragment" do
      expect(refusal(value)).to eq(fragment)
    end
  end

  # R4 — R1–R3 를 지나도 `java.net.URI.create` 가 던지는 값(JDK 21.0.8 실측): scheme 의 `:` 뒤가 비었다(R4a), 또는
  # `:` 뒤가 `/` 인 값의 `?` 앞에서 `[`·`]` 가 authority 의 괄호 호스트 하나 밖에 있다(R4b). 문구는 R3 와 같아 R3·R4 를
  # 함께 어기는 값(`https://app/c b[` · `https://app/c[\xFFb` · `myapp:/c[\xFF`)은 글만 잰다 — 깨진 UTF-8 은 R3 가 먼저
  # 받으므로 R4 의 정규식이 그 문자열에서 던지지 않는다.
  [*["https://app/c b", "https://app/cb\n", "https://app/c\\b", "https://app/c%zz", "https://app/c\u{A0}b",
     "https://app/c%2", "https://app/c%", "https://app/c%g0", "https://app/c\xFFb", "https://app/c\u{3000}b",
     "https://app/c\u{2028}b", "https://app/c b[", "https://app/c[\xFFb", "myapp:/c[\xFF"].map { |v| [v.inspect, v] },
   ["a binary String whose bytes are not UTF-8", "https://app/c\xFFb".b],
   ["an ISO-8859-1 String (its bytes are not UTF-8)", "https://app/c\xFCb".dup.force_encoding("ISO-8859-1")],
   *["https:", "myapp:", "https://app/c[b", "https://app/c]b", "myapp:/c[b", "https://[::1]/c[b", "https://app[1]/cb",
     "https://[::1]]/cb"].map { |v| ["#{v.inspect} (R4)", v] }]
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
   "https://app/c\u{3001}b", "https://[::1]/cb", "https://[::1]:8443/cb", "https://u@[::1]:8443/cb", "myapp:c[b",
   "urn:x[y]", "https:/", "https://[::1]?x=[1]"].each do |value|
    it "carries #{value.inspect} exactly as given" do
      expect(sent_redirect_uri(value)).to eq([value])
    end
  end

  it "holds the whole URI.create table, the three zone ids among the values the JDK reads" do
    table = AuthzRedirectUriSpec::URI_CREATE
    expect(table.size).to eq(83) # 빈 표면 아래 예제가 공허하게 통과한다
    expect(AuthzRedirectUriSpec::ZONE_ID_R3 - table.select(&:last).map(&:first)).to eq([])
  end

  # R4 의 authority — `java.net.URI.create` 가 받는 값은 그대로 싣고 거부하는 값은 R3·R4 문구로 거부한다. `//` 뒤가 비면
  # 거부(R4c), 괄호 호스트는 IPv6 주소여야 하고(R4d) 포트는 앞의 0 을 떼고 Java int 안이어야 한다(R4e). zone id 셋만
  # JDK 와 다르다 — R3 가 거부한다(위 ZONE_ID_R3). 결과 하나(거부 문구, 아니면 실린 값)를 표의 기대와 견준다.
  AuthzRedirectUriSpec::URI_CREATE.each do |value, jdk_reads|
    verb = AuthzRedirectUriSpec.carried?(value, jdk_reads) ? "carries" : "refuses"
    zone_id = " (R3: a zone id the JDK reads)" if AuthzRedirectUriSpec::ZONE_ID_R3.include?(value)
    it "#{verb} #{value.inspect}#{zone_id} as java.net.URI.create does" do
      expected = AuthzRedirectUriSpec.carried?(value, jdk_reads) ? [value] : not_valid
      expect(refusal(value) || sent_redirect_uri(value)).to eq(expected)
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
