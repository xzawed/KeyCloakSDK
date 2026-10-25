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

      # 자원 정리: 내부 Faraday 커넥션을 닫는다(§4 close 계약 — KeycloakClient#close가 위임).
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
