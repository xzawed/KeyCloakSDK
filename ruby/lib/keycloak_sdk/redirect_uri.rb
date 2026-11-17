# frozen_string_literal: true

module KeycloakSdk
  # The `redirect_uri` an authorization request may carry — checked, never rewritten: the URL carries the caller's
  # String exactly as given, and the code exchange sends that same String (RFC 6749 §4.1.3 wants the two to match, so
  # normalising one of them breaks the flow). Three rules, in this order:
  #
  # - R1 absolute (RFC 6749 §3.1.2): a scheme, then `:`. A value that is not a String — nil included — is not an
  #   absolute URI either.
  # - R2 no fragment (RFC 6749 §3.1.2): no `#` anywhere; `https://app/cb#` has an empty one.
  # - R3 a URI Keycloak can read (RFC 3986 §2): Keycloak parses `redirect_uri` with `java.net.URI.create` and refuses
  #   the request when that throws — for every character in U+0000-U+0020 and U+007F-U+00A0, for the Unicode space
  #   separators U+1680, U+2000-U+200A, U+2028, U+2029, U+202F, U+205F and U+3000, for `" < > \ ^ ` { | }`, and for a
  #   `%` that is not followed by two hex digits (measured on JDK 21.0.8). Bytes that are not UTF-8 are refused here
  #   too. Keycloak also refuses `[` or `]` outside the query and the host, and an empty part after the scheme; those
  #   are not checked here.
  #
  # The rules read the String's bytes — what the URL carries — so no regex runs on a String it could raise on (a broken
  # encoding raises ArgumentError, a non-ASCII-compatible one Encoding::CompatibilityError): R1 and R2 look at a binary
  # copy, and R3 matches only once those bytes proved to be UTF-8. A refusal is a ConfigError whose message never
  # quotes the value.
  module RedirectUri
    NOT_ABSOLUTE = "invalid redirect_uri: not an absolute URI (RFC 6749 §3.1.2)"
    FRAGMENT = "invalid redirect_uri: a fragment is not allowed (RFC 6749 §3.1.2)"
    NOT_VALID = "invalid redirect_uri: not a valid URI (RFC 3986 §2)"
    SCHEME = /\A[A-Za-z][A-Za-z0-9+.-]*:/
    # `/x` only so the pattern can wrap: the line break and the indentation are not part of it (the class holds no
    # literal space — U+0020 is `\u{20}`).
    UNREADABLE = /[\u{0}-\u{20}\u{7F}-\u{A0}\u{1680}\u{2000}-\u{200A}\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}"<>\\^`{|}]
                  | %(?![0-9A-Fa-f]{2})/x
    private_constant :NOT_ABSOLUTE, :FRAGMENT, :NOT_VALID, :SCHEME, :UNREADABLE

    # Raises ConfigError unless `value` passes R1, R2 and R3; returns nil.
    def self.check!(value)
      bytes = value.b if value.is_a?(String)
      raise ConfigError, NOT_ABSOLUTE unless bytes&.match?(SCHEME)
      raise ConfigError, FRAGMENT if bytes.include?("#")

      text = bytes.force_encoding(Encoding::UTF_8)
      raise ConfigError, NOT_VALID unless text.valid_encoding? && !text.match?(UNREADABLE)

      nil
    end
  end
end
