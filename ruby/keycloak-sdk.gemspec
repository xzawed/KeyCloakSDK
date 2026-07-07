# frozen_string_literal: true

require_relative "lib/keycloak_sdk/version"

Gem::Specification.new do |spec|
  spec.name        = "keycloak-sdk"
  spec.version     = KeycloakSdk::VERSION
  spec.authors     = ["xzawed"]
  spec.summary     = "Polyglot Keycloak SDK for Ruby — auth (OIDC/OAuth2) + Admin REST, hardened JWT validation"
  spec.description = "Idiomatic Ruby facade over rack-oauth2 (auth) and the Keycloak Admin REST API, " \
                     "with a self-hardened JWT validator. Isomorphic to the Java/Python/Node/Go/C#/PHP/Rust SDKs."
  spec.homepage    = "https://github.com/xzawed/KeyCloakSDK"
  spec.license     = "Apache-2.0"
  spec.required_ruby_version = ">= 3.2"

  spec.metadata = {
    "homepage_uri" => spec.homepage,
    "source_code_uri" => spec.homepage,
    "changelog_uri" => "#{spec.homepage}/releases",
    "bug_tracker_uri" => "#{spec.homepage}/issues",
    "rubygems_mfa_required" => "true"
  }

  spec.files = Dir["lib/**/*.rb", "LICENSE", "README.md"]
  spec.require_paths = ["lib"]

  spec.add_dependency "faraday", "~> 2.0"
  spec.add_dependency "jwt", "~> 3.2"
  spec.add_dependency "rack-oauth2", "~> 2.3"
end
