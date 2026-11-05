# frozen_string_literal: true

module Kc
  # Not a boundary file — the unit gate measures it.
  Config = Struct.new(:realm, :base, keyword_init: true)
end
