# frozen_string_literal: true

# measurement only — not for merge (task n3 · registry consumer-http-client-redirect-unmeasured).
#
# The three public ctors that take a consumer Faraday connection — AuthClient.new(config:, http:, jwt_validator:),
# ClientCredentialsTokenProvider.new(config:, http:) and JwksStore.new(jwks_url:, http:) — and the public admin resource
# classes Admin::{Users,Clients,Groups,Roles}.new(conn, realm) · Admin::Realms.new(conn) (create each; Users also update) are
# given (the admin rows' connections carry a base URL — `Faraday.new(url:)` · `Faraday.new(url:){json;follow_redirects}`):
#   default  `Faraday.new` — what a consumer gets with no options;
#   [extra]  `Faraday.new { |f| f.request :url_encoded; f.response :follow_redirects }` — the opt-in follow middleware
#            (faraday-follow_redirects, in this SDK's own bundle through rack-oauth2), with its defaults.
# Origin A answers the SDK's request with 302 · 303 · 307 · 308 whose Location points at `/moved<same path>` on A itself
# (same origin) or on a second server B (another port = cross origin). The target answers every request with a usable
# success body, so `result` shows what the SDK does with an answer that came from the redirect target. The JWKS row
# signs the token with a key only the target serves (kid kB): `result=Ok` means the SDK validated against it.
# Controls: the same cells through KeycloakClient.new (the SDK's own connections).
#
# Run: N3_OUT=<file> RUN_INTEGRATION=1 bundle exec rspec spec/unit/zz_n3_redirect_measure_spec.rb
#      (RUN_INTEGRATION only lifts spec_helper's coverage gate for a one-file run; this spec has no integration tag)

require "spec_helper"
require "socket"
require "openssl"
require "faraday/follow_redirects"

