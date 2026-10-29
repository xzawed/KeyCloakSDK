# frozen_string_literal: true

module KeycloakSdk
  module Admin
    # top-level — keyed by name.
    class Realms
      include Call

      def initialize(conn)
        @conn = conn
      end

      # POST /admin/realms — master realm only (a realm SA gets 403). Returns: the realm name.
      def create(representation)
        request { @conn.post("admin/realms", representation, &SettleBody::MARK) }
        representation[:realm] || representation["realm"]
      end

      def get(realm)
        request { @conn.get("admin/realms/#{esc(realm)}") }.body
      end

      def list
        request { @conn.get("admin/realms") }.body
      end

      def update(realm, representation)
        request { @conn.put("admin/realms/#{esc(realm)}", representation, &SettleBody::MARK) }
        nil
      end

      def delete(realm)
        request { @conn.delete("admin/realms/#{esc(realm)}", &SettleBody::MARK) }
        nil
      end
    end
  end
end
