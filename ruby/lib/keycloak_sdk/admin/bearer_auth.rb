# frozen_string_literal: true

require "faraday"
require "net/http"

module KeycloakSdk
  module Admin
    # 매 요청마다 TokenProvider에서 bearer 토큰을 소싱해 Authorization 헤더를 설정한다.
    class BearerAuth < Faraday::Middleware
      def initialize(app, token_provider)
        super(app)
        @token_provider = token_provider
      end

      def on_request(env)
        token = @token_provider.access_token
        sendable!(token) if token.is_a?(String)
        env.request_headers["Authorization"] = "Bearer #{token}"
      end

      private

      # ⚠️ **net-http 가 헤더에 실을 수 없는 Bearer 는 보내기 전에 SDK 오류로 거부한다.** net-http 는 요청 헤더를 만들
      # 때(`initialize_http_header`) CR·LF 면 헤더 값을 **통째로 인용한** raw ArgumentError(= Bearer 누출)를,
      # `MAX_FIELD_LENGTH`(65,536)를 넘으면 raw ArgumentError 를, 잘못된 UTF-8 이면 `strip` 의 raw
      # Encoding::CompatibilityError 를 낸다 — 셋 다 admin 경계(`rescue Faraday::Error`)를 지나 샜다(실측).
      # ⚠️ **같은 `value.strip`(0.9.1 header.rb:195)이 끝의 NUL·공백·탭·VT·FF 를 말없이 지운다** — 다른 토큰이 나갔다.
      # 앞의 공백·탭은 그대로 나가지만 받는 쪽이 `Bearer` 뒤 공백으로 접고(RFC 9110 §11.4 `1*SP`), NUL·그 밖의 C0·DEL 은
      # 어디 있든 그대로 나가지만 헤더 값에 올 수 없다(§5.5 — field-vchar·SP·HTAB 뿐). 셋 다 같은 거부다(실측 · 시험).
      # ⚠️ 고쳐 쓰지 않는다(잘라내거나 바꿔 보내면 다른 토큰이다). 헤더 값에 올 수 있는 것(가운데 공백·탭 · U+00FF
      # 위 문자)은 그대로 보내고 판정은 서버에 맡긴다. 메시지에는 토큰을 싣지 않는다(길이만).
      def sendable!(token)
        raise AuthError, "admin request not sent: the access token is not valid UTF-8" unless token.valid_encoding?

        if token.match?(/[\r\n]/)
          raise AuthError, "admin request not sent: the access token holds CR or LF, which an HTTP header cannot carry"
        end
        if token.match?(/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/)
          raise AuthError, "admin request not sent: the access token holds NUL, DEL or another control character, " \
                           "which an HTTP header cannot carry"
        end
        if token.match?(/\A[ \t]|[ \t]\z/)
          raise AuthError, "admin request not sent: the access token starts or ends with a space or tab, which an " \
                           "HTTP header cannot carry"
        end

        limit = field_limit
        return if limit.nil? || "Bearer ".bytesize + token.bytesize <= limit

        raise AuthError, "admin request not sent: the access token (#{token.bytesize} bytes) does not fit an " \
                         "HTTP header field (#{limit} bytes with \"Bearer \")"
      end

      # 이 SDK 의 어댑터는 net-http 로 고정돼 있다(`Http.build`). 그 상한이 없는 net-http 판은 길이로 막지 않는다.
      def field_limit
        Net::HTTPHeader::MAX_FIELD_LENGTH if defined?(Net::HTTPHeader::MAX_FIELD_LENGTH)
      end
    end
  end
end
