# frozen_string_literal: true

module KeycloakSdk
  module Admin
    class Users
      include CrudResource

      SEGMENT = "users"
    end
  end
end
