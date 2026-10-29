# frozen_string_literal: true

module KeycloakSdk
  # 덕 인터페이스: 구현체는 #access_token → String 을 응답한다.
  # admin은 이 인터페이스로만 토큰을 받는다(auth 비의존, §4 결합 규칙).
  # admin 은 그 값의 앞뒤 SP·HTAB·CR·LF 를 다듬어 보내고, 다듬은 것이 RFC 6750 bearer 토큰이 아니면 요청 전에 거부한다(`BearerGrammar`).
  module TokenProvider
  end

  # bearer 토큰 문법 — 아홉 SDK 가 같다(등록부 bearer-token-grammar-divergent). 앞뒤의 SP·HTAB·CR·LF 만 다듬고(NBSP·U+3000·
  # VT·FF 는 다듬지 않는다 — 그래서 NUL·VT·FF 까지 지우는 `strip` 이 아니다) 남은 것이 비지 않은 RFC 6750 b64token 이면 그 값,
  # 아니면 nil 이다. 보내는 자리(`Admin::BearerAuth`)와 캐시하는 자리(`ClientCredentialsTokenProvider`)가 이것 하나를 쓴다.
  # 다듬기와 판정을 `\A`…`\z` 매치 하나로 한다 — b64token 안에는 다듬을 글자가 없으니 「다듬고 나서 맞춘다」와 같은 뜻이다.
  # ⚠️ `\z` 다(`$` 는 줄 끝이라 "abc\nX" 를 받는다). `ascii_only?` 가 ASCII 밖·잘못된 UTF-8·ASCII 와 호환되지 않는
  # 인코딩(UTF-16 등)을 매치 전에 거른다 — 거르지 않으면 매치가 ArgumentError·Encoding::CompatibilityError 를 낸다(실측).
  module BearerGrammar
    TOKEN = %r{\A[ \t\r\n]*([A-Za-z0-9\-._~+/]+=*)[ \t\r\n]*\z}

    module_function

    def sendable(text)
      TOKEN.match(text)&.[](1) if text.ascii_only?
    end
  end
  private_constant :BearerGrammar

  # client-credentials 그랜트로 토큰을 발급하고 만료 전까지 캐시한다(Mutex single-flight).
  # admin 파사드가 소비하는 캐싱 provider(무캐시 AuthClient 직접 주입 금지 — §4 캐시 불변식).
  class ClientCredentialsTokenProvider
    include TokenProvider

    def initialize(config:, http:)
      @config = config
      @http = http
      @token_url = OidcEndpoints.from_config(config).token
      @mutex = Mutex.new
      @cached = nil
      @expires_at = 0.0
    end

    # ⚠️ 기본 `inspect` 는 인스턴스 변수를 전부 찍는데, 이 클래스는 **원시 액세스 토큰 문자열**을
    # `@cached` 에 들고 있다(`ts.access_token` — TokenSet 이 아니라서 `TokenSet#inspect` 가 안 탄다).
    # 실측(2026-09-12): 재정의 전 `p provider` 가 `@cached="AT-CENSUS-TOKEN-…"` 를 원문으로 찍었다.
    # `Config`·`TokenSet` 은 재정의가 있는데 이 타입만 없어 생긴 **형제 간 불일치**였다.
    # ⚠️ 캐시 유무는 남긴다 — 빈 캐시에 `***` 를 찍으면 「토큰이 있다」는 거짓 신호가 된다.
    def inspect
      "#<KeycloakSdk::ClientCredentialsTokenProvider config=#{@config.inspect} " \
        "cached=#{@cached ? '"***"' : 'nil'} expires_at=#{@expires_at.inspect}>"
    end
    alias to_s inspect

    def access_token
      @mutex.synchronize do
        now = Time.now.to_f
        return @cached if @cached && now < @expires_at

        ts = request_token
        # 캐시 전에 묻는다 — admin 요청마다 거부될 토큰을 만료까지 들고 있지 않는다(다음 호출은 IdP 에 다시 묻는다).
        token = BearerGrammar.sendable(ts.access_token)
        unless token
          raise AuthError, "token response has no usable access_token: it is not an RFC 6750 bearer token (b64token)"
        end

        @cached = token
        @expires_at = ts.expires_at ? (ts.expires_at - @config.clock_skew) : (now + 60)
        @cached
      end
    end

    private

    # 본문은 `Http::TOKEN_RESPONSE_MAX_BYTES` 까지만 읽는다 — 넘으면 `TransportError` 이고 admin 요청은 나가지 않는다.
    def request_token
      resp = Http.decode_json(Http.read_capped(@http, :post, @token_url,
                                               body: { grant_type: "client_credentials",
                                                       client_id: @config.client_id,
                                                       client_secret: @config.client_secret,
                                                       scope: @config.scopes.join(" ") },
                                               max_bytes: Http::TOKEN_RESPONSE_MAX_BYTES, what: "token"))
      unless resp.success?
        oauth = resp.body.is_a?(Hash) ? resp.body["error"] : nil
        raise AuthError.new("client-credentials token request failed: HTTP #{resp.status}", oauth_error: oauth)
      end

      TokenSet.from_response(resp.body, received_at: Time.now.to_f)
    rescue Error
      raise
    rescue StandardError => e # Faraday 밖 예외도 — net-http 0.10 의 응답 헤더 검증은 ArgumentError 다(어댑터 목록 밖)
      raise TransportError, "token endpoint transport error: #{RedactedCause.describe(e)}", cause: RedactedCause.new(e)
    end
  end
end
