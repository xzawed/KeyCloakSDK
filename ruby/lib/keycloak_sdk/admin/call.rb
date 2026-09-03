# frozen_string_literal: true

require "erb"

module KeycloakSdk
  module Admin
    # 리소스 공용: 요청 실행 + 오류 경계 변환 + Location 헤더 id 추출 + 경로 세그먼트 이스케이프.
    module Call
      private

      # 경로 세그먼트 하나를 이스케이프한다. **모든 admin 리소스가 이것을 거쳐야 한다.**
      #
      # 날 문자열 보간은 두 가지를 깬다:
      #  (1) "../" 를 담은 값이 경로를 재작성한다 — Faraday 가 base_url 기준으로 정규화하므로
      #      `users/../../../foo` 가 `/admin/foo` 로 접히고, 서비스 계정 베어러를 실은 채
      #      의도하지 않은 엔드포인트로 간다.
      #  (2) Keycloak 이 허용하는 **공백 든 role/group 이름**이 `URI::InvalidURIError` 를 올린다.
      #      그것은 `Faraday::Error` 가 아니라 stdlib 예외라 `request` 의 rescue 를 통과해
      #      §4「하위 오류는 경계에서 SDK 타입으로 변환된다」까지 함께 깬다.
      #
      # `ERB::Util.url_encode` 는 unreserved(A-Za-z0-9\-_.~) 밖을 전부 퍼센트 인코딩하고
      # 공백을 `+` 가 아니라 `%20` 으로 낸다 — 경로 세그먼트에 맞는 유일한 stdlib 선택지다
      # (`CGI.escape` 는 공백을 `+` 로 내므로 경로에서 틀린다). Go 의 `url.PathEscape` 와
      # 같은 자리를 채우며, 그 참조 구현이 `go/admin_realms.go` 에 있다.
      def esc(segment)
        ERB::Util.url_encode(segment.to_s)
      end

      def request
        resp = yield
        return resp if resp.success?

        raise AdminError.from_status(resp.status, "admin request failed: HTTP #{resp.status}")
      rescue Faraday::Error => e
        raise TransportError, "admin transport error: #{e.message}"
      end

      def id_from_location(resp)
        loc = resp.headers["location"]
        loc&.split("/")&.last
      end
    end
  end
end
