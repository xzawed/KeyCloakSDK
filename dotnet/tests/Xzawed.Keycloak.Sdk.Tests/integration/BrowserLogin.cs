using System.Net;
using System.Text.RegularExpressions;
using System.Web;
using Xunit;
using Xunit.Sdk;
using Xzawed.Keycloak;

namespace Xzawed.Keycloak.Sdk.Tests.Integration;

/// <summary>
/// 브라우저 없는 로그인 — 실제 Keycloak 로그인 폼을 HTTP 로 채워 인가 코드를 받는다
/// (python <c>tests/integration/browser_login.py</c> 와 같은 세 걸음).
/// <list type="number">
/// <item>SDK 가 만든 인가 URL 을 GET 한다(로그인 페이지 + 인증 세션 쿠키 — 쿠키는 2 에서 직접 되싣는다).</item>
/// <item><c>&lt;form id="kc-form-login"&gt;</c> 의 <c>action</c> 에 사용자명·비밀번호를 POST 하되 <b>리다이렉트는
/// 따라가지 않는다</b> — redirect_uri 에는 아무것도 떠 있지 않다. 302 의 <c>Location</c> 이 곧 콜백이다.</item>
/// <item><c>Location</c> 에서 <c>code</c>·<c>state</c> 를 꺼내고, <c>state</c> 가 SDK 가 발급한 값인지 확인한다.</item>
/// </list>
/// 폼을 못 찾거나 상태 코드가 틀리면 받은 HTML 앞부분을 실어 실패한다 — 테마가 바뀌었을 때 원인이 바로 보이게.
/// </summary>
internal static partial class BrowserLogin
{
    private const string LoginFormId = "kc-form-login";

    /// <summary><paramref name="request"/>(SDK 의 <c>CreateAuthorizationRequest</c> 결과)로 로그인해 인가 코드를 돌려준다.</summary>
    public static async Task<string> LoginAsync(AuthorizationRequest request, string redirectUri, string username, string password)
    {
        // ⚠️ 쿠키 저장소(CookieContainer)에 맡기지 말고 **직접 되싣는다.** Keycloak 26 은 http 에서도 로그인 쿠키에
        // `Secure` 를 단다. 브라우저는 localhost 를 안전한 출처로 봐서 보내지만, RFC 6265 대로 사는 저장소는 http
        // 요청에 싣지 않아 POST 가 400 "Restart login cookie not found" 로 끝난다(python 파일럿 실측).
        using var handler = new HttpClientHandler { AllowAutoRedirect = false, UseCookies = false };
        using var browser = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(30) };

        using var page = await browser.GetAsync(request.Url);
        var html = await page.Content.ReadAsStringAsync();
        if (page.StatusCode != HttpStatusCode.OK)
            throw FailException.ForFailure($"login page did not render:\n{Snippet(page, html)}");
        var action = FormAction(html)
            ?? throw FailException.ForFailure($"no <form id=\"{LoginFormId}\"> in the login page:\n{Snippet(page, html)}");
        var cookie = string.Join("; ", page.Headers.TryGetValues("Set-Cookie", out var setCookies)
            ? setCookies.Select(c => c.Split(';', 2)[0])
            : Enumerable.Empty<string>());

        using var post = new HttpRequestMessage(HttpMethod.Post, action)
        {
            Content = new FormUrlEncodedContent(new Dictionary<string, string>
            {
                ["username"] = username,
                ["password"] = password,
            }),
        };
        post.Headers.Add("Cookie", cookie);
        using var answer = await browser.SendAsync(post);
        if (answer.StatusCode != HttpStatusCode.Found)
            throw FailException.ForFailure($"login POST did not redirect:\n{Snippet(answer, await answer.Content.ReadAsStringAsync())}");

        var location = answer.Headers.Location;
        if (location is null || !location.IsAbsoluteUri || location.GetLeftPart(UriPartial.Path) != redirectUri)
            throw FailException.ForFailure($"login redirected somewhere else: {location}");
        var query = HttpUtility.ParseQueryString(location.Query);
        // state 는 SDK 가 인가 URL 에 실은 CSRF 값이다 — 서버가 그대로 되돌려야 한다.
        var states = query.GetValues("state") ?? Array.Empty<string>();
        if (states is not [var state] || state != request.State)
            throw FailException.ForFailure($"state mismatch: sent {request.State}, got [{string.Join(", ", states)}]");
        if (query.GetValues("code") is [var code] && !string.IsNullOrEmpty(code))
            return code;
        throw FailException.ForFailure($"no single authorization code in the callback: {location}");
    }

    /// <summary>인가 URL 에서 <c>nonce</c> 만 뺀다 — 서버가 nonce 클레임 <b>없는</b> id_token 을 서명하게 한다.</summary>
    public static AuthorizationRequest StripNonce(AuthorizationRequest request)
    {
        var url = new Uri(request.Url);
        var kept = url.Query.TrimStart('?').Split('&')
            .Where(pair => pair.Length > 0 && pair.Split('=', 2)[0] != "nonce");
        var stripped = new UriBuilder(url) { Query = string.Join("&", kept) }.Uri.AbsoluteUri;
        Assert.DoesNotContain("nonce=", stripped);
        return request with { Url = stripped };
    }

    /// <summary><c>&lt;form id="kc-form-login"&gt;</c> 의 action(속성 값의 <c>&amp;amp;</c> 는 푼다). 속성 순서는 가리지 않는다.</summary>
    private static string? FormAction(string html)
    {
        foreach (Match form in FormTag().Matches(html))
        {
            var attributes = Attribute().Matches(form.Value)
                .GroupBy(a => a.Groups["name"].Value.ToLowerInvariant())
                .ToDictionary(g => g.Key, g => WebUtility.HtmlDecode(g.First().Groups["value"].Value));
            if (attributes.TryGetValue("id", out var id) && id == LoginFormId)
                return attributes.GetValueOrDefault("action");
        }
        return null;
    }

    private static string Snippet(HttpResponseMessage response, string body) =>
        $"HTTP {(int)response.StatusCode} {response.RequestMessage?.RequestUri}\n{body[..Math.Min(body.Length, 1500)]}";

    [GeneratedRegex("<form\\b[^>]*>", RegexOptions.IgnoreCase)]
    private static partial Regex FormTag();

    [GeneratedRegex("(?<name>[A-Za-z_:][-A-Za-z0-9_:.]*)\\s*=\\s*\"(?<value>[^\"]*)\"")]
    private static partial Regex Attribute();
}
