using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using Microsoft.IdentityModel.Tokens;
using WireMock.RequestBuilders;
using WireMock.ResponseBuilders;
using WireMock.Server;
using Xunit;
using Xunit.Abstractions;

namespace Xzawed.Keycloak.Sdk.Tests;

/// <summary>
/// 형식이 틀리거나 적대적인 토큰·introspect 응답에서 난 SDK 오류가 <b>그 응답의 비밀을 찍지 않는다</b> — Node #603 과
/// 같은 부류의 .NET 측정. 인쇄 경로는 <c>exception.ToString()</c>(InnerException 사슬과 스택 포함)·사슬 전부의
/// <c>Message</c>·공개 속성 <c>OAuthError</c> 셋이다(로거는 앞의 둘을, 구조화 로거는 속성도 찍는다).
/// </summary>
/// <remarks>
/// <para>실측(2026-09-26, 수정 전): (1) 본문이 <c>t</c>·<c>f</c>·<c>n</c> 으로 시작하면 <c>System.Text.Json</c> 의
/// <c>JsonReaderException</c> 이 <b>첫 JSON 구분자까지의 본문 전부</b>를 인용했고(폼 인코딩 본문
/// <c>token_type=bearer&amp;access_token=…</c> 이면 살아 있는 토큰째), SDK 는 그 예외를 InnerException 으로 그대로
/// 달았다. id_token 의 헤더·페이로드가 JSON 이 아니면 IdentityModel 이 PII 를 가린 자기 메시지 <b>밑에</b> 같은
/// 예외를 달아 디코드된 내용이 찍혔다. (2) <c>HttpRequestException</c>(<c>InvalidResponse</c>)이 잘못된 헤더 줄·이름을
/// 인용했고(청크 길이 줄은 16진), Logout 은 그 메시지를 SDK 메시지에 복사했다. (3) SDK 가 서버의 reason phrase 와
/// 문자열이 아닌 <c>error</c> 멤버(Duende 가 원문 JSON 으로 바꾼다)를 메시지·<c>OAuthError</c> 에 실었다.
/// (4) JSON 루트가 객체가 아니면 <c>InvalidOperationException</c> 이 SDK 타입으로 번역되지 않고 샜다(§4).</para>
/// <para>⚠️ 흐름 검사가 먼저다 — 변형마다 호출이 기대한 SDK 타입으로 실패했는지(또는 기대대로 성공했는지)를 본다.
/// 가짜 IdP 가 변형을 안 내면 아래 누출 검사는 없는 것을 찾으며 통과한다.</para>
/// <para>변이 실측(2026-09-26) — 수정의 어느 조각을 무엇이 잡는가: 생성자 정화 제거 → a3·a4·g1~g3·걷기·ErrorsTests ·
/// <c>WithholdAll</c> 제거 → g5 · 서버 reason phrase → g4 · 원문 <c>error</c> → e3·e8 · introspect catch 제거 → d7·d8·e9·h ·
/// Logout 메시지 복사 → g1·g2 · <c>InvalidResponse</c> 규칙 제거 → g1~g3 · 변형이 SDK 에 안 닿음 → 흐름 검사.
/// ⚠️ <c>JwtValidator</c> 의 <c>catch</c> 쪽 <c>MessageOf</c> 는 SILENT 다 — IdentityModel 8 은 실패를(검증 대리자가 던진
/// 것까지) <c>result.Exception</c> 으로 돌려줘 그 catch 에 닿는 입력을 못 찾았다. <c>result</c> 쪽은
/// <c>JwtValidatorTests</c> 의 이음매 테스트가 잡는다.</para>
/// </remarks>
[Trait("Category", "Unit")]
public sealed class MalformedTokenResponseTests
{
    private const string Oidc = "/realms/r/protocol/openid-connect";
    private static readonly Type Auth = typeof(KeycloakAuthException);
    private static readonly Type Transport = typeof(KeycloakTransportException);

