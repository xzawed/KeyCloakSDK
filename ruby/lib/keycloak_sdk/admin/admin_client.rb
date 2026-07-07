# frozen_string_literal: true

module KeycloakSdk
  module Admin
    # Admin REST 파사드. gem 없이 Faraday로 직접 래핑하고, bearer는 주입된 TokenProvider에서 소싱한다.
    # representation은 plain hash로 통과한다(문서화된 은닉성 예외).
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

      # 탈출구: 내부 Faraday 커넥션(base = {server_url}/, bearer 자동).
      def raw
        @conn
      end

      private

      def build_conn(config, token_provider)
        Http.build(config, base_url: "#{config.server_url}/") do |f|
          f.request :json
          f.response :json, content_type: /\bjson$/
          f.use BearerAuth, token_provider
        end
      end
    end
  end
end
