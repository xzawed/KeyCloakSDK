# frozen_string_literal: true

module KeycloakSdk
  module Admin
    class Clients
      include Call

      def initialize(conn, realm)
        @conn = conn
        @realm = realm
      end

      def create(representation)
        id_from_location(request { @conn.post("admin/realms/#{esc(@realm)}/clients", representation) })
      end

      def get(id)
        request { @conn.get("admin/realms/#{esc(@realm)}/clients/#{esc(id)}") }.body
      end

      # client_id로 조회: 목록 + 필터(admin은 내부 uuid 키).
      def list(**params)
        request { @conn.get("admin/realms/#{esc(@realm)}/clients", params) }.body
      end

      def update(id, representation)
        request { @conn.put("admin/realms/#{esc(@realm)}/clients/#{esc(id)}", representation) }
        nil
      end

      def delete(id)
        request { @conn.delete("admin/realms/#{esc(@realm)}/clients/#{esc(id)}") }
        nil
      end
    end
  end
end
