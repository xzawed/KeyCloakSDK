# frozen_string_literal: true

require "openssl"
require "socket"
require "timeout"

module KeycloakSdk
  # The root of all SDK errors.
  class Error < StandardError; end

  # Configuration validation failure.
  class ConfigError < Error; end

  # Authentication/token issuance failure (keeps the OAuth error code).
  class AuthError < Error
    attr_reader :oauth_error

    def initialize(message = nil, oauth_error: nil)
      super(message)
      @oauth_error = oauth_error
    end
  end

  # Network transport failure (timeout/connection refused/DNS).
  class TransportError < Error; end

  # JWT validation failure.
  class TokenValidationError < Error; end

  # Admin REST error (keeps the HTTP status).
  class AdminError < Error
    attr_reader :status

    def initialize(message = nil, status: nil)
      super(message)
      @status = status
    end

    # status → an instance of the matching subclass exception.
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

  # The copy attached as an SDK error's `cause` in place of the original underlying exception — it carries over **only
  # the class-name chain and the backtrace**. The boundary attaches it with `raise …, cause: RedactedCause.new(e)`
  # (it is not a `KeycloakSdk::Error` — it only ever sits in the cause slot).
  #
  # ⚠️ In Ruby, a `raise` inside `rescue` attaches the exception being handled as `cause` **automatically**, and
  # `full_message` (uncaught exceptions · loggers) prints the messages of that chain. Underlying exceptions carry the
  # response — the JSON parser puts the first 32 bytes of the body in its message, rack-oauth2 the
  # `error_description` (the whole body for a non-JSON error), Net::HTTP the broken status line, and
  # `Faraday::ParsingError#inspect` printed even the **request** body and headers (client secret · refresh token ·
  # bearer). Ruby 3.2's `NoMethodError` quoted the receiver (the response body) (measured 2026-09-26 ·
  # `spec/unit/hostile_token_response_spec.rb`). §4 also requires that the original objects are not exposed through
  # the public API.
  class RedactedCause < StandardError
    # The underlying causes whose message may be carried into the SDK message — only socket · timeout · TLS
    # failures, which cannot quote the response.
    # ⚠️ `Faraday::ConnectionFailed` is not added wholesale — `Net::HTTPBadResponse` (a dump of the broken status
    # line) also arrives as one.
    QUOTE_FREE = [SystemCallError, SocketError, IOError, Timeout::Error, OpenSSL::SSL::SSLError].freeze

    # The class names of the original and its `cause`s (outermost first).
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

    # The description of an underlying error to carry in an SDK message — the message itself for a connection
    # failure that cannot quote the response, otherwise only the class name.
    def self.describe(error)
      origin = error.respond_to?(:wrapped_exception) && error.wrapped_exception ? error.wrapped_exception : error
      QUOTE_FREE.any? { |k| origin.is_a?(k) } ? error.message : error.class.name
    end
  end
end
