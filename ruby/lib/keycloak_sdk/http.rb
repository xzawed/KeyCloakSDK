# frozen_string_literal: true

require "faraday"

module KeycloakSdk
  # 공유 Faraday 커넥션 팩토리. 타임아웃을 config에서 주입하고,
  # follow_redirects 미들웨어를 절대 장착하지 않는다(SSRF 하드닝 — Faraday는 기본 미추종).
  # 상한을 건 본문 읽기(`read_capped`)도 여기 있다 — 토큰·introspection·JWKS 레인이 같은 기제를 쓴다.
  module Http
    # 토큰 엔드포인트(세 그랜트 · admin 레인의 자기 토큰)와 introspection 응답 본문의 상한(바이트).
    # 1 MiB 는 Keycloak 26.6 이 기본 설정으로 받는 가장 긴 Bearer(65,459 바이트 — 하나 더 길면 HTTP 431)의
    # 16 배라 서버가 받는 토큰은 거부하지 않고, 끝없는 본문은 여기서 멈춘다.
    # ⚠️ JWKS 의 51,200 을 빌려 쓰지 말 것 — 서비스 계정 토큰은 관리하는 realm 수만큼 자란다.
    # ⚠️ 맨 십진 리터럴이어야 한다 — 아홉 SDK 가 같은 값을 쓰고 교차언어 가드가 이 줄을 읽는다.
    TOKEN_RESPONSE_MAX_BYTES = 1_048_576

    # ⚠️ **SDK 가 직접 읽는 요청은 인코딩 없는 본문을 청한다.** Accept-Encoding 이 없으면 net-http 가 gzip 을 청하고
    # 스스로 푸는데, 그 inflater 는 상한에서 읽기를 끊어도 ensure 에서 `Inflater#finish` 로 **지금 읽은 압축 조각을
    # 끝까지** 푼다 — 16 KiB 조각 하나가 공백이면 ~16 MiB 다(실측: JWKS 상한이 지켜진 채 피크 +24 MB).
    # 요청에 이 헤더가 있으면 net-http 는 자기 것을 붙이지 않고 풀지도 않는다. 그래도 gzip 을 보내는 서버는
    # 압축된 바이트가 그대로 와 JSON 으로 읽히지 않으므로 SDK 오류로 닫힌다.
    IDENTITY = { "Accept-Encoding" => "identity" }.freeze

    # Faraday 의 JSON 응답 규칙 그대로(JSON 콘텐츠 타입만 · 빈 본문은 nil · 해석 실패는 Faraday::ParsingError).
    # 스트리밍으로 읽은 본문은 커넥션의 json 미들웨어가 보지 못하므로(그때 본문은 비어 있다) 여기서 같은 규칙을 건다.
    JSON_RESPONSE = Faraday::Response::Json.new(nil, content_type: /\bjson$/)
    private_constant :IDENTITY, :JSON_RESPONSE

    module_function

    def build(config, base_url: nil)
      Faraday.new(
        url: base_url,
        request: { timeout: config.read_timeout, open_timeout: config.connect_timeout }
      ) do |f|
        yield f if block_given?
        f.adapter :net_http
      end
    end

    # 요청 하나를 보내고 본문을 `max_bytes` 까지만 읽는다 — **상태와 무관하게**(오류 응답의 거대 본문도 같다).
    # 돌려주는 응답의 `body` 는 읽은 바이트(BINARY 문자열)다. 넘으면 그 즉시 `TransportError` 이고 연결은 닫힌다.
    #
    # ⚠️ 판정은 청크를 **붙이기 전에** 한다 — 버퍼는 상한을 넘지 않고, 넘는 청크는 복사하지 않는다. 읽는 크기는
    # SDK 가 정하지 못한다: net-http 가 소켓에서 16 KiB(`Net::BufferedIO::BUFSIZE`)씩 읽어 넘기므로 판정 순간
    # 손에 든 것은 많아야 상한 + 청크 하나(16,384 바이트)다. 버퍼는 읽은 만큼만 자란다(미리 상한만큼 잡지 않는다).
    # ⚠️ `Content-Length` 만 보면 그 헤더가 없거나 거짓인 응답을 놓친다 — 누적치로 판정한다.
    def read_capped(conn, method, url, max_bytes:, what:, body: nil, headers: {})
      buf = String.new(encoding: Encoding::BINARY)
      resp = conn.run_request(method, url, body, IDENTITY.merge(headers)) do |req|
        req.options.on_data = proc do |chunk, _received|
          over = buf.bytesize + chunk.bytesize > max_bytes
          raise TransportError, "#{what} response exceeds #{max_bytes} bytes" if over

          buf << chunk
        end
      end
      resp.env.body = buf
      resp
    end

    # `read_capped` 의 본문을 커넥션의 json 미들웨어가 하던 그대로 해석한다(응답을 돌려준다).
    def decode_json(resp)
      JSON_RESPONSE.on_complete(resp.env)
      resp
    end
  end
end
