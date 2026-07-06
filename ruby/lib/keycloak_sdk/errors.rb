# frozen_string_literal: true

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
end
