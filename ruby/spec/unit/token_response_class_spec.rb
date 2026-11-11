# frozen_string_literal: true

require "spec_helper"
require "socket"
require_relative "../support/body_server"

# 토큰 응답의 오류 계급(등록부 `token-response-class-divergent` · 판정 2026-11-10) — **끝까지 온** 토큰·introspection 응답을
# 쓸 수 없으면 `KeycloakSdk::AuthError` 이고, 다 오지 않은 응답(네트워크 실패 · 타임아웃 · 1,048,576 바이트 상한 초과 · 깨진
# 틀)만 `KeycloakSdk::TransportError` 다.
#
# 같은 가짜 IdP(진짜 소켓 — `BodyServer`)로 네 면을 잰다: auth 레인의 client_credentials(S1) · SDK 의 토큰 provider(S2) ·
# introspection(INTRO) · admin 파사드의 자기 그랜트(S5 — admin 첫 호출이 보낸다). 칸은 아홉 언어 실측표의 것(503 HTML · 200
# HTML · access_token/active 없음 · 400 HTML · 문자열 안의 잘못된 UTF-8 · 모르는 charset)에 「JSON 이라고 적은 비-JSON」 둘
# (r2j · r8j) · 오류 본문의 잘못된 UTF-8(r8u) · 토큰 엔드포인트의 401·403·404·409 를 더했고, 대조군은 정상 응답 · 모르는
# charset · 상한 초과 · 본문 중간에서 멈춘 응답 · 연결 거부다.
#
# - D1 2xx 본문이 UTF-8 이 아니면 쓸 수 없는 응답이다(RFC 8259 §8.1) — 수정 전: 네 면 모두 TransportError.
# - D2 모르는 charset 은 효과가 없다(RFC 8259 §11) — 받아들인다(r10).
# - D3 introspection 의 `active` 가 없거나 boolean 이 아니면 깨진 응답이다(RFC 7662 §2.2 REQUIRED) — 수정 전: 비활성.
# - D4 admin 의 자기 그랜트는 끝까지 온 응답이면 상태와 무관하게 S1 과 같은 계급이다. Ruby 는 S5 가 S2 의 provider 를 지나므로
#   S2 와 같은 오류다. 실패면 admin 요청은 하나도 나가지 않는다.
# 오류 상태의 본문은 JSON · UTF-8 로 판정하지 않는다 — 상태가 판정한다(r8j · r8u 는 r8 과 같다).
module TokenResponseClassSpec
  REALM = "r"
  OIDC = "/realms/#{REALM}/protocol/openid-connect".freeze
  TOKEN = "#{OIDC}/token".freeze
  INTROSPECT = "#{OIDC}/token/introspect".freeze
  USER = "/admin/realms/#{REALM}/users/u1".freeze
  CAP = 1_048_576 # 시험의 신탁 — SDK 상수와 같은지는 token_response_cap_spec 이 본다
  TRUNCATED_READ_TIMEOUT = 0.5
  BAD = "#{0xFF.chr}#{0xFE.chr}".b # 어떤 UTF-8 에도 없는 바이트

  # 가짜 IdP 의 답 — [상태, Content-Type, 본문, 본문 뒤 JSON 공백 바이트, 본문을 거기까지만 쓰고 멈출 바이트].
  # `:refused` 는 닫힌 포트다. 표가 길어 중첩 모듈에 둔다.
  module Cells
    JSON_TYPE = "application/json"
    HTML_TYPE = "text/html"
    ODD_CHARSET = "application/json; charset=x-no-such-charset"
    # Ruby 가 「dummy」로 두는 인코딩 — 어댑터가 스트리밍 본문의 빈 자리표시를 이것으로 바꾸면 json 미들웨어의 `strip` 이
    # Encoding::CompatibilityError 를 던졌다(r11 · r12, 2026-11-11 실측: 네 면 모두 TransportError).
    UTF16_CHARSET = "application/json; charset=utf-16"
    HTML = "<html><body><h1>503 Service Unavailable</h1></body></html>"
    OK_TOKEN = '{"access_token":"AT-ok-token","token_type":"Bearer","expires_in":300}'
    OK_INTROSPECTION = '{"active":true,"username":"svc"}'

    # BOM 을 단 UTF-16LE — RFC 8259 §8.1 밖이다(BINARY).
    def self.utf16(json) = "\xFF\xFE".b + json.encode("UTF-16LE").b

    # 잘못된 UTF-8 은 Ruby 리터럴로 적을 수 없어 이어 붙인다(BINARY).
    def self.bytes(*parts) = parts.map(&:b).join

    TOKEN = {
      "ok" => [200, JSON_TYPE, OK_TOKEN],
      "r1 503 HTML" => [503, HTML_TYPE, HTML],
      "r2 200 HTML" => [200, HTML_TYPE, HTML],
      "r2j 200 HTML typed as JSON" => [200, JSON_TYPE, HTML],
      "r4 200 JSON without access_token" => [200, JSON_TYPE, '{"token_type":"Bearer","expires_in":300}'],
      "r8 400 HTML" => [400, HTML_TYPE, HTML],
      "r8j 400 HTML typed as JSON" => [400, JSON_TYPE, HTML],
      "r8u 400 invalid UTF-8 in the error body" =>
        [400, JSON_TYPE, bytes('{"error":"invalid_grant","error_description":"', BAD, '"}')],
      "r9 200 invalid UTF-8 inside a string" =>
        [200, JSON_TYPE, bytes('{"access_token":"AT-', BAD, '-token","token_type":"Bearer","expires_in":300}')],
      "r10 200 unknown charset" => [200, ODD_CHARSET, OK_TOKEN],
      "r11 200 charset=utf-16 over a UTF-8 body" => [200, UTF16_CHARSET, OK_TOKEN],
      "r12 200 charset=utf-16 over a UTF-16 body" => [200, UTF16_CHARSET, utf16(OK_TOKEN)],
      "401 invalid_client" => [401, JSON_TYPE, '{"error":"invalid_client"}'],
      "403 access_denied" => [403, JSON_TYPE, '{"error":"access_denied"}'],
      "404 realm missing" => [404, JSON_TYPE, '{"error":"Realm does not exist"}'],
      "409 conflict" => [409, JSON_TYPE, '{"error":"conflict"}'],
      "cap one byte past 1 MiB" => [200, JSON_TYPE, OK_TOKEN, CAP + 1 - OK_TOKEN.bytesize],
      "truncated mid-body" => [200, JSON_TYPE, OK_TOKEN, 0, OK_TOKEN.bytesize / 2],
      # 서버가 `Content-Length` 의 절반에서 연결을 닫는다 — net-http 0.10 의 기본 `ignore_eof: true` 는 그 절반을 성공처럼
      # 돌려줬다(독립 레그가 찾음: 그 본문이 「JSON 아님」 AuthError 였다). 다 오지 않은 응답이다.
      "closed mid-body" => [200, JSON_TYPE, OK_TOKEN, 0, OK_TOKEN.bytesize / 2, true],
      "connection refused" => :refused
    }.freeze

    INTROSPECTION = {
      "ok" => [200, JSON_TYPE, OK_INTROSPECTION],
      "inactive" => [200, JSON_TYPE, '{"active":false}'],
      "r1 503 HTML" => [503, HTML_TYPE, HTML],
      "r2 200 HTML" => [200, HTML_TYPE, HTML],
      "r2j 200 HTML typed as JSON" => [200, JSON_TYPE, HTML],
      "r4 200 JSON without active" => [200, JSON_TYPE, '{"username":"svc"}'],
      "d3 active is the string \"false\"" => [200, JSON_TYPE, '{"active":"false","username":"svc"}'],
      "d3 active is the string \"true\"" => [200, JSON_TYPE, '{"active":"true","username":"svc"}'],
      "d3 active is 1" => [200, JSON_TYPE, '{"active":1,"username":"svc"}'],
      "d3 active is null" => [200, JSON_TYPE, '{"active":null,"username":"svc"}'],
      "r8 400 HTML" => [400, HTML_TYPE, HTML],
      "r8j 400 HTML typed as JSON" => [400, JSON_TYPE, HTML],
      "r8u 400 invalid UTF-8 in the error body" =>
        [400, JSON_TYPE, bytes('{"error":"invalid_request","error_description":"', BAD, '"}')],
      "r9 200 invalid UTF-8 inside a string" => [200, JSON_TYPE, bytes('{"active":true,"username":"s', BAD, 'vc"}')],
      "r10 200 unknown charset" => [200, ODD_CHARSET, OK_INTROSPECTION],
      "r11 200 charset=utf-16 over a UTF-8 body" => [200, UTF16_CHARSET, OK_INTROSPECTION],
      "r12 200 charset=utf-16 over a UTF-16 body" => [200, UTF16_CHARSET, utf16(OK_INTROSPECTION)],
      "cap one byte past 1 MiB" => [200, JSON_TYPE, OK_INTROSPECTION, CAP + 1 - OK_INTROSPECTION.bytesize],
      "truncated mid-body" => [200, JSON_TYPE, OK_INTROSPECTION, 0, OK_INTROSPECTION.bytesize / 2],
      "closed mid-body" => [200, JSON_TYPE, OK_INTROSPECTION, 0, OK_INTROSPECTION.bytesize / 2, true],
      "connection refused" => :refused
    }.freeze
  end

  # 기대 판정 — [:ok, 값] 또는 [오류 클래스, 메시지, oauth_error]. S5 는 S2 와 같은 provider 라 오류가 같다(D4).
  module Verdicts
    AUTH = KeycloakSdk::AuthError
    TRANSPORT = KeycloakSdk::TransportError
    CC = "client-credentials failed"
    GRANT = "client-credentials token request failed"
    TIMED_OUT = /\Atoken endpoint transport error: Net::ReadTimeout/
    REFUSED = /\Atoken endpoint transport error: Failed to open TCP connection/
    CUT = /end of file reached/
    NO_ACTIVE = [AUTH, "introspection response has no boolean active", nil].freeze

    S1 = {
      "ok" => [:ok, "AT-ok-token"],
      # rack-oauth2's "Unknown" and Keycloak's prose are no codes (`oauth_error_code_echo_spec`).
      "r1 503 HTML" => [AUTH, "#{CC}: non-standard error code (HTTP 503)", nil],
      "r2 200 HTML" => [AUTH, "#{CC}: unusable token response (NoMethodError)", nil],
      "r2j 200 HTML typed as JSON" => [AUTH, "token response is not valid JSON", nil],
      "r4 200 JSON without access_token" => [AUTH, "#{CC}: unusable token response (AttrRequired::AttrMissing)", nil],
      "r8 400 HTML" => [AUTH, "#{CC}: non-standard error code (HTTP 400)", nil],
      "r8j 400 HTML typed as JSON" => [AUTH, "#{CC}: non-standard error code (HTTP 400)", nil],
      "r8u 400 invalid UTF-8 in the error body" => [AUTH, "#{CC}: non-standard error code (HTTP 400)", nil],
      "r9 200 invalid UTF-8 inside a string" => [AUTH, "token response is not valid UTF-8", nil],
      "r10 200 unknown charset" => [:ok, "AT-ok-token"],
      "r11 200 charset=utf-16 over a UTF-8 body" => [:ok, "AT-ok-token"],
      "r12 200 charset=utf-16 over a UTF-16 body" => [AUTH, "token response is not valid JSON", nil],
      "401 invalid_client" => [AUTH, "#{CC}: invalid_client (HTTP 401)", "invalid_client"],
      "403 access_denied" => [AUTH, "#{CC}: access_denied (HTTP 403)", "access_denied"],
      "404 realm missing" => [AUTH, "#{CC}: non-standard error code (HTTP 404)", nil],
      "409 conflict" => [AUTH, "#{CC}: conflict (HTTP 409)", "conflict"],
      "cap one byte past 1 MiB" => [TRANSPORT, "token response exceeds #{CAP} bytes", nil],
      "truncated mid-body" => [TRANSPORT, TIMED_OUT, nil],
      "closed mid-body" => [TRANSPORT, CUT, nil],
      "connection refused" => [TRANSPORT, REFUSED, nil]
    }.freeze

    S2 = {
      "ok" => [:ok, "AT-ok-token"],
      "r1 503 HTML" => [AUTH, "#{GRANT}: HTTP 503", nil],
      "r2 200 HTML" => [AUTH, "token response is not a JSON object", nil],
      "r2j 200 HTML typed as JSON" => [AUTH, "token response is not valid JSON", nil],
      "r4 200 JSON without access_token" => [AUTH, "token response has no usable access_token", nil],
      "r8 400 HTML" => [AUTH, "#{GRANT}: HTTP 400", nil],
      "r8j 400 HTML typed as JSON" => [AUTH, "#{GRANT}: HTTP 400", nil],
      "r8u 400 invalid UTF-8 in the error body" => [AUTH, "#{GRANT}: HTTP 400", nil],
      "r9 200 invalid UTF-8 inside a string" => [AUTH, "token response is not valid UTF-8", nil],
      "r10 200 unknown charset" => [:ok, "AT-ok-token"],
      "r11 200 charset=utf-16 over a UTF-8 body" => [:ok, "AT-ok-token"],
      "r12 200 charset=utf-16 over a UTF-16 body" => [AUTH, "token response is not valid JSON", nil],
      "401 invalid_client" => [AUTH, "#{GRANT}: HTTP 401", "invalid_client"],
      "403 access_denied" => [AUTH, "#{GRANT}: HTTP 403", "access_denied"],
      "404 realm missing" => [AUTH, "#{GRANT}: HTTP 404", nil],
      "409 conflict" => [AUTH, "#{GRANT}: HTTP 409", "conflict"],
      "cap one byte past 1 MiB" => [TRANSPORT, "token response exceeds #{CAP} bytes", nil],
      "truncated mid-body" => [TRANSPORT, TIMED_OUT, nil],
      "closed mid-body" => [TRANSPORT, CUT, nil],
      "connection refused" => [TRANSPORT, REFUSED, nil]
    }.freeze

    # admin 요청이 받은 Bearer 를 되돌려준다 — 그 토큰을 실제로 썼다는 증거.
    ADMIN_OK = [:ok, { "id" => "u1", "authorization" => "Bearer AT-ok-token" }].freeze
    S5 = S2.merge("ok" => ADMIN_OK, "r10 200 unknown charset" => ADMIN_OK,
                  "r11 200 charset=utf-16 over a UTF-8 body" => ADMIN_OK).freeze

    INTRO = {
      "ok" => [:ok, [true, "svc"]],
      "inactive" => [:ok, [false, nil]],
      "r1 503 HTML" => [AUTH, "introspection failed: HTTP 503", nil],
      "r2 200 HTML" => [AUTH, "introspection response is not a JSON object", nil],
      "r2j 200 HTML typed as JSON" => [AUTH, "introspection response is not valid JSON", nil],
      "r4 200 JSON without active" => NO_ACTIVE,
      "d3 active is the string \"false\"" => NO_ACTIVE,
      "d3 active is the string \"true\"" => NO_ACTIVE,
      "d3 active is 1" => NO_ACTIVE,
      "d3 active is null" => NO_ACTIVE,
      "r8 400 HTML" => [AUTH, "introspection failed: HTTP 400", nil],
      "r8j 400 HTML typed as JSON" => [AUTH, "introspection failed: HTTP 400", nil],
      "r8u 400 invalid UTF-8 in the error body" => [AUTH, "introspection failed: HTTP 400", nil],
      "r9 200 invalid UTF-8 inside a string" => [AUTH, "introspection response is not valid UTF-8", nil],
      "r10 200 unknown charset" => [:ok, [true, "svc"]],
      "r11 200 charset=utf-16 over a UTF-8 body" => [:ok, [true, "svc"]],
      "r12 200 charset=utf-16 over a UTF-16 body" => [AUTH, "introspection response is not valid JSON", nil],
      "cap one byte past 1 MiB" => [TRANSPORT, "introspection response exceeds #{CAP} bytes", nil],
      "truncated mid-body" => [TRANSPORT, /\Aintrospection transport error: Net::ReadTimeout/, nil],
      "closed mid-body" => [TRANSPORT, CUT, nil],
      "connection refused" => [TRANSPORT, /\Aintrospection transport error: Failed to open TCP connection/, nil]
    }.freeze

    BY_LANE = { "S1" => S1, "S2" => S2, "S5" => S5, "INTRO" => INTRO }.freeze

    def self.of(lane, cell) = BY_LANE.fetch(lane).fetch(cell)

    def self.label(lane, cell)
      want = of(lane, cell).first
      "#{lane} · #{cell}: #{want == :ok ? 'succeeds' : want.name}"
    end
  end

  # 한 번의 호출 — 값 또는 오류, 그리고 가짜 IdP 가 받은 요청 경로들.
  Outcome = Data.define(:value, :error, :paths) do
    def verdict
      return [:ok, value] unless error

      [error.class, error.message, error.respond_to?(:oauth_error) ? error.oauth_error : nil]
    end
  end

  module_function

  # 본문 중간에서 멈춘 칸만 읽기 타임아웃을 줄인다(그 칸은 타임아웃으로 끝난다) — 나머지는 기본값이다.
  def config(url, read_timeout: 10)
    KeycloakSdk::Config.new(server_url: url, realm: REALM, client_id: "c", client_secret: "cs",
                            read_timeout: read_timeout)
  end

  def provider(cfg)
    http = KeycloakSdk::Http.build(cfg) do |f|
      f.request :url_encoded
      f.response :json, content_type: /\bjson$/
    end
    KeycloakSdk::ClientCredentialsTokenProvider.new(config: cfg, http: http)
  end

  LANES = {
    "S1" => [TOKEN, ->(cfg) { KeycloakSdk::KeycloakClient.new(cfg).auth.client_credentials_token.access_token }],
    "S2" => [TOKEN, ->(cfg) { provider(cfg).access_token }],
    "S5" => [TOKEN, ->(cfg) { KeycloakSdk::KeycloakClient.new(cfg).admin.users.get("u1") }],
    "INTRO" => [INTROSPECT, lambda { |cfg|
      result = KeycloakSdk::KeycloakClient.new(cfg).auth.introspect("tok")
      [result.active, result.username]
    }]
  }.freeze

  def cells(lane) = lane == "INTRO" ? Cells::INTROSPECTION : Cells::TOKEN

  # 한 프로세스에 한 번씩 잰다 — 판정 · D4 대조 · 누출 검사가 같은 결과를 나눠 쓴다.
  def outcome(lane, cell)
    (@outcomes ||= {})[[lane, cell]] ||= begin
      path, call = LANES.fetch(lane)
      against(cells(lane).fetch(cell), path, &call)
    end
  end

  def against(answer, path)
    return attempt(nil) { yield config(closed_url) } if answer == :refused

    server = BodyServer.new(framing: :length)
    status, type, body, pad, stop, close = answer
    server.route(path) { [status, { "Content-Type" => type }, body, pad || 0, stop, close] }
    server.route(USER) { |r| [200, {}, { id: "u1", authorization: r.headers["authorization"] }.to_json, 0] }
    cfg = stop ? config(server.url, read_timeout: TRUNCATED_READ_TIMEOUT) : config(server.url)
    attempt(server) { yield cfg }
  ensure
    server&.close
  end

  def attempt(server)
    value = yield
    Outcome.new(value: value, error: nil, paths: paths(server))
  rescue StandardError => e
    Outcome.new(value: nil, error: e, paths: paths(server))
  end

  def paths(server) = server.is_a?(BodyServer) ? server.requests.map(&:path) : []

  def closed_url
    probe = TCPServer.new("127.0.0.1", 0)
    port = probe.addr[1]
    probe.close
    "http://127.0.0.1:#{port}"
  end

  # 사용자가 보는 표현 전부 — 로거는 `full_message` 로 `cause` 사슬까지 찍는다.
  def renderings(err)
    out = [err.message, err.inspect, err.full_message(highlight: false)]
    cause = err.cause
    while cause
      out.push(cause.message, cause.inspect)
      cause = cause.cause
    end
    out.map(&:b)
  end

  def chain(err)
    names = []
    while err
      names << err.class.name
      err = err.cause
    end
    names
  end
