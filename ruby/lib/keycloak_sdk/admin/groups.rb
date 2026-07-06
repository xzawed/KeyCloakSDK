# frozen_string_literal: true

module KeycloakSdk
  module Admin
    class Groups
      include Call

      def initialize(conn, realm)
        @conn = conn
        @realm = realm
      end

      def create(representation)
        id_from_location(request { @conn.post("admin/realms/#{@realm}/groups", representation) })
      end

      def get(id)
        request { @conn.get("admin/realms/#{@realm}/groups/#{id}") }.body
      end

      def list(**params)
        request { @conn.get("admin/realms/#{@realm}/groups", params) }.body
      end

      def update(id, representation)
        request { @conn.put("admin/realms/#{@realm}/groups/#{id}", representation) }
        nil
      end

      def delete(id)
        request { @conn.delete("admin/realms/#{@realm}/groups/#{id}") }
        nil
      end
    end
  end
end
