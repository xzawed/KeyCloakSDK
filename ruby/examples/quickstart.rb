# frozen_string_literal: true

require "keycloak_sdk"

config = KeycloakSdk::Config.new(
  server_url: ENV.fetch("KC_URL", "http://localhost:8080"),
  realm: ENV.fetch("KC_REALM", "it-realm"),
  client_id: ENV.fetch("KC_CLIENT_ID", "it-client"),
  client_secret: ENV.fetch("KC_CLIENT_SECRET", "it-secret")
)

client = KeycloakSdk::KeycloakClient.new(config)

token = client.auth.client_credentials_token
puts "access token acquired (expires_in=#{token.expires_in})"

validated = client.auth.validate(token.access_token)
puts "validated: sub=#{validated.subject} iss=#{validated.issuer}"

puts "introspection active=#{client.auth.introspect(token.access_token).active?}"

user_id = client.admin.users.create({ username: "quickstart-user", enabled: true })
puts "created user #{user_id}"
client.admin.users.delete(user_id)
puts "deleted user"

client.close
