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
        token = sendable!(bearer_text(@token_provider.access_token))
        env.request_headers["Authorization"] = "Bearer #{token}"
      end

      private

      # ⚠️ **검사는 헤더에 실릴 글에 건다 — String 이 아닌 값도.** 덕 계약은 String 이지만 주입한 provider 는 무엇이든
      # 돌려줄 수 있고 헤더에 실리던 것은 그 값의 글이다 — String 일 때만 검사하던 때 CR 든 Symbol 은 `raw` 에서 Bearer 를
      # 통째로 인용한 raw ArgumentError 였다(실측). String 이 아니라고 거부하지 않는다(검사를 지나는 Symbol·숫자는 예전
      # 글 그대로 나간다). 글로는 **한 번만** 바꿔 검사한 글을 보낸다. `to_s` 가 아니라 보간인 것은 예전 헤더와 같은
      # 바이트라서다 — `to_s` 가 String 이 아닌 것을 돌려주면 보간은 그것을 `#<Class:0x…>` 로 바꾸고, 그 글은 문법이 거부한다.
      def bearer_text(token)
        token.is_a?(String) ? token : "#{token}" # rubocop:disable Style/RedundantInterpolation
      end

      # ⚠️ **보내기 전에 bearer 문법(`BearerGrammar` — token_provider.rb)으로 다듬거나 SDK 오류로 거부한다.** 다듬은 값을
      # 돌려준다. 거부는 넷을 한 번에 막는다 — net-http 의 raw 예외(CR·LF 면 헤더 값을 **통째로 인용한** ArgumentError, 잘못된
      # UTF-8 이면 `strip` 의 Encoding::CompatibilityError — admin 경계를 지나 샜다), 그 `strip`(0.9.1 header.rb:195)이 끝의
      # NUL·VT·FF 를 말없이 지워 보낸 다른 토큰, 「Authorization: Bearer」로 나간 빈 토큰(nil 의 글도 ""), 헤더 값에는 올 수
      # 있지만 bearer 가 아닌 것(가운데 공백·탭 · ASCII 밖 — 예전에는 그대로 보냈다). 메시지에는 토큰을 싣지 않는다(길이만).
      def sendable!(text)
        token = BearerGrammar.sendable(text)
        unless token
          raise AuthError, "admin request not sent: the access token is not an RFC 6750 bearer token (b64token)"
        end

        fits_field!(token)
        token
      end

      def fits_field!(token)
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
