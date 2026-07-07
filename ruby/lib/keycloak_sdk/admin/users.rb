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
        id_from_location(request { @conn.post("admin/realms/#{@realm}/users", representation) })
      end

      def get(id)
        request { @conn.get("admin/realms/#{@realm}/users/#{id}") }.body
      end

      def list(**params)
        request { @conn.get("admin/realms/#{@realm}/users", params) }.body
      end

      def update(id, representation)
        request { @conn.put("admin/realms/#{@realm}/users/#{id}", representation) }
        nil
      end

      def delete(id)
        request { @conn.delete("admin/realms/#{@realm}/users/#{id}") }
        nil
      end
    end
  end
end
