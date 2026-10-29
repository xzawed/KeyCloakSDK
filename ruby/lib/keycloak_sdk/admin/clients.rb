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
        path = "admin/realms/#{esc(@realm)}/clients"
        id_from_location(request { @conn.post(path, representation, &SettleBody::MARK) })
      end

      def get(id)
        request { @conn.get("admin/realms/#{esc(@realm)}/clients/#{esc(id)}") }.body
      end

      # Lookup by client_id: list + filter (admin keys on the internal uuid).
      def list(**params)
        request { @conn.get("admin/realms/#{esc(@realm)}/clients", params) }.body
      end

      def update(id, representation)
        request { @conn.put("admin/realms/#{esc(@realm)}/clients/#{esc(id)}", representation, &SettleBody::MARK) }
        nil
      end

      def delete(id)
        request { @conn.delete("admin/realms/#{esc(@realm)}/clients/#{esc(id)}", &SettleBody::MARK) }
        nil
      end
    end
  end
end
