# frozen_string_literal: true

# measurement only — not for merge (task n3 · registry admin-created-id-non-ascii-location).
#
# What id does admin.users.create return when the 201's Location carries a byte that is not visible ASCII? A raw TCP
# server answers the token grant with a token and the create with 201 +
# `Location: http://127.0.0.1:<port>/admin/realms/it-realm/users/<id bytes>` for `abc` (control), `ab` 0xE9 `cd`
# (Latin-1 obs-text) and `ab` 0xC3 0xA9 `cd` (UTF-8 for U+00E9). Per case: the bytes a raw socket reads off the wire (WIRE),
# what a plain Faraday connection hands back as the header (CLIENT), and what the SDK returns (ID).
#
# Run: N3_OUT=<file> RUN_INTEGRATION=1 bundle exec rspec spec/unit/zz_n3_location_measure_spec.rb

require "spec_helper"
require "socket"

module ZzN3Location
  REALM = "it-realm"
  USERS = "/admin/realms/#{REALM}/users".freeze
  CASES = [
    ["ascii-control", "abc".b],
    ["latin1-0xE9", "ab\xE9cd".b],
    ["utf8-0xC3A9", "ab\xC3\xA9cd".b]
  ].freeze

  # One request per connection; the Location value is written as raw bytes.
  class RawServer
    attr_accessor :location
    attr_reader :seen

    def initialize
      @server = TCPServer.new("127.0.0.1", 0)
      @seen = []
      @location = "".b
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

    def close
      @server.close
      @thread.join(5)
    end

    private

    def handle(sock)
      head = "".b
      until head.end_with?("\r\n\r\n")
        ch = sock.read(1)
        return if ch.nil?

        head << ch
      end
      lines = head.split("\r\n")
      verb, path, = lines.first.split(" ")
      length = lines.find { |l| l.downcase.start_with?("content-length:") }&.split(":", 2)&.last.to_i
      sock.read(length) if length.positive?
      @seen << "#{verb} #{path}"
      sock.write(answer(verb, path))
    rescue IOError, SystemCallError
      nil
    ensure
      sock.close unless sock.closed?
    end

    def answer(verb, path)
      if path.end_with?("/protocol/openid-connect/token")
        json = '{"access_token":"at-n3","token_type":"Bearer","expires_in":300}'
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{json.bytesize}\r\nConnection: close\r\n\r\n#{json}".b
      elsif verb == "POST" && path.chomp("/") == USERS
        "HTTP/1.1 201 Created\r\nLocation: ".b + @location + "\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".b
      else
        "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".b
      end
    end
  end

  module_function

  def hex(bytes)
    bytes.b.unpack("C*").map { |b| format("%02X", b) }.join(" ")
  end

  # A string with every char outside printable ASCII escaped, then its code points (or bytes when not valid).
  def show(value)
    return "nil" if value.nil?

    s = value.to_s
    unless s.valid_encoding? && s.encoding != Encoding::BINARY
      return "#{s.inspect} encoding=#{s.encoding} valid=#{s.valid_encoding?} bytes=[#{hex(s)}]"
    end

    escaped = s.each_char.map { |c| c.ord.between?(0x20, 0x7E) ? c : format("\\u%04X", c.ord) }.join
    "\"#{escaped}\" encoding=#{s.encoding} cps=[#{s.each_char.map { |c| format('U+%04X', c.ord) }.join(',')}]"
  end

  def tail(value)
    value&.split("/")&.last
  end

  def wire_probe(url, port)
    sock = TCPSocket.new("127.0.0.1", port)
    sock.write("POST #{USERS} HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
    raw = sock.read.b
    sock.close
    line = raw.split("\r\n".b).find { |l| l.start_with?("Location: ".b) }
    line ? line.delete_prefix("Location: ".b) : "no Location (#{url})"
  end
end

RSpec.describe "zz n3 location measure (measurement only)" do
  around do |example|
    WebMock.disable!
    example.run
  ensure
    WebMock.enable!
  end

  it "measures the id a create returns for a non-ASCII Location" do
    m = ZzN3Location
    server = m::RawServer.new
    port = server.url.split(":").last.to_i
    out = ["ENV|ruby=#{RUBY_VERSION}|faraday=#{Faraday::VERSION}|net-http=#{Net::HTTP::VERSION}|create=admin.users.create",
           "HEADER|sdk|lane|case|field|value"]
    config = KeycloakSdk::Config.new(server_url: server.url, realm: m::REALM, client_id: "it-client",
                                     client_secret: "dummy-secret")
    m::CASES.each do |name, id|
      base = "#{server.url}#{m::USERS}/".b
      server.location = base + id
      probe = m.wire_probe(server.url, port)
      out << "WIRE|ruby|-|#{name}|location=<base>/admin/realms/it-realm/users/+[#{m.hex(id)}]" \
             "|raw_socket_read_equals_sent=#{probe == server.location}|id_bytes_on_wire=#{m.hex(probe.delete_prefix(base))}"
      client = begin
        resp = Faraday.new.post("#{server.url}#{m::USERS}")
        "status=#{resp.status}|headers['location'].after_last_slash=#{m.show(m.tail(resp.headers['location']))}"
      rescue StandardError => e
        "raised #{e.class}: #{e.message}"
      end
      out << "CLIENT|ruby|Faraday.new(net_http)|#{name}|#{client}"
      server.seen.clear
      result = begin
        kc = KeycloakSdk::KeycloakClient.new(config)
        "Ok(#{m.show(kc.admin.users.create({ "username" => "n3-user" }))})"
      rescue StandardError => e
        cause = e.cause ? " cause=#{e.cause.class}: #{e.cause.message}" : ""
        "Err(#{e.class}: #{e.message}#{cause})".tr("|", "/")
      ensure
        kc&.close
      end
      out << "ID|ruby|admin.users.create|#{name}|#{result}|requests=#{server.seen.join(',')}"
    end
    server.close
    File.write(ENV.fetch("N3_OUT"), "#{out.join("\n")}\n")
    expect(out.count { |l| l.start_with?("ID|") }).to eq(3)
  end
end
