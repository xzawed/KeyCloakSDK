# frozen_string_literal: true

module KeycloakSdk
  module Admin
    # Admin REST facade. It wraps the API directly with Faraday, without a gem, and sources the bearer from the
    # injected TokenProvider. Representations pass through as plain hashes (a documented hiding exception).
    class AdminClient
      def initialize(config:, token_provider:)
        @config = config
        @conn = build_conn(config, token_provider)
      end

      def users
        Users.new(@conn, @config.realm)
      end

      def clients
        Clients.new(@conn, @config.realm)
      end

      def realms
        Realms.new(@conn)
      end

      def roles
        Roles.new(@conn, @config.realm)
      end

      def groups
        Groups.new(@conn, @config.realm)
      end

      # Escape hatch: the internal Faraday connection (base = {server_url}/, bearer attached automatically).
      def raw
        @conn
      end

      # Releases resources: closes the internal Faraday connection (§4 close contract — KeycloakClient#close
      # delegates to it).
      def close
        @conn.close if @conn.respond_to?(:close)
      end

      private

      # ⚠️ admin 요청은 인코딩 없는 본문을 청한다 — Accept-Encoding 이 없으면 net-http 가 gzip 을 청하고 상한 위에서 푼다
      # (`SettleBody` 가 오류 본문을 끊어도 그 inflater 는 읽은 압축 조각을 끝까지 푼다 · `Http::IDENTITY` 와 같은 까닭).
      # 요청에 이 머리가 있으면 net-http 는 자기 것을 붙이지 않고 풀지도 않는다.
      def build_conn(config, token_provider)
        Http.build(config, base_url: "#{config.server_url}/") do |f|
          f.headers["Accept-Encoding"] = "identity"
          f.request :json
          f.response :json, content_type: /\bjson$/
          f.use BearerAuth, token_provider
          f.use SettleBody
        end
      end
    end
  end
end
