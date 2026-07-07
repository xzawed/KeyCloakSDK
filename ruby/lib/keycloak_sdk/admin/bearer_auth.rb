# frozen_string_literal: true

require "faraday"

module KeycloakSdk
  module Admin
    # 매 요청마다 TokenProvider에서 bearer 토큰을 소싱해 Authorization 헤더를 설정한다.
    class BearerAuth < Faraday::Middleware
      def initialize(app, token_provider)
        super(app)
        @token_provider = token_provider
      end

      def on_request(env)
        env.request_headers["Authorization"] = "Bearer #{@token_provider.access_token}"
      end
    end
  end
end