end

RSpec.describe KeycloakSdk::KeycloakClient do
  around do |example|
    WebMock.disable!
    example.run
  ensure
    WebMock.enable!
  end

  let(:spec) { TokenResponseClassSpec }

  describe "token and introspection response error class (token-response-class-divergent)" do
    TokenResponseClassSpec::LANES.each_key do |lane|
      TokenResponseClassSpec.cells(lane).each_key do |cell|
        it TokenResponseClassSpec::Verdicts.label(lane, cell) do
          expect(spec.outcome(lane, cell).verdict).to match(spec::Verdicts.of(lane, cell))
        end
      end
    end

    # D4 — 끝까지 온 응답이면 admin 의 자기 그랜트도 S1 과 같은 계급이다(상태와 무관). 기대표가 아니라 두 레인의 실제
    # 결과를 대조한다.
    it "fails the admin facade's own grant exactly when S1 fails, with the same error class (D4)" do
      diverged = spec::Cells::TOKEN.keys.filter_map do |cell|
        s1 = spec.outcome("S1", cell).verdict.first
        s5 = spec.outcome("S5", cell).verdict.first
        "#{cell}: S1 #{s1}, S5 #{s5}" unless s1 == s5
      end
      expect(diverged).to eq([])
    end

    it "sends no admin request when the admin facade's own grant fails, and exactly one when it succeeds" do
      wrong = spec::Cells::TOKEN.keys.filter_map do |cell|
        out = spec.outcome("S5", cell)
        admin = out.paths.count(spec::USER)
        "#{cell}: #{admin} admin request(s)" unless admin == (out.error ? 0 : 1)
      end
      expect(wrong).to eq([])
    end

    # 토큰 엔드포인트의 404 는 리소스가 없다는 말이 아니다 — NotFoundError 를 「이미 지워졌다」로 처리하는 소비자에게 그것은
    # 지우지 않은 사용자를 지운 것으로 만든다(go #952 · php #1003 의 모양). Ruby 는 이미 AuthError 다 — 그것을 고정한다.
    it "does not read a delete whose token request got a 404 as already gone" do
      server = BodyServer.new(framing: :length)
      server.route(spec::TOKEN) { [404, {}, '{"error":"Realm does not exist"}', 0] }
      expect { described_class.new(spec.config(server.url)).admin.users.delete("u1") }
        .to raise_error(KeycloakSdk::AuthError, "client-credentials token request failed: HTTP 404")
      expect(server.requests.map(&:path)).to eq([spec::TOKEN])
    ensure
      server&.close
    end

    # 새로 AuthError 가 된 칸이 응답 본문 · 하위 예외를 싣지 않는다 — 메시지 · inspect · full_message · 원인 사슬 어디에도.
    it "carries neither the body nor a lower-library exception on the cells that became AuthError" do
      cells = ["r2j 200 HTML typed as JSON", "r8j 400 HTML typed as JSON", "r8u 400 invalid UTF-8 in the error body",
               "r9 200 invalid UTF-8 inside a string"]
      pieces = ["AT-", "<html", "invalid_grant", "invalid_request", "svc", spec::BAD].map(&:b)
      found = spec::LANES.keys.product(cells).filter_map do |lane, cell|
        err = spec.outcome(lane, cell).error
        next "#{lane} #{cell}: no error" unless err

        foreign = spec.chain(err).reject { |n| n.start_with?("KeycloakSdk::") }
        shown = pieces.select { |p| spec.renderings(err).any? { |s| s.include?(p) } }
        "#{lane} #{cell}: lower #{foreign} · shows #{shown}" unless foreign.empty? && shown.empty?
      end
      expect(found).to eq([])
    end
  end
end
