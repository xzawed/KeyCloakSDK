# frozen_string_literal: true

module KeycloakSdk
  # 완전 불투명 마스킹(접두 노출 없음).
  module Masking
    module_function

    def mask(secret)
      secret.nil? ? nil : "***"
    end
  end
end
