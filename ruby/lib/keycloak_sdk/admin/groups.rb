# frozen_string_literal: true

module KeycloakSdk
  module Admin
    class Groups
      include Call

      def initialize(conn, realm)
        @conn = conn
        @realm = realm
      end

      # Creates a group and returns its id — the one the answer's Location names, resolved against the request URL
      # (the last path segment, in the groups collection); nil when it names none.
      def create(representation)
        path = "admin/realms/#{esc(@realm)}/groups"
        id_from_location(request { @conn.post(path, representation, &SettleBody::MARK) })
      end

      def get(id)
        request { @conn.get("admin/realms/#{esc(@realm)}/groups/#{esc(id)}") }.body
      end

      def list(**params)
        request { @conn.get("admin/realms/#{esc(@realm)}/groups", params) }.body
      end

      def update(id, representation)
        request { @conn.put("admin/realms/#{esc(@realm)}/groups/#{esc(id)}", representation, &SettleBody::MARK) }
        nil
      end

      def delete(id)
        request { @conn.delete("admin/realms/#{esc(@realm)}/groups/#{esc(id)}", &SettleBody::MARK) }
        nil
      end
    end
  end
end
