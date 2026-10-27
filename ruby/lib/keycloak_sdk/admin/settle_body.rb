# frozen_string_literal: true

require "faraday"

module KeycloakSdk
  module Admin
    # admin 응답의 본문을 얼마나 읽는가 — 등록부 admin-response-body-unbounded. 요청 하나의 전송 동안 `Http` 의 net-http
    # 훅에 알린다: 300 이상의 본문은 상한에서 자르고(`raw` 커넥션의 요청도), 파사드 쓰기의 2xx 본문은 읽지 않는다.
    #
    # 쓰기는 응답 모양이 아니라 **요청에 단 표시**로 고른다 — `raw` 로 보낸 쓰기는 본문을 받아야 하고, 표시가 요청 옵션에
    # 있으니 다른 요청(토큰 공급자가 보내는 것 포함)에는 닿지 않는다. `BearerAuth` 뒤·어댑터 바로 앞에 선다.
    class SettleBody < Faraday::Middleware
      UNREAD = :kcsdk_unread

      # 파사드 쓰기가 요청에 다는 표시(`@conn.post(path, body, &MARK)`).
      MARK = ->(req) { req.options.context = (req.options.context || {}).merge(UNREAD => true) }

      # 흘려 받는 요청(`on_data` — `raw` 호출자만 쓴다)은 정하지 않는다: 본문은 오는 대로 호출자에게 가고 Faraday 는 쥐지
      # 않는다. 정하면 어댑터가 읽은 응답을 다시 읽어 IOError(read_body called twice)였다.
      def call(env)
        return @app.call(env) if env.stream_response?

        context = env.request.context
        Http.settling(context.is_a?(Hash) && context[UNREAD] == true) { @app.call(env) }
      end
    end
    private_constant :SettleBody
  end
end
