# frozen_string_literal: true

module KeycloakSdk
  module Admin
    # 리소스 공용: 요청 실행 + 오류 경계 변환 + Location 헤더 id 추출.
    module Call
      private

      def request
        resp = yield
        return resp if resp.success?

        raise AdminError.from_status(resp.status, "admin request failed: HTTP #{resp.status}")
      rescue Faraday::TimeoutError, Faraday::ConnectionFailed => e
        raise TransportError, "admin transport error: #{e.message}"
      end

      def id_from_location(resp)
        loc = resp.headers["location"] || resp.headers["Location"]
        loc&.split("/")&.last
      end
    end
  end
end