    /// <summary>
    /// 알려진 누출 — <c>"변형|경로"</c>(경로: <c>ToString()</c>·<c>Message</c>·<c>OAuthError</c>). ⚠️ 더 안 새면 <b>여기서
    /// 지워야 통과한다</b>(낡은 항목 검사). 둘 다 <b>계약</b>이다 — OAuth <c>error</c> 코드는 디버깅 정보로 그대로
    /// 넘기기로 한 값이고, RFC 6749 §5.2 문법(<c>%x20-21 / %x23-5B / %x5D-7E</c>)이 토큰 문자를 전부 허용해 SDK 가
    /// 코드와 토큰을 가를 수 없다. 서버가 코드 자리에 토큰을 넣는 경우만 여기 걸린다.
    /// </summary>
    private static readonly Dictionary<string, string> KnownLeaks = new(StringComparer.Ordinal)
    {
        ["e4 400 error string echo|ToString()"] = "OAuth error 코드는 계약상 그대로 싣는다 — 문자열 코드와 토큰을 가를 문법이 없다",
        ["e4 400 error string echo|Message"] = "OAuth error 코드는 계약상 그대로 싣는다 — 문자열 코드와 토큰을 가를 문법이 없다",
        ["e4 400 error string echo|OAuthError"] = "OAuth error 코드는 계약상 그대로 싣는다 — 문자열 코드와 토큰을 가를 문법이 없다",
        ["e7 500 JSON error echo|OAuthError"] = "OAuth error 코드는 계약상 그대로 싣는다 — 문자열 코드와 토큰을 가를 문법이 없다",
    };

    /// <summary>토큰 엔드포인트 변형 — 같은 본문을 introspect 엔드포인트도 낸다.</summary>
    /// <param name="Token">토큰 호출들의 기대 결과(<c>null</c> 은 성공). nonce 를 준 code 교환은 토큰이 성공해도
    /// id_token 검사에서 실패하므로 <c>Token ?? Auth</c> 다.</param>
    /// <param name="Encoded">원문이 아니라 변환된 꼴로만 찍히는 카나리아 — 전체 일치만 본다(10자 접두는 흔하다).</param>
    private sealed record Variant(string Name, int Status, string ContentType, string Body, string[] Canaries,
                                  Type? Token, Type? Introspect, string[]? Encoded = null);

    private static string Long(string canary) => canary + new string('x', 200);

    private static string B64(string s) => Base64UrlEncoder.Encode(s);

