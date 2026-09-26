# frozen_string_literal: true

require "net/http"
require "uri"

# 브라우저 없는 로그인 — 실제 Keycloak 로그인 폼을 HTTP 로 채워 인가 코드를 받는다
# (python `tests/integration/browser_login.py` 의 이식, 같은 세 걸음).
#
# 1. SDK 가 만든 인가 URL 을 GET 한다(로그인 페이지 + 인증 세션 쿠키 — 쿠키는 2 에서 직접 되싣는다).
# 2. `<form id="kc-form-login">` 의 `action` 에 사용자명·비밀번호를 POST 하되 **리다이렉트는 따라가지 않는다** —
#    redirect_uri 에는 아무것도 떠 있지 않다. 302 의 `Location` 이 곧 콜백이다(Net::HTTP 는 원래 안 따라간다).
# 3. `Location` 에서 `code`·`state` 를 꺼내고, `state` 가 SDK 가 발급한 값인지 확인한다.
#
# 폼을 못 찾거나 상태 코드가 틀리면 받은 HTML 앞부분을 실어 실패한다 — 테마가 바뀌었을 때 원인이 바로 보이게.
module BrowserLogin
  LOGIN_FORM_ID = "kc-form-login"
  # 속성 값의 문자 참조 — Keycloak 테마는 action URL 의 `&` 를 `&amp;` 로 낸다. `CGI.unescapeHTML` 대신 직접 푸는
  # 것은 CGI 가 Ruby 4.0 에서 줄었기 때문이다(`auth_client_spec.rb` 의 `CGI.parse` 사고와 같은 부류).
  ENTITIES = { "amp" => "&", "lt" => "<", "gt" => ">", "quot" => '"', "apos" => "'" }.freeze

  module_function

  # `request`(SDK 의 `create_authorization_request` 결과)로 로그인해 인가 코드를 돌려준다.
  def browser_login(request, redirect_uri, username, password)
    page = http_get(URI(request.url))
    fail_with("login page did not render", page) unless page.code == "200"
    action = login_form_action(page.body)
    fail_with("no <form id=\"#{LOGIN_FORM_ID}\"> in the login page", page) unless action

    # ⚠️ 쿠키 저장소에 맡기지 말고 **직접 되싣는다.** Keycloak 26 은 http 에서도 로그인 쿠키에 `Secure` 를 단다.
    # 브라우저는 localhost 를 안전한 출처로 봐서 보내지만, RFC 6265 대로 사는 저장소는 http 요청에 싣지 않아
    # POST 가 400 "Restart login cookie not found" 로 끝난다(python 파일럿 실측).
    answer = http_post_form(URI(action), { "username" => username, "password" => password }, cookie_header(page))
    fail_with("login POST did not redirect", answer) unless answer.code == "302"
    callback_code(answer["location"], request.state, redirect_uri)
  end

  def callback_code(location, sent_state, redirect_uri)
    query = callback_query(location, redirect_uri)
    # state 는 SDK 가 인가 URL 에 실은 CSRF 값이다 — 서버가 그대로 되돌려야 한다.
    returned = query["state"]
    fail_with("state mismatch: sent #{sent_state.inspect}, got #{returned.inspect}") if returned != [sent_state]
    codes = query.fetch("code", [])
    fail_with("no single authorization code in the callback: #{location}") unless codes.size == 1 && !codes[0].empty?
    codes[0]
  end

  # 콜백 URL 의 쿼리(이름 → 값 배열). 목적지가 redirect_uri 가 아니면 실패한다.
  def callback_query(location, redirect_uri)
    fail_with("login redirected somewhere else: #{location}") unless location.to_s.split("?", 2).first == redirect_uri
    URI.decode_www_form(URI(location).query.to_s).group_by(&:first).transform_values { |pairs| pairs.map(&:last) }
  end

  def login_form_action(html)
    html.to_s.scan(/<form\b[^>]*>/i).each do |tag|
      attrs = tag.scan(/([\w:-]+)\s*=\s*"([^"]*)"/).to_h { |name, value| [name.downcase, value] }
      return decode_entities(attrs["action"]) if attrs["id"] == LOGIN_FORM_ID && attrs["action"]
    end
    nil
  end

  def decode_entities(value)
    value.gsub(/&(#x\h+|#\d+|[a-z]+);/i) do
      ref = Regexp.last_match(1)
      if ref.start_with?("#x", "#X") then [ref[2..].hex].pack("U")
      elsif ref.start_with?("#") then [ref[1..].to_i].pack("U")
      else ENTITIES.fetch(ref, "&#{ref};")
      end
    end
  end

  # 응답이 준 `Set-Cookie` 의 name=value 만 모아 `Cookie` 헤더로 만든다(속성 — Secure·Path·SameSite — 은 버린다).
  def cookie_header(response)
    pairs = Array(response.get_fields("set-cookie")).to_h { |line| line.split(";", 2).first.strip.split("=", 2) }
    pairs.map { |name, value| "#{name}=#{value}" }.join("; ")
  end

  def http_get(uri)
    Net::HTTP.start(uri.host, uri.port, open_timeout: 30, read_timeout: 30) { |h| h.request(Net::HTTP::Get.new(uri)) }
  end

  def http_post_form(uri, form, cookie)
    post = Net::HTTP::Post.new(uri)
    post.set_form_data(form)
    post["Cookie"] = cookie
    Net::HTTP.start(uri.host, uri.port, open_timeout: 30, read_timeout: 30) { |h| h.request(post) }
  end

  # 받은 응답을 실어 실패한다. 3xx 는 본문이 비어 있으니 `Location` 도 싣는다 — Keycloak 은 인가 요청 오류
  # (예: PKCE 방식 불일치)를 redirect_uri 로의 302 + `error=` 로 알린다(실측: 로그인 페이지 대신 302).
  def fail_with(message, response = nil)
    if response
      message += ":\nHTTP #{response.code} #{response.uri}"
      message += "\nLocation: #{response['location']}" if response["location"]
      message += "\n#{response.body.to_s[0, 1500]}"
    end
    RSpec::Expectations.fail_with(message)
  end
end
