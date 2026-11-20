# frozen_string_literal: true

module KeycloakSdk
  module Admin
    class Roles
      include Call

      def initialize(conn, realm)
        @conn = conn
        @realm = realm
      end

      def create(representation)
        path = "admin/realms/#{esc(@realm)}/roles"
        name_from_location(request { @conn.post(path, representation, &SettleBody::MARK) })
      end

      def get(name)
        request { @conn.get("admin/realms/#{esc(@realm)}/roles/#{esc(name)}") }.body
      end

      def list(**params)
        request { @conn.get("admin/realms/#{esc(@realm)}/roles", params) }.body
      end

      def update(name, representation)
        request { @conn.put("admin/realms/#{esc(@realm)}/roles/#{esc(name)}", representation, &SettleBody::MARK) }
        nil
      end

      def delete(name)
        request { @conn.delete("admin/realms/#{esc(@realm)}/roles/#{esc(name)}", &SettleBody::MARK) }
        nil
      end
    end
  end
end
