# frozen_string_literal: true

require "spec_helper"
require "json"
require "jwt"
require "openssl"
require "uri"

# 적대 경로 행렬 — 공개 호출 경로를 파생해 분류하고, 적대 변형을 **메서드 손 목록이 아니라 계급에** 붙인다
# (등록부 `guard-detection-surface-hand-narrowed` · 참조 구현 `go/hostile_path_matrix_test.go`).
#
# nonce·콜드캐시 백오프·토큰응답 타입검증 축은 `scripts/test/test-security-defaults.sh` 가 손으로 고른 자리에 앵커를
# 건다. 그래서 **새 공개 교환 경로**가 생기면 세 축 모두 그것을 모른다. 여기서는 경로를 손 목록이 아니라 파생한다:
#
#   - 선언 집합: facade_dump_spec.rb 의 뿌리·걷기(FacadeDumpSpec::Scene·Walker)가 닿는 SDK 클래스마다, 그 SDK 소유
#     조상(자기 · include 한 SDK 모듈)의 `public_instance_methods(false)` 전부. 여기에 `ruby/lib` 에 소스 위치가 있는
#     공개 메서드 전부(싱글턴 포함)를 합친다. 걷기가 못 닿는 모듈의 인스턴스 메서드는 수신자가 없어 UNDETERMINED 다.
#     소스의 정의(`def` · 한 줄 `; def` · `define_method`) 이름은 런타임과 다시 대조하고, `require "keycloak_sdk"` 가
#     싣지 않는 lib 파일도 행이 된다. 찾은 인스턴스에만 붙은 공개 싱글턴 메서드도 행이다(Grok 레그 실측 셋).
#   - 수신자: 빌더 둘(KeycloakClient.new · 그리고 admin 을 만든 것)의 **새** 인스턴스를 같은 걷기로 훑어 찾는다. 거기
#     없는 타입은 **공개 호출의 반환값**을 따라 얻는다(admin.users → Users · client_credentials_token → TokenSet —
#     고정점). 그래도 없는 타입은 `allocate`(Go 의 영값 수신자)다. 싱글턴 메서드의 수신자는 그 클래스·모듈 자신이다.
#   - 호출: 메서드마다 **새** 가짜 IdP 와 **새** 수신자. 기록은 모든 호스트의 요청을 받는 catch-all 스텁 하나가 한다.
#   - 분류: 그 호출이 실제로 보낸 요청으로 가른다(`Wire.classify`). 엔드포인트는 경로 **꼬리**로 본다.
#
# 단언:
#   (1) UNDETERMINED 가 없다(EXEMPT 에 이유와 함께 있으면 통과, 낡은 면제는 실패).
#   (2) CODE_EXCHANGE·TOKEN_GRANT·JWKS_FETCH 가 각각 비어 있지 않다.
#   (3) 런타임에 선언된 SDK 클래스는 전부 행렬의 수신자 타입이다(파생에서 타입 하나가 빠지면 운다).
#   (4) 어느 행도 설정한 서버가 아닌 호스트로 요청하지 않는다(W3a 는 토큰 요청 **뒤**만 본다 — 교환 앞의 유출은 여기서만).
#   (W1) 손으로 고른 Ruby 보안 테스트가 겨누는 메서드(Hand::TARGETS)가 전부 행이고 기대 계급이다. 표 자신도 손
#        목록이라 셋과 대조한다 — 앵커 예제가 정말 그 메서드를 부르는가 · hostile_token_response_spec 의 CALLS 가 전부
#        표에 있는가(호출 사슬을 기록 대역에 **실행해** 라벨을 얻는다) · 보안 기본값 가드의 Ruby 행위 앵커가 전부 표에 있는가.
#   (W3a) TOKEN_GRANT·CODE_EXCHANGE 행마다 형식이 틀린 토큰 응답 변형 — 변형은 기존 테스트에서 가져온다
#        (hostile_token_response_spec.rb 의 VARIANTS · tokens_spec.rb 의 NON_STRING_ACCESS_TOKENS). 칸마다: 크래시 없음 ·
#        SDK 오류(원인 사슬까지 SDK 타입) · 카나리아가 message·inspect·full_message·원인 사슬 어디에도 없음 · 토큰
#        엔드포인트에 닿음 · 그러나 대조보다 많이 닿지 않음 · 적대 응답 **뒤로** 요청이 없음. nonce 파라미터는 비운다
#        (id_token 없는 변형이 「id_token 없음」으로 공허하게 실패하지 않게 — Go 의 변이 b 와 같은 부류).
#   (W3b) CODE_EXCHANGE 행 중 **서명에 nonce 파라미터가 있는** 것(Method#parameters 이름)마다 nonce 가 다른 id_token ·
#        다른 키(같은 kid · 다른 kid) · id_token 없음 · nonce 클레임 없음을 거부하고, 대조는 통과하며 JWKS 에 닿는다.
#        nonce 파라미터가 없는 CODE_EXCHANGE 행은 NONCE_DROP_EXEMPT 에 이유가 있어야만 빠진다. iss≠·aud≠·exp지남 은
#        측정만 한다(교환 경로에 그것을 단언하는 기존 테스트가 아직 없다 — NONCE_VARIANTS 주석).
#   (W3c) 분류 실행에서 /certs 를 조회한 행마다 콜드 캐시 + 503 에서 k 회 — 전부 SDK 오류, 1 ≤ /certs ≤ k−1.
#        시간이 아니라 요청 수만 잰다.
# 실패한 칸은 KNOWN_GAPS 에 이유와 함께 있으면 GAP 이고, 관측되지 않는 항목은 낡은 것이라 실패한다.
#
# ⚠️ 잴 때 함정(Go 와 같은 둘 + Ruby 고유 셋):
#   - 문자열 인자는 가짜 IdP 키로 **서명한 JWS** 다. 평문이면 validate 가 요청 전에 실패해 JWKS_FETCH 가 빈다.
#   - 토큰 응답의 expires_in 은 skew(30s)보다 짧다(1). 길면 provider 캐시가 부여 경로를 가려 admin 행이 OTHER 가 된다.
#   - Ruby 에는 인자 타입이 없다 — 합성은 **파라미터 종류**로 한다. 기본 모양은 필수 인자 + 이름에 nonce 가 든 선택
#     인자다(서버 id_token 의 nonce 가 보편 인자라 교환이 검증기까지 간다). 선택 인자가 더 있으면 **전부 채운 모양**도
#     불러 더 강한 계급을 딴다 — 선택 인자가 요청을 여는 새 메서드가 NONE 으로 숨지 않게(Go 의 오버로드 자리).
#   - 의존 spec(facade_dump·hostile_token_response·tokens)은 rspec 이 이번에 싣기로 한 파일이면 여기서 싣지 않는다 —
#     spec 파일은 `load` 로 실려 두 번 실으면 예제가 두 번 돈다. 그래서 그 상수는 **실행 시점에만** 읽는다.
#   - 행렬은 프로세스에 한 번 돈다(`HostilePathMatrixSpec.result`) — 예제 다섯이 같은 결과를 나눠 단언한다.
#
# ⚠️ 한계(Grok 레그가 심어 실측했다 — 전부 NONE 으로 읽히거나 선언 집합 밖이다): 요청도 오류도 없이 끝나는 경로 —
# 비동기로 나가는 요청 · `**opts` 의 키가 요청을 여는 것(키 이름을 알 길이 없다) · 합성 인자(JWS 문자열)가 요청 앞의
# 검사에 걸리는 것(`redirect_uri.start_with?("https://")` 류 — 기본 모양은 nil 로 돌아가 NONE 이 이긴다) · 생성자
# (`initialize` — 빌더가 부르고 그 요청은 reset 이 버린다) · `method_missing` 공개면. 채택하지 않은 둘: k 번째 뒤에만
# 열리는 콜드 경로(k=5 는 설계다) · 오류 밖의 저장소(Thread.current 등)로 새는 응답(누출 검사는 오류 렌더링의 계약이다).
# 분류표·판정표는 HP_MATRIX_VERBOSE=1 일 때 찍고, 실패 메시지에는 요약이 실린다.
%w[facade_dump_spec hostile_token_response_spec tokens_spec].each do |dep|
  path = File.expand_path("#{dep}.rb", __dir__)
  require path unless RSpec.configuration.files_to_run.any? { |f| File.expand_path(f) == path }
end