    private static readonly Variant[] Variants =
    {
        // (a) id_token 이 JWT 가 아니다 — 토큰 호출은 id_token 을 안 보므로 성공, nonce 교환만 실패한다.
        new("a id_token not a JWT", 200, "application/json",
            """{"access_token":"LK-A-AT-01-canary","token_type":"Bearer","expires_in":300,"refresh_token":"LK-A-RT-01-canary","id_token":"LK-A-ID-01-canary"}""",
            new[] { "LK-A-AT-01-canary", "LK-A-RT-01-canary", "LK-A-ID-01-canary" }, null, null),
        new("a2 id_token JWT-shaped garbage", 200, "application/json",
            """{"access_token":"LK-A2-AT-1-canary","token_type":"Bearer","expires_in":300,"refresh_token":"LK-A2-RT-1-canary","id_token":"LK-A2-ID-1-canary.LK-A2-PL-1-canary.LK-A2-SG-1-canary"}""",
            new[] { "LK-A2-AT-1-canary", "LK-A2-RT-1-canary", "LK-A2-ID-1-canary", "LK-A2-PL-1-canary", "LK-A2-SG-1-canary" }, null, null),
        new("a3 id_token header decodes to non-JSON", 200, "application/json",
            $$"""{"access_token":"LK-A3-AT-1-canary","token_type":"Bearer","expires_in":300,"refresh_token":"LK-A3-RT-1-canary","id_token":"{{B64("tLK-A3-HDR-1-canary")}}.{{B64("tLK-A3-PAY-1-canary")}}.c2ln"}""",
            new[] { "LK-A3-AT-1-canary", "LK-A3-RT-1-canary", "tLK-A3-HDR-1-canary", "tLK-A3-PAY-1-canary" }, null, null),
        new("a4 id_token payload decodes to non-JSON", 200, "application/json",
            $$"""{"access_token":"LK-A4-AT-1-canary","token_type":"Bearer","expires_in":300,"refresh_token":"LK-A4-RT-1-canary","id_token":"{{B64("""{"alg":"RS256","kid":"k1"}""")}}.{{B64("fLK-A4-PAY-1-canary")}}.c2ln"}""",
            new[] { "LK-A4-AT-1-canary", "LK-A4-RT-1-canary", "fLK-A4-PAY-1-canary" }, null, null),
        // (b) access_token 이 문자열이 아니다 — refresh/id 토큰은 카나리아다.
        new("b access_token number", 200, "application/json",
            """{"access_token":12345,"token_type":"Bearer","expires_in":300,"refresh_token":"LK-B-RT-01-canary","id_token":"LK-B-ID-01-canary"}""",
            new[] { "LK-B-RT-01-canary", "LK-B-ID-01-canary" }, Auth, null),
        new("b2 access_token object", 200, "application/json",
            """{"access_token":{"t":"LK-B2-AT-1-canary"},"token_type":"Bearer","expires_in":300,"refresh_token":"LK-B2-RT-1-canary"}""",
            new[] { "LK-B2-AT-1-canary", "LK-B2-RT-1-canary" }, Auth, null),
        // (c) expires_in·token_type 의 타입이 틀렸다 — ⚠️ .NET 은 이것을 **성공**으로 받는다(Duende 가 강제변환:
        // expires_in → 0 이라 ExpiresAt 미상 = 만료로 취급, token_type 5 → "5"). 누출 검사는 반환값의 표현에 건다.
        new("c expires_in string", 200, "application/json",
            """{"access_token":"LK-C-AT-01-canary","token_type":"Bearer","expires_in":"x","refresh_token":"LK-C-RT-01-canary"}""",
            new[] { "LK-C-AT-01-canary", "LK-C-RT-01-canary" }, null, null),
        new("c2 token_type number", 200, "application/json",
            """{"access_token":"LK-C2-AT-1-canary","token_type":5,"expires_in":300,"refresh_token":"LK-C2-RT-1-canary"}""",
            new[] { "LK-C2-AT-1-canary", "LK-C2-RT-1-canary" }, null, null),
        new("c3 expires_in object", 200, "application/json",
            """{"access_token":"LK-C3-AT-1-canary","token_type":"Bearer","expires_in":{"v":"LK-C3-EX-1-canary"},"refresh_token":"LK-C3-RT-1-canary"}""",
            new[] { "LK-C3-AT-1-canary", "LK-C3-RT-1-canary", "LK-C3-EX-1-canary" }, null, null),
        // (d) 200 인데 본문이 JSON 이 아니다 — 분류는 기존대로 전송 오류다(Duende 가 파싱 실패를 ErrorType.Exception 으로 낸다).
        new("d non-JSON short", 200, "application/json", "LK-D-BODY-01", new[] { "LK-D-BODY-01" }, Transport, Transport),
        new("d2 non-JSON long", 200, "application/json", Long("LK-D2-BODY-canary"), new[] { "LK-D2-BODY-canary" }, Transport, Transport),
        new("d3 non-JSON t-literal short", 200, "application/json", "tLK-D3-BODY-can", new[] { "tLK-D3-BODY-can" }, Transport, Transport),
        new("d3b non-JSON t-literal long", 200, "application/json", Long("tLK-D3B-BODY-canary"), new[] { "tLK-D3B-BODY-canary" }, Transport, Transport),
        new("d3c non-JSON f-literal", 200, "application/json", "fLK-D3C-BODY-canary.eyJ.sig", new[] { "fLK-D3C-BODY-canary" }, Transport, Transport),
        new("d3d form-encoded body", 200, "application/x-www-form-urlencoded", "token_type=bearer&access_token=LK-D3D-AT-1-canary",
            new[] { "LK-D3D-AT-1-canary" }, Transport, Transport),
        new("d4 non-JSON n-literal", 200, "application/json", "nLK-D4-BODY-canary", new[] { "nLK-D4-BODY-canary" }, Transport, Transport),
        new("d5 unterminated string", 200, "application/json", "\"LK-D5-BODY-canary", new[] { "LK-D5-BODY-canary" }, Transport, Transport),
        new("d6 number prefix", 200, "application/json", "123LK-D6-BODY-canary", new[] { "123LK-D6-BODY-canary" }, Transport, Transport),
        new("d9 html body", 200, "text/html", "<html>LK-D9-BODY-canary</html>", new[] { "LK-D9-BODY-canary" }, Transport, Transport),
        // JSON 이지만 루트가 객체가 아니다 — 수정 전에는 InvalidOperationException 이 그대로 샜다(§4).
        new("d7 JSON string root", 200, "application/json", "\"LK-D7-BODY-canary\"", new[] { "LK-D7-BODY-canary" }, Auth, Auth),
        new("d8 JSON array root", 200, "application/json", """["LK-D8-BODY-canary"]""", new[] { "LK-D8-BODY-canary" }, Auth, Auth),
        // (e) 4xx/5xx 오류 본문이 토큰을 되울린다.
        new("e 400 error_description echo", 400, "application/json",
            """{"error":"invalid_grant","error_description":"bad token LK-E-DESC-1-canary"}""", new[] { "LK-E-DESC-1-canary" }, Auth, Auth),
        new("e2 401 error_description echo", 401, "application/json",
            """{"error":"invalid_client","error_description":"bad token LK-E2-DSC-1-canary"}""", new[] { "LK-E2-DSC-1-canary" }, Auth, Auth),
        new("e3 400 error object echo", 400, "application/json",
            """{"error":{"code":"invalid_grant","token":"LK-E3-ERR-1-canary"}}""", new[] { "LK-E3-ERR-1-canary" }, Auth, Auth),
        new("e4 400 error string echo", 400, "application/json", """{"error":"LK-E4-ERR-1-canary"}""", new[] { "LK-E4-ERR-1-canary" }, Auth, Auth),
        new("e5 400 non-JSON echo", 400, "text/plain", "LK-E5-BODY-canary", new[] { "LK-E5-BODY-canary" }, Transport, Transport),
        new("e5b 400 non-JSON t-literal echo", 400, "text/plain", "tLK-E5B-BODY-canary", new[] { "tLK-E5B-BODY-canary" }, Transport, Transport),
        new("e6 401 non-JSON echo", 401, "text/plain", "LK-E6-BODY-canary", new[] { "LK-E6-BODY-canary" }, Auth, Auth),
        new("e7 500 JSON error echo", 500, "application/json",
            """{"error":"LK-E7-ERR-1-canary","error_description":"LK-E7-DSC-1-canary"}""", new[] { "LK-E7-ERR-1-canary", "LK-E7-DSC-1-canary" }, Auth, Auth),
        new("e8 400 error array echo", 400, "application/json", """{"error":["LK-E8-ERR-1-canary"]}""", new[] { "LK-E8-ERR-1-canary" }, Auth, Auth),
        new("e9 400 JSON string root", 400, "application/json", "\"LK-E9-BODY-canary\"", new[] { "LK-E9-BODY-canary" }, Auth, Auth),
        // (f) introspect 모양 — active 가 불리언이 아니면 Duende 가 비활성으로 읽는다(성공). 토큰 호출에는 access_token 이 없다.
        new("f introspect active string", 200, "application/json", """{"active":"LK-F-ACT-01-canary","username":"svc"}""",
            new[] { "LK-F-ACT-01-canary" }, Auth, null),
        // Grok 레그의 주장 — 빈 200 본문이면 Duende 의 TokenIntrospectionResponse 가 "Json is null" 을 던진다. 카나리아는
        // 없다(흐름 검사만 — SDK 타입으로 번역되는가).
        new("h empty 200 body", 200, "application/json", "", Array.Empty<string>(), Auth, Auth),
    };

