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
        id_from_location(request { @conn.post("admin/realms/#{@realm}/roles", representation) })
      end

      def get(name)
        request { @conn.get("admin/realms/#{@realm}/roles/#{name}") }.body
      end

      def list(**params)
        request { @conn.get("admin/realms/#{@realm}/roles", params) }.body
      end

      def update(name, representation)
        request { @conn.put("admin/realms/#{@realm}/roles/#{name}", representation) }
        nil
      end

      def delete(name)
        request { @conn.delete("admin/realms/#{@realm}/roles/#{name}") }
        nil
      end
    end
  end
end