module ZzN3Redirect
  REALM = "it-realm"
  CLIENT_ID = "it-client"
  SECRET = "dummy-secret-MARK"
  REFRESH = "dummy-refresh-MARK"
  CODE = "dummy-code-MARK"
  VERIFIER = "dummy-verifier-MARK"
  INTROSPECTED = "dummy-introspected-MARK"
  OIDC = "/realms/#{REALM}/protocol/openid-connect".freeze
  STATUSES = [302, 303, 307, 308].freeze
  REASONS = { 200 => "OK", 204 => "No Content", 302 => "Found", 303 => "See Other", 307 => "Temporary Redirect",
              308 => "Permanent Redirect", 404 => "Not Found" }.freeze
  TARGET_KEY = OpenSSL::PKey::RSA.generate(2048)
  TARGET_JWK = JWT::JWK.new(TARGET_KEY, kid: "kB")
  # The representations' marker — an admin body, not a secret (`admin_body` in the output).
  ADMIN_MARK = "admin-body-mark"
  ADMIN_BEARER = "ADMIN-BEARER-MARK"
  ADMIN_REALM = "/admin/realms/#{REALM}".freeze
  USERS = "#{ADMIN_REALM}/users".freeze

  # The public admin resource classes take a Faraday connection too — one row per class (create; Users also update).
  # op => [resource, ctor, name, origin path, call]. The body encoding is the connection's: the default `Faraday.new(url:)`
  # form-encodes the representation Hash (url_encoded), the [extra] connection and the SDK's own send JSON — hence "body".
  ADMIN = {
    admin_users_create: [:users, "Admin::Users.new(conn,realm)", "create(POST body)", USERS,
                         ->(r) { "created_id=#{r.create({ 'username' => ADMIN_MARK }).inspect}" }],
    admin_users_update: [:users, "Admin::Users.new(conn,realm)", "update(PUT body)", "#{USERS}/u1",
                         ->(r) { r.update("u1", { "username" => ADMIN_MARK }).inspect }],
    admin_clients_create: [:clients, "Admin::Clients.new(conn,realm)", "create(POST body)", "#{ADMIN_REALM}/clients",
                           ->(r) { "created_id=#{r.create({ 'clientId' => ADMIN_MARK }).inspect}" }],
    admin_groups_create: [:groups, "Admin::Groups.new(conn,realm)", "create(POST body)", "#{ADMIN_REALM}/groups",
                          ->(r) { "created_id=#{r.create({ 'name' => ADMIN_MARK }).inspect}" }],
    admin_realms_create: [:realms, "Admin::Realms.new(conn)", "create(POST body)", "/admin/realms",
                          ->(r) { "returned=#{r.create({ 'realm' => ADMIN_MARK }).inspect}" }],
    admin_roles_create: [:roles, "Admin::Roles.new(conn,realm)", "create(POST body)", "#{ADMIN_REALM}/roles",
                         ->(r) { "returned=#{r.create({ 'name' => ADMIN_MARK }).inspect}" }]
  }.freeze
  ADMIN_OPS = ADMIN.keys.freeze

  # [op, ctor, name, origin path]
  OPS = ([
    [:auth_cc, "AuthClient.new(http:)", "client_credentials_token(POST form)", "#{OIDC}/token"],
    [:auth_code, "AuthClient.new(http:)", "exchange_code(POST form)", "#{OIDC}/token"],
    [:auth_refresh, "AuthClient.new(http:)", "refresh(POST form)", "#{OIDC}/token"],
    [:auth_introspect, "AuthClient.new(http:)", "introspect(POST form)", "#{OIDC}/token/introspect"],
    [:auth_logout, "AuthClient.new(http:)", "logout(POST form)", "#{OIDC}/logout"],
    [:provider_cc, "ClientCredentialsTokenProvider.new(http:)", "access_token(POST form)", "#{OIDC}/token"],
    [:jwks, "JwksStore.new(http:)", "validate->JWKS fetch(GET)", "#{OIDC}/certs"]
  ] + ADMIN.map { |op, (_, ctor, name, path, _)| [op, ctor, name, path] }).freeze

  CONTROL_NAMES = {
    auth_cc: "auth.client_credentials_token(POST form)", auth_code: "auth.exchange_code(POST form)",
    auth_refresh: "auth.refresh(POST form)", auth_introspect: "auth.introspect(POST form)",
    auth_logout: "auth.logout(POST form)", provider_cc: "admin.realms.get->provider grant(POST form)",
    jwks: "auth.validate->JWKS fetch(GET)"
  }.merge(ADMIN.to_h { |op, (res, _, name, _, _)| [op, "admin.#{res}.#{name}"] }).freeze

  # A raw TCP HTTP/1.1 server: one request per connection, Content-Length bodies, answers from the block.
  class Server
    Req = Struct.new(:verb, :path, :headers, :body)

    def initialize(&handler)
      @handler = handler
      @server = TCPServer.new("127.0.0.1", 0)
      @seen = []
      @lock = Mutex.new
      @thread = Thread.new do
        loop do
          sock = @server.accept
          Thread.new(sock) { |s| handle(s) }
        rescue IOError, SystemCallError
          break
        end
      end
    end

    def url
      "http://127.0.0.1:#{@server.addr[1]}"
    end

    def requests
      @lock.synchronize { @seen.dup }
    end

    def reset
      @lock.synchronize { @seen.clear }
    end

    def close
      @server.close
      @thread.join(5)
    end

    private

    def handle(sock)
      head = +""
      until head.end_with?("\r\n\r\n")
        ch = sock.read(1)
        return if ch.nil?

        head << ch
      end
      lines = head.split("\r\n")
      verb, path, = lines.first.split(" ")
      headers = lines.drop(1).to_h do |l|
        k, v = l.split(":", 2)
        [k.downcase, v.to_s.strip]
      end
      body = headers["content-length"] ? sock.read(headers["content-length"].to_i).to_s : ""
      req = Req.new(verb, path, headers, body)
      @lock.synchronize { @seen << req }
      status, hdrs, payload = @handler.call(req)
      out = +"HTTP/1.1 #{status} #{REASONS.fetch(status, 'X')}\r\n"
      hdrs.each { |k, v| out << "#{k}: #{v}\r\n" }
      out << "Content-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n" << payload
      sock.write(out)
    rescue IOError, SystemCallError
      nil
    ensure
      sock.close unless sock.closed?
    end
  end

  module_function

  def json(status, body)
    [status, { "Content-Type" => "application/json" }, body]
  end

  def redirect(status, location)
    [status, { "Location" => location }, ""]
  end

  def clean(text)
    text.to_s.tr("|", "/").tr("\r\n", "  ")
  end

  def auth_of(req)
    v = req.headers["authorization"]
    return "none" if v.nil?
    return "Bearer(admin-token)" if v == "Bearer #{ADMIN_BEARER}"
    return "other(#{v})" unless v.start_with?("Basic ")

    decoded = Base64.decode64(v.delete_prefix("Basic "))
    decoded == "#{CLIENT_ID}:#{SECRET}" ? "Basic(client_id:client_secret)" : "Basic(#{decoded})"
  end

  def body_secret_of(req)
    b = req.body
    return "no-body" if b.empty?

    marks = []
    marks << "client_secret" if b.include?("client_secret=#{SECRET}")
    marks << "refresh_token" if b.include?("refresh_token=#{REFRESH}")
    marks << "code" if b.include?("code=#{CODE}")
    marks << "code_verifier" if b.include?("code_verifier=#{VERIFIER}")
    marks << "introspected_token" if b.include?("token=#{INTROSPECTED}")
    marks << "admin_body" if b.include?(ADMIN_MARK) # a representation — not a secret
    marks.empty? ? "none" : marks.join("+")
  end

  def body_of(req)
    return "0B" if req.body.empty?
    return "#{req.body.bytesize}B[json]" if req.body.start_with?("{")

    "#{req.body.bytesize}B[#{req.body.split('&').map { |kv| kv.split('=').first }.join(',')}]"
  end

  # The body shape (`NB[json]` or `NB[form keys]`) shows the encoding the connection used.
  def hop_of(req)
    "#{req.verb} auth=#{auth_of(req)} body_secret=#{body_secret_of(req)} body=#{body_of(req)}"
  end

  def each(reqs, &block)
    reqs.empty? ? "-" : reqs.map(&block).join(",")
  end

  def err(error)
    extra = error.respond_to?(:oauth_error) ? " oauth_error=#{error.oauth_error.inspect}" : ""
    clean("Err(#{error.class.name.split('::').last}: #{error.message}#{extra})")
  end

  def target_token(issuer)
    payload = { iss: issuer, sub: "signed-by-target-key", aud: CLIENT_ID, typ: "Bearer", exp: Time.now.to_i + 300 }
    JWT.encode(payload, TARGET_KEY, "RS256", { kid: "kB" })
  end

  def outcome
    yield
  rescue StandardError => e
    err(e)
  end
