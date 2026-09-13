# frozen_string_literal: true

module KeycloakSdk
  # OAuth 토큰 응답의 불변 값타입. access/refresh/id 토큰은 inspect에서 마스킹.
  TokenSet = Data.define(:access_token, :token_type, :expires_in, :refresh_token,
                         :id_token, :scope, :expires_at) do
    # ⚠️ **검증은 팩토리가 아니라 생성자에 있다.** `from_response` 에만 두면 `AuthClient`
    # 가 `TokenSet.new` 을 직접 부르는 경로(`auth_client.rb` 의 `to_token_set`)가 그것을
    # 통째로 우회한다 — 독립 레그가 그 구멍을 지목했다. 생성자는 어떤 경로도 지나므로
    # 여기 두면 우회가 불가능하다.
    def initialize(access_token:, **rest)
      unless access_token.is_a?(String) && !access_token.empty?
        raise AuthError, "token response has no usable access_token"
      end

      super
    end

    def self.from_response(body, received_at: Time.now.to_f)
      # ⚠️ **존재 검사는 타입 검사가 아니다.** 예전에는 값을 그대로 담아 숫자·해시·nil 이
      # `access_token` 이 됐고, 소비자는 그것을 Bearer 로 실어 보내 매번 401 을 받았다
      # (조용한 반복 실패). `expires_in` 의 문자열 허용은 **의도된 것**이라 건드리지 않는다.
      access_token = body["access_token"]
      unless access_token.is_a?(String) && !access_token.empty?
        raise AuthError, "token response has no usable access_token"
      end

      expires_in = body["expires_in"] && Integer(body["expires_in"])
      new(
        access_token: access_token,
        token_type: body["token_type"],
        expires_in: expires_in,
        refresh_token: body["refresh_token"],
        id_token: body["id_token"],
        scope: body["scope"],
        expires_at: expires_in ? received_at + expires_in : nil
      )
    end

    # ⚠️ **만료 시각을 모르면 "만료됨"이다**(fail-safe — 자매 여덟과 동형, Java 의 M.6).
    # `false`(=아직 살아있다)를 돌려주면 만료 시각 미상인 토큰이 **영원히 유효**해진다.
    # `expires_at` 이 nil 인 경우는 서버가 `expires_in` 을 안 보냈을 때뿐이라 정상 경로가
    # 아니고, 그때 취할 안전한 쪽은 "재발급"이다.
    def expired?(skew: 0, now: Time.now.to_f)
      return true if expires_at.nil?

      now >= (expires_at - skew)
    end

    def inspect
      "#<KeycloakSdk::TokenSet access_token=\"***\" token_type=#{token_type.inspect} " \
        "expires_in=#{expires_in.inspect} refresh_token=#{refresh_token ? '"***"' : 'nil'} " \
        "id_token=#{id_token ? '"***"' : 'nil'} scope=#{scope.inspect} expires_at=#{expires_at.inspect}>"
    end
    alias_method :to_s, :inspect

    # ⚠️ `pp`/`pretty_inspect` 는 `inspect` 와 같은 계급의 **표시 경로**인데, `Data` 타입은 PP 가
    # 멤버를 직접 찍어 위 `inspect` 를 **건너뛴다**(실측: access_token 원문이 나왔다). 일반
    # 클래스인 `Config` 는 PP 가 `inspect` 로 폴백해 안전하다 — 그래서 `Data` 만 이 훅이 필요하다.
    def pretty_print(pp)
      pp.text(inspect)
    end
  end

  # 검증된 access token의 관심 클레임.
  ValidatedToken = Data.define(:subject, :audience, :issuer, :expires_at, :issued_at, :claims)

  # RFC 7662 introspection 결과.
  IntrospectionResult = Data.define(:active, :username, :client_id, :claims) do
    def self.from_response(body)
      new(active: body["active"] == true, username: body["username"],
          client_id: body["client_id"], claims: body)
    end

    def active?
      active == true
    end
  end

  # authorization-code 흐름 시작 값(PKCE code_verifier 포함·inspect 마스킹).
  # nonce는 인가 URL에 실리는 재생 방지 값이라 비밀이 아니다(state와 동급 — code_verifier만 마스킹).
  AuthorizationRequest = Data.define(:url, :state, :code_verifier, :nonce) do
    def inspect
      "#<KeycloakSdk::AuthorizationRequest url=#{url.inspect} state=#{state.inspect} " \
        "nonce=#{nonce.inspect} code_verifier=\"***\">"
    end
    alias_method :to_s, :inspect

    # ⚠️ `pp`/`pretty_inspect` 는 `inspect` 와 같은 계급의 **표시 경로**인데, `Data` 타입은 PP 가
    # 멤버를 직접 찍어 위 `inspect` 를 **건너뛴다**(실측: access_token 원문이 나왔다). 일반
    # 클래스인 `Config` 는 PP 가 `inspect` 로 폴백해 안전하다 — 그래서 `Data` 만 이 훅이 필요하다.
    def pretty_print(pp)
      pp.text(inspect)
    end
  end
end
