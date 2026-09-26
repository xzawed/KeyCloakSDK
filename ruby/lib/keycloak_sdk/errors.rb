# frozen_string_literal: true

require "openssl"
require "socket"
require "timeout"

module KeycloakSdk
  # 모든 SDK 오류의 루트.
  class Error < StandardError; end

  # 설정 검증 실패.
  class ConfigError < Error; end

  # 인증/토큰 발급 실패(OAuth 오류 코드 보존).
  class AuthError < Error
    attr_reader :oauth_error

    def initialize(message = nil, oauth_error: nil)
      super(message)
      @oauth_error = oauth_error
    end
  end

  # 네트워크 전송 실패(타임아웃/연결거부/DNS).
  class TransportError < Error; end

  # JWT 검증 실패.
  class TokenValidationError < Error; end

  # Admin REST 오류(HTTP status 보존).
  class AdminError < Error
    attr_reader :status

    def initialize(message = nil, status: nil)
      super(message)
      @status = status
    end

    # status → 적절한 하위 예외 인스턴스.
    def self.from_status(status, message)
      case status
      when 404 then NotFoundError.new(message, status: status)
      when 409 then ConflictError.new(message, status: status)
      when 403 then ForbiddenError.new(message, status: status)
      else AdminError.new(message, status: status)
      end
    end
  end

  class NotFoundError < AdminError; end
  class ConflictError < AdminError; end
  class ForbiddenError < AdminError; end

  # SDK 오류의 `cause` 에 원본 하위 예외 대신 다는 사본 — **클래스 이름 사슬과 백트레이스만** 옮긴다.
  # 경계는 `raise …, cause: RedactedCause.new(e)` 로 단다(`KeycloakSdk::Error` 가 아니다 — 원인 자리에만 있다).
  #
  # ⚠️ Ruby 는 `rescue` 안의 `raise` 가 처리 중인 예외를 `cause` 에 **자동으로** 달고, `full_message`(잡히지 않은
  # 예외·로거)가 그 사슬의 메시지를 찍는다. 하위 예외는 응답을 싣는다 — JSON 파서는 본문 앞 32 바이트를,
  # rack-oauth2 는 `error_description`(JSON 이 아닌 오류면 본문 전체)을, Net::HTTP 는 깨진 상태 줄을 메시지에 싣고,
  # `Faraday::ParsingError#inspect` 는 **요청** 본문·헤더(클라이언트 시크릿·refresh 토큰·베어러)까지 찍었다. Ruby 3.2 의
  # `NoMethodError` 는 수신자(응답 본문)를 인용했다(실측 2026-09-26 · `spec/unit/hostile_token_response_spec.rb`).
  # 원본 객체를 공개 API 로 내보내지 않는 것은 §4 도 요구한다.
  class RedactedCause < StandardError
    # 메시지를 SDK 메시지로 옮겨도 되는 하위 원인 — 응답을 인용할 수 없는 소켓·타임아웃·TLS 실패뿐이다.
    # ⚠️ `Faraday::ConnectionFailed` 를 통째로 넣지 않는다 — `Net::HTTPBadResponse`(깨진 상태 줄 dump)도 그것으로 온다.
    QUOTE_FREE = [SystemCallError, SocketError, IOError, Timeout::Error, OpenSSL::SSL::SSLError].freeze

    # 원본과 그 `cause` 들의 클래스 이름(바깥부터).
    attr_reader :lower_classes

    def initialize(error)
      @lower_classes = []
      link = error
      while link && @lower_classes.size < 8
        @lower_classes << link.class.name
        link = link.cause
      end
      super("#{@lower_classes.join(' <- ')} (message withheld: it can quote the response)")
      set_backtrace(error.backtrace) if error.backtrace
    end

    # SDK 메시지에 실을 하위 오류 설명 — 인용할 수 없는 연결 실패면 그 메시지, 아니면 클래스 이름뿐.
    def self.describe(error)
      origin = error.respond_to?(:wrapped_exception) && error.wrapped_exception ? error.wrapped_exception : error
      QUOTE_FREE.any? { |k| origin.is_a?(k) } ? error.message : error.class.name
    end
  end
end
