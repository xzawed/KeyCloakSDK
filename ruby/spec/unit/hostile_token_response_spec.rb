# frozen_string_literal: true

require "spec_helper"
require "base64"
require "pp"

# 적대적·형식이 틀린 IdP 응답에서 난 SDK 오류가 **그 응답의 토큰·본문을 찍지 않는다** — Node #603 의 Ruby 측정.
#
# Ruby 는 `rescue` 안에서 `raise` 하면 처리 중인 하위 예외를 **자동으로 `cause` 에 단다**. 그 사슬은
# `full_message`(잡히지 않은 예외·로거가 찍는 것)에 실리고, 하위 예외의 메시지가 응답을 인용하면 그대로 찍힌다.
# 걷기 테스트(`facade_dump_spec.rb`)의 뿌리는 401·깨진 토큰·도달 불가뿐이라 이 경로를 안 밟는다 — 여기서
# **변형 × 공개 호출** 행렬로 밟는다. 변형마다 realm 을 따로 둬 URL 로 응답을 고른다(호출 순서와 무관).
#
# 검사는 **전체 일치 또는 앞 10 자** — 하위 파서가 입력을 잘라 인용한다(Node 의 `JSON.parse` 가 앞 10 자).
module HostileTokenResponseSpec
  SERVER = "https://kc.hostile.test"
  CALLBACK = "https://app/cb"
  # SDK 가 **보내는** 비밀 — IdP 가 되울리면 이것이 찍힌다.
  SECRET = "sQ7k-client-secret-canary"
  SENT_REFRESH = "rS7k-sent-refresh-token-canary"
  SENT_CODE = "cD7k-sent-authorization-code-canary"
  SENT_VERIFIER = "vF7k-sent-pkce-verifier-canary-0123456789abcdefghijklmnopqrstu"
  SENT_TOKEN = "tK7k-sent-introspected-token-canary"
  SENT = { "SECRET" => SECRET, "BASIC" => Base64.strict_encode64("c:#{SECRET}"), "SENT_REFRESH" => SENT_REFRESH,
           "SENT_CODE" => SENT_CODE, "SENT_VERIFIER" => SENT_VERIFIER, "SENT_TOKEN" => SENT_TOKEN }.freeze

  JSON_TYPE = { "Content-Type" => "application/json" }.freeze
  LONG_BODY = "dL7k-long-non-json-body-canary.#{'x' * 400}".freeze

  # 공개 호출 — 토큰·introspect·logout 엔드포인트를 부르는 것 전부. 기본 경로(파사드)와 주입 경로(provider).
  CALLS = {
    "auth.client_credentials_token" => ->(s) { s.kc.auth.client_credentials_token },
    "auth.access_token" => ->(s) { s.kc.auth.access_token },
    "auth.refresh" => ->(s) { s.kc.auth.refresh(refresh_token: SENT_REFRESH) },
    "auth.exchange_code" => lambda { |s|
      s.kc.auth.exchange_code(code: SENT_CODE, code_verifier: SENT_VERIFIER, redirect_uri: CALLBACK)
    },
    "auth.exchange_code(expected_nonce:)" => lambda { |s|
      s.kc.auth.exchange_code(code: SENT_CODE, code_verifier: SENT_VERIFIER, redirect_uri: CALLBACK,
                              expected_nonce: "n-1")
    },
    "ClientCredentialsTokenProvider#access_token" => ->(s) { s.provider.access_token },
    "admin.users.get(token via provider)" => ->(s) { s.kc.admin.users.get("u") },
    "auth.introspect" => ->(s) { s.kc.auth.introspect(SENT_TOKEN) },
    "auth.logout" => ->(s) { s.kc.auth.logout(refresh_token: SENT_REFRESH) }
  }.freeze

  RACK = ["auth.client_credentials_token", "auth.access_token", "auth.refresh", "auth.exchange_code",
          "auth.exchange_code(expected_nonce:)"].freeze
  PROVIDER = ["ClientCredentialsTokenProvider#access_token", "admin.users.get(token via provider)"].freeze
  TOKEN = (RACK + PROVIDER).freeze
  ALL = (TOKEN + ["auth.introspect", "auth.logout"]).freeze

  # 변형 표 — 중첩 모듈에 둔다(표가 길다).
  module Table
    def self.json(status, body) = { status: status, headers: JSON_TYPE, body: body.to_json }

    def self.expect_all(calls, klass) = calls.to_h { |c| [c, klass] }

    def self.b64(text) = Base64.urlsafe_encode64(text, padding: false)

    auth = KeycloakSdk::AuthError
    transport = KeycloakSdk::TransportError
    header = "aHD8k-decoded-header-canary"
    payload = "aPL8k-decoded-payload-canary"
    # 변형 — realm 이름 => 응답·그 응답이 품은 카나리아·호출별 기대 SDK 오류(흐름 검사).
    # ⚠️ 기대에 없는 (변형, 호출) 쌍은 SDK 가 그 응답을 **받아들이는** 경우다(예: id_token 은 nonce 검증에서만 읽힌다).
    VARIANTS = {
      "a1" => { note: "200 JSON — id_token 이 JWT 가 아니다",
                reply: json(200, access_token: "aAT7k-access-token-canary", token_type: "Bearer", expires_in: 300,
                                 refresh_token: "aRT7k-refresh-token-canary", id_token: "aID7k-id-token-canary"),
                expect: { "auth.exchange_code(expected_nonce:)" => auth } },
      "a2" => { note: "200 JSON — id_token 이 세 조각이지만 헤더가 JSON 이 아니다(디코드하면 카나리아)",
                reply: json(200, access_token: "aAT8k-access-token-canary", token_type: "Bearer", expires_in: 300,
                                 refresh_token: "aRT8k-refresh-token-canary",
                                 id_token: "#{b64(header)}.#{b64(payload)}.c2ln"),
                canaries: { "a2.HEADER" => header, "a2.PAYLOAD" => payload },
                expect: { "auth.exchange_code(expected_nonce:)" => auth } },
      "b1" => { note: "200 JSON — access_token 이 문자열이 아니다, refresh_token 은 카나리아",
                reply: json(200, access_token: 123, token_type: "Bearer", expires_in: 300,
                                 refresh_token: "bRT7k-refresh-token-canary", id_token: "bID7k-id-token-canary"),
                expect: expect_all(TOKEN, auth) },
      "b2" => { note: "200 JSON — access_token 이 없다, refresh_token 은 카나리아",
                reply: json(200, token_type: "Bearer", expires_in: 300, refresh_token: "bRT8k-refresh-token-canary"),
                expect: expect_all(TOKEN, auth) },
      "c1" => { note: "200 JSON — expires_in 이 숫자가 아니다, 토큰은 카나리아",
                reply: json(200, access_token: "cAT7k-access-token-canary", token_type: "Bearer", expires_in: "soon",
                                 refresh_token: "cRT7k-refresh-token-canary", id_token: "cID7k-id-token-canary"),
                expect: expect_all(TOKEN, auth) },
      "c2" => { note: "200 JSON — token_type 이 문자열이 아니다, 토큰은 카나리아(provider 는 token_type 을 안 본다)",
                reply: json(200, access_token: "cAT8k-access-token-canary", token_type: 5, expires_in: 300,
                                 refresh_token: "cRT8k-refresh-token-canary"),
                expect: expect_all(RACK, auth) },
      "d1" => { note: "200 application/json — 본문이 JSON 이 아닌 짧은 카나리아(<=20자)",
                reply: { status: 200, headers: JSON_TYPE, body: "dS7k-short-body" },
                expect: expect_all(ALL, transport) },
      "d2" => { note: "200 application/json — 본문이 카나리아로 시작하는 긴 비-JSON",
                reply: { status: 200, headers: JSON_TYPE, body: LONG_BODY },
                canaries: { "d2.BODY" => "dL7k-long-non-json-body-canary" },
                expect: expect_all(ALL, transport) },
      "d3" => { note: "200 text/plain — 본문이 짧은 카나리아(logout 은 본문을 안 읽어 받아들인다)",
                reply: { status: 200, headers: { "Content-Type" => "text/plain" }, body: "dT7k-plain-body" },
                expect: expect_all(TOKEN + ["auth.introspect"], auth) },
      "e1" => { note: "400 JSON — error_description 이 토큰을 되울린다",
                reply: json(400, error: "invalid_grant",
                                 error_description: "Token is not active: eEC7k-echoed-token-canary"),
                expect: expect_all(ALL, auth) },
      "e2" => { note: "401 JSON — error_description 이 보낸 클라이언트 시크릿을 되울린다",
                reply: json(401, error: "invalid_client", error_description: "Invalid client secret #{SECRET}"),
                expect: expect_all(ALL, auth) },
      "e3" => { note: "400 text/html — 요청을 되울리는 WAF 차단 페이지",
                reply: { status: 400, headers: { "Content-Type" => "text/html" },
                         body: "<html>blocked: refresh_token=#{SENT_REFRESH}&code=eHT7k-waf-echo-canary</html>" },
                canaries: { "e3.BODY" => "eHT7k-waf-echo-canary" },
                expect: expect_all(ALL, auth) },
      "e4" => { note: "400 application/json — 오류 본문이 JSON 이 아니다",
                reply: { status: 400, headers: JSON_TYPE, body: "eJS7k-bad-json-err" },
                expect: expect_all(ALL, transport) },
      "f1" => { note: "200 JSON — 본문이 객체가 아니라 배열",
                reply: { status: 200, headers: JSON_TYPE, body: ["fAR7k-array-body-canary"].to_json },
                canaries: { "f1.BODY" => "fAR7k-array-body-canary" },
                expect: expect_all(ALL - ["auth.logout"], auth) },
      # 연결 계층 실패도 응답을 인용한다 — Net::HTTP 는 깨진 상태 줄을 메시지에 dump 하고 어댑터가 ConnectionFailed 로 감싼다.
      "g1" => { note: "상태 줄이 깨졌다(Net::HTTPBadResponse → Faraday::ConnectionFailed)",
                raise: Net::HTTPBadResponse.new('wrong status line: "HTTP/1.1 gSL7k-status-line-canary"'),
                expect: expect_all(ALL, transport) },
      # 같은 경계가 admin 에도 있다 — 토큰은 정상, admin 응답이 JSON 이 아니다. 요청에는 살아 있는 베어러가 실린다.
      "h1" => { note: "admin 200 application/json — 본문이 JSON 이 아니다(토큰 발급은 정상)",
                reply: json(200, access_token: "hAT7k-admin-bearer-canary", token_type: "Bearer", expires_in: 300),
                admin: { status: 200, headers: JSON_TYPE, body: "hBD7k-admin-body-canary" },
                expect: { "admin.users.get(token via provider)" => transport } },
      # 대조군 — 응답을 인용할 수 없는 연결 실패는 메시지를 그대로 남긴다(디버깅 정보를 과하게 깎지 않았다).
      "z1" => { note: "연결 거부(Errno::ECONNREFUSED → Faraday::ConnectionFailed)",
                raise: Errno::ECONNREFUSED, expect: expect_all(ALL, transport) }
    }.freeze
  end
  VARIANTS = Table::VARIANTS

  # 알려진 누출 — `"변형|호출|경로|카나리아"` => 사유. ⚠️ 더 안 새면 **지워야 통과한다**(낡은 항목 검사).
  KNOWN_LEAKS = {}.freeze

  # 변형의 카나리아 — 응답 본문의 카나리아 모양 문자열 전부(자동) + 명시분 + SDK 가 보낸 비밀.
  def self.canaries(key)
    v = VARIANTS.fetch(key)
    texts = [v.dig(:reply, :body), v.dig(:admin, :body), v[:raise].is_a?(Exception) ? v[:raise].message : nil].compact
    found = texts.join(" ").scan(/[a-z][A-Z]{1,2}\dk-[\w-]+/).to_h { |c| ["#{key}.#{c[0, 3]}", c] }
    SENT.merge(found, v.fetch(:canaries, {}))
  end

  # 한 변형의 가짜 IdP 와 그 realm 의 클라이언트들.
  class Scene
    extend WebMock::API

    attr_reader :kc, :provider

    def initialize(key)
      @key = key
      stub
      cfg = KeycloakSdk::Config.new(server_url: SERVER, realm: key, client_id: "c", client_secret: SECRET)
      @kc = KeycloakSdk::KeycloakClient.new(cfg)
      http = KeycloakSdk::Http.build(cfg) do |f|
        f.request :url_encoded
        f.response :json, content_type: /\bjson$/
      end
      @provider = KeycloakSdk::ClientCredentialsTokenProvider.new(config: cfg, http: http)
    end

    # 호출 하나 — 오류를 돌려준다(SDK 밖 예외도 그대로 잡아 잰다). 성공하면 nil.
    def run(call)
      CALLS.fetch(call).call(self)
      nil
    rescue StandardError => e
      e
    end

    def served?
      pattern = WebMock::RequestPattern.new(:any, %r{/realms/#{@key}/protocol/openid-connect/})
      WebMock::RequestRegistry.instance.times_executed(pattern).positive?
    end

    private

    # ⚠️ admin 은 변형이 안 정했어도 스텁한다(404) — 토큰 발급이 뜻밖에 성공하면 미등록 요청 예외(Exception 이라
    # `run` 이 못 잡는다)로 행렬이 통째로 죽지 않고, 흐름 검사가 「기대 X, 실제 NotFoundError」로 짚는다.
    def stub
      v = VARIANTS.fetch(@key)
      oidc = self.class.stub_request(
        :post, %r{\A#{Regexp.escape(SERVER)}/realms/#{@key}/protocol/openid-connect/(token|token/introspect|logout)\z}
      )
      v[:raise] ? oidc.to_raise(v[:raise]) : oidc.to_return(v[:reply])
      self.class.stub_request(:any, %r{\A#{Regexp.escape(SERVER)}/admin/realms/#{@key}/})
          .to_return(v.fetch(:admin, { status: 404 }))
    end
  end

  # 사용자가 보는 표현 전부 — 로거는 `full_message` 로 `cause` 사슬까지 찍는다.
  def self.renderings(err)
    outs = { "message" => err.message, "inspect" => err.inspect, "pretty_inspect" => err.pretty_inspect,
             "full_message" => err.full_message(highlight: false) }
    cause = err.cause
    (1..8).each do |depth|
      break if cause.nil?

      outs["cause[#{depth}].message"] = cause.message
      outs["cause[#{depth}].inspect"] = cause.inspect
      cause = cause.cause
    end
    outs
  end

  # 오류와 그 `cause` 들의 클래스 이름(바깥부터).
  def self.chain(err)
    names = []
    while err && names.size < 10
      names << err.class.name
      err = err.cause
    end
    names
  end

  # [경로, 카나리아 이름, FULL|PREFIX10] — 앞 10 자만 나와도 누출이다.
  def self.scan(outs, canaries)
    outs.flat_map do |path, text|
      canaries.filter_map do |name, value|
        if text.include?(value) then [path, name, "FULL"]
        elsif text.include?(value[0, 10]) then [path, name, "PREFIX10"]
        end
      end
    end
  end

  # 행렬 전부를 돌려 [변형, 호출, 오류] 를 모은다.
  def self.outcomes
    VARIANTS.flat_map do |key, v|
      scene = Scene.new(key)
      rows = v[:expect].keys.map { |call| [key, call, scene.run(call)] }
      rows << [key, :served, scene.served?]
    end
  end
end

RSpec.describe KeycloakSdk::AuthClient do
  describe "errors from hostile or malformed IdP responses" do
    let(:outcomes) { HostileTokenResponseSpec.outcomes }
    let(:calls) { outcomes.reject { |_, call, _| call == :served } }

    it "makes every hostile variant fail the call with the expected SDK error (flow check)" do
      unserved = outcomes.select { |_, call, hit| call == :served && !hit }.map(&:first)
      expect(unserved).to eq([]), "가짜 IdP 가 응답하지 않은 변형: #{unserved}"
      wrong = calls.filter_map do |key, call, err|
        want = HostileTokenResponseSpec::VARIANTS[key][:expect][call]
        "#{key} #{call}: 기대 #{want}, 실제 #{err.nil? ? '성공(오류 없음)' : err.class}" unless want === err # rubocop:disable Style/CaseEquality
      end
      expect(wrong).to eq([]), "변형이 호출을 기대대로 실패시키지 않았다:\n#{wrong.join("\n")}"
      expect(calls.size).to be > 60 # 행렬이 공허하지 않다
    end

    it "never prints a canary (full or a 10-char prefix) on message, inspect, full_message or the cause chain" do
      seen = []
      leaks = calls.select { |_, _, err| err }.flat_map do |key, call, err|
        outs = HostileTokenResponseSpec.renderings(err)
        HostileTokenResponseSpec.scan(outs, HostileTokenResponseSpec.canaries(key)).filter_map do |path, name, how|
          id = "#{key}|#{call}|#{path}|#{name}"
          next seen << id if HostileTokenResponseSpec::KNOWN_LEAKS.key?(id)

          "#{id} [#{err.class}] #{how}"
        end
      end
      expect(leaks).to eq([]), "오류 표현이 카나리아를 찍는다:\n#{leaks.join("\n")}"
      expect(HostileTokenResponseSpec::KNOWN_LEAKS.keys - seen).to eq([]), "알려진 누출이 더 안 난다 — 지워라"
    end

    it "keeps every cause an SDK type — no lower-library exception rides the chain (§4)" do
      foreign = calls.select { |_, _, err| err }.filter_map do |key, call, err|
        names = HostileTokenResponseSpec.chain(err)
        "#{key} #{call}: #{names.join(' <- ')}" unless names.all? { |n| n.start_with?("KeycloakSdk::") }
      end
      expect(foreign).to eq([]), "하위 예외가 공개 API 로 샜다(원인 사슬 포함):\n#{foreign.join("\n")}"
    end

    # 깎은 것은 응답이 실리는 자리뿐이다 — OAuth 코드·HTTP 상태·하위 클래스 이름·인용 없는 연결 실패 메시지는 남는다.
    it "keeps the debugging info: OAuth code, HTTP status, lower class names, quote-free transport messages" do
      run = ->(key, call) { HostileTokenResponseSpec::Scene.new(key).run(call) }
      oauth = run.call("e1", "auth.refresh")
      expect([oauth.message, oauth.oauth_error]).to eq(["refresh failed: invalid_grant (HTTP 400)", "invalid_grant"])
      parse = run.call("d1", "auth.client_credentials_token")
      expect(parse.message).to eq("token endpoint transport error: Faraday::ParsingError")
      expect(parse.cause.lower_classes).to eq(%w[Faraday::ParsingError JSON::ParserError])
      refused = Errno::ECONNREFUSED.new("Exception from WebMock").message # OS 마다 문구가 달라 원천에서 얻는다
      expect(run.call("z1", "auth.introspect").message).to eq("introspection transport error: #{refused}")
      expect(run.call("c2", "auth.client_credentials_token").message)
        .to eq("client-credentials failed: unusable token response (NoMethodError)")
    end

    it "sees a canary when a rendering does carry one (the detector is not blind)" do
      err = RuntimeError.new("x #{HostileTokenResponseSpec::LONG_BODY[0, 12]}")
      found = HostileTokenResponseSpec.scan(HostileTokenResponseSpec.renderings(err),
                                            HostileTokenResponseSpec.canaries("d2"))
      expect(found).to include(["message", "d2.BODY", "PREFIX10"])
      expect(HostileTokenResponseSpec.canaries("e1")).to include("e1.eEC" => "eEC7k-echoed-token-canary")
    end
  end
end
