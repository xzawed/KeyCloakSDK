# frozen_string_literal: true

module Kc
  # Not a boundary file — the unit gate measures it, so the ledger does not (the drive never calls valid?).
  class Config
    attr_reader :realm, :base

    def initialize(realm:, base:)
      @realm = realm
      @base = base
    end

    def valid?
      !realm.empty?
    end
  end
end
