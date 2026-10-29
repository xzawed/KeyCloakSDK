# frozen_string_literal: true

module KeycloakSdk
  # Fully opaque masking (no prefix exposed).
  module Masking
    module_function

    def mask(secret)
      secret.nil? ? nil : "***"
    end
  end
end