module HostilePathMatrixSpec
  CODE_EXCHANGE = "CODE_EXCHANGE"
  TOKEN_GRANT = "TOKEN_GRANT"
  JWKS_FETCH = "JWKS_FETCH"
  OTHER = "OTHER"
  NONE = "NONE"
  UNDETERMINED = "UNDETERMINED"
  CLASSES = [CODE_EXCHANGE, TOKEN_GRANT, JWKS_FETCH, OTHER, NONE, UNDETERMINED].freeze
  # 합성 모양 둘이 다르게 가르면 더 강한 쪽 — 뒤가 이긴다.
  RANK = CLASSES.reverse.freeze

  SERVER = "https://hp.idp.test"
  BASE = "/realms/r/protocol/openid-connect"
  # 분류는 realm·호스트와 무관하게 **꼬리**로 본다(Go 레그 실측: 정확한 경로로 가르면 다른 realm 의 certs 가 OTHER).
  TOKEN_SUFFIX = "/protocol/openid-connect/token"
  CERTS_SUFFIX = "/protocol/openid-connect/certs"
  COLD_K = 5
  RT_CANARY = "mRT9k-matrix-refresh-token-canary"
  JSON_HEADERS = { "Content-Type" => "application/json" }.freeze
  LIB = File.expand_path("../../lib", __dir__)

  # UNDETERMINED 여도 되는 행과 그 이유. **이유 없는 면제는 넣지 않는다.** 행이 없거나 더는 UNDETERMINED 가 아니면
  # 낡은 면제로 실패한다.
  EXEMPT = {
    "Admin::BearerAuth#on_request" => "Faraday 미들웨어 훅 — Faraday 가 요청 Env 를 넘겨 부른다. admin 요청은 전부 " \
                                      "이것을 지나고 그 요청은 부른 자원 메서드의 행(TOKEN_GRANT)에 잡힌다(Go 의 " \
                                      "wireScrubTransport.RoundTrip 과 같은 자리)",
    "TokenSet#pretty_print" => "PP 훅 — `pp` 가 PrettyPrint 를 넘겨 부르고 `inspect` 를 찍을 뿐이다(tokens.rb)",
    "AuthorizationRequest#pretty_print" => "PP 훅 — `pp` 가 PrettyPrint 를 넘겨 부르고 `inspect` 를 찍을 뿐이다(tokens.rb)",
    "Http.build" => "커넥션 팩토리 — Config 를 받아 Faraday 커넥션을 조립할 뿐이다. 그 커넥션의 요청은 그것을 쓰는 " \
                    "메서드의 행에 잡힌다(http.rb)",
    "Http.read_capped" => "본문 상한 헬퍼 — 받은 커넥션으로 요청 하나를 보내 본문을 상한까지만 읽는다. 그 요청은 그것을 " \
                          "쓰는 메서드의 행(세 그랜트·admin 토큰 TOKEN_GRANT/CODE_EXCHANGE · JWKS_FETCH · introspect " \
                          "OTHER)에 잡힌다(http.rb)",
    "Http.decode_json" => "이미 받은 응답의 해석기 — 요청을 내지 않는다. 입구는 read_capped 를 쓰는 메서드들이다(http.rb)",
    "Http::BoundedReads#readuntil" => "소켓 틀 리더 — 요청 때 BufferedIO 인스턴스에 extend 된다(BoundedTransport#on_connect). " \
                                      "도달 가능한 수신자가 아니라 응답 틀 줄을 읽을 뿐이고, 그 요청은 그것을 내는 메서드의 " \
                                      "행(세 그랜트·admin 토큰·JWKS·introspect)에 잡힌다(http.rb)",
    "Http::BoundedReads#readline" => "소켓 틀 리더 — readuntil 과 같다(상태 줄·청크 크기/확장 줄·트레일러를 읽는다, http.rb)",
    "Http::BoundedReads#kcsdk_reset_framing!" => "요청마다 틀 예산을 0 으로 되돌린다(BoundedTransport#begin_transport). " \
                                                 "소켓 상태 리셋일 뿐 요청을 내지 않는다(http.rb)",
    "JwtValidator.from_config" => "생성 팩토리 — 검증기를 조립할 뿐이다. 검증 요청은 JwtValidator#validate 행(JWKS_FETCH)이다",
    "OidcEndpoints.from_config" => "엔드포인트 조립 — 네트워크가 없다(oidc_endpoints.rb 머리 주석)",
    "TokenSet.from_response" => "이미 받은 본문의 파서 — Hash 가 아니면 요청 없이 AuthError 다. 그 계약은 입구 " \
                                "ClientCredentialsTokenProvider#access_token 의 W3a 칸이 잰다(W1 의 tokens_spec 앵커)",
    "IntrospectionResult.from_response" => "이미 받은 본문의 파서 — 요청을 내지 않는다. 입구는 AuthClient#introspect(OTHER)다"
  }.freeze

  # W3b 에서 빠져도 되는 CODE_EXCHANGE 행과 그 이유. nonce 파라미터를 **이름**으로 파생하므로 nonce 를 다른 이름으로
  # 받는 새 교환 메서드는 이 표가 없으면 조용히 빠진다 — 그래서 빠지는 것은 이유와 함께 여기 적어야만 한다. 오늘은 비었다.
  NONCE_DROP_EXEMPT = {}.freeze

  # 현재 main 에서 실패하는 칸 — 키는 `W3<축> 행/변형`, 값은 `등록부 id: 한 줄 이유`. SDK 를 고치지 않고 드러내 둔다.
  # 관측되지 않는 항목은 낡은 것이라 실패한다. **이유 없는 항목은 넣지 않는다.**
  KNOWN_GAPS = {}.freeze

  Req = Data.define(:verb, :host, :path, :grant)
  Outcome = Data.define(:value, :error, :crash) do
    def failed? = !raised.nil?

    def raised = error || crash
  end
  Row = Struct.new(:label, :cls, :reqs, :recv, :outcome, :note, :sent, :shape, :target, :meth, :params, :foreign,
                   keyword_init: true)
  Cell = Struct.new(:axis, :label, :variant, :why, :measure, :note, keyword_init: true) do
    def key = "W3#{axis} #{label}/#{variant}"
  end
  # 수신자를 얻는 길 — 빌더 이름과, 거기서 부를 공개 호출 사슬([타입, 메서드, 모양]).
  Recipe = Data.define(:builder, :steps) do
    def then_call(type, meth, shape) = with(steps: steps + [[type, meth, shape]])

    def to_s = ([builder] + steps.map { |t, m, _| "#{Wire.short(t)}##{m}" }).join(" → ")
  end

  # 수신자를 얻는 공개 API 뿌리 — **덜 데운 것부터**(Go 와 같다: admin 을 안 만든 것이 먼저).
  BUILDERS = {
    "KeycloakClient.new" => ->(cfg) { KeycloakSdk::KeycloakClient.new(cfg) },
    "KeycloakClient.new+admin" => ->(cfg) { KeycloakSdk::KeycloakClient.new(cfg).tap(&:admin) }
  }.freeze

  def self.result = (@result ||= Run.new.call)

  # 요청 기록을 읽는 순수 함수들.
  module Wire
    module_function

    def short(name) = name.to_s.delete_prefix("KeycloakSdk::")

    def json(status, body) = { status: status, headers: JSON_HEADERS, body: body.to_json }

    def token?(req) = req.verb == :post && req.path.end_with?(TOKEN_SUFFIX)

    def certs?(req) = req.verb == :get && req.path.end_with?(CERTS_SUFFIX)

    def code_exchange?(req) = token?(req) && req.grant == "authorization_code"

    def foreign?(req) = req.host != URI(SERVER).host

    # 점 세그먼트와 빈·끝 슬래시를 걷어낸 경로 — `/token/`·`/x/../token` 이 꼬리 대조를 비껴가지 않게(Grok 레그 실측:
    # 끝 슬래시 하나로 코드 교환이 OTHER 로 읽혔다). 가짜 IdP 의 라우팅도 이 경로로 한다.
    def normalize(path)
      segs = path.to_s.split("/").each_with_object([]) do |seg, out|
        next if seg.empty? || seg == "."

        seg == ".." ? out.pop : out << seg
      end
      "/#{segs.join('/')}"
    end

    # 요청으로 가른다. 앞 줄이 이긴다: 코드 교환 > 토큰 부여 > JWKS 조회 > 그 밖의 요청 > 요청 없음.
    # ⚠️ 토큰 엔드포인트 POST 는 grant_type 이 무엇이든 TOKEN_GRANT 다 — 새 grant 가 OTHER 로 새지 않게.
    def classify(reqs, failed)
      rules = [[CODE_EXCHANGE, method(:code_exchange?)], [TOKEN_GRANT, method(:token?)],
               [JWKS_FETCH, method(:certs?)], [OTHER, ->(_) { true }]]
      hit = rules.find { |_, pred| reqs.any?(&pred) }
      return hit.first if hit

      failed ? UNDETERMINED : NONE
    end

    # 토큰 요청 수와, 첫 토큰 요청 **뒤에** 나간 토큰 아닌 요청.
    def after_token(reqs)
      first = reqs.index { |r| token?(r) }
      return [0, []] if first.nil?

      [reqs.count { |r| token?(r) }, reqs[first..].reject { |r| token?(r) }]
    end

    def format(reqs, universal)
      return "-" if reqs.empty?

      reqs.map { |r| format_req(r, universal) }.tally.map { |k, n| n > 1 ? "#{k} ×#{n}" : k }.join(", ")
    end

    def format_req(req, universal)
      path = req.path.delete_prefix(BASE)
      path = path.gsub(universal, "{U}") if universal
      host = req.host == URI(SERVER).host ? "" : "//#{req.host}"
      "#{req.verb.upcase} #{host}#{path}#{"[#{req.grant}]" if req.grant}"
    end
  end

  # 부르기와 걷기.
  module Reflect
    module_function

    # 한 번 부른다 — StandardError 는 오류, 그 밖(rspec 이 안 잡는 것 제외)은 크래시(Go 의 panic 자리).
    def invoke(recv, meth, shape, universal, blank: false)
      pos, kw = Args.build(recv.method(meth).parameters, shape, universal, blank: blank)
      Outcome.new(value: recv.public_send(meth, *pos, **kw), error: nil, crash: nil)
    rescue StandardError => e
      Outcome.new(value: nil, error: e, crash: nil)
    rescue RSpec::Support::AllExceptionsExceptOnesWeMustNotRescue => e
      Outcome.new(value: nil, error: nil, crash: e)
    end

    # 같은 걷기(FacadeDumpSpec::Walker)로 SDK 인스턴스를 모은다 — 찍지 않는다(누출 단언은 facade_dump_spec 의 몫).
    # 의존 spec 이 이 파일보다 늦게 실릴 수 있어 클래스를 처음 쓸 때 만든다.
    def finder_class
      @finder_class ||= Class.new(FacadeDumpSpec::Walker) do
        def found = (@found ||= {})

        private

        def visit(obj, path, root)
          found[self.class::CLASS_OF.bind_call(obj).name] ||= obj if own?(obj)
          super
        end

        def render(*) = nil
      end
    end

    def find_all(root) = finder_class.new({}).tap { |w| w.walk(root, "root") }.found

    # 인스턴스에만 붙은 공개 싱글턴 메서드(`define_singleton_method`·`extend`) — 클래스의 메서드 목록에 없다.
    def eigen_methods(obj) = Kernel.instance_method(:singleton_methods).bind_call(obj)
  end

  # 인자 합성 — 타입이 없으니 파라미터 **종류**로. 모양 :base = 필수 + 이름에 nonce 가 든 선택 · :full = 선택까지 전부.
  module Args
    FILLABLE = %i[req opt keyreq key].freeze

    module_function

    def nonce?(name) = name.to_s.downcase.include?("nonce")

    def nonce_names(params) = params.select { |kind, name| FILLABLE.include?(kind) && nonce?(name) }.map(&:last)

    def shapes(params)
      params.any? { |kind, name| %i[opt key].include?(kind) && !nonce?(name) } ? %i[base full] : %i[base]
    end

    # [위치 인자, 키워드 인자]. blank 면 nonce 자리는 nil 이다(W3a 가 id_token 검증을 끈다).
    def build(params, shape, universal, blank: false)
      last = last_opt(params, shape)
      pos = []
      kw = {}
      params.each_with_index do |(kind, name), i|
        next unless fill?(kind, name, shape, i <= last)

        value = blank && nonce?(name) ? nil : universal
        %i[req opt].include?(kind) ? pos << value : kw[name] = value
      end
      [pos, kw]
    end

    # 채울 마지막 위치형 선택 인자 — 그 앞의 위치형 선택 인자도 자리를 맞추려 채운다.
    def last_opt(params, shape) = params.rindex { |kind, name| kind == :opt && (shape == :full || nonce?(name)) } || -1

    def fill?(kind, name, shape, opt_in_range)
      case kind
      when :req, :keyreq then true
      when :opt then opt_in_range
      when :key then shape == :full || nonce?(name)
      else false
      end
    end
  end

  # 한 실행의 키·서명 값 — 호스트가 하나라 보편 인자와 id_token 은 실행마다 한 번 서명한다.
  class Fixture
    attr_reader :key, :other, :universal, :id_token, :jwks

    def initialize
      @key = OpenSSL::PKey::RSA.generate(2048)
      @other = OpenSSL::PKey::RSA.generate(2048)
      # ⚠️ 평문이 아니라 **서명한 JWS** — 토큰을 받는 메서드(validate 둘)가 요청 전에 실패하지 않게.
      @universal = sign(@key, "k1", {})
      @id_token = sign(@key, "k1", { "nonce" => @universal })
      @jwks = { keys: [JWT::JWK.new(@key, kid: "k1").export] }.to_json
    end

    def sign(key, kid, extra)
      now = Time.now.to_i
      claims = { "iss" => "#{SERVER}/realms/r", "sub" => "u1", "aud" => "c", "exp" => now + 300, "iat" => now }
      JWT.encode(claims.merge(extra), key, "RS256", { kid: kid })
    end

    # 클라이언트 시크릿은 적대 응답 행렬의 카나리아와 같다 — 그 SENT(시크릿 · Basic 헤더) 표를 그대로 쓴다.
    def config
      KeycloakSdk::Config.new(server_url: SERVER, realm: "r", client_id: "c",
                              client_secret: HostileTokenResponseSpec::SECRET)
    end
  end

  # 기록하는 가짜 IdP — 모든 요청을 (verb, 호스트, 경로, 토큰 요청이면 grant_type) 로 남긴다. 기록은 라우팅 **앞**이라
  # 라우트가 없는 경로(admin 404 · 다른 호스트)도 남는다: 분류는 SDK 가 무엇을 **시도했나**를 본다.
  class Idp
    attr_reader :reqs
    attr_accessor :token_reply, :certs_down

    def initialize(fixture)
      @fixture = fixture
      @reqs = []
      @token_reply = nil
      @certs_down = false
    end

    def reset = @reqs.clear

    def handle(sig)
      path = Wire.normalize(sig.uri.path)
      @reqs << Req.new(verb: sig.method, host: sig.uri.host, path: path, grant: self.class.grant(sig, path))
      sig.uri.host == URI(SERVER).host ? route(sig.method, path) : { status: 404 }
    end

    # 폼이든 JSON 이든 쿼리든 grant_type 을 읽는다 — 본문 밖에 둔 코드 교환이 TOKEN_GRANT 로 새지 않게(JSON 본문 ·
    # Grok 레그 실측: 쿼리에만 둔 authorization_code 가 TOKEN_GRANT 로 읽혔다).
    def self.grant(sig, path)
      return unless sig.method == :post && path.end_with?(TOKEN_SUFFIX)

      from_body(sig.body.to_s) || sig.uri.query_values&.fetch("grant_type", nil)
    end

    def self.from_body(body)
      parsed = begin
        JSON.parse(body)
      rescue JSON::ParserError
        URI.decode_www_form(body).to_h
      end
      parsed.is_a?(Hash) ? parsed["grant_type"] : nil
    rescue ArgumentError
      nil
    end

    private

    def route(verb, path)
      case [verb, path.delete_prefix(BASE)]
      in [:post, "/token"] then token_reply || default_token
      in [:post, "/token/introspect"] then Wire.json(200, active: true, username: "svc", client_id: "c", sub: "u1")
      in [:get, "/certs"] then certs
      in [:post, "/logout"] then { status: 204 }
      else { status: 404 }
      end
    end

    def certs = certs_down ? { status: 503 } : { status: 200, headers: JSON_HEADERS, body: @fixture.jwks }

    # ⚠️ expires_in 은 skew(30s)보다 짧다 — provider 캐시가 늘 식어 있어 부여에 닿을 수 있는 메서드는 실제로 닿는다.
    def default_token
      Wire.json(200, access_token: "hp-access", token_type: "Bearer", expires_in: 1, refresh_token: "hp-refresh",
                     id_token: @fixture.id_token, scope: "openid")
    end
  end

  # 새 IdP · 새 수신자로 부른다. catch-all 스텁 하나가 그 순간의 IdP 로 보낸다(모든 호스트).
  class Engine
    include WebMock::API

    attr_reader :fixture, :idp

    def initialize
      @fixture = Fixture.new
      @idp = Idp.new(@fixture)
      engine = self
      stub_request(:any, /.*/).to_return { |sig| engine.idp.handle(sig) }
    end

    def fresh_idp = (@idp = Idp.new(@fixture))

    def universal = @fixture.universal

    # target: [:recipe, 타입, Recipe] · [:allocate, 클래스] · [:module, 모듈]
    def receiver(target)
      kind, what, recipe = target
      case kind
      when :recipe then Reflect.find_all(build(recipe)).fetch(what)
      when :allocate then what.allocate
      else what
      end
    end

    def build(recipe)
      obj = BUILDERS.fetch(recipe.builder).call(@fixture.config)
      recipe.steps.each do |type, meth, shape|
        obj = Reflect.invoke(Reflect.find_all(obj).fetch(type), meth, shape, universal).value
      end
      obj
    end

    # 한 칸 — 수신자를 정상 응답으로 만든 **뒤에** 토큰 응답·JWKS 를 바꾼다. 수신자를 만들며 나간 요청은 버린다.
    def call(target, meth, shape, blank: false, reply: nil, certs_down: false, times: 1)
      fresh_idp
      recv = receiver(target)
      @idp.reset
      @idp.token_reply = reply
      @idp.certs_down = certs_down
      outs = Array.new(times) { Reflect.invoke(recv, meth, shape, universal, blank: blank) }
      [@idp.reqs.dup, times == 1 ? outs.first : outs]
    end
  end

  # 선언 집합 — 걷기가 닿은 클래스의 SDK 소유 조상 메서드 ∪ 소스 위치가 ruby/lib 인 공개 메서드(싱글턴 포함).
  class Declared
    # 줄 머리의 `def` 만이 아니라 한 줄 정의(`…; def x`)와 `define_method`·`define_singleton_method` 도 읽는다.
    DEF = /(?:^|;)\s*def\s+(?:self\.)?([a-z_]\w*[?!=]?)|define_(?:singleton_)?method\(?\s*:([a-z_]\w*[?!=]?)/

    attr_reader :types, :instance, :singleton, :source_only, :unloaded

    def initialize(reached)
      @types = reached.to_a.sort
      @instance = {}
      @types.each { |t| add_instance(t) }
      @singleton = {}
      @source_only = []
      FacadeDumpSpec::Declared.runtime.each { |m| add_source(Object.const_get(m)) }
      @unloaded = unloaded_files + unloaded_defs
    end

    def labels_for(type)
      @instance.select { |_, info| info[:candidates].include?(type) }.map { |label, info| [label, info[:name]] }
    end

    # 인스턴스에만 붙은 공개 싱글턴 메서드도 행이다 — 그 타입의 새 수신자에서 부른다(Grok 레그 실측: 생성자 안의
    # `define_singleton_method` 가 선언 집합에서 조용히 빠졌다).
    def add_eigen(type, meth)
      (@instance["#{Wire.short(type)}##{meth}"] ||= { owner: nil, name: meth, candidates: [] })[:candidates] |= [type]
    end

    private

    def own?(mod) = mod.name.to_s.start_with?("KeycloakSdk::")

    def in_lib?(meth) = meth.source_location&.first.to_s.start_with?("#{LIB}/")

    def add_instance(type)
      Object.const_get(type).ancestors.select { |a| own?(a) }.each do |owner|
        owner.public_instance_methods(false).sort.each do |m|
          label = "#{Wire.short(owner.name)}##{m}"
          (@instance[label] ||= { owner: owner, name: m, candidates: [] })[:candidates] << type
        end
      end
    end

    def add_source(mod)
      mod.public_instance_methods(false).each do |m|
        label = "#{Wire.short(mod.name)}##{m}"
        @source_only << label if in_lib?(mod.instance_method(m)) && !@instance.key?(label)
      end
      mod.singleton_class.public_instance_methods(false).each do |m|
        @singleton["#{Wire.short(mod.name)}.#{m}"] = { mod: mod, name: m } if in_lib?(mod.method(m))
      end
    end

    # `require "keycloak_sdk"` 가 싣지 않는 ruby/lib 파일 — 그 안의 정의는 이름이 로드된 메서드와 겹쳐도 행이 못 된다
    # (Grok 레그 실측: 아무도 require 하지 않는 파일의 한 줄 `class_eval` 정의가 조용히 빠졌다).
    def unloaded_files
      loaded = $LOADED_FEATURES.map { |f| File.expand_path(f) }
      missing = Dir.glob(File.join(LIB, "**", "*.rb")).reject { |f| loaded.include?(File.expand_path(f)) }
      missing.map { |f| "#{f.delete_prefix("#{LIB}/")} (로드되지 않은 파일)" }
    end

    # 소스의 정의 이름이 런타임 SDK 메서드(가시성·싱글턴 무관)에 없으면 로드되지 않은 선언이다.
    def unloaded_defs
      runtime = FacadeDumpSpec::Declared.runtime.flat_map { |n| names(Object.const_get(n)) }.to_set
      Dir.glob(File.join(LIB, "**", "*.rb")).flat_map do |file|
        File.readlines(file).each_with_index.flat_map do |line, i|
          line.scan(DEF).map(&:compact).flatten.reject { |name| runtime.include?(name.to_sym) }
              .map { |name| "#{file.delete_prefix("#{LIB}/")}:#{i + 1} def #{name}" }
        end
      end
    end

    def names(mod)
      s = mod.singleton_class
      mod.instance_methods(false) + mod.private_instance_methods(false) + s.instance_methods(false) +
        s.private_instance_methods(false)
    end
  end

  # 분류 — 빌더의 걷기로 수신자를 찾고, 반환값을 따라 새 타입의 수신자를 얻는다(고정점).
  class Classifier
    def initialize(engine, declared)
      @engine = engine
      @declared = declared
      @rows = {}
    end

    def run
      recipes = probe
      queue = recipes.keys
      until queue.empty?
        type = queue.shift
        @declared.labels_for(type).each do |label, meth|
          next if @rows.key?(label)

          @rows[label], returns = classify(label, [:recipe, type, recipes[type]], meth, recipes[type].to_s)
          returns.each { |shape, value| discover(value, recipes, queue, recipes[type].then_call(type, meth, shape)) }
        end
      end
      finish_allocated
      finish_rest
      @rows.values.sort_by(&:label)
    end

    private

    def probe
      BUILDERS.each_with_object({}) do |(name, build), recipes|
        @engine.fresh_idp
        Reflect.find_all(build.call(@engine.fixture.config)).each do |type, obj|
          next if recipes.key?(type) || !@declared.types.include?(type)

          recipes[type] = Recipe.new(builder: name, steps: [])
          eigen(type, obj)
        end
      end
    end

    def discover(value, recipes, queue, recipe)
      Reflect.find_all(value).each do |type, obj|
        next if recipes.key?(type) || !@declared.types.include?(type)

        recipes[type] = recipe
        eigen(type, obj)
        queue << type
      end
    end

    def eigen(type, obj) = Reflect.eigen_methods(obj).each { |m| @declared.add_eigen(type, m) }

    # 빌더·반환값 어디에도 안 닿은 타입은 allocate(Go 의 영값 수신자)로 부른다.
    def finish_allocated
      @declared.instance.each do |label, info|
        next if @rows.key?(label)

        klass = info[:owner].is_a?(Class) ? info[:owner] : Object.const_get(info[:candidates].first)
        @rows[label], = classify(label, [:allocate, klass], info[:name], "allocate")
      end
    end

    # 싱글턴은 모듈 자신이 수신자 · 걷기 밖 모듈의 인스턴스 메서드와 로드되지 않은 선언은 수신자가 없다.
    def finish_rest
      @declared.singleton.each do |label, info|
        @rows[label], = classify(label, [:module, info[:mod]], info[:name], "(#{Wire.short(info[:mod].name)} 자신)")
      end
      # 인스턴스 싱글턴으로 행이 된 이름은 소스 대조의 「로드 안 된 선언」에서 뺀다(같은 것을 두 번 세지 않게).
      rowed = @rows.keys.map { |l| l.split(/[#.]/).last }
      unloaded = @declared.unloaded.reject { |u| rowed.include?(u[/ def (\S+)\z/, 1]) }
      (@declared.source_only + unloaded).each { |label| @rows[label] = unreached(label) }
    end

    def unreached(label)
      Row.new(label: label, cls: UNDETERMINED, reqs: "-", recv: "없음", outcome: "-", sent: [], shape: :base,
              params: [], foreign: [],
              note: " · 걷기가 닿지 않거나 로드되지 않은 선언이라 수신자가 없다(facade_dump_spec 의 뿌리에 닿게 하거나 " \
                    "이유와 함께 면제하라)")
    end

    # 파라미터는 실제 수신자에서 읽는다 — 인스턴스 싱글턴 메서드는 클래스의 instance_method 에 없다.
    def classify(label, target, meth, recv)
      @engine.fresh_idp
      params = @engine.receiver(target).method(meth).parameters
      runs = Args.shapes(params).map do |shape|
        reqs, out = @engine.call(target, meth, shape)
        { shape: shape, reqs: reqs, out: out, cls: Wire.classify(reqs, out.failed?) }
      end
      returns = runs.reject { |r| r[:out].value.nil? }.map { |r| [r[:shape], r[:out].value] }
      [row(label, target, meth, recv, runs).tap { |r| r.params = params }, returns]
    end

    # 모양이 둘이면 더 강한 계급이 이기고, 같으면 앞 모양(:base)이 이긴다. 다른 호스트 요청은 두 모양 전부에서 모은다.
    def row(label, target, meth, recv, runs)
      best = runs.each_with_index.max_by { |r, i| [RANK.index(r[:cls]), -i] }.first
      Row.new(label: label, cls: best[:cls], reqs: Wire.format(best[:reqs], @engine.universal),
              recv: recv, outcome: outcome(best[:out]), note: note(best), sent: best[:reqs], shape: best[:shape],
              target: target, meth: meth, foreign: runs.flat_map { |r| r[:reqs] }.select { |q| Wire.foreign?(q) })
    end

    # 사유는 분류를 못 한 행에만 — 요청을 낸 행의 오류(admin 404 등)는 분류와 무관하다.
    def note(run)
      raised = run[:out].raised
      run[:cls] == UNDETERMINED ? " · #{raised.class}: #{raised.message.to_s[0, 120]}" : ""
    end

    def outcome(out)
      return "crash" if out.crash

      out.error ? "err" : "ok"
    end
  end

  # W3 의 변형 집합 — 새로 만들지 않고 기존 테스트에서 가져온다.
  module Variants
    module_function

    # hostile_token_response_spec.rb 의 VARIANTS 중 토큰 호출(TOKEN) **전부에** 단언된 것 + tokens_spec.rb 의 비문자열
    # access_token 표. 일부 토큰 호출에만 단언된 것은 측정만 한다(from=nil). admin 응답 변형과 id_token 변형은 뺀다.
    # 연결 계층 변형(g1·z1)도 쓴다 — webmock 의 `exception:` 은 토큰 엔드포인트에만 걸 수 있다(Go 는 raw 소켓이라 뺐다).
    def token_response(universal)
      out = []
      skipped = []
      HostileTokenResponseSpec::VARIANTS.each do |key, v|
        case kind(v)
        when :admin then skipped << "#{key}(admin 응답 변형 — 토큰 응답은 정상)"
        when :id_token then skipped << "#{key}(id_token 변형 — (a) 는 nonce 를 비운다 · W3b 가 잰다)"
        else out << hostile(key, v, universal)
        end
      end
      [out + non_string(universal), skipped]
    end

    def kind(variant)
      return :admin if variant[:admin]
      return :asserted if HostileTokenResponseSpec::TOKEN.all? { |c| variant[:expect].key?(c) }
      return :id_token if variant[:expect].keys.all? { |c| c.include?("nonce") }

      :measure
    end

    def hostile(key, variant, universal)
      from = kind(variant) == :asserted ? "hostile_token_response_spec.rb #{key}" : nil
      { code: key, from: from, reply: reply(variant),
        canaries: HostileTokenResponseSpec.canaries(key).merge("U" => universal) }
    end

    # 연결 계층 변형은 그 spec 의 `to_raise` 와 같은 뜻의 `exception:`(인스턴스는 사본 — 칸끼리 상태를 나누지 않게).
    def reply(variant)
      raised = variant[:raise]
      return variant[:reply] if raised.nil?

      { exception: raised.is_a?(Exception) ? raised.dup : raised }
    end

    def non_string(universal)
      TokensSpec::NON_STRING_ACCESS_TOKENS.map do |bad|
        body = { access_token: bad, token_type: "Bearer", expires_in: 300, refresh_token: RT_CANARY }
        { code: "at:#{bad.to_json}", from: "tokens_spec.rb NON_STRING_ACCESS_TOKENS", reply: Wire.json(200, body),
          canaries: HostileTokenResponseSpec::SENT.merge("RT" => RT_CANARY, "U" => universal) }
      end
    end
  end

  # 칸의 실패 사유 — 비면 통과.
  module Why
    module_function

    def control(out, hits, after)
      return ["정상 응답에 크래시: #{out.crash.class}"] if out.crash
      return ["정상 응답에서 토큰 엔드포인트에 안 닿았다 — 이 행의 변형은 공허하다"] if hits.zero?
      return [] unless out.error && after.empty?

      ["정상 응답에 실패했고 토큰 뒤로 나아가지도 않았다 — 변형이 무엇을 바꿨는지 가를 수 없다: #{out.error.class}"]
    end

    def hostile(reqs, out, canaries, ctl_hits)
      why = outcome(out)
      why.concat(leaks(out.raised, canaries)) if out.failed?
      hits, after = Wire.after_token(reqs)
      why << "토큰 엔드포인트에 한 번도 안 닿았다 — 변형이 공허하다" if hits.zero?
      # 하한만 두면 틀린 응답마다 재시도하는 새 메서드가 통과한다(Go 레그 실측). 상한은 손 상수가 아니라 같은 행의 대조다.
      why << "토큰 요청 #{hits} 건 — 정상 응답 대조(#{ctl_hits} 건)보다 많다: 틀린 응답이 재시도를 부른다" if hits > ctl_hits
      why << "적대 토큰 응답 뒤로 나아갔다: #{Wire.format(after, nil)}" if after.any?
      why
    end

    def outcome(out)
      return ["크래시(StandardError 밖): #{out.crash.class}"] if out.crash
      return ["오류 없이 성공했다"] if out.error.nil?

      chain = HostileTokenResponseSpec.chain(out.error)
      why = []
      why << "SDK 오류 타입이 아니다: #{out.error.class}" unless out.error.is_a?(KeycloakSdk::Error)
      why << "원인 사슬에 하위 예외가 있다(§4): #{chain.join(' <- ')}" unless chain.all? { |n| n.start_with?("KeycloakSdk::") }
      why
    end

    # 적대 응답 행렬의 검출기 그대로 — message·inspect·pretty_inspect·full_message·원인 사슬, 전체 또는 앞 10 자.
    def leaks(err, canaries)
      outs = HostileTokenResponseSpec.renderings(err)
      HostileTokenResponseSpec.scan(outs, canaries).map { |path, name, how| "카나리아 #{name} 가 #{path} 에 찍혔다(#{how})" }
    end

    # W3b 한 칸이 공허하지 않은가 — 토큰 엔드포인트에 닿았고, id_token 이 있는 변형은 검증기까지 갔다(콜드 캐시라
    # JWKS 를 조회한다). 아니면 다른 이유로 실패한 것이다.
    def reach(out, reqs, certs, no_id)
      why = []
      why << "크래시: #{out.crash.class}" if out.crash
      why << "토큰 엔드포인트에 안 닿았다 — 변형이 공허하다" if reqs.none? { |q| Wire.token?(q) }
      why << "JWKS 를 조회하지 않았다 — id_token 이 검증기에 닿지 않았다" if certs.zero? && !no_id
      why
    end

    def nonce(out, want)
      err = out.error
      return err ? ["맞는 id_token 에 실패했다 — 아래 변형의 실패가 아무것도 증명하지 않는다: #{err.class}"] : [] if want == :ok
      return ["틀린 id_token 을 받아들였다"] unless out.failed?
      return ["SDK 오류 타입이 아니다: #{err.class}"] if err && !err.is_a?(KeycloakSdk::Error)

      []
    end

    def cold(out, nth)
      return ["#{nth}번째 호출이 크래시: #{out.crash.class}"] if out.crash
      return ["#{nth}번째 호출이 JWKS 503 인데 성공했다"] if out.error.nil?
      return [] if out.error.is_a?(KeycloakSdk::Error)

      ["#{nth}번째 호출의 오류가 SDK 오류 타입이 아니다: #{out.error.class}"]
    end
  end

  # ---- W3: 계급별 적대 변형 ----
  class Hostile
    # W3b — 대조와 다섯. 다른 키로 서명할 때 kid 가 k1 이면 캐시된 키로 서명 검증이 실패하고, k2 면 키를 못 찾는다.
    # 「id_token 없음」·「nonce 클레임 없음」까지 거부가 계약이다(auth_client_spec · 통합 code_exchange_spec).
    # 뒤의 셋(iss·aud·exp)은 **측정만** 한다 — 교환 경로의 id_token 에 대해 그것을 단언하는 기존 테스트가 없다. id_token
    # aud 는 (a)「client_id 로 따로 검증」으로 판정됐으나 아직 구현 전이다(등록부 `id-token-audience-follows-access-audience`,
    # #653) — 그 구현이 단언 테스트를 세우면 이 열을 단언으로 올린다. Grok 레그가 「서명·nonce 만 보고 iss·aud 를 안 보는
    # 새 교환이 다섯을 다 통과한다」를 실측으로 보였다 — 계약을 새로 만들지 않고 드러내 둔다.
    NonceVariant = Data.define(:code, :kid, :other, :claims, :no_id, :want)
    NONCE_VARIANTS = [
      NonceVariant.new("대조", "k1", false, nil, false, :ok),
      NonceVariant.new("nonce≠", "k1", false, { "nonce" => "hp-other-nonce" }, false, :reject),
      NonceVariant.new("key≠·kid=k1", "k1", true, nil, false, :reject),
      NonceVariant.new("key≠·kid=k2", "k2", true, nil, false, :reject),
      NonceVariant.new("id_token없음", nil, false, nil, true, :reject),
      NonceVariant.new("nonce클레임없음", "k1", false, {}, false, :reject),
      NonceVariant.new("iss≠", "k1", false, { "iss" => "https://evil.test/realms/r" }, false, :measure),
      NonceVariant.new("aud≠", "k1", false, { "aud" => "someone-else" }, false, :measure),
      NonceVariant.new("exp지남", "k1", false, { "exp" => Time.now.to_i - 3600 }, false, :measure)
    ].freeze
    # W3a 대조 — 변형들과 같은 모양(id_token 없음)의 쓸 수 있는 토큰 응답.
    WELL_FORMED = { access_token: "hp-access", token_type: "Bearer", expires_in: 300,
                    refresh_token: "hp-refresh" }.freeze

    attr_reader :log

    def initialize(engine)
      @engine = engine
      @log = []
    end

    def run_a(rows)
      variants, skipped = Variants.token_response(@engine.universal)
      @log << "(a) 토큰응답 형식 변형 #{variants.size}(측정만 #{variants.count { |v| v[:from].nil? }}) — 기존 테스트에서 " \
              "파생 · 뺀 것: #{skipped.join(', ')}"
      rows.flat_map { |row| cells_a(row, variants) }
    end

    def run_b(rows)
      names = rows.map { |r| "#{r.label}#{Args.nonce_names(r.params)}" }
      @log << "(b) nonce 대상(서명에서 파생 — 파라미터 이름): #{names.join(', ')}"
      rows.flat_map { |row| NONCE_VARIANTS.map { |v| cell_b(row, v) } }
    end

    def run_c(rows)
      @log << "(c) 콜드 캐시 JWKS 대상(분류 실행이 /certs 를 조회한 행): #{rows.map(&:label).join(', ')}"
      rows.map { |row| cell_c(row) }
    end

    private

    # ⚠️ 행마다 정상 응답 대조를 먼저 돈다 — admin 자원 메서드는 정상 응답에도 404 로 실패하므로 그 행에서 「오류다」는
    # 공허하고, 무게는 「토큰 뒤로 안 나아갔다」가 진다. 대조가 둘 다 못 가르면 행이 실패한다.
    def cells_a(row, variants)
      reqs, out = @engine.call(row.target, row.meth, row.shape, blank: true, reply: Wire.json(200, WELL_FORMED))
      hits, after = Wire.after_token(reqs)
      control = Cell.new(axis: "a", label: row.label, variant: "대조", measure: false,
                         why: Why.control(out, hits, after), note: out.error ? "↓#{after.size}" : "ok")
      [control] + variants.map { |v| cell_a(row, v, hits) }
    end

    def cell_a(row, variant, ctl_hits)
      reqs, out = @engine.call(row.target, row.meth, row.shape, blank: true, reply: variant[:reply])
      Cell.new(axis: "a", label: row.label, variant: variant[:code], measure: variant[:from].nil?,
               why: Why.hostile(reqs, out, variant[:canaries], ctl_hits), note: out.raised.class.name.to_s)
    end

    def cell_b(row, variant)
      reqs, out = @engine.call(row.target, row.meth, row.shape, reply: id_token_reply(variant))
      certs = reqs.count { |q| Wire.certs?(q) }
      measure = variant.want == :measure
      note = measure ? "certs #{certs} · #{out.raised.class}" : "certs #{certs}"
      Cell.new(axis: "b", label: row.label, variant: variant.code, measure: measure, note: note,
               why: Why.reach(out, reqs, certs, variant.no_id) + Why.nonce(out, variant.want))
    end

    # 측정 변형은 nonce 가 맞는 채로 한 클레임만 바꾼다 — 거부가 nonce 탓이면 그 칸은 아무것도 재지 않는다.
    def id_token_reply(variant)
      body = WELL_FORMED.dup
      unless variant.no_id
        fixture = @engine.fixture
        nonce = { "nonce" => fixture.universal }
        claims = variant.want == :measure ? nonce.merge(variant.claims) : (variant.claims || nonce)
        body[:id_token] = fixture.sign(variant.other ? fixture.other : fixture.key, variant.kid, claims)
      end
      Wire.json(200, body)
    end

    def cell_c(row)
      reqs, outs = @engine.call(row.target, row.meth, row.shape, certs_down: true, times: COLD_K)
      why = outs.each_with_index.flat_map { |out, i| Why.cold(out, i + 1) }
      hits = reqs.count { |q| Wire.certs?(q) }
      why << "/certs 요청 #{hits} — 콜드 경로에 닿지 않았다(하한 1)" if hits < 1
      why << "/certs 요청 #{hits} — 실패한 조회가 물러서지 않았다(상한 #{COLD_K - 1})" if hits > COLD_K - 1
      Cell.new(axis: "c", label: row.label, variant: "503×#{COLD_K}", why: why, measure: false, note: "certs #{hits}")
    end
  end

  # 칸마다 pass · GAP · FAIL · 측정(m:rej/m:ACC)을 정하고 판정표·요약을 만든다.
  class Judge
    attr_reader :fails

    def initialize(cells)
      @cells = cells
      @fails = []
      @observed = []
      @verdict = cells.to_h { |c| [c.key, verdict(c)] }
      KNOWN_GAPS.each do |key, why|
        @fails << "KNOWN_GAPS[#{key}]: 더는 관측되지 않는다 — 낡은 항목을 지워라(#{why})" unless @observed.include?(key)
      end
    end

    def lines = %w[a b c].flat_map { |axis| table(axis) } + measured

    def summaries = %w[a b c].map { |axis| summary(axis) }

    private

    def verdict(cell)
      v = base_verdict(cell)
      cell.note.to_s.empty? || (cell.axis == "a" && cell.variant != "대조") ? v : "#{v}(#{cell.note})"
    end

    def base_verdict(cell)
      return cell.why.empty? ? "m:rej" : "m:ACC" if cell.measure
      return "pass" if cell.why.empty?

      if KNOWN_GAPS.key?(cell.key)
        @observed << cell.key
        return "GAP"
      end
      @fails << "#{cell.key}: #{cell.why.join(' · ')}"
      "FAIL"
    end

    def summary(axis)
      cells = @cells.select { |c| c.axis == axis }
      n = Hash.new(0).merge(cells.map { |c| @verdict[c.key].split("(").first }.tally)
      "W3#{axis} 요약: pass #{n['pass']} · GAP #{n['GAP']} · FAIL #{n['FAIL']} · 측정 #{n['m:rej'] + n['m:ACC']}" \
        "(m:rej #{n['m:rej']} · m:ACC #{n['m:ACC']}) · FAIL 열 #{failed_columns(cells)}"
    end

    def failed_columns(cells)
      cells.select { |c| @verdict[c.key].start_with?("FAIL") }.map(&:variant).tally.map { |v, k| "#{v}×#{k}" }
    end

    # 한 축의 판정표 — 행은 메서드, 열은 변형.
    def table(axis)
      cells = @cells.select { |c| c.axis == axis }
      return ["W3#{axis} 판정표: 대상 행이 없다"] if cells.empty?

      labels = cells.map(&:label).uniq
      cols = cells.map(&:variant).uniq
      grid = labels.map { |l| [l] + cols.map { |col| cell_text(axis, l, col) } }
      head = ["행 \\ 변형"] + cols
      ["W3#{axis} 판정표 — #{labels.size}행 × #{cols.size}열 (pass · GAP=알려진 틈 · FAIL · m:rej/m:ACC=측정만: " \
       "거부/받아들임)"] + align([head] + grid)
    end

    def cell_text(axis, label, col) = @verdict.fetch(Cell.new(axis: axis, label: label, variant: col).key, "")

    def align(grid)
      widths = grid.transpose.map { |col| col.map(&:length).max }
      widths[0] = 44
      grid.map { |r| r.each_with_index.map { |v, i| v.ljust(widths[i]) }.join(" ").rstrip }
    end

    # 측정 칸은 변형마다 한 줄 — 받아들인 행만 이름을 적는다.
    def measured
      @cells.select(&:measure).group_by { |c| "W3#{c.axis} #{c.variant}" }.map do |k, cells|
        rejected, accepted = cells.partition { |c| c.why.empty? }
        "측정(단언 안 함) #{k} — 거부 #{rejected.size} · 받아들임 #{accepted.size} · 거부 오류 " \
          "#{rejected.map(&:note).uniq.sort} · 받아들인 행 #{accepted.map(&:label)}"
      end
    end
  end

  # ---- W1: 손 목록 포함 ----
  #
  # 손으로 고른 Ruby 보안 테스트가 겨누는 메서드 — 파생 집합이 이것 밑으로 **조용히** 줄지 않게 한다.
  # anchor 는 그 손 테스트, call 은 그 테스트가 실제로 부르는 이름이다(생략하면 라벨의 메서드). call 이 라벨의 메서드와
  # 다르면 라벨은 그것의 공개 입구이고, 입구의 소스가 call 에 닿는지(같은 클래스의 도우미를 두 단계까지) 대조한다.
  # axis: a·b·c = 그 W3 축의 파생 대상에 있어야 한다 · row = 행이고 계급이 맞기만 하면 된다(교환 계급 밖).
  module Hand
    HOSTILE = "hostile_token_response_spec.rb"
    Target = Data.define(:label, :cls, :axis, :anchor, :call) do
      def initialize(label:, cls:, axis:, anchor:, call: nil) = super
    end
    TARGETS = [
      # #624 의 적대 토큰응답 행렬(HostileTokenResponseSpec::CALLS) — 키마다 한 줄. 라벨은 그 호출 사슬을 **실행해** 얻는다.
      Target.new("AuthClient#client_credentials_token", TOKEN_GRANT, "a",
                 "#{HOSTILE}|CALLS[auth.client_credentials_token]"),
      Target.new("AuthClient#access_token", TOKEN_GRANT, "a", "#{HOSTILE}|CALLS[auth.access_token]"),
      Target.new("AuthClient#refresh", TOKEN_GRANT, "a", "#{HOSTILE}|CALLS[auth.refresh]"),
      Target.new("AuthClient#exchange_code", CODE_EXCHANGE, "a", "#{HOSTILE}|CALLS[auth.exchange_code]"),
      Target.new("AuthClient#exchange_code", CODE_EXCHANGE, "a",
                 "#{HOSTILE}|CALLS[auth.exchange_code(expected_nonce:)]"),
      Target.new("ClientCredentialsTokenProvider#access_token", TOKEN_GRANT, "a",
                 "#{HOSTILE}|CALLS[ClientCredentialsTokenProvider#access_token]"),
      Target.new("Admin::Users#get", TOKEN_GRANT, "a", "#{HOSTILE}|CALLS[admin.users.get(token via provider)]"),
      Target.new("AuthClient#introspect", OTHER, "row", "#{HOSTILE}|CALLS[auth.introspect]"),
      Target.new("AuthClient#logout", OTHER, "row", "#{HOSTILE}|CALLS[auth.logout]"),
      # 보안 기본값 가드(scripts/test/test-security-defaults.sh)의 Ruby 행위 앵커 — nonce · 백오프 · 토큰 타입.
      Target.new("AuthClient#exchange_code", CODE_EXCHANGE, "b", 'auth_client_spec.rb|it "rejects a mismatched nonce"'),
      Target.new("AuthClient#exchange_code", CODE_EXCHANGE, "b",
                 'auth_client_spec.rb|it "rejects a response missing the id_token when a nonce is expected"'),
      Target.new("JwksStore#key_set", JWKS_FETCH, "c",
                 'jwks_store_spec.rb|it "bounds retries while the IdP is failing — 20회 시도가 요청 1건이 된다"'),
      Target.new("JwksStore#key_set", JWKS_FETCH, "c", 'jwks_store_spec.rb|it "백오프가 지나면 다시 시도한다 (대조군)"'),
      Target.new("JwksStore#key_set", JWKS_FETCH, "c", 'jwks_store_spec.rb|it "성공하면 실패 카운터가 0으로 돌아간다 (대조군)"'),
      # 토큰 타입 앵커는 파서(TokenSet.from_response)를 직접 부른다 — 교환 입구는 provider 다.
      Target.new("ClientCredentialsTokenProvider#access_token", TOKEN_GRANT, "a",
                 "tokens_spec.rb|it \"rejects a non-string access_token (\#{bad.inspect})\"", "from_response")
    ].freeze
    # 보안 기본값 가드가 Ruby 행위 앵커를 적는 모양(`ruby/spec/unit/<파일>|it "<설명>"`) — nonce·백오프·토큰 타입 세 축.
    SCRIPT = File.expand_path("../../../scripts/test/test-security-defaults.sh", __dir__)
    SCRIPT_ANCHOR = %r{ruby/spec/unit/([a-z_]+_spec\.rb)\|(it "[^"]*")}

    # 호출 사슬을 기록하는 대역 — CALLS 의 람다를 이것에 대고 **실행해** 무엇을 부르는지 읽는다(소스를 파싱하지 않는다).
    class Chain < BasicObject
      def initialize(log)
        @log = log
      end

      def method_missing(name, *, **)
        @log << name
        self
      end

      def respond_to_missing?(*) = true
    end

    module_function

    def problems(by_label, targets)
      TARGETS.flat_map { |t| row_problems(by_label[t.label], t, targets) + anchor_problems(t) } + completeness
    end

    def row_problems(row, target, targets)
      return ["W1 #{target.label}: 손 테스트(#{target.anchor})가 겨누는데 파생 집합에 행이 없다"] unless row
      if row.cls != target.cls
        return ["W1 #{target.label}: 손 테스트(#{target.anchor})가 겨누는 계급은 #{target.cls} 인데 파생은 #{row.cls} 다"]
      end
      return [] if target.axis == "row" || targets.fetch(target.axis).include?(row)

      ["W1 #{target.label}: 손 테스트(#{target.anchor})가 겨누는데 W3#{target.axis} 의 파생 대상에 없다"]
    end

    def anchor_problems(target)
      file, what = target.anchor.split("|", 2)
      key = what[/\ACALLS\[(.+)\]\z/, 1]
      return it_problems(target, file, what) if key.nil?

      derived, called = resolve(key)
      return [] if derived == target.label

      ["W1 #{target.anchor}: 호출 사슬이 #{derived}(.#{called}) 를 부른다 — 표의 #{target.label} 과 다르다"]
    end

    def it_problems(target, file, what)
      call = target.call || target.label.split("#").last
      body = it_body(file, what)
      return ["W1 #{file}|#{what}: 앵커 예제가 없다 — 손 테스트가 옮겨졌으면 표를 따라 고쳐라"] if body.nil?
      return ["W1 #{file}|#{what}: 앵커가 .#{call} 을 부르지 않는다 — 손 테스트의 대상이 바뀌었다"] unless body.match?(/\.#{call}\b/)
      return [] if target.label.end_with?("##{call}") || reaches?(target.label, call)

      ["W1 #{target.label}: 공개 입구가 #{call} 에 닿지 않는다 — 앵커(#{file}|#{what})의 대상과 이어지지 않는다"]
    end

    # CALLS 가 부르는 공개 호출 전부가 표에 있고, 보안 기본값 가드의 Ruby 행위 앵커가 전부 표의 앵커다.
    def completeness
      anchors = TARGETS.map(&:anchor)
      calls = HostileTokenResponseSpec::CALLS.keys.map { |k| "#{HOSTILE}|CALLS[#{k}]" }
      why = (calls - anchors).map { |a| "W1 #{a} 가 Hand::TARGETS 에 없다" }
      return why + script_missing unless File.file?(SCRIPT)

      found = script_anchors
      why << "W1 test-security-defaults.sh 에서 Ruby 행위 앵커를 하나도 못 읽었다 — 적는 모양이 바뀌었나?" if found.empty?
      why + (found - anchors).map { |a| "W1 보안 기본값 가드의 Ruby 앵커 #{a} 가 Hand::TARGETS 에 없다" }
    end

    # 가드가 없을 때 — 저장소 체크아웃이면 실패, 저장소 밖(ruby/ 만 마운트한 하네스 컨테이너)이면 건너뛴다(go·node 등과 같다).
    def script_missing
      return ["W1 저장소 체크아웃인데 보안 기본값 가드를 못 읽었다: #{SCRIPT}"] if File.exist?(File.expand_path("../../../.git", __dir__))

      $stdout.puts("W1: 저장소 밖에서 돌아 보안 기본값 가드 대조는 건너뛴다")
      []
    end

    # Result#summary 도 부른다 — 가드가 없으면 빈 목록이다(건너뜀 · 실패의 판정은 completeness 가 한다).
    def script_anchors = File.file?(SCRIPT) ? File.read(SCRIPT).scan(SCRIPT_ANCHOR).map { |f, e| "#{f}|#{e}" } : []

    def resolve(key)
      log = []
      HostileTokenResponseSpec::CALLS.fetch(key).call(Chain.new(log))
      @scene ||= HostileTokenResponseSpec::Scene.new(HostileTokenResponseSpec::VARIANTS.keys.first)
      obj = log[0..-2].reduce(@scene) { |o, m| o.public_send(m) }
      ["#{Wire.short(obj.method(log.last).owner.name)}##{log.last}", log.last]
    end

    # `it "…"` 줄부터 같은 들여쓰기의 `end` 까지(rubocop 이 들여쓰기를 강제한다).
    def it_body(file, what)
      lines = File.readlines(File.join(__dir__, file))
      i = lines.index { |l| l.strip.start_with?(what) } or return nil
      block(lines, i)
    end

    def block(lines, index)
      indent = lines[index][/\A\s*/]
      lines[(index + 1)..].take_while { |l| l.rstrip != "#{indent}end" }.join
    end

    def reaches?(label, call, depth = 2)
      owner, meth = label.split("#")
      klass = Object.const_get("KeycloakSdk::#{owner}")
      file, line = klass.instance_method(meth.to_sym).source_location
      body = block(File.readlines(file), line - 1)
      return true if body.match?(/\b#{call}\b/)
      return false if depth.zero?

      helpers = klass.private_instance_methods(false) + klass.instance_methods(false)
      body.scan(/\b[a-z_]\w*[?!]?/).uniq.map(&:to_sym).select { |n| helpers.include?(n) }
          .any? { |n| reaches?("#{owner}##{n}", call, depth - 1) }
    end
  end

  # 한 번의 실행 — 파생 · 분류 · W3 · W1 을 돌려 단언할 거리를 모은다.
  class Run
    def call
      declared = Declared.new(dump_reached)
      engine = Engine.new
      rows = Classifier.new(engine, declared).run
      targets = w3_targets(rows)
      hostile = Hostile.new(engine)
      cells = hostile.run_a(targets["a"]) + hostile.run_b(targets["b"]) + hostile.run_c(targets["c"])
      Result.new(rows: rows, declared: declared, cells: cells, log: hostile.log,
                 late: nonce_drops(rows), hand: Hand.problems(rows.to_h { |r| [r.label, r] }, targets))
    end

    private

    # 선언 타입은 facade_dump_spec 의 걷기가 정한다 — 그 뿌리·걷기를 그대로 쓴다(두 번째 걷기를 만들지 않는다).
    def dump_reached
      scene = FacadeDumpSpec::Scene.new
      walker = FacadeDumpSpec::Walker.new(scene.canaries)
      scene.roots.each { |name, obj| walker.walk(obj, name) }
      walker.reached
    end

    # W3 대상은 전부 파생이다: (a) 계급 · (b) 계급 ∩ 서명 · (c) 분류 실행이 보낸 요청.
    def w3_targets(rows)
      called = rows.reject { |r| r.target.nil? }
      { "a" => called.select { |r| [TOKEN_GRANT, CODE_EXCHANGE].include?(r.cls) },
        "b" => called.select { |r| r.cls == CODE_EXCHANGE && nonce?(r) },
        "c" => called.select { |r| r.sent.any? { |q| Wire.certs?(q) } } }
    end

    def nonce?(row) = Args.nonce_names(row.params).any?

    # nonce 파라미터 없는 CODE_EXCHANGE 행은 면제가 있어야 하고, 면제는 그런 행이어야 한다(낡은 면제는 실패).
    def nonce_drops(rows)
      dropped = rows.select { |r| r.cls == CODE_EXCHANGE && !r.target.nil? && !nonce?(r) }.map(&:label)
      missing = (dropped - NONCE_DROP_EXEMPT.keys).map do |label|
        "W3b #{label}: CODE_EXCHANGE 인데 이름에 nonce 가 든 파라미터가 없어 W3b 가 붙지 않는다 — nonce 를 그 이름으로 " \
          "받게 하거나, 정말 nonce 없는 흐름이면 이유와 함께 NONCE_DROP_EXEMPT 에 적어라"
      end
      missing + (NONCE_DROP_EXEMPT.keys - dropped).map do |label|
        "NONCE_DROP_EXEMPT[#{label}]: 낡은 면제다 — nonce 파라미터 없는 CODE_EXCHANGE 행이 아니다(#{NONCE_DROP_EXEMPT[label]})"
      end
    end
  end

  # 단언할 거리와 찍을 표.
  class Result
    attr_reader :rows, :judge, :late, :hand

    def initialize(rows:, declared:, cells:, log:, late:, hand:)
      @rows = rows
      @declared = declared
      @judge = Judge.new(cells)
      @log = log
      @late = late
      @hand = hand
      $stdout.puts(text) if ENV.fetch("HP_MATRIX_VERBOSE", nil) == "1"
    end

    def counts = CLASSES.to_h { |c| [c, @rows.count { |r| r.cls == c }] }

    def undetermined
      undetermined = @rows.select { |r| r.cls == UNDETERMINED }
      open = undetermined.reject { |r| EXEMPT.key?(r.label) }.map { |r| "#{r.label}: UNDETERMINED#{r.note}" }
      stale = EXEMPT.keys - undetermined.map(&:label)
      open + stale.map { |l| "EXEMPT[#{l}]: 낡은 면제다 — 행이 없거나 더는 UNDETERMINED 가 아니다(#{EXEMPT[l]})" }
    end

    def empty_classes = [CODE_EXCHANGE, TOKEN_GRANT, JWKS_FETCH].select { |c| counts[c].zero? }

    # 설정한 서버가 아닌 호스트로 나간 요청(두 모양 전부) — SDK 엔드포인트는 전부 server_url 에서 조립되므로 0 이다.
    # W3a 는 토큰 요청 **뒤**만 보므로, 교환 **앞**에서 code 를 다른 호스트로 흘리는 새 메서드는 여기서만 운다(Grok 레그 실측).
    def foreign = @rows.flat_map { |r| r.foreign.to_a.map { |q| "#{r.label}: #{Wire.format([q], nil)}" } }

    # 런타임에 선언된 SDK 클래스 가운데 행렬의 수신자 타입이 아닌 것(facade_dump_spec 의 면제는 뺀다).
    def untyped_classes
      classes = FacadeDumpSpec::Declared.runtime.select { |n| Object.const_get(n).is_a?(Class) }
      classes - @declared.types - FacadeDumpSpec::EXEMPT.keys
    end

    def summary
      head = "계급별: #{counts.map { |c, n| "#{c} #{n}" }.join(' · ')} — 선언 집합 #{@rows.size}"
      hand = "W1 손 목록 #{Hand::TARGETS.size} 항목 · CALLS #{HostileTokenResponseSpec::CALLS.size} · 보안 기본값 가드의 " \
             "Ruby 행위 앵커 #{Hand.script_anchors.size}"
      ([head] + @judge.summaries + [hand]).join("\n")
    end

    def text
      table = @rows.map do |r|
        shape = r.shape == :full ? "·full" : ""
        "#{r.label.ljust(44)} → #{r.cls.ljust(13)} · #{r.reqs}  [수신자 #{r.recv}#{shape} · #{r.outcome}]#{r.note}"
      end
      ["선언 집합 #{@rows.size} 메서드 — 경로의 #{BASE} 는 생략, {U} 는 보편 인자(서명된 JWS)"] + table + @log +
        @judge.lines + [summary]
    end
  end
end

RSpec.describe KeycloakSdk do
  describe "hostile path matrix" do
    let(:result) { HostilePathMatrixSpec.result }

    it "classifies every derived public call path — no unexempted UNDETERMINED, no stale exemption" do
      expect(result.undetermined).to eq([]), "#{result.undetermined.join("\n")}\n#{result.summary}"
    end

    it "finds every exchange class (CODE_EXCHANGE · TOKEN_GRANT · JWKS_FETCH are non-empty)" do
      expect(result.empty_classes).to eq([]), "교환 경로를 하나도 못 찾은 계급 — 분류기·가짜 IdP·인자 합성이 " \
                                              "공허하다\n#{result.summary}"
    end

    it "sends every request of every derived row to the configured server only" do
      expect(result.foreign).to eq([]), "설정한 서버가 아닌 호스트로 나간 요청:\n#{result.foreign.join("\n")}"
    end

    it "keeps every declared SDK class a receiver type of the matrix (a dropped type is not silent)" do
      expect(result.untyped_classes).to eq([]), "행렬의 파생에서 빠진 SDK 클래스 — 그 메서드가 행에서 조용히 사라졌다"
    end

    it "contains every hand-picked Ruby security target at its expected class (W1)" do
      expect(result.hand).to eq([]), "#{result.hand.join("\n")}\n#{result.summary}"
    end

    it "rejects the class-attached hostile variants (W3a · W3b · W3c) or lists the cell as a known gap" do
      failures = result.late + result.judge.fails
      expect(failures).to eq([]), "#{failures.join("\n")}\n#{result.summary}"
    end
  end
end
