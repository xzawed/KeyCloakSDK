# frozen_string_literal: true

require "open3"
require "net/http"
require "uri"

# Docker CLI 셸아웃으로 실제 Keycloak 26.6을 기동한다.
# (testcontainers-ruby는 stale 0.2.0 + docker-api가 Windows npipe 미지원 → PHP 동형 셸아웃.)
class KeycloakContainer
  IMAGE = "quay.io/keycloak/keycloak:26.6"
  attr_reader :base_url

  def initialize(fixtures_dir:)
    @fixtures_dir = fixtures_dir
    @name = "kc-ruby-it-#{Process.pid}-#{rand(10_000)}"
  end

  def start
    run!("docker", "run", "-d", "--name", @name, "-p", "8080",
         "-e", "KEYCLOAK_ADMIN=admin", "-e", "KEYCLOAK_ADMIN_PASSWORD=admin",
         "-v", "#{docker_path(@fixtures_dir)}:/opt/keycloak/data/import:ro",
         IMAGE, "start-dev", "--import-realm")
    @base_url = "http://localhost:#{discover_port}"
    wait_ready!
    @base_url
  end

  def stop
    system("docker", "rm", "-f", @name, out: File::NULL, err: File::NULL)
  end

  private

  def discover_port
    out, _e, _s = Open3.capture3("docker", "port", @name, "8080/tcp")
    out[/:(\d+)\s*\z/, 1] or raise "could not discover mapped port: #{out.inspect}"
  end

  def wait_ready!(timeout: 120)
    deadline = Time.now + timeout
    uri = URI("#{@base_url}/realms/master")
    loop do
      raise "Keycloak did not become ready within #{timeout}s" if Time.now > deadline

      begin
        return if Net::HTTP.get_response(uri).is_a?(Net::HTTPSuccess)
      rescue StandardError
        # not up yet
      end
      sleep 2
    end
  end

  def run!(*cmd)
    out, err, status = Open3.capture3(*cmd)
    raise "command failed (#{status.exitstatus}): #{cmd.join(' ')}\n#{err}#{out}" unless status.success?

    out
  end

  # Git Bash(Windows) 경로를 Docker Desktop가 수용하는 형태로 변환.
  # /d/... 형태는 그대로 두고, C:\ 형태만 //c/ 로 변환(대개 절대경로가 이미 unix 형태).
  def docker_path(path)
    path.tr("\\", "/").sub(%r{\A([A-Za-z]):/}) { "//#{Regexp.last_match(1).downcase}/" }
  end
end
