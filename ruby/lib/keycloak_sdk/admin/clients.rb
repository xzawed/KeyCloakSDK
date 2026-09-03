# frozen_string_literal: true

module KeycloakSdk
  module Admin
    # ⚠️ client_id 로 조회할 때는 list(clientId: ...) 를 쓴다 — admin 의 멤버 키는 내부 uuid 다.
    class Clients
      include CrudResource

      SEGMENT = "clients"
    end
  end
end