    public static IEnumerable<object[]> VariantNames => Variants.Select(v => new object[] { v.Name });

    private delegate Task<object?> Call(KeycloakClient kc);

    /// <summary>토큰·introspect 엔드포인트를 타는 공개 호출 전부 — provider 와 admin 워밍업도 토큰 엔드포인트를 탄다.</summary>
    private static readonly (string Name, bool Introspect, bool Nonce, Call Run)[] Calls =
    {
        ("ClientCredentialsTokenAsync", false, false, async kc => await kc.Auth.ClientCredentialsTokenAsync()),
        ("RefreshAsync", false, false, async kc => await kc.Auth.RefreshAsync("rt-sent")),
        ("ExchangeCodeAsync(nonce)", false, true, async kc => await kc.Auth.ExchangeCodeAsync("code", "https://app/cb", new string('v', 43), "n1")),
        ("ExchangeCodeAsync(no nonce)", false, false, async kc => await kc.Auth.ExchangeCodeAsync("code", "https://app/cb", new string('v', 43))),
        ("ClientCredentialsTokenProvider", false, false, async kc => await new ClientCredentialsTokenProvider(kc.Auth).GetAccessTokenAsync()),
        ("AdminAsync", false, false, async kc => await kc.AdminAsync()),
        ("IntrospectAsync", true, false, async kc => await kc.Auth.IntrospectAsync("tok-sent")),
    };

