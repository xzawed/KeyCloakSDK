# frozen_string_literal: true

require "spec_helper"
require "base64"
require "jwt"
require "openssl"
require "pp"

# 바닥 계약(기본 표현이 비밀을 찍지 않는다)을 **손으로 고른 값 타입이 아니라 도달 가능한 객체 전부**에
# 건다. `tokens_spec`·`config_spec` 은 값 타입 몇을 재는데, 자매 SDK(go·php·dotnet)에서 실측(2026-09-26)으로
# 그 밖의 **파사드**가 새고 있었다. 이 파일은 Go `facade_dump_test.go`·PHP `FacadeDumpTest.php` 와 같은 모양이다.
#
# ⚠️ **새 자리를 스스로 찾는 것이 요점이다**(등록부 `guard-detection-surface-hand-narrowed`). 검사 대상은
# (1) 공개 API 로 만든 뿌리에서 리플렉션으로 **닿는 이 SDK 의 객체 전부**이고, (2) `KeycloakSdk.constants` 를
# 재귀로 훑어 얻은 **선언 타입 전수**가 그 걷기에 걸렸는지 대조한다. 그 전수는 다시 `ruby/lib` 의
# `class`/`module`/`X = Data.define` 선언과 맞춰 본다(로드 안 된 새 파일도 여기서 걸린다).
#
# ⚠️ Ruby 고유: 기본 `#inspect` 는 ivar 를 **재귀로** 찍으므로 SDK 객체 안의 Faraday 객체도 표현에 섞인다.
# 그래서 걷기는 **남의 객체 속으로도 내려간다**(`BearerAuth`·기본 경로의 provider 는 Faraday 미들웨어
# 사슬 안에만 있다). 찍어 재는 것은 SDK 타입뿐이다. `Data` 멤버는 ivar 가 아니라서 따로 걷는다.
#
# 바닥 경로는 SDK 타입의 `inspect`·`to_s`·`pretty_inspect`, 예외는 `full_message` 까지(`cause` 사슬의
# 메시지가 거기 실린다). 남의 타입은 걷기만 하고 따로 찍지 않는다 — SDK 객체의 `inspect` 가 이미 그것을 싣는다.
#
# ⚠️ 비밀 이름의 필드가 빈 값으로만 닿으면 실패한다(등록부 `facade-dump-reached-empty-secret-field`). 카나리아 검사는
# 뿌리가 채운 값만 본다 — 아무 뿌리도 채우지 않는 새 비밀 필드는 빈 값으로 찍혀 아무것도 증명하지 못한 채 초록이었다.
# 그래서 걷기가 SDK 타입이 선언한 필드(ivar 는 `ruby/lib` 에서 그것을 대입하는 SDK 클래스·모듈의 것, `Data` 멤버는 그
# 클래스의 것)마다 「비지 않은 값을 쥔 인스턴스를 봤는가」를 적고(`Walker#record`), 이름이 비밀을 뜻하는데 닿은
# 인스턴스가 전부 빈 값이면 실패한다 — 뿌리에서 카나리아로 채우거나 `EMPTY_SECRET_EXEMPT` 에 이유와 함께 적는다.
# 한계: 비밀 이름의 필드가 비지 않은 자리표시 값을 쥐면, 비밀이 순한 이름의 필드에 들면, 인코딩된(base64 등) 비밀이면
# 이 검사는 못 본다.
#
# ⚠️ 한계: 카나리아는 뿌리를 만드는 호출이 흘려 넣은 비밀뿐이다. 새 타입이 이 뿌리들이 안 밟는 경로로
# 비밀을 받으면 그 비밀은 여기 없다 — 그때는 그 경로를 뿌리에 더한다. 검사는 **전체 일치**라서
# 부분 노출(`"CANA***"` 같은 접두·접미 마스크)은 못 잡는다 — 부분 일치는 렌더링 속 난수(JWKS 모듈러스·
# state·nonce)와 우연히 겹쳐 흔들린다. `***` 모양 자체는 타입별 spec 이 잰다(`include("***")` 라서 그것도
# 접두 마스크를 통과시킨다 — 알려진 빈틈).
module FacadeDumpSpec
  SECRET = "CANARY-DUMP-CLIENT-SECRET"
  ACCESS = "CANARY-DUMP-ACCESS-TOKEN"
  REFRESH = "CANARY-DUMP-REFRESH-TOKEN"
  ID = "CANARY-DUMP-ID-TOKEN"
  GARBAGE = "CANARY-DUMP-GARBAGE-TOKEN"
  PASSWORD = "CANARY-DUMP-ADMIN-PASSWORD"
  SERVER = "https://kc.dump.test"
  # 닿지 않는 서버 — webmock 이 연결 거부를 낸다(Windows 에서 실제 닫힌 포트는 거부까지 ~2초 걸린다).
  DOWN = "https://down.dump.test"
  CALLBACK = "https://app/cb"

  # 걷기에 안 닿아도 되는 클래스와 그 이유. ⚠️ 이유 없는 면제는 넣지 않는다.
  EXEMPT = {
    "KeycloakSdk::Error" => "오류 계층의 추상 루트 — lib 어디도 이것을 맨몸으로 raise 하지 않는다. 하위 여덟은 " \
                            "실제 실패 호출로 전부 닿고, 표현은 Exception#inspect 를 그대로 물려받는다."
  }.freeze

  # 알려진 누출 — `"뿌리|카나리아"` => 사유. ⚠️ 고쳐져 더 안 새면 **여기서 지워야 통과한다**(낡은 항목 검사).
  KNOWN_LEAKS = {}.freeze

  # 비밀 이름인데 닿은 인스턴스가 전부 빈 값이어도 되는 필드 — `"<타입>.<필드>"` => 이유. ⚠️ 이유 없는 면제는 넣지
  # 않는다. 더는 「닿고 · 빈 값만」이 아니면(비지 않은 값이 보였거나 닿지 않으면) 낡은 면제다.
  EMPTY_SECRET_EXEMPT = {}.freeze

  # 규칙 1–3 — 비밀 이름의 낱말, 빈 값, 그리고 SDK 타입이 선언한 필드(규칙 2).
  module SecretFields
    WORDS = %w[secret password passwd passphrase token credential verifier private key bearer].freeze
    # 대소문자 경계 — 대문자 묶음(약어)은 다음 대문자 낱말 앞에서 끝난다(`IDToken` → `ID`·`Token`).
    WORD = /[A-Z]+(?=[A-Z][a-z])|[A-Z]?[a-z]+|[A-Z]+|[0-9]+/
    # `ruby/lib` 의 ivar 대입(`@이름 =`·`@이름 ||=` 등) — ivar 는 선언이 없으므로 대입이 곧 선언이다.
    IVAR = %r{@([a-z_]\w*)\s*(?:\|\||&&|[-+*/])?=(?![=~>])}
    IVARS = Kernel.instance_method(:instance_variables)
    IVAR_GET = Kernel.instance_method(:instance_variable_get)
    CLASS_OF = Kernel.instance_method(:class)

    # `_`·`-`·`$`·`.`·`@`·`#` 와 대소문자 경계로 자르고, 소문자로 바꿔 끝의 `s` 하나를 뗀다.
    def self.words(name)
      name.to_s.split(/[_\-$.@#]+/).flat_map { |part| part.scan(WORD) }.map { |w| w.downcase.delete_suffix("s") }
    end

    def self.secret_named?(name) = words(name).any? { |w| WORDS.include?(w) }

    # nil, 길이 0 인 String·Array·Hash·Set. 불리언·숫자·심벌·그 밖의 객체는 비지 않았다.
    def self.empty?(value)
      case value
      when nil then true
      when String, Array, Hash, Set then value.empty?
      else false
      end
    end

    # (선언한 SDK 타입, 필드, 값). ivar 는 그것을 `ruby/lib` 에서 대입하는 가장 가까운 SDK 조상의 것이고, 아무 SDK
    # 조상도 대입하지 않는 ivar(`Faraday::Middleware` 가 두는 `@app`·`@options`)는 세지 않는다. `Data` 멤버는 그 클래스의 것.
    def self.of(obj)
      klass = CLASS_OF.bind_call(obj)
      ivar_fields(obj, klass) + member_fields(obj, klass)
    end

    def self.ivar_fields(obj, klass)
      owners = klass.ancestors.select { |a| a.name.to_s.start_with?("KeycloakSdk::") }
      IVARS.bind_call(obj).filter_map do |iv|
        owner = owners.find { |a| ivar_table.fetch(a.name, []).include?(iv.to_s) }
        [owner.name, iv.to_s, IVAR_GET.bind_call(obj, iv)] if owner
      end
    end

    def self.member_fields(obj, klass)
      return [] unless obj.is_a?(Data)

      Data.instance_method(:to_h).bind_call(obj).map { |k, v| [klass.name, k.to_s, v] }
    end

    # 완전 이름 => 그 클래스·모듈이 대입하는 ivar 들 — 들여쓰기로 중첩을 복원한다(`Declared.declarations` 와 같은 법).
    def self.ivar_table
      @ivar_table ||= Dir.glob(File.join(Declared::LIB, "**", "*.rb")).each_with_object({}) do |file, table|
        scope_ivars(File.readlines(file), table)
      end
    end

    def self.scope_ivars(lines, table)
      stack = []
      lines.each do |line|
        next if blank?(line)

        indent = unwind(stack, line)
        declared = Declared::DECL.match(line)
        declared ? stack << [indent, declared[2] || declared[3]] : assigned(stack, line, table)
      end
    end

    def self.blank?(line) = line.strip.empty? || line.lstrip.start_with?("#")

    # 이 줄이 대입하는 ivar 를 지금 범위(가장 안쪽 클래스·모듈)의 것으로 적는다.
    def self.assigned(stack, line, table)
      return if stack.empty?

      (table[stack.map(&:last).join("::")] ||= []).concat(line.scan(IVAR).map { |(name)| "@#{name}" })
    end

    # 이 줄의 들여쓰기 — 그만큼 이상 들여 쓴 범위(이미 닫힌 클래스·모듈)를 스택에서 걷어낸다.
    def self.unwind(stack, line)
      indent = line[/\A\s*/].size
      stack.pop while stack.any? && stack.last[0] >= indent
      indent
    end
  end

  class FlowError < StandardError; end

  # 가짜 IdP — URL 로 응답을 고른다(순서 큐가 아니라서 호출 순서가 바뀌어도 안 깨진다).
  module Idp
    extend WebMock::API

    JSON_HEADERS = { "Content-Type" => "application/json" }.freeze
    OIDC = "#{SERVER}/realms/r/protocol/openid-connect".freeze
    TOKEN = %r{/realms/r/protocol/openid-connect/token\z}
    ADMIN = "#{SERVER}/admin/realms".freeze

    def self.stub(key)
      stub_oidc(key)
      stub_request(:post, %r{/realms/bad/protocol/openid-connect/token}).to_return(reply(401, error: "invalid_client"))
      stub_request(:get, "#{ADMIN}/r/users/missing").to_return(status: 404)
      stub_request(:get, "#{ADMIN}/r/users/down").to_raise(Errno::ECONNREFUSED)
      stub_request(:post, "#{ADMIN}/r/users").to_return(status: 409)
      stub_request(:post, ADMIN).to_return(status: 403)
      stub_request(:get, "#{ADMIN}/r/groups").to_return(status: 500)
      stub_request(:any, /down\.dump\.test/).to_raise(Errno::ECONNREFUSED)
    end

    def self.stub_oidc(key)
      stub_request(:post, TOKEN).to_return(reply(200, access_token: ACCESS, token_type: "Bearer", expires_in: 300,
                                                      refresh_token: REFRESH, id_token: ID))
      %w[refresh_token authorization_code].each do |grant|
        stub_request(:post, TOKEN).with(body: hash_including("grant_type" => grant))
                                  .to_return(reply(400, error: "invalid_grant"))
      end
      stub_request(:post, "#{OIDC}/token/introspect")
        .to_return(reply(200, active: true, username: "svc", client_id: "c", sub: "u1"))
      stub_request(:post, "#{OIDC}/logout").to_return(reply(400, error: "invalid_grant"))
      stub_request(:get, "#{OIDC}/certs").to_return(reply(200, keys: [JWT::JWK.new(key, kid: "k1").export]))
    end

    def self.reply(status, body)
      { status: status, headers: JSON_HEADERS, body: body.to_json }
    end

    # IdP 가 실제로 받은 요청에 `text` 가 실렸는가(헤더 또는 본문).
    def self.received?(method, url, text)
      pattern = a_request(method, url).with do |req|
        req.body.to_s.include?(text) || req.headers.values.join(" ").include?(text)
      end
      WebMock::RequestRegistry.instance.times_executed(pattern).positive?
    end
  end

  # 공개 API 로 뿌리를 만들고, 그 과정이 흘려 넣은 비밀 전부를 카나리아로 남긴다.
  # ⚠️ 카나리아·뿌리를 RSpec 예제 인스턴스가 아니라 이 객체에 둔다 — 걷기는 이 객체에 닿지 않는다.
  class Scene
    attr_reader :roots, :canaries

    def initialize
      @key = OpenSSL::PKey::RSA.generate(2048)
      Idp.stub(@key)
      @jwt = sign("c")
      @jwt_rejected = sign("someone-else")
      @roots = {}
      build_default_path
      build_injected_path
      failures = auth_failures.merge(admin_failures, transport_failures)
      @roots.merge!(failures.transform_values { |call| caught(&call) })
      @canaries = canary_table
      verify_flow!
    end

    # ⚠️ 카나리아가 실제로 흘러 들어갔는가 — 안 흘렀으면 누출 검사는 없는 것을 찾으며 통과한다.
    # 흐름은 뿌리의 공개 값과 **IdP 가 받은 요청**으로 잰다(리플렉션 아님).
    def unflowed
      ts = @roots["client_credentials_token"]
      bearer = "Bearer #{ACCESS}"
      { "TokenSet 필드 = 카나리아" => [ts.access_token, ts.refresh_token, ts.id_token] == [ACCESS, REFRESH, ID],
        "주입 provider 가 카나리아를 돌려준다" => @provider_token == ACCESS,
        "기본 경로 provider 가 캐시한 카나리아로 admin 을 불렀다" => Idp.received?(:get, %r{/users/missing}, bearer),
        "주입 admin 이 provider 의 카나리아로 불렀다" => Idp.received?(:post, %r{/admin/realms/r/users}, bearer),
        "admin 409 호출이 PASSWORD 를 실었다" => Idp.received?(:post, %r{/admin/realms/r/users}, PASSWORD),
        "토큰 요청의 Basic 헤더 = BASIC 카나리아" => Idp.received?(:post, Idp::TOKEN, "Basic #{@canaries['BASIC']}"),
        "exchange_code 가 VERIFIER 를 실었다" => Idp.received?(:post, Idp::TOKEN, @canaries["VERIFIER"]),
        "logout 이 REFRESH 를 실었다" => Idp.received?(:post, %r{/logout}, REFRESH),
        "JWT 가 실제로 검증됐다" => @roots["validate"].subject == "u1",
        "introspect 가 active" => @roots["introspect"].active? }.reject { |_, ok| ok }.keys
    end

    private

    def verify_flow!
      missing = unflowed
      return if missing.empty?

      raise FlowError, "카나리아가 뿌리에 안 흘렀다 — 가짜 IdP 응답이나 매핑이 바뀌었다: #{missing.join(' · ')}"
    end

    def config(server = SERVER, realm = "r")
      KeycloakSdk::Config.new(server_url: server, realm: realm, client_id: "c", client_secret: SECRET)
    end

    # Keycloak 의 접근 토큰 모양 — typ "Bearer"(접근 토큰 검증은 Bearer · DPoP 만 받는다).
    def sign(aud)
      now = Time.now.to_i
      claims = { "iss" => "#{SERVER}/realms/r", "sub" => "u1", "aud" => aud, "typ" => "Bearer", "exp" => now + 60,
                 "iat" => now }
      JWT.encode(claims, @key, "RS256", { kid: "k1" })
    end

    # 실패 뿌리 — 공개 API 의 실제 실패 호출에서 얻는다. SDK 밖 예외는 잡지 않고 그대로 터뜨린다(§4).
    def caught
      yield
      raise FlowError, "실패 뿌리를 못 만들었다 — 가짜 IdP 가 실패를 안 냈다"
    rescue KeycloakSdk::Error => e
      e
    end

    def build_default_path
      @kc = KeycloakSdk::KeycloakClient.new(config)
      admin = @kc.admin
      # 기본 경로의 admin — 내부 provider 가 토큰을 캐시하고 미들웨어 사슬이 조립된 뒤라야 걷기에 걸린다.
      @roots["NotFoundError(admin 404)"] = caught { admin.users.get("missing") }
      auth = @kc.auth
      @roots.merge!("KeycloakClient.new" => @kc, "admin" => admin, "admin.users" => admin.users,
                    "admin.clients" => admin.clients, "admin.realms" => admin.realms, "admin.roles" => admin.roles,
                    "admin.groups" => admin.groups, "client_credentials_token" => auth.client_credentials_token,
                    "create_authorization_request" => auth.create_authorization_request(redirect_uri: CALLBACK),
                    "introspect" => auth.introspect(ACCESS), "validate" => auth.validate(@jwt))
    end

    # 주입 경로 — 소비자가 직접 만드는 provider 와 admin.
    def build_injected_path
      http = KeycloakSdk::Http.build(config) do |f|
        f.request :url_encoded
        f.response :json, content_type: /\bjson$/
      end
      provider = KeycloakSdk::ClientCredentialsTokenProvider.new(config: config, http: http)
      @provider_token = provider.access_token
      injected = KeycloakSdk::Admin::AdminClient.new(config: config, token_provider: provider)
      user = { username: "u", credentials: [{ type: "password", value: PASSWORD, temporary: false }] }
      @roots.merge!("ClientCredentialsTokenProvider.new" => provider, "AdminClient.new(token_provider:)" => injected,
                    "ConflictError(admin 409)" => caught { injected.users.create(user) })
    end

    def auth_failures
      bad = KeycloakSdk::KeycloakClient.new(config(SERVER, "bad"))
      verifier = @roots["create_authorization_request"].code_verifier
      auth = @kc.auth
      { "ConfigError(blank server_url)" => -> { config(" ") },
        "AuthError(client_credentials 401)" => -> { bad.auth.client_credentials_token },
        "AuthError(admin token 401)" => -> { bad.admin.users.get("x") },
        "AuthError(refresh 400)" => -> { auth.refresh(refresh_token: REFRESH) },
        "AuthError(exchange_code 400)" => lambda {
          auth.exchange_code(code: "code", code_verifier: verifier, redirect_uri: CALLBACK)
        },
        "AuthError(logout 400)" => -> { auth.logout(refresh_token: REFRESH) } }
    end

    def admin_failures
      admin = @kc.admin
      { "TokenValidationError(garbage)" => -> { @kc.auth.validate(GARBAGE) },
        "TokenValidationError(wrong aud)" => -> { @kc.auth.validate(@jwt_rejected) },
        "ForbiddenError(admin 403)" => -> { admin.realms.create({ realm: "x" }) },
        "AdminError(admin 500)" => -> { admin.groups.list },
        "TransportError(admin call)" => -> { admin.users.get("down") } }
    end

    def transport_failures
      down = KeycloakSdk::KeycloakClient.new(config(DOWN))
      @roots["KeycloakClient.new(down)"] = down
      { "TransportError(admin token)" => -> { down.admin.users.get("x") },
        "TransportError(token)" => -> { down.auth.client_credentials_token },
        "TransportError(introspect)" => -> { down.auth.introspect(ACCESS) },
        "TransportError(logout)" => -> { down.auth.logout(refresh_token: REFRESH) },
        "TransportError(jwks)" => -> { down.auth.validate(@jwt) } }
    end

    def canary_table
      { "SECRET" => SECRET, "ACCESS" => ACCESS, "REFRESH" => REFRESH, "ID" => ID, "GARBAGE" => GARBAGE,
        "PASSWORD" => PASSWORD, "VERIFIER" => @roots["create_authorization_request"].code_verifier,
        "JWT" => @jwt, "JWT_REJECTED" => @jwt_rejected,
        # 토큰 요청의 Basic 헤더 값 — 시크릿의 인코딩된 형태도 비밀이다.
        "BASIC" => Base64.strict_encode64("c:#{SECRET}") }
    end
  end

  # 뿌리에서 닿는 객체 전부를 걷고, SDK 타입만 바닥 경로로 찍어 카나리아를 찾는다.
  class Walker
    FLOORS = %i[inspect to_s pretty_inspect].freeze
    LEAVES = [NilClass, TrueClass, FalseClass, Numeric, Symbol, String].freeze
    # 내려가지 않는 것: 클래스·모듈(클래스 수준 상태는 인스턴스 표현에 안 찍힌다)·클로저·스레드.
    # ⚠️ 클로저의 바인딩은 `self` 로 **테스트 인스턴스**를 쥘 수 있다 — PHP 가 밟은 하네스 오염의 입구다.
    OPAQUE = [Module, Proc, Method, UnboundMethod, Binding, Thread].freeze
    # 걷기가 이것에 닿으면 표현에 SDK 와 무관한 하네스 상태가 섞인다 — 면제가 아니라 제거할 대상이다.
    HARNESS = [RSpec::Core::ExampleGroup, RSpec::Core::Example, Scene,
               WebMock::RequestStub, WebMock::StubRegistry, WebMock::RequestRegistry].freeze
    IVARS = Kernel.instance_method(:instance_variables)
    IVAR_GET = Kernel.instance_method(:instance_variable_get)
    CLASS_OF = Kernel.instance_method(:class)

    attr_reader :reached, :leaks, :known_seen, :contamination, :fields

    def initialize(canaries)
      @canaries = canaries
      @seen = {}.compare_by_identity
      @reached = Set.new
      @leaks = []
      @known_seen = Set.new
      @contamination = []
      # `"<선언 타입>.<필드>"` => 닿은 인스턴스 하나라도 비지 않은 값을 쥐었는가(`record`).
      @fields = {}
    end

    # SDK 타입이 선언한 필드마다 이 인스턴스가 비지 않은 값을 쥐었는가 — 판정은 예제가 한다.
    def record(obj)
      SecretFields.of(obj).each do |owner, name, value|
        key = "#{owner}.#{name}"
        @fields[key] = @fields.fetch(key, false) || !SecretFields.empty?(value)
      end
    end

    # 비밀 이름인데 닿은 인스턴스가 전부 빈 값을 쥔 필드, 그리고 낡은 면제(규칙 4·5).
    def empty_secret_problems
      empty_secret_fields.map do |key|
        "#{key}: secret-named but every reached instance holds an empty value — fill it from a root with a canary, " \
          "or exempt it with a reason"
      end + stale_empty_exemptions.map { |key| "#{key}: EMPTY_SECRET_EXEMPT 에 있지만 더는 「닿고 · 빈 값만」이 아니다 — 낡은 면제다" }
    end

    def empty_secret_fields
      @fields.reject { |key, seen| seen || EMPTY_SECRET_EXEMPT.key?(key) }.keys
             .select { |key| SecretFields.secret_named?(key.split(".").last) }.sort
    end

    # 낡은 면제 — 더는 「닿고 · 빈 값만」이 아니다(비지 않은 값이 보였거나 닿지 않는다).
    def stale_empty_exemptions = EMPTY_SECRET_EXEMPT.keys.reject { |key| @fields.key?(key) && !@fields[key] }

    def visited = @seen.size

    def scan(text)
      @canaries.select { |_, value| text.include?(value) }.keys
    end

    # 너비 우선 — 실패 메시지의 경로가 가장 짧은 경로가 된다.
    def walk(root_obj, root)
      # 뿌리는 소유와 무관하게 찍는다 — 소비자가 쥐는 값 자체다(이름 없는 `Data.define` 인스턴스도 여기서 잰다).
      render(root_obj, root, root) unless own?(root_obj) || kind?(LEAVES, root_obj)
      queue = [[root_obj, root]]
      until queue.empty?
        obj, path = queue.shift
        queue.concat(visit(obj, path, root)) unless kind?(LEAVES, obj) || @seen.key?(obj)
      end
    end

    private

    # 한 객체를 재고, 더 걸어 내려갈 자리를 돌려준다.
    def visit(obj, path, root)
      @seen[obj] = true
      # 하네스 객체는 적고 **거기서 멈춘다** — 그 안(RSpec 내부·스텁 응답의 카나리아)은 SDK 와 무관한 소음이다.
      if kind?(HARNESS, obj)
        @contamination << path
        return []
      end
      if own?(obj)
        @reached << CLASS_OF.bind_call(obj).name
        render(obj, path, root)
      end
      edges(obj, path)
    end

    # `Module#===` 는 BasicObject 에도 안전하다(수신자 메서드를 부르지 않는다).
    def kind?(types, obj)
      types.any? { |t| t === obj } # rubocop:disable Style/CaseEquality
    end

    def own?(obj)
      kind?([Kernel], obj) && CLASS_OF.bind_call(obj).name.to_s.start_with?("KeycloakSdk::")
    end

    # 비공개 ivar 까지 — 기본 `inspect` 가 바로 그것을 찍기 때문이다. 재정의를 우회해 원본 메서드로 읽는다.
    def edges(obj, path)
      return [] if !kind?([Kernel], obj) || kind?(OPAQUE, obj)

      ivars = IVARS.bind_call(obj).map { |iv| [".#{iv}", IVAR_GET.bind_call(obj, iv)] }
      (ivars + members(obj)).map { |label, value| [value, "#{path}#{label}"] }
    end

    # ivar 가 아닌 자리 — 컨테이너 원소, `Data`·`Struct` 멤버, 예외의 `cause`.
    def members(obj)
      case obj
      when Hash then hash_members(obj)
      when Array, Set then indexed(obj.to_a)
      when Data then named(Data.instance_method(:to_h).bind_call(obj))
      when Struct then named(Struct.instance_method(:each_pair).bind_call(obj).to_a)
      when Exception then [[".cause", Exception.instance_method(:cause).bind_call(obj)]]
      else []
      end
    end

    def hash_members(hash)
      Hash.instance_method(:to_a).bind_call(hash).flat_map { |k, v| [["{key}", k], ["[#{k.inspect[0, 40]}]", v]] }
    end

    def indexed(items) = items.each_with_index.map { |x, i| ["[#{i}]", x] }

    def named(pairs) = pairs.map { |k, v| [".#{k}", v] }

    # 예외는 `full_message` 도 바닥이다 — 잡히지 않은 예외와 로거가 찍는 것이고, `cause` 사슬의 메시지를 싣는다.
    def renderings(obj)
      outs = FLOORS.to_h { |how| [how, obj.public_send(how)] }
      outs[:full_message] = obj.full_message(highlight: false) if obj.is_a?(Exception)
      outs
    end

    # ⚠️ 기록은 여기서 한다 — 적대 경로 행렬은 이 걷기를 쓰되 `render` 를 덮어 찍지 않으므로 기록도 하지 않는다
    # (행렬의 동작·출력은 그대로다).
    def render(obj, path, root)
      record(obj) if own?(obj)
      klass = CLASS_OF.bind_call(obj)
      renderings(obj).each do |how, out|
        scan(out).each do |name|
          key = "#{root}|#{name}"
          next @known_seen << key if KNOWN_LEAKS.key?(key)

          @leaks << "#{path} [#{klass}] ##{how}: 비밀 #{name} 이 원문으로 찍혔다"
        end
      end
    end
  end

  # 선언 타입 전수 — 손 목록이 아니라 트리에서 파생한다.
  module Declared
    LIB = File.expand_path("../../lib", __dir__)
    DEFINE = /(?:Data\.define|Struct\.new|Class\.new|Module\.new)\b/
    DECL = /\A(\s*)(?:(?:class|module)\s+([A-Z]\w*)|([A-Z]\w*)\s*=\s*#{DEFINE})/

    # 실행 중인 `KeycloakSdk` 아래 클래스·모듈 상수를 재귀로. 별칭(다른 자리에 정의된 것)은 이름으로 거른다.
    def self.runtime(mod = KeycloakSdk)
      mod.constants(false).each_with_object([mod.name]) do |c, acc|
        value = mod.const_get(c, false)
        acc.concat(runtime(value)) if value.is_a?(Module) && value.name == "#{mod.name}::#{c}"
      end.sort
    end

    # 소스에 선언됐지만 `private_constant` 로 숨긴 것 — 공개 상수 걷기(`runtime`)에는 없다. 공개 API 가 아니라 뿌리·
    # 면제 대상도 아니고, 로드됐는지(`const_defined?` 는 private 도 참)와 정말 private 인지만 본다(require 누락은 그대로 운다).
    def self.private_declared
      (source - runtime).select do |name|
        parent, _, last = name.rpartition("::")
        mod = Object.const_get(parent)
        mod.const_defined?(last, false) && !mod.constants(false).include?(last.to_sym)
      end
    end

    # `ruby/lib` 의 선언을 들여쓰기로 중첩을 복원해 완전 이름으로(rubocop 이 들여쓰기를 강제한다).
    def self.source
      Dir.glob(File.join(LIB, "**", "*.rb")).flat_map { |f| declarations(File.readlines(f)) }.uniq.sort
    end

    def self.declarations(lines)
      stack = []
      lines.filter_map do |line|
        m = DECL.match(line) or next
        stack.pop while stack.any? && stack.last[0] >= m[1].size
        stack << [m[1].size, m[2] || m[3]]
        stack.map(&:last).join("::")
      end
    end

    # 닿았거나 · 규칙(인스턴스를 못 만드는 모듈)으로 빠지거나 · 이유와 함께 면제 — 셋 중 하나여야 한다.
    def self.problems(reached)
      declared = runtime
      declared.filter_map { |name| problem(name, reached.include?(name), EXEMPT.key?(name)) } +
        (EXEMPT.keys - declared).map { |name| "#{name}: 면제 표에 있지만 선언이 없다 — 낡은 면제다" }
    end

    def self.problem(name, hit, exempt)
      return "#{name}: 걷기에 닿는데 면제 표에도 있다 — 면제를 지워라" if hit && exempt
      return if hit || exempt || !Object.const_get(name).is_a?(Class)

      "#{name}: 공개 API 뿌리에서 닿지 않는 클래스다 — 만드는 경로를 뿌리에 더하거나, 이유와 함께 면제하라"
    end
  end
end

RSpec.describe KeycloakSdk do
  describe "floor representations of every reachable object" do
    # Scene 은 만들며 흐름을 검사하고, 카나리아가 안 흘렀으면 FlowError 로 모든 예제를 멈춘다.
    let(:scene) { FacadeDumpSpec::Scene.new }
    let(:walker) do
      FacadeDumpSpec::Walker.new(scene.canaries).tap { |w| scene.roots.each { |name, obj| w.walk(obj, name) } }
    end

    it "plants every canary into its root through the public API (flow check)" do
      expect(scene.unflowed).to eq([])
      expect(scene.canaries.values.uniq.size).to eq(10)
    end

    it "renders no secret on #inspect, #to_s, #pretty_inspect (or an error's #full_message)" do
      expect(walker.leaks).to eq([]), "기본 표현이 비밀을 찍는다:\n#{walker.leaks.join("\n")}"
      expect(FacadeDumpSpec::KNOWN_LEAKS.keys - walker.known_seen.to_a)
        .to eq([]), "알려진 누출이 더 안 난다 — 고쳐졌으면 KNOWN_LEAKS 에서 지워라"
    end

    it "reaches every declared SDK class, or excludes it by rule, or exempts it with a reason" do
      expect(FacadeDumpSpec::Declared.runtime.size).to be >= 30 # 파생이 공허하지 않다
      problems = FacadeDumpSpec::Declared.problems(walker.reached)
      expect(problems).to eq([]), problems.join("\n")
    end

    it "derives the same declared types at runtime as ruby/lib declares in source" do
      runtime = FacadeDumpSpec::Declared.runtime
      source = FacadeDumpSpec::Declared.source
      missing = source - runtime - FacadeDumpSpec::Declared.private_declared
      expect(missing).to eq([]), "ruby/lib 에 선언됐지만 로드되지 않았다(require 누락?): #{missing}"
      expect(runtime - source).to eq([]), "런타임에 있지만 ruby/lib 선언 파싱이 못 찾았다: #{runtime - source}"
    end

    it "never walks into the harness's own objects (example, scene, webmock stubs)" do
      expect(walker.visited).to be > 100 # 걷기가 실제로 내려갔다
      expect(walker.contamination).to eq([]), "하네스 객체에 닿았다 — 오염을 제거하라:\n#{walker.contamination.join("\n")}"
    end

    it "fails a secret-named field that every reached instance holds empty, unless it is exempted with a reason" do
      named = walker.fields.keys.select { |key| FacadeDumpSpec::SecretFields.secret_named?(key.split(".").last) }
      expect(named.size).to be >= 5 # 기록이 공허하지 않다
      problems = walker.empty_secret_problems
      expect(problems).to eq([]), problems.join("\n")
    end

    it "splits a field name into whole words (IDToken is id and token; keycloak is not key)" do
      fields = FacadeDumpSpec::SecretFields
      expect(fields.words("IDToken")).to eq(%w[id token])
      expect(fields.words("@client_secret")).to eq(%w[client secret])
      expect(fields.secret_named?("@code_verifier")).to be(true)
      expect(fields.secret_named?("keycloak")).to be(false)
      expect(fields.secret_named?("@expected_audience")).to be(false)
    end

    it "sees a canary when a carrier does print one (the detector is not blind)" do
      expect(walker.scan(scene.roots["client_credentials_token"].to_h.inspect)).to include("ACCESS", "REFRESH", "ID")
    end
  end
end
