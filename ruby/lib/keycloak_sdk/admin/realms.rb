# frozen_string_literal: true

module KeycloakSdk
  module Admin
    # top-level — name 키.
    class Realms
      include Call

      def initialize(conn)
        @conn = conn
      end

      # POST /admin/realms — master realm 전용(realm SA는 403). 반환: realm 이름.
      def create(representation)
        request { @conn.post("admin/realms", representation) }
        representation[:realm] || representation["realm"]
      end

      def get(realm)
        request { @conn.get("admin/realms/#{realm}") }.body
      end

      def list
        request { @conn.get("admin/realms") }.body
      end

      def update(realm, representation)
        request { @conn.put("admin/realms/#{realm}", representation) }
        nil
      end

      def delete(realm)
        request { @conn.delete("admin/realms/#{realm}") }
        nil
      end
    end
  end
end