    private readonly ITestOutputHelper _out;

    public MalformedTokenResponseTests(ITestOutputHelper output) => _out = output;

    [Theory]
    [MemberData(nameof(VariantNames))]
    public async Task Malformed_token_response_errors_do_not_print_its_secrets(string name)
    {
        // IdentityModel 의 기본값(ShowPII=false) 위에서 잰다 — 켜면 a 변형의 메시지가 토큰 세그먼트를 싣는다.
        Assert.False(Microsoft.IdentityModel.Logging.IdentityModelEventSource.ShowPII, "ShowPII 가 켜져 있다 — 다른 테스트가 전역 값을 바꿨다");
        var v = Variants.Single(x => x.Name == name);
        using var rsa = RSA.Create(2048);
        var p = new RsaSecurityKey(rsa) { KeyId = "k1" }.Rsa!.ExportParameters(false);
        using var idp = WireMockServer.Start();
        var issuer = $"{idp.Urls[0]}/realms/r";
        Stub(idp, Request.Create().WithPath($"{Oidc}/token").UsingPost(), v.Status, v.ContentType, v.Body);
        Stub(idp, Request.Create().WithPath($"{Oidc}/token/introspect").UsingPost(), v.Status, v.ContentType, v.Body);
        Stub(idp, Request.Create().WithPath("/realms/r/.well-known/openid-configuration").UsingGet(), 200, "application/json",
            $$"""{"issuer":"{{issuer}}","jwks_uri":"{{issuer}}/protocol/openid-connect/certs"}""");
        Stub(idp, Request.Create().WithPath($"{Oidc}/certs").UsingGet(), 200, "application/json",
            $$"""{"keys":[{"kty":"RSA","kid":"k1","use":"sig","alg":"RS256","n":"{{Base64UrlEncoder.Encode(p.Modulus)}}","e":"{{Base64UrlEncoder.Encode(p.Exponent)}}"}]}""");

        var report = new Report(v.Name, v.Canaries, v.Encoded ?? Array.Empty<string>());
        foreach (var (callName, introspect, nonce, run) in Calls)
        {
            var expected = introspect ? v.Introspect : nonce ? v.Token ?? Auth : v.Token;
            using var kc = KeycloakClient.Create(new KeycloakConfig { ServerUrl = idp.Urls[0], Realm = "r", ClientId = "c", ClientSecret = "S" });
            await report.RunAsync(callName, expected, () => run(kc));
        }
        report.AssertClean(_out);
    }

