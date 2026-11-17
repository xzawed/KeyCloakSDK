using WireMock.Server;
using Xunit;

namespace Xzawed.Keycloak.Sdk.Tests;

/// <summary>
/// <see cref="AuthClient.CreateAuthorizationRequest"/> 는 URL 을 만들기 전에 redirect_uri 를 검사한다(등록부
/// <c>authz-request-redirect-unvalidated</c>). R1 — RFC 6749 §3.1.2 의 절대 URI(<c>^[A-Za-z][A-Za-z0-9+.-]*:</c> — null 도 여기다) ·
/// R2 — fragment 성분이 없다(빈 fragment <c>#</c> 도 성분이다) · R3 — Keycloak 이 받는 URI 문자열이다(RFC 3986 §2 — Keycloak 의
/// <c>RedirectUtils.toUri</c> 는 <c>java.net.URI.create</c> 가 던지면 어느 클라이언트 등록에서든 거부한다: U+0000–U+0020 ·
/// U+007F–U+00A0 · <c>" &lt; &gt; \ ^ ` { | }</c> · 뒤에 16진 두 자리가 없는 <c>%</c>). 순서는 R1 → R2 → R3 이고, 메시지는 셋 다
/// 고정 문구라 입력을 싣지 않는다.
/// </summary>
/// <remarks>검사만 하고 고치지 않는다 — URL 의 <c>redirect_uri</c> 는 호출자 문자열 그대로다. 코드 교환이 그 문자열을 그대로
/// 보내므로 두 요청 중 하나만 정규화하면 두 값이 갈린다(#1133). 고치기 전(2026-11-18 실측)에는 <c>cb</c> · <c>not a url</c> ·
/// <c>https://app/cb#f</c> 가 전부 URL 에 그대로 실렸다. 보이지 않는 문자는 코드값으로 받는다 — 소스와 테스트 이름에 두지 않는다.</remarks>
[Trait("Category", "Unit")]
public sealed class AuthClientRedirectUriTests : IDisposable
{
    private const string NotAbsolute = "invalid redirect_uri: not an absolute URI (RFC 6749 §3.1.2)";
    private const string Fragment = "invalid redirect_uri: a fragment is not allowed (RFC 6749 §3.1.2)";
    private const string NotUri = "invalid redirect_uri: not a valid URI (RFC 3986 §2)";

    // 기록하는 IdP — 이 메서드는 받는 값에도 거부한 값에도 요청을 내지 않는다. 호출마다 그것을 잰다(HostilePathMatrixTests 가
    // 이 행을 면제하는 근거다 — 그 행렬의 합성 문자열은 절대 URI 가 아니라 R1 에서 끝난다).
    private readonly WireMockServer _idp = WireMockServer.Start();
    private readonly KeycloakClient _kc;

    public AuthClientRedirectUriTests() =>
        _kc = KeycloakClient.Create(new KeycloakConfig { ServerUrl = _idp.Urls[0], Realm = "r", ClientId = "app" });

    public void Dispose()
    {
        _kc.Dispose();
        _idp.Dispose();
    }

    [Theory]
    [InlineData("")]
    [InlineData("cb")]
    [InlineData("/cb")]
    [InlineData("//app/cb")]
    [InlineData("not a url")]
    [InlineData("cb#f")]         // 순서 — R1 이 R2 보다 먼저다
    [InlineData("1app:/cb")]     // scheme 은 글자로 시작한다
    [InlineData("my_app:/cb")]   // '_' 는 scheme 문자가 아니다
    public void Relative_value_is_refused_as_not_absolute(string redirectUri) => AssertRefused(redirectUri, NotAbsolute);

    [Fact]
    public void Null_is_refused_as_not_absolute() => AssertRefused(null!, NotAbsolute);

    [Theory]
    [InlineData("https://app/cb#")]    // 빈 fragment 도 fragment 성분이다
    [InlineData("https://app/cb#f")]
    [InlineData("https://app/c b#f")]  // 순서 — R2 가 R3 보다 먼저다
    public void Fragment_is_refused(string redirectUri) => AssertRefused(redirectUri, Fragment);

