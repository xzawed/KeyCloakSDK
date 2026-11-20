# frozen_string_literal: true

module Kc
  # Fixture boundary class for the unit-unreached ledger — the unit drive (spec/unit/drive_spec.rb) reaches part of it.
  class AuthClient
    def initialize(config)
      @config = config
    end

    # Fully reached by the drive — not in the ledger. A one-line method's line runs at require; its call count says it ran.
    def realm = @config.realm

    # Fully reached by the drive, both arms of the ternary — not in the ledger.
    def token(kind)
      kind.nil? ? "#{@config.realm}:default" : "#{@config.realm}:#{kind}"
    end

    # A failure branch on its own line: the drive never sends an empty code — its line and its arm are unreached.
    def exchange(code)
      if code.empty?
        raise ArgumentError, "empty code"
      end

      "token:#{code}"
    end

    # A failure arm on a line the happy path already runs: no line is left unreached, the unless arm is.
    def pick(map, key)
      raise KeyError, "no #{key}" unless map.key?(key)

      map[key]
    end

    # || is not a branch to Ruby's Coverage: a failure arm behind it, on a line that ran, is not seen (the ledger's known gap).
    def fallback(value)
      value || raise(ArgumentError, "none")
    end

    # A block's lines and arms are its method's: the drive passes no items, so the block body never runs.
    def apply(items)
      items.map do |item|
        item.empty? ? "-" : item.upcase
      end
    end

    # The &. nil arm: the drive always passes claims.
    def realm_of(claims) = claims&.fetch(:realm)

    # A one-line method the drive never calls — its line ran at require, so the call count says it never ran.
    def describe = "AuthClient(#{@config.realm})"

    # Never called by the drive (the integration spec calls it — the unit run leaves that spec out).
    def logout_url
      "#{@config.base}/logout"
    end

    # A singleton method keys with "." — the drive never sends nil.
    def self.parse(raw)
      if raw.nil?
        raise ArgumentError, "nil"
      end

      raw.strip
    end
  end
end
