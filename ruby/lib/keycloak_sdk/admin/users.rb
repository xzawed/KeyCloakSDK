# frozen_string_literal: true

module KeycloakSdk
  module Admin
    class Users
      include Call

      def initialize(conn, realm)
        @conn = conn
        @realm = realm
      end

      def create(representation)
        id_from_location(request { @conn.post("admin/realms/#{esc(@realm)}/users", representation, &SettleBody::MARK) })
      end

      def get(id)
        request { @conn.get("admin/realms/#{esc(@realm)}/users/#{esc(id)}") }.body
      end

      def list(**params)
        request { @conn.get("admin/realms/#{esc(@realm)}/users", params) }.body
      end

      def update(id, representation)
        request { @conn.put("admin/realms/#{esc(@realm)}/users/#{esc(id)}", representation, &SettleBody::MARK) }
        nil
      end

      def delete(id)
        request { @conn.delete("admin/realms/#{esc(@realm)}/users/#{esc(id)}", &SettleBody::MARK) }
        nil
      end
    end
  end
end
