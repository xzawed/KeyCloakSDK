# frozen_string_literal: true

module KeycloakSdk
  # Immutable value type of an OAuth token response. The access/refresh/id tokens are masked in inspect.
  TokenSet = Data.define(:access_token, :token_type, :expires_in, :refresh_token,
                         :id_token, :scope, :expires_at) do
    # ⚠️ **The validation lives in the constructor, not the factory.** Put only in `from_response`, it would be
    # bypassed entirely by the path where `AuthClient` calls `TokenSet.new` directly (`to_token_set` in
    # `auth_client.rb`) — an independent leg pointed out that hole. Every path goes through the constructor, so
    # placing it here makes a bypass impossible.
    def initialize(access_token:, **rest)
      unless access_token.is_a?(String) && !access_token.empty?
        raise AuthError, "token response has no usable access_token"
      end

      super
    end

    def self.from_response(body, received_at: Time.now.to_f)
      # An array body broke through the boundary as a TypeError from `Array#[]` — a body that is not an object is
      # an SDK error.
      raise AuthError, "token response is not a JSON object" unless body.is_a?(Hash)

      # ⚠️ **A presence check is not a type check.** The value used to be stored as is, so a number, a hash or nil
      # became the `access_token`, and the consumer sent it as the Bearer and got a 401 every time
      # (a silent, repeated failure). Accepting a string `expires_in` is **intended**, so it is left alone.
      access_token = body["access_token"]
      unless access_token.is_a?(String) && !access_token.empty?
        raise AuthError, "token response has no usable access_token"
      end

      expires_in = begin
        body["expires_in"] && Integer(body["expires_in"])
      rescue ArgumentError, TypeError, RangeError # RangeError: JSON 1e400 = Infinity → FloatDomainError
        # `cause: nil` — ArgumentError quotes the value (`invalid value for Integer(): "…"`).
        raise AuthError, "token response has an unusable expires_in", cause: nil
      end
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

    # ⚠️ **An unknown expiry time means "expired"** (fail-safe — isomorphic with the eight siblings, Java's M.6).
    # Returning `false` (= still alive) would make a token whose expiry time is unknown **valid forever**.
    # `expires_at` is nil only when the server did not send `expires_in`, so it is not the normal path, and the
    # safe side to take then is "reissue".
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

    # ⚠️ `pp`/`pretty_inspect` is a **display path** of the same rank as `inspect`, but for a `Data` type PP prints
    # the members directly and **skips** the `inspect` above (measured: the raw access_token came out). For `Config`,
    # an ordinary class, PP falls back to `inspect`, so it is safe — that is why only `Data` needs this hook.
    def pretty_print(pp)
      pp.text(inspect)
    end
  end

  # The claims of interest of a validated access token.
  ValidatedToken = Data.define(:subject, :audience, :issuer, :expires_at, :issued_at, :claims)

  # RFC 7662 introspection result.
  IntrospectionResult = Data.define(:active, :username, :client_id, :claims) do
    # A body that is not an object is an SDK error — an array broke through the boundary as a TypeError, and a string
    # became a result whose `claims` was a string.
    def self.from_response(body)
      raise AuthError, "introspection response is not a JSON object" unless body.is_a?(Hash)

      new(active: body["active"] == true, username: body["username"],
          client_id: body["client_id"], claims: body)
    end

    def active?
      active == true
    end
  end

  # The values that start an authorization-code flow (PKCE code_verifier included · masked in inspect).
  # The nonce is a replay-protection value carried in the authorization URL, so it is not a secret (on a par with
  # state — only code_verifier is masked).
  AuthorizationRequest = Data.define(:url, :state, :code_verifier, :nonce) do
    def inspect
      "#<KeycloakSdk::AuthorizationRequest url=#{url.inspect} state=#{state.inspect} " \
        "nonce=#{nonce.inspect} code_verifier=\"***\">"
    end
    alias_method :to_s, :inspect

    # ⚠️ `pp`/`pretty_inspect` is a **display path** of the same rank as `inspect`, but for a `Data` type PP prints
    # the members directly and **skips** the `inspect` above (measured: the raw access_token came out). For `Config`,
    # an ordinary class, PP falls back to `inspect`, so it is safe — that is why only `Data` needs this hook.
    def pretty_print(pp)
      pp.text(inspect)
    end
  end
end
