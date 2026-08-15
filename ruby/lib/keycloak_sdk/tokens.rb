# frozen_string_literal: true

module KeycloakSdk
  # OAuth 토큰 응답의 불변 값타입. access/refresh/id 토큰은 inspect에서 마스킹.
  TokenSet = Data.define(:access_token, :token_type, :expires_in, :refresh_token,
                         :id_token, :scope, :expires_at) do
    def self.from_response(body, received_at: Time.now.to_f)
      expires_in = body["expires_in"] && Integer(body["expires_in"])
      new(
        access_token: body["access_token"],
        token_type: body["token_type"],
        expires_in: expires_in,
        refresh_token: body["refresh_token"],
        id_token: body["id_token"],
        scope: body["scope"],
        expires_at: expires_in ? received_at + expires_in : nil
      )
    end

    def expired?(skew: 0, now: Time.now.to_f)
      return false if expires_at.nil?

      now >= (expires_at - skew)
    end

    def inspect
      "#<KeycloakSdk::TokenSet access_token=\"***\" token_type=#{token_type.inspect} " \
        "expires_in=#{expires_in.inspect} refresh_token=#{refresh_token ? '"***"' : 'nil'} " \
        "id_token=#{id_token ? '"***"' : 'nil'} scope=#{scope.inspect} expires_at=#{expires_at.inspect}>"
    end
    alias_method :to_s, :inspect
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
  end
end
