# frozen_string_literal: true

module KeycloakSdk
  module Admin
    # users·clients·groups 는 CRUD 다섯 메서드의 모양이 **완전히 같다** — 컬렉션 세그먼트
    # 하나만 다르다(실측: users.rb 와 groups.rb 는 이름을 뺀 나머지가 바이트 동일, clients.rb 는
    # 주석 한 줄만 더 있었다).
    #
    # 세 파일을 따로 두면 **경로 조립 규칙이 세 곳에 복제된다.** 그것이 실제 비용을 냈다:
    # 경로 세그먼트 이스케이프를 넣자 세 파일의 유사도가 올라가 SonarCloud 신규코드 중복이
    # 17.6%(임계 3%)로 발현했다. 여기 모으면 이스케이프를 포함한 경로 규칙의 정의 자리가
    # 하나가 되고, 다음에 규칙이 바뀔 때도 한 곳만 고치면 된다.
    #
    # ⚠️ roles·realms 는 넣지 않는다 — roles 는 멤버 키가 `id` 가 아니라 `name` 이고(rename 이
    # 경로와 body 를 분리해야 하는 특수 규약을 갖는다), realms 는 realm 이름 자체가 세그먼트라
    # 경로 모양이 다르다. 억지로 묶으면 그 두 규약이 이 모듈 안에서 분기로 살아난다.
    module CrudResource
      include Call

      def initialize(conn, realm)
        @conn = conn
        @realm = realm
      end

      def create(representation)
        id_from_location(request { @conn.post(collection_path, representation) })
      end

      def get(id)
        request { @conn.get(member_path(id)) }.body
      end

      def list(**params)
        request { @conn.get(collection_path, params) }.body
      end

      def update(id, representation)
        request { @conn.put(member_path(id), representation) }
        nil
      end

      def delete(id)
        request { @conn.delete(member_path(id)) }
        nil
      end

      private

      # 포함한 클래스가 `SEGMENT` 상수로 컬렉션 이름을 준다.
      def collection_path
        "admin/realms/#{esc(@realm)}/#{self.class::SEGMENT}"
      end

      def member_path(id)
        "#{collection_path}/#{esc(id)}"
      end
    end
  end
end
