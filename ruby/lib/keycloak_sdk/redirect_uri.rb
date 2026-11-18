# frozen_string_literal: true

module KeycloakSdk
  # The `redirect_uri` an authorization request may carry — checked, never rewritten. The value is turned into a String
  # with `to_s`, as rack-oauth2 always did (a `URI` object worked, so it still does), and that String is what is
  # checked and what the URL carries; the code exchange sends the caller's value verbatim (RFC 6749 §4.1.3 wants the
  # two to match, so normalising one of them breaks the flow). Checking the converted String also keeps a String
  # subclass whose `to_s` differs from its value from sending something that was never checked. Four rules, in order:
  #
  # - R1 absolute (RFC 6749 §3.1.2): a scheme, then `:`. nil becomes "", which is not an absolute URI.
  # - R2 no fragment (RFC 6749 §3.1.2): no `#` anywhere; `https://app/cb#` has an empty one.
  # - R3 a URI Keycloak can read (RFC 3986 §2): Keycloak parses `redirect_uri` with `java.net.URI.create` and refuses
  #   the request when that throws — for every character in U+0000-U+0020 and U+007F-U+00A0, for the Unicode space
  #   separators U+1680, U+2000-U+200A, U+2028, U+2029, U+202F, U+205F and U+3000, for `" < > \ ^ ` { | }`, and for a
  #   `%` that is not followed by two hex digits (measured on JDK 21.0.8). Bytes that are not UTF-8 are refused here
  #   too.
  # - R4 what `java.net.URI.create` still refuses after R1-R3 (same message as R3, measured on JDK 21.0.8): nothing
  #   after the scheme's `:` (`https:`, R4a); and, when the part after the `:` starts with `/`, a `[` or `]` before the
  #   first `?` anywhere but in the authority's one bracketed host — `https://app/c[b`, `https://app[1]/cb`,
  #   `myapp:/c[b` (R4b); `//` with nothing after it (`https://`, `myapp://` — R4c; `https:///cb` and `https://?x=1`
  #   are read); a bracketed host that is not an RFC 3986 IPv6 address with Java's dotted quads (leading zeros allowed),
  #   optionally followed by a zone id of letters, digits, `_` and `.` after a `%` (`[zz]`, `[v1.x]`, `[::1::2]` — R4d);
  #   and a port after that host above 2147483647 once its leading zeros are dropped (R4e). An opaque value
  #   (`myapp:c[b`, `urn:x[y]`) and the query may hold brackets. R3 still refuses a zone id whose `%` is not followed by
  #   two hex digits (`[fe80::1%eth0]`), which `URI.create` reads, because RFC 6874 §2 writes that `%` as `%25` in a URI
  #   (`[fe80::1%25eth0]`).
  #
  # The rules read the String's bytes — what the URL carries — so no regex runs on a String it could raise on (a broken
  # encoding raises ArgumentError, a non-ASCII-compatible one Encoding::CompatibilityError): R1 and R2 look at a binary
  # copy, and R3 and R4 match only once those bytes proved to be UTF-8. A refusal is a ConfigError whose message never
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
    # R4d — RFC 3986's IPv6address, with `dec-octet` as Java reads it (leading zeros allowed: `01`, `00000000255`).
    H16 = "[0-9A-Fa-f]{1,4}"
    DEC = "0*(?:25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])"
    LS32 = "(?:#{H16}:#{H16}|#{DEC}\\.#{DEC}\\.#{DEC}\\.#{DEC})".freeze
    IPV6 = [
      "(?:#{H16}:){6}#{LS32}",
      "::(?:#{H16}:){5}#{LS32}",
      "(?:#{H16})?::(?:#{H16}:){4}#{LS32}",
      "(?:(?:#{H16}:){0,1}#{H16})?::(?:#{H16}:){3}#{LS32}",
      "(?:(?:#{H16}:){0,2}#{H16})?::(?:#{H16}:){2}#{LS32}",
      "(?:(?:#{H16}:){0,3}#{H16})?::#{H16}:#{LS32}",
      "(?:(?:#{H16}:){0,4}#{H16})?::#{LS32}",
      "(?:(?:#{H16}:){0,5}#{H16})?::#{H16}",
      "(?:(?:#{H16}:){0,6}#{H16})?::"
    ].join("|").freeze
    # R4d — the one bracketed host an authority may hold: optional user info, `[`, an IPv6 address, an optional zone id
    # (Java's scope_id: letters, digits, `_`, `.`), `]`, an optional port (group 1 — R4e reads it).
    BRACKETED_AUTHORITY = %r{\A(?:[^@\[\]/]*@)?\[(?:#{IPV6})(?:%[A-Za-z0-9_.]+)?\](?::([0-9]*))?\z}
    # R4e — Java's `Integer.MAX_VALUE`: `URI` reads a port with `Integer.parseInt`.
    PORT_MAX = 2_147_483_647
    BRACKET = /[\[\]]/
    private_constant :NOT_ABSOLUTE, :FRAGMENT, :NOT_VALID, :SCHEME, :UNREADABLE, :H16, :DEC, :LS32, :IPV6,
                     :BRACKETED_AUTHORITY, :PORT_MAX, :BRACKET

    # Returns the String the URL carries — `value.to_s` as a plain String — once it passes R1, R2, R3 and R4; otherwise
    # raises ConfigError. A plain String, because a `to_s` may return a String subclass whose own `to_s` (which the URL
    # builder calls again) would send something that was never checked.
    def self.check!(value)
      shown = value.to_s
      raise ConfigError, NOT_ABSOLUTE unless shown.is_a?(String)

      sent = String.new(shown)
      bytes = sent.b
      raise ConfigError, NOT_ABSOLUTE unless bytes.match?(SCHEME)
      raise ConfigError, FRAGMENT if bytes.include?("#")

      text = bytes.force_encoding(Encoding::UTF_8)
      raise ConfigError, NOT_VALID unless text.valid_encoding? && !text.match?(UNREADABLE)
      raise ConfigError, NOT_VALID unless parsable?(text.partition(":").last)

      sent
    end

    # R4 on the part after the scheme's `:` (R1 matched, so the first `:` is the scheme's).
    def self.parsable?(rest)
      return false if rest.empty?
      return true unless rest.start_with?("/")

      head = rest.partition("?").first
      return !head.match?(BRACKET) unless head.start_with?("//")
      return false if rest == "//"

      authority, _slash, path = head.delete_prefix("//").partition("/")
      (!authority.match?(BRACKET) || bracketed_host?(authority)) && !path.match?(BRACKET)
    end
    private_class_method :parsable?

    # R4d and R4e on an authority that holds a bracket: its one bracketed host, then the port's digits without their
    # leading zeros — at most ten, and no larger than PORT_MAX.
    def self.bracketed_host?(authority)
      host = BRACKETED_AUTHORITY.match(authority)
      return false unless host

      digits = host[1].to_s.sub(/\A0+/, "")
      digits.length <= 10 && digits.to_i <= PORT_MAX
    end
    private_class_method :bracketed_host?
  end
end
