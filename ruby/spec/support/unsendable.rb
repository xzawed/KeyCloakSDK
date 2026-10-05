# frozen_string_literal: true

# 보낼 수 없는 토큰·디코드할 수 없는 응답 시험(wave 4 · §4)이 나눠 쓰는 것.
#
# 헤더 사례 탐침(수정 전, 가짜 IdP 가 내준 토큰 · net-http 0.9.1):
#   admin LF·CR → RAW ArgumentError "header Authorization has field value \"Bearer …\", this cannot include CR/LF"
#     (메시지·inspect·full_message 에 Bearer 전체), 65,530·1,000,000 바이트 → RAW ArgumentError "… too long field value",
#   NUL → SDK TransportError(서버가 끊었다) · U+0100·U+4E2D → 그대로 보냈고 성공. introspect·refresh·logout 은 토큰을
#   폼 본문에 실어 다섯 모두 성공했다. 잘못된 UTF-8 은 validate·logout·introspect 에서 raw ArgumentError 였다.
module UnsendableTokenSpec
  SERVER = "https://kc.unsendable.test"
  OIDC = "#{SERVER}/realms/r/protocol/openid-connect".freeze
  USERS = "#{SERVER}/admin/realms/r/users".freeze
  JSON_TYPE = { "Content-Type" => "application/json" }.freeze
  SECRET = "uS7k-client-secret-canary"
  BAD = "uBD7k-not-utf8-canary#{0xFF.chr}x".force_encoding(Encoding::UTF_8).freeze # 잘못된 UTF-8

  # 주어진 문자열을 그대로 돌려주는 provider(TokenProvider 덕 인터페이스).
  Fixed = Struct.new(:access_token)

  module_function

  def config = KeycloakSdk::Config.new(server_url: SERVER, realm: "r", client_id: "c", client_secret: SECRET)

  # 사용자가 보는 표현 전부(오류 렌더링 · 원인 사슬의 메시지·inspect·백트레이스).
  def renderings(err)
    out = [err.message, err.inspect, err.full_message(highlight: false)]
    cause = err.cause
    while cause
      out.push(cause.message, cause.inspect, Array(cause.backtrace).join("\n"))
      cause = cause.cause
    end
    out.map { |s| s.dup.force_encoding(Encoding::BINARY) }
  end

  # 토큰의 앞 10 바이트(카나리아)가 어디에도 없다 — 원문·이스케이프된 모양 모두 그 앞부분으로 잡힌다.
  def quoted?(err, token)
    renderings(err).any? { |s| s.include?(token.b[0, 10]) }
  end
end