end

RSpec.describe "zz n3 redirect measure (measurement only)" do
  include ZzN3Redirect

  around do |example|
    WebMock.disable!
    example.run
  ensure
    WebMock.enable!
  end

  it "measures what a consumer Faraday connection does on a 3xx" do
    out_path = ENV.fetch("N3_OUT")
    m = ZzN3Redirect
    state = { cell: nil, bounce: nil }
    servers = {}
    issuer = -> { "#{servers[:a].url}/realms/#{m::REALM}" }
    target_answer = lambda do |req, label|
      path = req.path
      if path.include?("/admin/")
        # A real collection answers a POST with 201 + Location, a GET with a list; a PUT with 204.
        next [201, { "Location" => "#{servers[label].url}#{path}/target-id" }, ""] if req.verb == "POST"
        next [204, {}, ""] if req.verb == "PUT"

        next m.json(200, "[]")
      end
      if path.end_with?("/certs")
        m.json(200, JSON.generate({ keys: [m::TARGET_JWK.export] }))
      elsif path.end_with?("/token/introspect")
        m.json(200, '{"active":true,"username":"target-user","client_id":"target-client"}')
      elsif path.end_with?("/logout")
        [204, {}, ""]
      else
        m.json(200, '{"access_token":"TARGET-AT","token_type":"Bearer","expires_in":300,"refresh_token":"TARGET-RT"}')
      end
    end
    handler = lambda do |label|
      lambda do |req|
        path = req.path
        if (b = state[:bounce])
          if label == :a && path == "/token"
            b[:hits] += 1
            next b[:hits] == 1 ? m.redirect(307, "#{servers[:b].url}/hop") : m.json(200, '{"access_token":"AT","token_type":"Bearer"}')
          end
          next m.redirect(307, "#{servers[:a].url}/token") if label == :b && path == "/hop"
        end
        cell = state[:cell]
        next m.redirect(cell[:status], cell[:location]) if cell && label == :a && path == cell[:origin_path]
        next target_answer.call(req, label) if cell && label == cell[:target] && path.start_with?("/moved/")
        next m.json(200, '{"realm":"origin-realm"}') if label == :a && path == "/admin/realms/#{m::REALM}"
        # The control's admin needs its provider's grant first — the token endpoint answers it.
        if label == :a && path == "#{m::OIDC}/token"
          next m.json(200, %({"access_token":"#{m::ADMIN_BEARER}","token_type":"Bearer","expires_in":300}))
        end

        m.json(404, "{}")
      end
    end
    servers[:a] = ZzN3Redirect::Server.new(&handler.call(:a))
    servers[:b] = ZzN3Redirect::Server.new(&handler.call(:b))
    label = ->(url) { url.to_s.gsub(servers[:a].url, "{A}").gsub(servers[:b].url, "{B}") }

    consumers = {
      "Faraday.new" => -> { Faraday.new },
      "Faraday.new{url_encoded;follow_redirects}[extra]" => lambda {
        Faraday.new do |f|
          f.request :url_encoded
          f.response :follow_redirects
        end
      }
    }

    # The admin resources take paths relative to the connection's base URL — the consumer's connection has one.
    admin_conns = {
      "Faraday.new" => ["Faraday.new(url:)", -> { Faraday.new(url: "#{servers[:a].url}/") }],
      "Faraday.new{url_encoded;follow_redirects}[extra]" => [
        "Faraday.new(url:){json;follow_redirects}[extra]",
        lambda {
          Faraday.new(url: "#{servers[:a].url}/") do |f|
            f.request :json
            f.response :follow_redirects
          end
        }
      ]
    }

    config = lambda do
      KeycloakSdk::Config.new(server_url: servers[:a].url, realm: m::REALM, client_id: m::CLIENT_ID,
                              client_secret: m::SECRET)
    end

    # `resource` is the admin resource instance the row calls — built on the consumer's connection, or the SDK's own.
    admin_call = lambda do |op, resource|
      m.outcome { "Ok(#{m::ADMIN.fetch(op)[4].call(resource)})" }
    end

    # The resource class a consumer constructs with its own connection (Realms takes no realm).
    consumer_resource = lambda do |op, conn|
      key = m::ADMIN.fetch(op)[0]
      klass = KeycloakSdk::Admin.const_get(key.to_s.capitalize)
      key == :realms ? klass.new(conn) : klass.new(conn, m::REALM)
    end

    call_op = lambda do |op, auth: nil, provider: nil, validate: nil|
      m.outcome do
        case op
        when :auth_cc then "Ok(access_token=#{auth.client_credentials_token.access_token})"
        when :auth_code
          ts = auth.exchange_code(code: m::CODE, code_verifier: m::VERIFIER, redirect_uri: "https://app.example/cb")
          "Ok(access_token=#{ts.access_token})"
        when :auth_refresh then "Ok(access_token=#{auth.refresh(refresh_token: m::REFRESH).access_token})"
        when :auth_introspect
          r = auth.introspect(m::INTROSPECTED)
          "Ok(active=#{r.active} username=#{r.username})"
        when :auth_logout then "Ok(#{auth.logout(refresh_token: m::REFRESH).inspect})"
        when :provider_cc then "Ok(#{provider.call})"
        when :jwks then "Ok(validated sub=#{validate.call(m.target_token(issuer.call)).subject})"
        end
      end
    end

    lowlevel = lambda do |op, http|
      cfg = config.call
      endpoints = KeycloakSdk::OidcEndpoints.from_config(cfg)
      store = KeycloakSdk::JwksStore.new(jwks_url: endpoints.jwks, http: http)
      validator = KeycloakSdk::JwtValidator.new(issuer: endpoints.issuer, audience: m::CLIENT_ID, jwks_store: store)
      auth = KeycloakSdk::AuthClient.new(config: cfg, http: http, jwt_validator: validator)
      provider = KeycloakSdk::ClientCredentialsTokenProvider.new(config: cfg, http: http)
      call_op.call(op, auth: auth, provider: -> { "access_token=#{provider.access_token}" },
                       validate: ->(t) { validator.validate(t) })
    end

    control = lambda do |op|
      kc = KeycloakSdk::KeycloakClient.new(config.call)
      begin
        if m::ADMIN_OPS.include?(op)
          admin_call.call(op, kc.admin.public_send(m::ADMIN.fetch(op)[0]))
        else
          call_op.call(op, auth: kc.auth, provider: -> { "realm=#{kc.admin.realms.get(m::REALM)['realm']}" },
                           validate: ->(t) { kc.auth.validate(t) })
        end
      ensure
        kc.close
      end
    end

    lines = []
    lines << "ENV|ruby=#{RUBY_VERSION}|faraday=#{Faraday::VERSION}|faraday-net_http=#{Faraday::NetHttp::VERSION}" \
             "|net-http=#{Net::HTTP::VERSION}|faraday-follow_redirects=#{Faraday::FollowRedirects::VERSION}" \
             "|jwt=#{JWT.gem_version}|rack-oauth2=#{Gem.loaded_specs['rack-oauth2']&.version}"
    plain = Faraday.new
    lines << "API|Faraday.new|handlers=#{plain.builder.handlers.map(&:name).inspect}|adapter=#{plain.builder.adapter.name}"
    follow = consumers.values.last.call
    lines << "API|Faraday.new{url_encoded;follow_redirects}|handlers=#{follow.builder.handlers.map(&:name).inspect}" \
             "|follow_redirects defaults: limit=#{Faraday::FollowRedirects::Middleware::FOLLOW_LIMIT}" \
             " standards_compliant=false clear_authorization_header=true (middleware.rb options.fetch defaults)"
    lines << "HEADER|ctor|op|status|target|followed|method@target|body_secret@target|auth@target|result|body@target" \
             "|content-type@target|paths@target|origin_hop|hits"

    totals = Hash.new { |h, k| h[k] = [0, 0] }
    variants = consumers.keys.map { |k| [k, consumers[k]] } + [["KeycloakClient.new(control)", nil]]
    variants.each do |vname, make|
      m::OPS.each do |op, ctor, name, opath|
        m::STATUSES.each do |status|
          [false, true].each do |cross|
            servers.each_value(&:reset)
            target = cross ? :b : :a
            state[:cell] = { origin_path: opath, status: status, target: target,
                             location: "#{servers[target].url}/moved#{opath}" }
            admin_op = m::ADMIN_OPS.include?(op)
            result = if make.nil? then control.call(op)
                     elsif admin_op then admin_call.call(op, consumer_resource.call(op, admin_conns[vname][1].call))
                     else lowlevel.call(op, make.call)
                     end
            used = admin_op && make ? admin_conns[vname][0] : vname
            first = servers[:a].requests.select { |r| r.path == opath }
            moved = servers[target].requests.select { |r| r.path.start_with?("/moved/") }
            state[:cell] = nil
            totals[vname][1] += 1
            totals[vname][0] += 1 unless moved.empty?
            lines << [
              "CELL", make ? "#{ctor}<-#{used}" : vname, make ? name : m::CONTROL_NAMES.fetch(op), status,
              cross ? "cross-origin" : "same-origin", "followed=#{moved.empty? ? 'no' : 'yes'}",
              "method=#{m.each(moved, &:verb)}", "body_secret=#{m.each(moved) { |r| m.body_secret_of(r) }}",
              "auth=#{m.each(moved) { |r| m.auth_of(r) }}", "result=#{result}", "body=#{m.each(moved) { |r| m.body_of(r) }}",
              "ctype=#{m.each(moved) { |r| r.headers['content-type'] || 'none' }}", "paths=#{m.each(moved, &:path)}",
              "origin_hop=#{m.each(first) { |r| m.hop_of(r) }}", "hits=origin:#{first.size}/target:#{moved.size}"
            ].join("|")
          end
        end
      end
    end
    lines << "SUMMARY|#{totals.map { |k, (f, t)| "#{k} followed #{f}/#{t} cells" }.join('|')}"

    basic = "Basic #{Base64.strict_encode64("#{m::CLIENT_ID}:#{m::SECRET}")}"
    consumers.each do |vname, make|
      m::STATUSES.each do |status|
        servers.each_value(&:reset)
        state[:cell] = { origin_path: "/start", status: status, target: :b, location: "#{servers[:b].url}/moved/start" }
        url = "#{servers[:a].url}/start"
        resp = make.call.post(url, { client_secret: m::SECRET }, "Authorization" => basic)
        b_got = servers[:b].requests.select { |r| r.path == "/moved/start" }
        state[:cell] = nil
        lines << "DETECT|#{vname}|single hop #{status} A->B|request_url=#{label.call(url)}" \
                 "|response.env.url=#{label.call(resp.env.url)}|status=#{resp.status}" \
                 "|url_differs=#{resp.env.url.to_s != url}|B_got=#{m.each(b_got) { |r| m.hop_of(r) }}"
      end
      servers.each_value(&:reset)
      state[:bounce] = { hits: 0 }
      url = "#{servers[:a].url}/token"
      resp = make.call.post(url, { client_secret: m::SECRET }, "Authorization" => basic)
      hop = servers[:b].requests.select { |r| r.path == "/hop" }
      a_hits = servers[:a].requests.select { |r| r.path == "/token" }
      state[:bounce] = nil
      lines << "DETECT|#{vname}|bounce A-307->B-307->A|request_url=#{label.call(url)}" \
               "|response.env.url=#{label.call(resp.env.url)}|status=#{resp.status}" \
               "|url_differs=#{resp.env.url.to_s != url}|B_got=#{m.each(hop) { |r| m.hop_of(r) }}" \
               "|A_hits=#{a_hits.size}|A_hops=#{m.each(a_hits) { |r| m.hop_of(r) }}"
    end
    servers.each_value(&:close)
    File.write(out_path, "#{lines.join("\n")}\n")
    expect(lines.count { |l| l.start_with?("CELL|") }).to eq(3 * 13 * 4 * 2)
  end
end
