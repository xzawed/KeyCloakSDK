# frozen_string_literal: true

require "erb"

module KeycloakSdk
  module Admin
    # Shared by the resources: request execution + error conversion at the boundary + id extraction from the
    # Location header + path segment escaping.
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
      rescue Error
        raise
      rescue StandardError => e
        UnencodableBody.refuse!(e) # 쓰기 본문을 JSON 이 못 쓴다 — 요청 전이다(errors.rb)
        # 원본을 달면 `Faraday::ParsingError#inspect` 가 요청의 베어러 토큰을, 메시지가 응답 앞부분을 찍는다(실측).
        # Faraday 밖 예외도 감싼다 — net-http 0.10 의 응답 헤더 검증 ArgumentError 는 헤더 이름을 인용한다.
        status = unparsable_error_status(e)
        if status
          raise AdminError.from_status(status, "admin request failed: HTTP #{status}"), cause: RedactedCause.new(e)
        end

        raise TransportError, "admin transport error: #{RedactedCause.describe(e)}", cause: RedactedCause.new(e)
      end

      # 커넥션의 json 미들웨어는 상태 검사보다 먼저 해석한다 — JSON 이라면서 JSON 이 아닌 **오류** 본문(404·409·403 …)이어도
      # 상태가 클래스를 정한다(.NET 과 같다). 2xx 의 해석 실패는 전송 오류 그대로다(nil).
      # ⚠️ `Faraday::Error#response_status` 를 쓰지 않는다 — faraday 2.0.0 은 응답 객체에 `[:status]` 를 묻고, 그것은
      # `headers[:status]` 로 위임돼 nil 이다. 응답 객체면 `status`, 해시면 `[:status]` 를 읽는다.
      def unparsable_error_status(err)
        return unless err.is_a?(Faraday::ParsingError)

        resp = err.response
        status = resp.respond_to?(:status) ? resp.status : (resp[:status] if resp.is_a?(Hash))
        status if status.is_a?(Integer) && !(200..299).cover?(status)
      end

      # 생성된 리소스의 id — 등록부 admin-create-relative-location 의 규칙(아홉 SDK 가 같다). `Location` 값(앞뒤 SP · HTAB 를
      # 뗀)을 요청 URL 에 대해 풀고(RFC 9110 §10.2.2 — 상대 값도), 풀린 경로(디코딩하지 않고 · 끝 `/` 하나는 무시)의 마지막 조각이
      # id 다 — 그 앞 조각은 보낸 컬렉션이어야 한다. 쿼리 · 조각은 id 가 아니다. 없거나 비었거나 풀리지 않는 값, 그 컬렉션의 id 를
      # 이름하지 않는 경로(다른 컬렉션의 id 도)는 nil(id 없음).
      def id_from_location(resp)
        value = resp.headers["location"].to_s
        # 앞뒤 SP · HTAB 를 뗀다 — 앞에서 · 뒤에서 처음 만나는 다른 글자로(선형). `[ \t]+\z` 정규식은 긴 안쪽 공백 줄에서 되짚는다.
        first = value.index(/[^ \t]/)
        return unless first

        sent_to = resp.env.url
        collection, id = last_segments(sent_to.merge(value[first..value.rindex(/[^ \t]/)]).path)
        id if !id.empty? && collection == last_segments(sent_to.path).last
      rescue URI::Error
        nil
      end

      # URL 경로의 마지막 두 조각(끝 `/` 하나는 무시) — 조각이 하나뿐이면 앞의 것은 nil.
      def last_segments(path)
        segments = path.to_s.delete_suffix("/").split("/", -1)
        [segments[-2], segments.last.to_s]
      end

      # 이름으로 주소를 잡는 create(roles) 의 답 — 서버가 매기는 id 가 없어 위 규칙 밖이고 예전 그대로다(등록부
      # admin-create-relative-location): `Location` 원문의 마지막 `/` 조각. `Location` 은 이름으로 끝나서, `/` 를 품은
      # 이름 `a/b` 의 `…/roles/a/b` 에 컬렉션 검사를 걸면 서버가 만든 뒤 nil 이 된다.
      def name_from_location(resp)
        loc = resp.headers["location"]
        loc&.split("/")&.last
      end
    end
  end
end
