# frozen_string_literal: true

module Kc
  module Admin
    # Fixture admin facade. The drive spec calls initialize and users only.
    class Client
      def initialize(auth)
        @auth = auth
      end

      def users
        [@auth.token("admin")]
      end

      def close; end

      def flush
      end
    end
  end
end
