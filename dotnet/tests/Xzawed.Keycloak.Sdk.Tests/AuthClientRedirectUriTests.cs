using WireMock.Server;
using Xunit;

namespace Xzawed.Keycloak.Sdk.Tests;

/// <summary>
/// <see cref="AuthClient.CreateAuthorizationRequest"/> 는 URL 을 만들기 전에 redirect_uri 를 검사한다(등록부
/// <c>authz-request-redirect-unvalidated</c>). R1 — RFC 6749 §3.1.2 의 절대 URI(<c>^[A-Za-z][A-Za-z0-9+.-]*:</c> — null 도 여기다) ·
/// R2 — fragment 성분이 없다(빈 fragment <c>#</c> 도 성분이다) · R3 — Keycloak 이 받는 URI 문자열이다(RFC 3986 §2 — Keycloak 의
/// <c>RedirectUtils.toUri</c> 는 <c>java.net.URI.create</c> 가 던지면 어느 클라이언트 등록에서든 거부한다: U+0000–U+0020 ·
/// U+007F–U+00A0 · 그 위의 Unicode 공백 구분자 열일곱 · <c>" &lt; &gt; \ ^ ` { | }</c> · 뒤에 16진 두 자리가 없는 <c>%</c> — 그리고 짝
/// 없는 서로게이트, Duende 가 U+FFFD 로 바꿔 쓰는 것). 순서는 R1 → R2 → R3 이고, 메시지는 셋 다
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

    /// <summary>R3 — U+00A0 위의 Unicode 공백 구분자: java.net.URI 가 거부하는 바로 그 열일곱(JDK 21.0.8 실측 — U+1680 ·
    /// U+2000–U+200A · U+2028 · U+2029 · U+202F · U+205F · U+3000). 코드값으로 잇는다(가운데 · 끝).</summary>
    [Theory]
    [InlineData(0x1680)]
    [InlineData(0x2000)]
    [InlineData(0x2001)]
    [InlineData(0x2002)]
    [InlineData(0x2003)]
    [InlineData(0x2004)]
    [InlineData(0x2005)]
    [InlineData(0x2006)]
    [InlineData(0x2007)]
    [InlineData(0x2008)]
    [InlineData(0x2009)]
    [InlineData(0x200A)]
    [InlineData(0x2028)]
    [InlineData(0x2029)]
    [InlineData(0x202F)]
    [InlineData(0x205F)]
    [InlineData(0x3000)]
    public void Unicode_space_separator_is_refused(int codePoint)
    {
        var c = (char)codePoint;
        AssertRefused("https://app/c" + c + "b", NotUri);
        AssertRefused("https://app/cb" + c, NotUri);
    }

    // 대조군 — 그 열일곱의 바로 옆(같은 측정에서 java.net.URI 가 받는다): 구간마다 아래 · 위.
    [Theory]
    [InlineData(0x167F)]
    [InlineData(0x1681)]
    [InlineData(0x1FFF)]
    [InlineData(0x200B)]
    [InlineData(0x2027)]
    [InlineData(0x202A)]
    [InlineData(0x202E)]
    [InlineData(0x2030)]
    [InlineData(0x205E)]
    [InlineData(0x2060)]
    [InlineData(0x2FFF)]
    [InlineData(0x3001)]
    public void Neighbour_of_a_space_separator_is_carried_verbatim(int codePoint) =>
        AssertCarried("https://app/c" + (char)codePoint + "b");

    // R4 — R3 를 지나도 Keycloak 의 java.net.URI.create 가 거부하는 모양(등록부 redirect-uri-r3-narrower-than-keycloak). 표는 JDK
    // 21.0.8 로 잰 거부 그대로다: scheme 뒤가 빈 값("Expected scheme-specific part") · 괄호 호스트 하나 밖의 [ ](경로 · 호스트 이름 ·
    // 사용자 정보 · 포트 자리 · 빈 괄호 · 괄호 안의 괄호). 문구는 R3 와 같다.
    [Theory]
    [InlineData("https:")]
    [InlineData("myapp:")]
    [InlineData("https://app/c[b")]
    [InlineData("https://app/c]b")]
    [InlineData("myapp:/c[b")]
    [InlineData("https://[::1]/c[b")]
    [InlineData("https://app[1]/cb")]
    [InlineData("https://[::1]]/cb")]
    [InlineData("myapp://a]b")]
    [InlineData("https://[::1]:x/cb")]
    [InlineData("https://u[@h/cb")]
    [InlineData("https://a]b@[::1]/cb")]
    [InlineData("https://a@b@[::1]/cb")]
    [InlineData("https://[]/cb")]
    [InlineData("https://[a[b]/cb")]
    [InlineData("https://app/c[b?x")]
    [InlineData("https://u@[::1]/c]b")]
    [InlineData("https://[::1/cb")]   // "Expected closing bracket for IPv6 address"
    public void Shape_java_net_uri_refuses_is_refused(string redirectUri) => AssertRefused(redirectUri, NotUri);

    // 대조군 — 같은 측정에서 java.net.URI 가 받는 값: 괄호 호스트 하나(사용자 정보 · 포트 · 빈 포트와 함께) · 불투명한 값과 쿼리의 괄호 ·
    // scheme 뒤 / 하나.
    [Theory]
    [InlineData("https://[::1]/cb")]
    [InlineData("https://[::1]:8443/cb")]
    [InlineData("https://u@[::1]:8443/cb")]
    [InlineData("myapp:c[b")]
    [InlineData("urn:x[y]")]
    [InlineData("https:/")]
    [InlineData("myapp://[::1]")]
    [InlineData("myapp://[::1]:8443")]
    [InlineData("https://[::1]:/cb")]
    [InlineData("https://[::1]?x=[1]")]
    [InlineData("myapp:///cb")]    // R4c 의 이웃 — "//" 뒤에 경로 · 쿼리가 있다
    [InlineData("myapp://?x=1")]
    public void Shape_java_net_uri_accepts_is_carried_verbatim(string redirectUri) => AssertCarried(redirectUri);

    // 순서 — 앞 규칙에도 걸리는 값은 앞 규칙의 문구다(R3 와 R4 는 문구가 같아 문구만 본다).
    [Theory]
    [InlineData("c[b", NotAbsolute)]
    [InlineData("https://app/c[b#f", Fragment)]
    [InlineData("https://app/c[b c", NotUri)]
    public void An_earlier_rule_answers_first(string redirectUri, string message) => AssertRefused(redirectUri, message);

    // 예전의 잔여(등록부 redirect-uri-create-residuals) — Keycloak 의 java.net.URI 가 거부하는데(JDK 21.0.8 실측: "Expected authority" ·
    // 괄호 안의 값 — "Malformed IPv6 address") R4 가 받던 값. 이제 R4c(scheme 의 ':' 뒤가 "//" 뿐)와 R4d(괄호 안이 IPv6 리터럴이 아니다)가
    // 거부한다.
    [Theory]
    [InlineData("https://")]
    [InlineData("myapp://")]
    [InlineData("https://[zz]/cb")]
    [InlineData("https://[v1.x]/cb")]
    public void Former_residual_is_refused(string redirectUri) => AssertRefused(redirectUri, NotUri);

    /// <summary>R4c–R4e 의 표 — Keycloak 의 <c>RedirectUtils.toUri</c>(<c>java.net.URI.create</c>)가 각 값에 내린 판정(JDK 21.0.8 실측,
    /// 등록부 redirect-uri-create-residuals 의 벡터 표 83 행 그대로; true = 받음). 받는 행은 URL 에 그대로 실리고, 거부 행은 R3/R4
    /// 문구다 — <see cref="ZoneIdPercentNotWrittenAs25"/> 셋만 빼고(의도한 차이).</summary>
    public static TheoryData<string, bool> UriCreateVectors => new()
    {
        { "https://", false },
        { "myapp://", false },
        { "https:///", true },
        { "https:///cb", true },
        { "https://?x=1", true },
        { "https://u@/cb", true },
        { "https://:80/cb", true },
        { "https://@/cb", true },
        { "https:/", true },
        { "https://[::1]/cb", true },
        { "https://[zz]/cb", false },
        { "https://[v1.x]/cb", false },
        { "https://[::1::2]/cb", false },
        { "https://[1:2:3:4:5:6:7:8:9]/cb", false },
        { "https://[1:2:3:4:5:6:7:8]/cb", true },
        { "https://[1:2:3:4:5:6:7::]/cb", true },
        { "https://[::1:2:3:4:5:6:7]/cb", true },
        { "https://[1:2:3:4:5:6:7:8::]/cb", false },
        { "https://[::1:2:3:4:5:6:7:8]/cb", false },
        { "https://[1:2:3:4:5:6:7]/cb", false },
        { "https://[::]/cb", true },
        { "https://[:]/cb", false },
        { "https://[:::]/cb", false },
        { "https://[1:::2]/cb", false },
        { "https://[::1:]/cb", false },
        { "https://[:1::2]/cb", false },
        { "https://[1::2:]/cb", false },
        { "https://[12345::]/cb", false },
        { "https://[ABCD::EF]/cb", true },
        { "https://[abcd:EF01::]/cb", true },
        { "https://[0001:2:3:4:5:6:7:8]/cb", true },
        { "https://[::ffff:1.2.3.4]/cb", true },
        { "https://[::1.2.3.4]/cb", true },
        { "https://[1.2.3.4]/cb", false },
        { "https://[::ffff:01.2.3.4]/cb", true },
        { "https://[::ffff:0001.2.3.4]/cb", true },
        { "https://[::ffff:00000000255.2.3.4]/cb", true },
        { "https://[::ffff:256.2.3.4]/cb", false },
        { "https://[::ffff:1.2.3]/cb", false },
        { "https://[::ffff:1.2.3.4.5]/cb", false },
        { "https://[::ffff:1.2.3.]/cb", false },
        { "https://[::ffff:.1.2.3]/cb", false },
        { "https://[::ffff:1..2.3]/cb", false },
        { "https://[1:2:3:4:5:6:1.2.3.4]/cb", true },
        { "https://[1:2:3:4:5:6:7:1.2.3.4]/cb", false },
        { "https://[1:2:3:4:5:1.2.3.4]/cb", false },
        { "https://[1::1.2.3.4]/cb", true },
        { "https://[1:2:3:4:5::1.2.3.4]/cb", true },
        { "https://[1:2:3:4:5:6::1.2.3.4]/cb", false },
        { "https://[::1.2.3.4:5]/cb", false },
        { "https://[1.2.3.4::]/cb", false },
        { "https://[::99999999999.2.3.4]/cb", false },
        { "https://[::1.2.3.9999999999999]/cb", false },
        { "https://[fe80::1%eth0]/cb", true },
        { "https://[fe80::1%25eth0]/cb", true },
        { "https://[fe80::1%25]/cb", true },
        { "https://[fe80::1%]/cb", false },
        { "https://[fe80::1%25en-1]/cb", false },
        { "https://[fe80::1%25a_b.c]/cb", true },
        { "https://[fe80::1%25a%25b]/cb", false },
        { "https://[fe80::1%25a~b]/cb", false },
        { "https://[fe80::1%25é]/cb", false },
        { "https://[%25::1]/cb", false },
        { "https://[::1%1]/cb", true },
        { "https://[::1%zz]/cb", true },
        { "https://[::1]:/cb", true },
        { "https://[::1]:8443/cb", true },
        { "https://[::1]:2147483647/cb", true },
        { "https://[::1]:2147483648/cb", false },
        { "https://[::1]:00000000000000000080/cb", true },
        { "https://[::1]:99999999999/cb", false },
        { "https://h:99999999999/cb", true },
        { "https://u@[::1]:8443/cb", true },
        { "https://u:p@[::1]/cb", true },
        { "https://a@b@[::1]/cb", false },
        { "https://[::1]", true },
        { "https://[::1]?x=[1]", true },
        { "myapp://[::1]/cb", true },
        { "myapp://[zz]/cb", false },
        { "https://my_host/cb", true },
        { "https://999.1.1.1/cb", true },
        { "https://host:abc/cb", true },
        { "https://hé/cb", true },
    };

    // 의도한 차이(유지한다) — zone id 안에서도 뒤에 16진 두 자리가 없는 '%' 는 R3 가 거부한다. URI.create 는 받지만(표의 받는 행), RFC 6874
    // §2 가 URI 안의 zone id 앞 '%' 를 "%25" 로 쓰게 한다 — 그렇게 쓴 값은 둘 다 받는다.
    private static readonly string[] ZoneIdPercentNotWrittenAs25 =
        { "https://[fe80::1%eth0]/cb", "https://[::1%1]/cb", "https://[::1%zz]/cb" };

    [Theory]
    [MemberData(nameof(UriCreateVectors))]
    public void Uri_create_vector_is_judged_as_keycloak_judges_it(string redirectUri, bool uriCreateAccepts)
    {
        if (uriCreateAccepts && Array.IndexOf(ZoneIdPercentNotWrittenAs25, redirectUri) < 0)
            AssertCarried(redirectUri);
        else
            AssertRefused(redirectUri, NotUri);
    }

    [Fact]
    public void Zone_id_percent_not_written_as_25_is_refused_although_uri_create_accepts_it()
    {
        foreach (var redirectUri in ZoneIdPercentNotWrittenAs25)
        {
            Assert.Contains(UriCreateVectors, row => (string)row[0] == redirectUri && (bool)row[1]);
            AssertRefused(redirectUri, NotUri);
        }
        AssertCarried("https://[fe80::1%25eth0]/cb");   // RFC 6874 §2 대로 쓴 값
        AssertCarried("https://[::1%251]/cb");
    }

    /// <summary>R3 — 짝 없는 서로게이트(뒤에 낮은 것이 없는 높은 것 · 앞에 높은 것이 없는 낮은 것). 고치기 전에는 Duende 의 인코더가
    /// 그것을 U+FFFD 로 바꿔 썼다(실측 <c>…c%EF%BF%BDb</c>) — 값을 고친 것이다. 코드 단위로 잇는다(가운데 · 끝).</summary>
    [Theory]
    [InlineData(0xD800)]
    [InlineData(0xDBFF)]
    [InlineData(0xDC00)]
    [InlineData(0xDFFF)]
    public void Unpaired_surrogate_is_refused(int codeUnit)
    {
        var s = (char)codeUnit;
        AssertRefused("https://app/c" + s + "b", NotUri);
        AssertRefused("https://app/cb" + s, NotUri);
    }

    [Fact]
    public void Surrogates_out_of_order_are_refused()
    {
        AssertRefused("https://app/c" + (char)0xDC00 + (char)0xD800 + "b", NotUri);               // 낮은 것이 먼저
        AssertRefused("https://app/c" + (char)0xD800 + (char)0xD800 + (char)0xDC00 + "b", NotUri);  // 높은 것 둘 — 첫째는 짝이 없다
    }

    // 대조군 — 짝을 이룬 아스트랄 문자(U+1F600)는 한 문자다: 가운데 · 끝 · 둘 잇따라.
    [Fact]
    public void Paired_astral_character_is_carried_verbatim()
    {
        var pair = char.ConvertFromUtf32(0x1F600);
        AssertCarried("https://app/c" + pair + "b");
        AssertCarried("https://app/cb" + pair);
        AssertCarried("https://app/c" + pair + pair + "b");
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