    [Theory]
    [InlineData("https://app/c\"b")]
    [InlineData("https://app/c<b")]
    [InlineData("https://app/c>b")]
    [InlineData("https://app/c\\b")]   // 역슬래시 하나
    [InlineData("https://app/c^b")]
    [InlineData("https://app/c`b")]
    [InlineData("https://app/c{b")]
    [InlineData("https://app/c|b")]
    [InlineData("https://app/c}b")]
    [InlineData("https://app/c%zz")]
    [InlineData("https://app/c%2gb")]  // 둘째 자리만 16진이 아니다
    [InlineData("https://app/c%2")]    // 끝에서 잘린 퍼센트 인코딩
    [InlineData("https://app/c%")]
    public void Character_outside_uri_text_is_refused(string redirectUri) => AssertRefused(redirectUri, NotUri);

    /// <summary>R3 의 두 구간 경계와 대표값 — 그 문자를 <c>https://app/c</c> 와 <c>b</c> 사이에 한 번, <c>https://app/cb</c> 끝에
    /// 한 번(끝의 LF 가 여기다) 둔다.</summary>
    [Theory]
    [InlineData(0x00)]
    [InlineData(0x09)]
    [InlineData(0x0A)]
    [InlineData(0x1F)]
    [InlineData(0x20)]
    [InlineData(0x7F)]
    [InlineData(0x80)]
    [InlineData(0x9F)]
    [InlineData(0xA0)]   // NBSP
    public void Control_space_or_nbsp_is_refused(int codePoint)
    {
        var c = (char)codePoint;
        AssertRefused("https://app/c" + c + "b", NotUri);
        AssertRefused("https://app/cb" + c, NotUri);
    }

    [Fact]
    public void Refusal_does_not_echo_the_input()
    {
        foreach (var (value, message) in new[]
                 {
                     ("cb-CANARY-7d1f", NotAbsolute),
                     ("https://app/cb-CANARY-7d1f#f", Fragment),
                     ("https://app/cb-CANARY-7d1f b", NotUri),
                 })
        {
            var ex = Assert.Throws<KeycloakConfigException>(() => _kc.Auth.CreateAuthorizationRequest(value));
            Assert.Equal(message, ex.Message);
            Assert.DoesNotContain("CANARY", ex.ToString());
        }
        Assert.Empty(_idp.LogEntries);
    }

    // 대조군 — 받는 값은 URL 의 redirect_uri 에 호출자 문자열 그대로 실린다(복호한 값이 입력과 같다 — 고치지 않는다).
    [Theory]
    [InlineData("https://app/cb")]
    [InlineData("https://app/cb?x=1")]
    [InlineData("myapp:/cb")]
    [InlineData("com.example.app:/oauth2redirect")]
    [InlineData("HTTP://LOCALHOST/cb")]
    [InlineData("https://app/c%20b")]
    [InlineData("https://app/cb?x=[1]")]
    [InlineData("a+b-c.d:/cb")]        // scheme 의 + - .
    [InlineData("https://app/c%aFb")]  // 대소문자가 섞인 16진
    [InlineData("https://app/c~!b")]   // 금지 구간 바로 옆(U+007E · U+0021)
    public void Accepted_value_is_carried_verbatim(string redirectUri) => AssertCarried(redirectUri);

    [Theory]
    [InlineData(0xA1)]   // 금지 구간 바로 위
    [InlineData(0xFC)]   // ü
    public void Non_ascii_above_nbsp_is_carried_verbatim(int codePoint) =>
        AssertCarried("https://app/c" + (char)codePoint + "b");

    private void AssertRefused(string redirectUri, string message)
    {
        var ex = Assert.Throws<KeycloakConfigException>(() => _kc.Auth.CreateAuthorizationRequest(redirectUri));
        Assert.Equal(message, ex.Message);
        Assert.Null(ex.InnerException);
        Assert.Empty(_idp.LogEntries);
    }

    private void AssertCarried(string redirectUri)
    {
        var req = _kc.Auth.CreateAuthorizationRequest(redirectUri);
        Assert.Equal(redirectUri, QueryValue(req.Url, "redirect_uri"));
        Assert.Empty(_idp.LogEntries);
    }

    // URL 문자열의 쿼리에서 직접 읽는다 — System.Uri 의 정규화를 거치지 않는다.
    private static string? QueryValue(string url, string name)
    {
        foreach (var pair in url[(url.IndexOf('?') + 1)..].Split('&'))
        {
            var eq = pair.IndexOf('=');
            if (eq > 0 && pair[..eq] == name)
                return Uri.UnescapeDataString(pair[(eq + 1)..]);
        }
        return null;
    }
}