    /// <summary>
    /// 선(wire) 수준에서 형식이 틀린 응답 — 가짜 IdP(WireMock)로는 못 만드는 모양이라 원시 소켓으로 낸다. SocketsHttpHandler 가
    /// 잘못된 헤더 줄·이름을 인용하고(청크 길이 줄은 16진), 서버의 reason phrase 는 그대로 SDK 까지 온다.
    /// </summary>
    /// <param name="expected">토큰·introspect 호출의 기대 예외.</param>
    /// <param name="logout">logout 의 기대 예외(<c>null</c> 은 성공 — logout 은 2xx 본문을 읽지 않는다).</param>
    [Theory]
    [InlineData("g1 invalid header line", "HTTP/1.1 200 OK\r\nLK-G1-HDRLINE-canary\r\nContent-Length: 2\r\n\r\n{}", "LK-G1-HDRLINE-canary",
        typeof(KeycloakTransportException), typeof(KeycloakTransportException))]
    [InlineData("g2 invalid header name", "HTTP/1.1 200 OK\r\nBad LK-G2-HDRNAME-canary: v\r\nContent-Length: 2\r\n\r\n{}", "LK-G2-HDRNAME-canary",
        typeof(KeycloakTransportException), typeof(KeycloakTransportException))]
    [InlineData("g3 invalid chunk size line", "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nLK-G3-CHUNK-canary\r\n\r\n", "LK-G3-CHUNK-canary",
        typeof(KeycloakTransportException), typeof(KeycloakTransportException))]
    [InlineData("g4 reason phrase echo", "HTTP/1.1 401 Unauthorized LK-G4-REASON-canary\r\nContent-Length: 0\r\n\r\n", "LK-G4-REASON-canary",
        typeof(KeycloakAuthException), typeof(KeycloakAuthException))]
    // Grok 레그의 주장 — 알 수 없는 charset 은 본문을 문자열로 읽을 때 Encoding.GetEncoding 이 그 이름을 인용한다.
    [InlineData("g5 unknown charset", "HTTP/1.1 200 OK\r\nContent-Type: application/json; charset=LK-G5-CHARSET-canary\r\nContent-Length: 2\r\n\r\n{}",
        "LK-G5-CHARSET-canary", typeof(KeycloakTransportException), null)]
    public async Task Malformed_wire_response_errors_do_not_print_its_secrets(string name, string raw, string canary, Type expected, Type? logout)
    {
        using var listener = new RawServer(raw);
        using var kc = KeycloakClient.Create(new KeycloakConfig { ServerUrl = listener.Url, Realm = "r", ClientId = "c", ClientSecret = "S" });
        var report = new Report(name, new[] { canary }, new[] { BitConverter.ToString(Encoding.ASCII.GetBytes(canary)) });
        await report.RunAsync("ClientCredentialsTokenAsync", expected, async () => await kc.Auth.ClientCredentialsTokenAsync());
        await report.RunAsync("RefreshAsync", expected, async () => await kc.Auth.RefreshAsync("rt-sent"));
        await report.RunAsync("ExchangeCodeAsync(nonce)", expected,
            async () => await kc.Auth.ExchangeCodeAsync("code", "https://app/cb", new string('v', 43), "n1"));
        await report.RunAsync("IntrospectAsync", expected, async () => await kc.Auth.IntrospectAsync("tok-sent"));
        // logout 은 토큰 엔드포인트가 아니지만 같은 선 오류를 받고, 수정 전에는 그 메시지를 SDK 메시지에 복사했다.
        await report.RunAsync("LogoutAsync", logout, async () => { await kc.Auth.LogoutAsync("rt-sent"); return null; });
        report.AssertClean(_out);
    }

    /// <summary>한 변형의 호출 결과를 모아 흐름·누출·알려진 누출을 한꺼번에 판정한다.</summary>
    private sealed class Report
    {
        private readonly string _variant;
        private readonly string[] _canaries;
        private readonly string[] _encoded;
        private readonly List<string> _flow = new();
        private readonly List<string> _leaks = new();
        private readonly HashSet<string> _knownSeen = new(StringComparer.Ordinal);
        private readonly List<string> _log = new();

        public Report(string variant, string[] canaries, string[] encoded)
        {
            _variant = variant;
            _canaries = canaries;
            _encoded = encoded;
        }

