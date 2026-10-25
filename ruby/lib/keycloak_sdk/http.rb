# frozen_string_literal: true

require "faraday"
require "faraday/net_http"
require "json"

module KeycloakSdk
  # 공유 Faraday 커넥션 팩토리. 타임아웃을 config에서 주입하고,
  # follow_redirects 미들웨어를 절대 장착하지 않는다(SSRF 하드닝 — Faraday는 기본 미추종).
  # 상한을 건 본문 읽기(`read_capped`)도 여기 있다 — 토큰·introspection·logout·JWKS 레인이 같은 기제를 쓴다.
  module Http
    # ⚠️ **응답 **틀**(상태 줄·헤더 줄·청크 크기/확장 줄·트레일러)의 상한.** `read_capped` 의 1 MiB 는 `on_data` 로 오는
    # **본문 바이트**만 본다 — net-http(net-protocol 의 `BufferedIO`)는 그 앞뒤로 틀을 한도 없이 읽는다(헤더·트레일러는
    # `readuntil("\n")`, 청크 크기/확장 줄도 `readline`). 그래서 16 MiB 헤더 한 줄·청크 확장·트레일러가 상한 밖이었다
    # (response-framing-unbounded · 2026-10-09 실측 · auth·admin 같다). 다른 여덟 언어는 전부 틀을 묶는다(.NET 64 KiB ·
    # Go 64 KiB · Java 8,192/100 · undici · h11 · hyper).
    #
    # ⚠️ **두 상한은 함께 움직인다.** `MAX_FRAMING_LINE_BYTES` 는 한 **줄**(F1·F2·F3b — 거대한 줄 하나)을, `MAX_FRAMING_BYTES`
    # 는 한 **응답의 틀 전체**(F3a — 작은 줄 다수)를 묶는다. 둘 중 하나만 두면 다른 공격이 지나간다(변이 증명 M1·M2).
    # ⚠️ **틀 예산은 본문 중에 읽히는 청크 크기 줄도 센다** — 그래서 큰 본문을 수십 바이트 청크로 잘게 쪼갠 응답은
    # 거부된다. Keycloak·주류 리버스 프록시는 KiB 단위로 청크하므로(nginx proxy_buffer 4–8 KiB) 현실 트래픽은 통과한다
    # (control: `response_framing_cap_spec` 의 「realistically chunked multi-chunk body」). admin 레인은 본문 상한이 없어
    # 이 예산이 **순수 안전 추가**다(잘게 쪼갠 무한 청크 틀을 여기서 끊는다).
    #   · 8,192 = Java MessageConstraints 줄 한도. Keycloak 26.6 의 가장 긴 응답 틀 줄 85 B(Go 실측)의 ×96.
    #   · 65,536 = .NET 헤더+트레일러 한도 · Go 머리 블록 한도. Keycloak 머리 블록 ≤339 B · 브라우저 로그인 최대 3,018 B
    #     (둘 다 Go 실측) — SDK 가 받는 것의 ×19 이상이라 기본 서버가 어떤 프록시를 거쳐 보내도 거부하지 않는다.
    # ⚠️ 맨 십진 리터럴 — 교차언어 가드가 이 줄을 읽을 수 있어야 한다(`TOKEN_RESPONSE_MAX_BYTES` 와 같은 관용).
    MAX_FRAMING_LINE_BYTES = 8_192
    MAX_FRAMING_BYTES = 65_536
    # ⚠️ 메시지에 바이트를 싣지 않는다(상수 문자열) — 다른 경계와 같은 규율(§4 · `RedactedCause`).
    FRAMING_LINE_MSG = "HTTP response framing line exceeds #{MAX_FRAMING_LINE_BYTES} bytes".freeze
    FRAMING_TOTAL_MSG = "HTTP response framing exceeds #{MAX_FRAMING_BYTES} bytes".freeze
    # ⚠️ 공개 API 가 아니다 — 교차언어 내부 값이다(Go 의 responseHeaderMaxBytes 도 비노출). 시험은 const_get 으로 본다.
    private_constant :MAX_FRAMING_LINE_BYTES, :MAX_FRAMING_BYTES, :FRAMING_LINE_MSG, :FRAMING_TOTAL_MSG
    # 토큰 엔드포인트(세 그랜트 · admin 레인의 자기 토큰)·introspection·logout 응답 본문의 상한(바이트).
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

    # admin 응답의 본문을 얼마나 읽는가(admin-response-body-unbounded) — admin 커넥션의 `Admin::SettleBody` 가 요청 하나의
    # 전송 동안만 거는 파이버 지역 값이다. 300 이상의 본문은 `TOKEN_RESPONSE_MAX_BYTES` 에서 자르고, 파사드
    # 쓰기(요청 옵션의 표시)의 2xx 본문은 읽지 않는다 — 둘 다 net-http 가 머리를 읽은 뒤·본문을 읽기 전에 정한다
    # (`BoundedTransport#request`). 그 밖의 성공 본문은 지금처럼 끝까지 읽는다.
    SETTLE = :kcsdk_admin_settle

    # Faraday 의 JSON 응답 규칙 그대로(JSON 콘텐츠 타입만 · 빈 본문은 nil · 해석 실패는 Faraday::ParsingError).
    # 스트리밍으로 읽은 본문은 커넥션의 json 미들웨어가 보지 못하므로(그때 본문은 비어 있다) 여기서 같은 규칙을 건다.
    JSON_RESPONSE = Faraday::Response::Json.new(nil, content_type: /\bjson$/)
    UNDECODABLE = "JSON text decodes to invalid UTF-8"
    private_constant :IDENTITY, :SETTLE, :JSON_RESPONSE, :UNDECODABLE

    # 소켓 하나에 거는 **싱글턴 확장** — 전역 몽키패치가 아니라 이 SDK 가 연 `BufferedIO` 인스턴스 하나에만 붙는다
    # (`BoundedHttp#on_connect`). 호스트 애플리케이션의 net-http 는 건드리지 않는다.
    #
    # 틀 줄은 전부 `readuntil`/`readline` 로 읽힌다(상태 줄·헤더 줄·청크 크기/확장 줄·트레일러 — `readline` 은
    # `readuntil("\n").chop`). `readuntil` 은 net-protocol 원판과 **같은 버퍼 주사**를 하되(종단 문자를 `@rbuf` 에서 찾고,
    # 못 찾을 때만 `rbuf_fill` 로 소켓에서 16 KiB 를 더 받는다), 채우기 **전에** 두 상한을 건다: 쌓인 부분 줄이
    # `MAX_FRAMING_LINE_BYTES` 를 넘으면(F1·F2·F3b — 거대한 줄 하나) 그 자리에서, 한 응답의 틀 누적이
    # `MAX_FRAMING_BYTES` 를 넘으면(F3a — 작은 줄 다수) 거부한다. 원판이 종단 문자를 찾을 때까지 16 MiB 를 통째로
    # 담은 **뒤** 돌려주던 것을, 채우기 루프 안에서 끊는다.
    #
    # ⚠️ **net-protocol `BufferedIO` 내부(`@rbuf`·`@rbuf_offset`·private `rbuf_fill`·`rbuf_consume`)에 기댄다.**
    # 한 바이트씩 읽는 `read(1)` 은 F3a 의 64 KiB 를 쌓느라 할당을 10 MB 넘게 튀겼다(실측) — 버퍼 주사는 그 churn 이 없다.
    # 이 내부가 바뀌면 조용히 깨지므로 `http_framing_pins_spec` 이 그 모양(ivar·메서드·`readuntil`/`readline` 호출 경로)을
    # 핀으로 고정해 **시끄럽게** 실패시킨다. 그 내부는 net-protocol 0.2.1(루비 3.2 하한)·0.2.2·0.3.0·0.4.0 에서 같고,
    # 0.3.0 이 `readuntil` 에 `limit:` 키워드를 더했다 — net-http 0.10 은 모든 틀 줄을 그것으로 읽는다(아래).
    # ⚠️ 거부는 `TransportError`(상수 메시지) — net-http 가 인식하지 않는 타입이라 그 **바깥** rescue 가 소켓을 닫고
    # 다시 던진다(비우지 않는다 · idempotent 재시도 목록에 없어 재시도도 안 된다). Faraday 어댑터의
    # `NET_HTTP_EXCEPTIONS` 에도 없어 공개 경계까지 `TransportError` 로 그대로 올라간다.
    module BoundedReads
      def kcsdk_reset_framing!
        @kcsdk_framing_total = 0
      end

      # ⚠️ 시그니처는 net-protocol 원판(0.3.0+)과 같아야 한다 — net-http 0.9.x 이하는 `sock.readuntil("\n", true)` 로
      # 위치 인자로, 0.10 은 `sock.readuntil("\n", ignore_eof, limit: 1 MiB)` 로 키워드를 붙여 부른다. 키워드를 못 받으면
      # SDK 의 HTTP 호출이 전부 ArgumentError 다(net-protocol 0.4.0 실측). 그래서 `ignore_eof` 를 키워드로 바꾸지 않는다
      # (Style/OptionalBooleanParameter 를 그 이유로 끈다).
      # `limit:` 은 원판의 뜻 그대로다 — 같은 검증(ArgumentError), 넘으면 `Net::ReadLimitExceeded` 이고 소비하지 않는다
      # (net-http 0.10 이 그것을 HTTPBadResponse 로 바꾼다). SDK 의 두 상한을 먼저 본다 — 둘 다 넘으면 SDK 오류가 이긴다.
      def readuntil(terminator, ignore_eof = false, limit: nil) # rubocop:disable Style/OptionalBooleanParameter
        kcsdk_check_limit(limit)
        @kcsdk_framing_total ||= 0
        offset = @rbuf_offset
        begin
          until (idx = @rbuf.index(terminator, offset))
            kcsdk_bound_line(@rbuf.bytesize - @rbuf_offset, limit) # 이 줄에 쌓인, 아직 소비되지 않은 바이트
            # 원판(0.3.0+)과 같은 되감기 — 두 바이트 종단 문자가 읽기 경계에 걸쳐도 찾는다(0.2.x 는 놓쳤다).
            # net-http 의 `"\n"` 에서는 `@rbuf.bytesize` 와 같다.
            offset = [@rbuf.bytesize - terminator.bytesize + 1, @rbuf_offset].max
            rbuf_fill
          end
          len = idx + terminator.bytesize - @rbuf_offset
          kcsdk_bound_line(len, limit)
          line = rbuf_consume(len)
        rescue EOFError
          raise unless ignore_eof

          line = rbuf_consume
        end
        kcsdk_charge_framing(line.bytesize)
        line
      end

      def readline
        readuntil("\n").chop
      end

      private

      # ⚠️ 이름은 전부 `kcsdk_` 로 시작한다 — 싱글턴 확장은 원판의 같은 이름 메서드를 **가린다**(원판 안의 호출까지).
      # 원판이 `limit:` 검증을 들인 판이 바로 0.3.0 이라, `check_limit` 같은 맨 이름은 언젠가 원판과 겹칠 수 있다.

      # 줄 하나(`len` 바이트 — 채우는 중이면 쌓인 몫)를 소비하기 **전에** 본다: SDK 의 두 상한, 그다음 호출자의 `limit:`.
      def kcsdk_bound_line(len, limit)
        raise KeycloakSdk::TransportError, FRAMING_LINE_MSG if len > MAX_FRAMING_LINE_BYTES
        raise KeycloakSdk::TransportError, FRAMING_TOTAL_MSG if @kcsdk_framing_total + len > MAX_FRAMING_BYTES
        raise kcsdk_limit_error, "exceeded the #{limit} byte read limit" if limit && len > limit
      end

      # ⚠️ `Net::ReadLimitExceeded` 는 net-protocol 0.3.0+ 에만 있다 — `limit:` 을 넘기는 net-http 0.10 은 그 판을 요구하지만,
      # 0.2.x 에서 누가 직접 넘기면 NameError 가 났다(Grok 적대 레그). 그때는 그 부모 `Net::ProtocolError` 다 — 둘 다
      # Faraday 어댑터가 `ConnectionFailed` 로 바꾼다. 전역 상수를 세우지 않는다(싱글턴 확장 규율).
      def kcsdk_limit_error
        defined?(Net::ReadLimitExceeded) ? Net::ReadLimitExceeded : Net::ProtocolError
      end

      # 원판과 같은 검증 — `Integer ===` 는 호출자의 값에 메서드를 부르지 않는다(원판 주석과 같은 이유).
      def kcsdk_check_limit(limit)
        return if limit.nil? || (Integer === limit && limit.positive?) # rubocop:disable Style/CaseEquality

        got = Integer === limit ? limit : "a non-Integer" # rubocop:disable Style/CaseEquality
        raise ArgumentError, "limit must be a positive Integer, got #{got}"
      end

      # 돌려줄 줄 하나를 틀 예산에 올린다 — EOF 로 끝난 부분 줄(`ignore_eof`)은 `kcsdk_bound_line` 을 지나지 않으므로 여기서
      # 두 상한을 다시 본다(원판도 그 갈래에는 `limit:` 을 걸지 않는다).
      def kcsdk_charge_framing(len)
        raise KeycloakSdk::TransportError, FRAMING_LINE_MSG if len > MAX_FRAMING_LINE_BYTES

        @kcsdk_framing_total += len
        raise KeycloakSdk::TransportError, FRAMING_TOTAL_MSG if @kcsdk_framing_total > MAX_FRAMING_BYTES
      end
    end

    # ⚠️ **프록시 CONNECT 응답의 틀 상한** — HTTPS 대상을 프록시로 부르면 net-http `connect` 는 프록시 소켓 위에 **지역**
    # `BufferedIO` 를 따로 만들어 CONNECT 응답(`HTTPResponse.read_new`)을 읽는다. `on_connect` 보다 앞이라 `BoundedReads` 가
    # 그 읽기를 못 봤다(ruby-framing-proxy-connect-unbounded — net-http 0.9.1 은 996,039 B 머리 블록도 받고 TLS 로
    # 넘어갔고, 0.10.0 은 상태 줄·블록을 1 MiB 까지 받았다 · 65,536 B 넘는 헤더 값만 다 읽은 뒤 raw ArgumentError).
    # 그 `BufferedIO` 는 잡을 자리가 없으니(전역 패치 금지) 그것이 읽는 **소켓 하나**에 건다 — `rbuf_fill` 이 부르는
    # `read_nonblock` 이 돌려준 바이트를 세어 `BoundedReads` 와 같은 두 상한(줄은 종단 문자까지 8,192 · 블록은 빈 줄까지
    # 65,536)을 넘으면 같은 상수 메시지의 `TransportError` 다(`connect` 의 rescue 가 그 소켓을 닫는다). 빈 줄(첫 줄 뒤의
    # "\r\n"·"\n" — 두 읽기에 갈려도)에서 꺼진다: 그 뒤 바이트는 손대지 않고 돌려주고(net-http 가 버린다) 그 소켓의 뒤
    # 읽기는 세지 않는다.
    # ⚠️ 빈 줄은 "\r\n"·"\n" 둘뿐이다(0.10 의 `chomp` 와 같다) — 0.9.1 처럼 공백만 있는 줄까지 끝으로 보면 그 줄 하나로
    # 상한을 끌 수 있다.
    module ConnectFraming
      # 시그니처는 상류(`IO`·`OpenSSL::Buffering`)와 같다 — `BufferedIO#rbuf_fill` 은 `read_nonblock(BUFSIZE, tmp,
      # exception: false)` 로 부르고(`http_framing_pins_spec`), 받은 버퍼를 같은 객체로 돌려받기를 기대한다.
      def read_nonblock(len, buf = nil, exception: true)
        chunk = super
        kcsdk_connect_scan(chunk) if @kcsdk_connect_armed && chunk.is_a?(String)
        chunk
      end

      def kcsdk_arm_connect_framing!
        @kcsdk_connect_armed = true
        @kcsdk_connect_total = 0  # 끝난 줄들의 바이트(종단 문자 포함)
        @kcsdk_connect_line = 0   # 지금 줄에 쌓인 바이트 — 아직 "\n" 전
        @kcsdk_connect_last = nil # 그 쌓인 바이트의 마지막 — "\r" 하나로 읽기가 끝났으면 다음 읽기의 "\n" 과 빈 줄이다
      end

      def kcsdk_connect_framing_armed?
        @kcsdk_connect_armed == true
      end

      private

      # ⚠️ 바이트 위치로 읽는다(`byteindex`·`getbyte`) — 소켓이 돌려주는 BINARY 문자열에서 위치는 늘 바이트다.
      def kcsdk_connect_scan(chunk)
        from = 0
        while @kcsdk_connect_armed && (eol = chunk.byteindex("\n", from))
          kcsdk_connect_line_end(chunk, from, eol)
          from = eol + 1
        end
        kcsdk_connect_partial(chunk, from) if @kcsdk_connect_armed && from < chunk.bytesize
      end

      # 빈 줄 = 첫 줄이 아닌 "\n"(1 바이트) 또는 "\r\n"(2 바이트) — 2 바이트 줄의 "\r" 은 "\n" 바로 앞 바이트다.
      def kcsdk_connect_line_end(chunk, from, eol)
        before = eol > from ? chunk.getbyte(eol - 1) : @kcsdk_connect_last
        len = @kcsdk_connect_line + eol + 1 - from
        kcsdk_connect_bound(len)
        blank = @kcsdk_connect_total.positive? && (len == 1 || (len == 2 && before == 13))
        @kcsdk_connect_total += len
        @kcsdk_connect_line = 0
        @kcsdk_connect_armed = false if blank
      end

      def kcsdk_connect_partial(chunk, from)
        @kcsdk_connect_line += chunk.bytesize - from
        @kcsdk_connect_last = chunk.getbyte(-1)
        kcsdk_connect_bound(@kcsdk_connect_line)
      end

      # `BoundedReads#kcsdk_bound_line` 와 같은 경계다 — 줄이든 블록이든 상한과 **같으면** 받고 넘으면 거부한다.
      def kcsdk_connect_bound(len)
        raise KeycloakSdk::TransportError, FRAMING_LINE_MSG if len > MAX_FRAMING_LINE_BYTES
        raise KeycloakSdk::TransportError, FRAMING_TOTAL_MSG if @kcsdk_connect_total + len > MAX_FRAMING_BYTES
      end
    end

    # `Net::HTTP` 인스턴스의 싱글턴에 **prepend** 해 소켓이 만들어지는 자리(`on_connect`, `connect` 끝)에서 그 소켓에만
    # `BoundedReads` 를 건다. `begin_transport` 는 요청마다 틀 예산을 0 으로 되돌린다 — keep-alive 로 연결을 재사용해도
    # 다음 응답은 새 예산을 받는다(한 요청의 1xx 중간 응답들은 같은 예산을 나눠 쓴다 — 그래야 1xx 홍수도 묶인다).
    # ⚠️ **`Net::HTTP` 를 하위 클래스로 두지 않는다.** 그 하위 클래스 인스턴스가 Faraday 스택에 남으면 공개 표면 가드의
    # 객체 걷기(`facade_dump_spec`·`hostile_path_matrix_spec`)가 그 세 시험을 끝내지 못했다(실측: 90–150 초 timeout 에
    # 죽었다 — 이 설계로 바꾼 뒤 같은 셋은 14 초). 원인은 가드 코드를 읽은 추정이다 — SDK 네임스페이스로 보고 그 상속 공개
    # 메서드(Net::HTTP 수백 개)를 불러 실 네트워크에서 기다린다. 표준 어댑터 + 인스턴스 prepend 는 그래프에 SDK 이름의
    # 어댑터·HTTP 타입을 남기지 않는다.
    module BoundedTransport
      private

      def on_connect
        super
        @socket.extend(BoundedReads)
        @socket.kcsdk_reset_framing!
      end

      def begin_transport(req)
        super
        @socket.kcsdk_reset_framing! if @socket.respond_to?(:kcsdk_reset_framing!)
      end

      # ── 프록시 CONNECT(`ConnectFraming`) — `connect` 가 소켓을 여는 두 자리. 상한은 CONNECT 응답을 나르는 소켓에만 걸고
      # 대상과의 TLS 소켓은 건드리지 않는다. ⚠️ `timeouted_connect` 는 net-http 0.9.0 에 생겼다 — gemspec 하한이다.

      # 연결마다 「이 `connect` 의 첫 `ssl_socket_connect`」를 되돌린다(keep-alive 가 끊긴 뒤 다시 열 때도 같다).
      def connect
        @kcsdk_connect_tls_pending = true
        super
      end

      # 평문 프록시 + HTTPS 대상 — net-http 는 이 TCP 소켓을 그대로 BufferedIO 로 감싸 CONNECT 응답을 읽는다.
      def timeouted_connect(conn_addr, conn_port)
        sock = super
        kcsdk_bound_connect(sock) if proxy? && use_ssl? && !@proxy_use_ssl
        sock
      end

      # TLS 프록시 + HTTPS 대상 — 이 `connect` 의 **첫** 호출이 프록시와의 TLS 소켓(CONNECT 응답을 나른다)이고, 둘째는
      # 대상과의 TLS 다. `@proxy_use_ssl` 은 `connect` 가 가르는 그 ivar 다(공개 읽기가 없다 — 모양은 핀으로 고정).
      def ssl_socket_connect(sock, timeout)
        first = @kcsdk_connect_tls_pending
        @kcsdk_connect_tls_pending = false
        result = super
        kcsdk_bound_connect(sock) if first && proxy? && use_ssl? && @proxy_use_ssl
        result
      end

      def kcsdk_bound_connect(sock)
        sock.extend(ConnectFraming)
        sock.kcsdk_arm_connect_framing!
      end

      # ── admin 응답 본문(`SETTLE`). faraday-net_http 는 `start` 블록 안에서 `request` 에 블록을 넘기고, 그 블록이 머리를
      # 저장한 뒤 net-http 의 `reading_body` 가 본문을 끝까지 읽는다 — 그 블록 앞에서 본문을 정하면 net-http 는 읽은
      # 응답(`@read`)의 소켓을 더 읽지 않는다. 정한 응답의 소켓은 닫는다(남은 바이트를 다음 요청이 읽지 않게).
      public

      def request(req, body = nil, &block)
        settle = Thread.current[SETTLE]
        return super unless settle && started?

        super do |res|
          kcsdk_settle(res, settle[:unread])
          block&.call(res)
        end
      end

      private

      def kcsdk_settle(res, unread)
        if res.code.to_i >= 300
          kcsdk_keep(res, Http.read_error_body(res))
        elsif unread
          kcsdk_keep(res, String.new(encoding: Encoding::BINARY))
        end
      end

      # ⚠️ **net-http `HTTPResponse` 내부(`@body`·`@read`)에 기댄다** — 읽은 응답의 `body` 는 소켓을 다시 읽지 않고 `@body`
      # 를 돌려준다. 모양은 `admin_response_body_spec` 의 핀이 고정한다.
      def kcsdk_keep(res, body)
        res.instance_variable_set(:@body, body)
        res.instance_variable_set(:@read, true)
        @socket.close
      end
    end

    # 표준 `:net_http` 어댑터의 설정 블록 — 커넥션을 짓기 직전 그 `Net::HTTP` 인스턴스의 싱글턴에 `BoundedTransport` 를
    # prepend 한다. 프록시 인자·연결 조립은 어댑터가 그대로 하고(원판 `net_http_connection`), 프록시·keep-alive 경로는
    # `http_framing_pins_spec` 이 고정한다.
    BOUND_CONNECTION = lambda do |http|
      http.singleton_class.prepend(BoundedTransport)
    end
    private_constant :BoundedReads, :ConnectFraming, :BoundedTransport, :BOUND_CONNECTION

    module_function

    def build(config, base_url: nil)
      Faraday.new(
        url: base_url,
        request: { timeout: config.read_timeout, open_timeout: config.connect_timeout }
      ) do |f|
        yield f if block_given?
        f.adapter :net_http, &BOUND_CONNECTION
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

    # admin 요청 하나의 전송 동안 그 응답의 본문을 정하게 한다(`SETTLE`) — `unread` 면 파사드 쓰기라 2xx 본문을 읽지 않는다.
    def settling(unread)
      previous = Thread.current[SETTLE]
      Thread.current[SETTLE] = { unread: unread }
      yield
    ensure
      Thread.current[SETTLE] = previous
    end

    # 300 이상의 본문을 `TOKEN_RESPONSE_MAX_BYTES` 까지만 쥔다 — 상한을 넘기는 조각이 오면 읽기를 멈추고 상한에서 자른다
    # (거부하지 않는다: 상태가 이미 오류를 정했다). net-http 가 16 KiB 씩 넘기므로 손에 드는 것은 많아야 상한 + 청크 하나다.
    def read_error_body(res)
      buf = String.new(encoding: Encoding::BINARY)
      catch(:kcsdk_cut) do
        res.read_body do |chunk|
          buf << chunk
          throw :kcsdk_cut if buf.bytesize > TOKEN_RESPONSE_MAX_BYTES
        end
      end
      buf.bytesize > TOKEN_RESPONSE_MAX_BYTES ? buf.byteslice(0, TOKEN_RESPONSE_MAX_BYTES) : buf
    end

    # `read_capped` 의 본문을 커넥션의 json 미들웨어가 하던 그대로 해석한다(응답을 돌려준다).
    # ⚠️ 해석한 값의 문자열이 잘못된 UTF-8 이면 해석 실패다(Faraday::ParsingError ← JSON::ParserError — 짝 없는
    # 서로게이트 이스케이프에서 json 3 이 내는 것과 같은 모양). 고쳐 쓰지 않는다 — 그 값은 SDK 를 지나며 raw 예외가 된다.
    # `check_utf8: false` 는 해석한 값을 하나도 쓰지 않는 호출(logout)의 것이다 — 미들웨어의 판정만 남는다.
    def decode_json(resp, check_utf8: true)
      JSON_RESPONSE.on_complete(resp.env)
      return resp if !check_utf8 || utf8?(resp.body)

      begin
        raise JSON::ParserError, UNDECODABLE
      rescue JSON::ParserError => e
        raise Faraday::ParsingError.new(e, resp) # 원인 사슬도 json 3 의 실패와 같다(ParsingError <- ParserError)
      end
    end

    # 해석한 JSON 값(키 포함)의 문자열이 전부 올바른 인코딩인가. 해석하지 않은 본문(BINARY)은 언제나 참이다.
    # ⚠️ **json 버전으로 막을 수 없다** — 잠긴 json 3.0.2 도 날 잘못된 UTF-8 바이트(0xFF)는 그대로 받아 잘못된
    # 문자열을 내고, json 2.9–2.21 은 짝 없는 **낮은** 서로게이트 이스케이프(\udc00)까지 그렇게 푼다(둘 다 실측).
    # 그 문자열이 지나는 자리마다 raw 예외다 — OAuth 코드 대조(`match?`)의 ArgumentError, admin 헤더의
    # Encoding::CompatibilityError(net-http `strip`), ruby-jwt base64 의 ArgumentError.
    def utf8?(value)
      case value
      when String then value.valid_encoding?
      when Hash then value.all? { |k, v| utf8?(k) && utf8?(v) }
      when Array then value.all? { |v| utf8?(v) }
      else true
      end
    end
  end
end
