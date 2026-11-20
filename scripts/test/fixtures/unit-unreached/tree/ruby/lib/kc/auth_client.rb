# frozen_string_literal: true

module Kc
  # Fixture boundary class for the unit-unreached ledger — the unit drive (spec/unit/drive_spec.rb) reaches part of it.
  class AuthClient
    def initialize(config)
      @config = config
    end

    # Fully reached by the drive — not in the ledger. A one-line method's line runs at require; its call count says it ran.
    def realm = @config.realm

    # Fully reached by the drive — not in the ledger.
    def token(kind)
      "#{@config.realm}:#{kind}"
    end

    # A failure branch on its own line: the drive never sends an empty code.
    def exchange(code)
      if code.empty?
        raise ArgumentError, "empty code"
      end

      "token:#{code}"
    end

    # A failure branch on a line the happy path already runs — line counts cannot see it (the ledger's known gap).
    def pick(map, key)
      map[key] || raise(KeyError, "no #{key}")
    end

    # A block's lines are the method's: the drive passes no items, so the block body never runs.
    def apply(items)
      items.map do |item|
        item.upcase
      end
    end

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