        public async Task RunAsync(string call, Type? expected, Func<Task<object?>> run)
        {
            object? result = null;
            Exception? error = null;
            try { result = await run(); }
            catch (Exception e) { error = e; }

            // 흐름 — 변형이 정말 SDK 에 닿아 기대한 결과를 냈는가.
            var actual = error?.GetType();
            _log.Add($"{call}: {(error is null ? "성공" : Chain(error))}");
            if (actual != expected)
                _flow.Add($"{call}: {expected?.Name ?? "성공"} 을 기대했는데 {actual?.FullName ?? "성공"} — {error?.Message}");

            if (error is not null)
            {
                Check(call, "ToString()", error.ToString());
                for (var e = error; e is not null; e = e.InnerException)
                    Check(call, "Message", e.Message);
                if (error is KeycloakAuthException { OAuthError: { } code })
                    Check(call, "OAuthError", code);
            }
            else if (result is not (null or string))
            {
                // 성공 — 반환값의 기본 표현(TokenSet 은 마스킹한다). provider 의 반환 문자열은 계약상 토큰 자체다.
                Check(call, "ToString()", result.ToString() ?? "");
            }
        }

        private void Check(string call, string path, string text)
        {
            foreach (var c in _canaries)
            {
                var hit = text.Contains(c, StringComparison.Ordinal) ? "FULL"
                    : text.Contains(c[..10], StringComparison.Ordinal) ? "PREFIX10" : null;
                if (hit is not null)
                    Note(call, path, $"{hit} {c}");
            }
            foreach (var c in _encoded)
            {
                if (text.Contains(c, StringComparison.Ordinal))
                    Note(call, path, $"ENCODED {c}");
            }
        }

        private void Note(string call, string path, string what)
        {
            var key = $"{_variant}|{path}";
            if (KnownLeaks.ContainsKey(key))
            {
                _knownSeen.Add(key);
                return;
            }
            _leaks.Add($"{call} {path}: {what}");
        }

        public void AssertClean(ITestOutputHelper output)
        {
            foreach (var line in _log)
                output.WriteLine(line);
            Assert.True(_flow.Count == 0, $"[{_variant}] 흐름 — 변형이 기대한 결과를 안 냈다:\n" + string.Join("\n", _flow));
            Assert.True(_leaks.Count == 0, $"[{_variant}] SDK 오류가 응답의 비밀을 찍는다:\n" + string.Join("\n", _leaks));
            var stale = KnownLeaks.Keys.Where(k => k.StartsWith(_variant + "|", StringComparison.Ordinal) && !_knownSeen.Contains(k)).ToList();
            Assert.True(stale.Count == 0, $"[{_variant}] 알려진 누출이 더 안 난다 — KnownLeaks 에서 지워라: " + string.Join(", ", stale));
        }

        private static string Chain(Exception error)
        {
            var parts = new List<string>();
            for (var e = error; e is not null; e = e.InnerException)
                parts.Add($"{e.GetType().Name}: {e.Message}");
            return string.Join(" <- ", parts);
        }
    }

    /// <summary>요청마다 같은 원시 응답을 쓰고 연결을 닫는 최소 서버.</summary>
    private sealed class RawServer : IDisposable
    {
        private readonly TcpListener _listener = new(IPAddress.Loopback, 0);
        private readonly CancellationTokenSource _cts = new();
        private readonly Task _loop;

        public RawServer(string raw)
        {
            _listener.Start();
            Url = $"http://127.0.0.1:{((IPEndPoint)_listener.LocalEndpoint).Port}";
            var bytes = Encoding.ASCII.GetBytes(raw);
            _loop = Task.Run(async () =>
            {
                var buf = new byte[65536];
                while (!_cts.IsCancellationRequested)
                {
                    using var client = await _listener.AcceptTcpClientAsync(_cts.Token);
                    var stream = client.GetStream();
                    _ = await stream.ReadAsync(buf, _cts.Token);
                    await stream.WriteAsync(bytes, _cts.Token);
                    await stream.FlushAsync(_cts.Token);
                }
            });
        }

        public string Url { get; }

        public void Dispose()
        {
            _cts.Cancel();
            _listener.Stop();
            try { _loop.Wait(TimeSpan.FromSeconds(5)); }
            catch (AggregateException) { /* 취소·리스너 종료 */ }
            _cts.Dispose();
        }
    }

    private static void Stub(WireMockServer idp, IRequestBuilder request, int status, string contentType, string body)
        => idp.Given(request).RespondWith(Response.Create().WithStatusCode(status)
            .WithHeader("Content-Type", contentType).WithBody(body));
}
