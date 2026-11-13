using System.Globalization;
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

    /// <summary>
    /// 알려진 누출 — <c>"변형|경로"</c>(경로: <c>ToString()</c>·<c>Message</c>·<c>OAuthError</c>). ⚠️ 더 안 새면 <b>여기서
    /// 지워야 통과한다</b>(낡은 항목 검사). 지금은 없다 — e4 · e7 의 코드 자리 카나리아(<c>LK-E4-ERR-1-canary</c>)는 RFC 6749
    /// §5.2 문법 안이라 예전에는 계약상 그대로 실렸지만, 이제 코드는 <c>[a-z_]{1,64}</c> 이고 그 요청이 보낸 비밀과 겹치지 않을
    /// 때만 싣는다(<c>OAuthErrorCode</c> · <c>OAuthErrorCodeEchoTests</c> · 등록부 token-error-code-secret-echo). 그 밖의
    /// 문자열(제어 문자·<c>"</c>·<c>\</c>·비 ASCII)은 원래 코드가 아니었다 — e10·e11 이 그 쪽을 잰다.
    /// </summary>
    /// <remarks>internal — HostilePathMatrixTests 가 같은 계약(어느 경로의 카나리아가 계약상 찍히는가)을 파생 행에 그대로 건다.</remarks>
    internal static readonly Dictionary<string, string> KnownLeaks = new(StringComparer.Ordinal);

    /// <summary>토큰 엔드포인트 변형 — 같은 본문을 introspect 엔드포인트도 낸다.</summary>
    /// <param name="Token">토큰 호출들의 기대 결과(<c>null</c> 은 성공). nonce 를 준 code 교환은 토큰이 성공해도
    /// id_token 검사에서 실패하므로 <c>Token ?? Auth</c> 다.</param>
    /// <param name="Encoded">원문이 아니라 변환된 꼴로만 찍히는 카나리아 — 전체 일치만 본다(10자 접두는 흔하다).</param>
    internal sealed record Variant(string Name, int Status, string ContentType, string Body, string[] Canaries,
                                   Type? Token, Type? Introspect, string[]? Encoded = null);

    private static string Long(string canary) => canary + new string('x', 200);

    private static string B64(string s) => Base64UrlEncoder.Encode(s);

    /// <remarks>internal — HostilePathMatrixTests 가 변형 집합을 새로 만들지 않고 여기서 가져간다(토큰 호출에 단언된 것만).</remarks>
    internal static readonly Variant[] Variants =
    {
        // (a) id_token 이 JWT 가 아니다 — 토큰 호출은 id_token 을 안 보므로 성공, nonce 교환만 실패한다. introspect 는 이 본문에
        // `active` 가 없어 KeycloakAuthException 이다(RFC 7662 §2.2 REQUIRED — 판정 D3, 2026-11-10; 예전에는 「비활성」 성공이었다).
        new("a id_token not a JWT", 200, "application/json",
            """{"access_token":"LK-A-AT-01-canary","token_type":"Bearer","expires_in":300,"refresh_token":"LK-A-RT-01-canary","id_token":"LK-A-ID-01-canary"}""",
            new[] { "LK-A-AT-01-canary", "LK-A-RT-01-canary", "LK-A-ID-01-canary" }, null, Auth),
        new("a2 id_token JWT-shaped garbage", 200, "application/json",
            """{"access_token":"LK-A2-AT-1-canary","token_type":"Bearer","expires_in":300,"refresh_token":"LK-A2-RT-1-canary","id_token":"LK-A2-ID-1-canary.LK-A2-PL-1-canary.LK-A2-SG-1-canary"}""",
            new[] { "LK-A2-AT-1-canary", "LK-A2-RT-1-canary", "LK-A2-ID-1-canary", "LK-A2-PL-1-canary", "LK-A2-SG-1-canary" }, null, Auth),
        new("a3 id_token header decodes to non-JSON", 200, "application/json",
            $$"""{"access_token":"LK-A3-AT-1-canary","token_type":"Bearer","expires_in":300,"refresh_token":"LK-A3-RT-1-canary","id_token":"{{B64("tLK-A3-HDR-1-canary")}}.{{B64("tLK-A3-PAY-1-canary")}}.c2ln"}""",
            new[] { "LK-A3-AT-1-canary", "LK-A3-RT-1-canary", "tLK-A3-HDR-1-canary", "tLK-A3-PAY-1-canary" }, null, Auth),
        new("a4 id_token payload decodes to non-JSON", 200, "application/json",
            $$"""{"access_token":"LK-A4-AT-1-canary","token_type":"Bearer","expires_in":300,"refresh_token":"LK-A4-RT-1-canary","id_token":"{{B64("""{"alg":"RS256","kid":"k1"}""")}}.{{B64("fLK-A4-PAY-1-canary")}}.c2ln"}""",
            new[] { "LK-A4-AT-1-canary", "LK-A4-RT-1-canary", "fLK-A4-PAY-1-canary" }, null, Auth),
        // (b) access_token 이 문자열이 아니다 — refresh/id 토큰은 카나리아다. introspect 는 `active` 가 없어 실패한다(D3).
        new("b access_token number", 200, "application/json",
            """{"access_token":12345,"token_type":"Bearer","expires_in":300,"refresh_token":"LK-B-RT-01-canary","id_token":"LK-B-ID-01-canary"}""",
            new[] { "LK-B-RT-01-canary", "LK-B-ID-01-canary" }, Auth, Auth),
        new("b2 access_token object", 200, "application/json",
            """{"access_token":{"t":"LK-B2-AT-1-canary"},"token_type":"Bearer","expires_in":300,"refresh_token":"LK-B2-RT-1-canary"}""",
            new[] { "LK-B2-AT-1-canary", "LK-B2-RT-1-canary" }, Auth, Auth),
        // (c) expires_in·token_type 의 타입이 틀렸다 — ⚠️ .NET 은 이것을 **성공**으로 받는다(Duende 가 강제변환:
        // expires_in → 0 이라 ExpiresAt 미상 = 만료로 취급, token_type 5 → "5"). 누출 검사는 반환값의 표현에 건다.
        // introspect 는 `active` 가 없어 실패한다(D3) — 그 오류에 같은 누출 검사가 걸린다.
        new("c expires_in string", 200, "application/json",
            """{"access_token":"LK-C-AT-01-canary","token_type":"Bearer","expires_in":"x","refresh_token":"LK-C-RT-01-canary"}""",
            new[] { "LK-C-AT-01-canary", "LK-C-RT-01-canary" }, null, Auth),
        new("c2 token_type number", 200, "application/json",
            """{"access_token":"LK-C2-AT-1-canary","token_type":5,"expires_in":300,"refresh_token":"LK-C2-RT-1-canary"}""",
            new[] { "LK-C2-AT-1-canary", "LK-C2-RT-1-canary" }, null, Auth),
        new("c3 expires_in object", 200, "application/json",
            """{"access_token":"LK-C3-AT-1-canary","token_type":"Bearer","expires_in":{"v":"LK-C3-EX-1-canary"},"refresh_token":"LK-C3-RT-1-canary"}""",
            new[] { "LK-C3-AT-1-canary", "LK-C3-RT-1-canary", "LK-C3-EX-1-canary" }, null, Auth),
        // (d) 200 인데 본문이 JSON 이 아니다 — 끝까지 온 응답이라 KeycloakAuthException 이다(판정 2026-11-10,
        // token-response-class-divergent · TokenResponseClassTests). 예전에는 Duende 가 파싱 실패를 ErrorType.Exception 으로 내
        // 전송 오류였다. 파서의 원인 사슬은 메시지를 전부 뺀 채 남는다 — 누출 검사가 그것을 잰다.
        new("d non-JSON short", 200, "application/json", "LK-D-BODY-01", new[] { "LK-D-BODY-01" }, Auth, Auth),
        new("d2 non-JSON long", 200, "application/json", Long("LK-D2-BODY-canary"), new[] { "LK-D2-BODY-canary" }, Auth, Auth),
        new("d3 non-JSON t-literal short", 200, "application/json", "tLK-D3-BODY-can", new[] { "tLK-D3-BODY-can" }, Auth, Auth),
        new("d3b non-JSON t-literal long", 200, "application/json", Long("tLK-D3B-BODY-canary"), new[] { "tLK-D3B-BODY-canary" }, Auth, Auth),
        new("d3c non-JSON f-literal", 200, "application/json", "fLK-D3C-BODY-canary.eyJ.sig", new[] { "fLK-D3C-BODY-canary" }, Auth, Auth),
        new("d3d form-encoded body", 200, "application/x-www-form-urlencoded", "token_type=bearer&access_token=LK-D3D-AT-1-canary",
            new[] { "LK-D3D-AT-1-canary" }, Auth, Auth),
        new("d4 non-JSON n-literal", 200, "application/json", "nLK-D4-BODY-canary", new[] { "nLK-D4-BODY-canary" }, Auth, Auth),
        new("d5 unterminated string", 200, "application/json", "\"LK-D5-BODY-canary", new[] { "LK-D5-BODY-canary" }, Auth, Auth),
        new("d6 number prefix", 200, "application/json", "123LK-D6-BODY-canary", new[] { "123LK-D6-BODY-canary" }, Auth, Auth),
        new("d9 html body", 200, "text/html", "<html>LK-D9-BODY-canary</html>", new[] { "LK-D9-BODY-canary" }, Auth, Auth),
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
        // 끝까지 온 400 — 상태가 판정한다(판정 2026-11-10). 예전에는 (d) 와 같은 까닭으로 전송 오류였다.
        new("e5 400 non-JSON echo", 400, "text/plain", "LK-E5-BODY-canary", new[] { "LK-E5-BODY-canary" }, Auth, Auth),
        new("e5b 400 non-JSON t-literal echo", 400, "text/plain", "tLK-E5B-BODY-canary", new[] { "tLK-E5B-BODY-canary" }, Auth, Auth),
        new("e6 401 non-JSON echo", 401, "text/plain", "LK-E6-BODY-canary", new[] { "LK-E6-BODY-canary" }, Auth, Auth),
        new("e7 500 JSON error echo", 500, "application/json",
            """{"error":"LK-E7-ERR-1-canary","error_description":"LK-E7-DSC-1-canary"}""", new[] { "LK-E7-ERR-1-canary", "LK-E7-DSC-1-canary" }, Auth, Auth),
        new("e8 400 error array echo", 400, "application/json", """{"error":["LK-E8-ERR-1-canary"]}""", new[] { "LK-E8-ERR-1-canary" }, Auth, Auth),
        new("e9 400 JSON string root", 400, "application/json", "\"LK-E9-BODY-canary\"", new[] { "LK-E9-BODY-canary" }, Auth, Auth),
        // error 가 RFC 6749 §5.2 문법 밖이다(끝 CRLF·LF) — 코드가 아니므로 어느 경로에도 싣지 않는다. 다듬어(Trim) 코드로
        // 만들지도 않는다 — 카나리아는 줄바꿈을 뺀 앞부분이라 다듬은 값이 실려도 잡힌다. 경계 전부는 OAuthErrorCodeGrammarTests.
        new("e10 400 error code + CRLF", 400, "application/json", """{"error":"LK-E10-ERR-1-canary\r\n"}""",
            new[] { "LK-E10-ERR-1-canary" }, Auth, Auth),
        new("e11 401 error code + LF", 401, "application/json", """{"error":"LK-E11-ERR-1-canary\n"}""",
            new[] { "LK-E11-ERR-1-canary" }, Auth, Auth),
        // (f) introspect 모양 — active 가 불리언이 아니면 KeycloakAuthException 이다(판정 D3; Duende 는 비활성으로 읽어 예전에는
        // 성공이었다). 토큰 호출에는 access_token 이 없다.
        new("f introspect active string", 200, "application/json", """{"active":"LK-F-ACT-01-canary","username":"svc"}""",
            new[] { "LK-F-ACT-01-canary" }, Auth, Auth),
        // Grok 레그의 주장 — 빈 200 본문이면 Duende 의 TokenIntrospectionResponse 가 "Json is null" 을 던진다. 카나리아는
        // 없다(흐름 검사만 — SDK 타입으로 번역되는가).
        new("h empty 200 body", 200, "application/json", "", Array.Empty<string>(), Auth, Auth),
        // (s) 짝 없는 서로게이트 이스케이프 — System.Text.Json 은 파싱하지만 GetString 이 InvalidOperationException 을 던진다.
        // 수정 전에는 토큰 호출 전부에서 그것이 그대로 샜다(§4, UndecodableResponseTests). 값은 어느 경로에도 싣지 않는다.
        new("s1 access_token unpaired surrogate", 200, "application/json",
            """{"access_token":"\ud800LK-S1-AT-1-canary","token_type":"Bearer","expires_in":300,"refresh_token":"LK-S1-RT-1-canary"}""",
            new[] { "LK-S1-AT-1-canary", "LK-S1-RT-1-canary" }, Auth, Auth),
        new("s2 refresh_token unpaired surrogate", 200, "application/json",
            """{"access_token":"LK-S2-AT-1-canary","token_type":"Bearer","expires_in":300,"refresh_token":"\udc00LK-S2-RT-1-canary"}""",
            new[] { "LK-S2-AT-1-canary", "LK-S2-RT-1-canary" }, Auth, Auth),
        new("s3 400 error unpaired surrogate", 400, "application/json", """{"error":"\ud800LK-S3-ERR-1-canary"}""",
            new[] { "LK-S3-ERR-1-canary" }, Auth, Auth),
        new("s4 401 error unpaired surrogate", 401, "application/json", """{"error":"\ud800xLK-S4-ERR-1-canary"}""",
            new[] { "LK-S4-ERR-1-canary" }, Auth, Auth),
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
    /// <param name="logout">logout 의 기대 예외 — logout 의 성공은 204 뿐이라(등록부 logout-2xx-html-false-success, 2026-11-12) 200 은
    /// 본문과 무관하게 <see cref="KeycloakAuthException"/> 이다.</param>
    [Theory]
    [InlineData("g1 invalid header line", "HTTP/1.1 200 OK\r\nLK-G1-HDRLINE-canary\r\nContent-Length: 2\r\n\r\n{}", "LK-G1-HDRLINE-canary",
        typeof(KeycloakTransportException), typeof(KeycloakTransportException))]
    [InlineData("g2 invalid header name", "HTTP/1.1 200 OK\r\nBad LK-G2-HDRNAME-canary: v\r\nContent-Length: 2\r\n\r\n{}", "LK-G2-HDRNAME-canary",
        typeof(KeycloakTransportException), typeof(KeycloakTransportException))]
    [InlineData("g3 invalid chunk size line", "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nLK-G3-CHUNK-canary\r\n\r\n", "LK-G3-CHUNK-canary",
        typeof(KeycloakTransportException), typeof(KeycloakTransportException))]
    [InlineData("g4 reason phrase echo", "HTTP/1.1 401 Unauthorized LK-G4-REASON-canary\r\nContent-Length: 0\r\n\r\n", "LK-G4-REASON-canary",
        typeof(KeycloakAuthException), typeof(KeycloakAuthException))]
    // Grok 레그의 주장 — 알 수 없는 charset 은 본문을 문자열로 읽을 때 Encoding.GetEncoding 이 그 이름을 인용한다. 이제 SDK 가
    // charset 을 무시하고 UTF-8 로 읽어(RFC 8259 §11 — 판정 D2, 2026-11-10) 그 조회가 없다: `{}` 는 끝까지 온 쓸 수 없는 본문이라
    // 토큰 호출(access_token 없음)도 introspect(active 없음 — D3)도 KeycloakAuthException 이다. 예전에는 읽기 실패로 전송 오류였다.
    [InlineData("g5 unknown charset", "HTTP/1.1 200 OK\r\nContent-Type: application/json; charset=LK-G5-CHARSET-canary\r\nContent-Length: 2\r\n\r\n{}",
        "LK-G5-CHARSET-canary", typeof(KeycloakAuthException), typeof(KeycloakAuthException))]
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

    /// <summary>
    /// 원시 서버는 풀이 재사용한 연결에도 답한다 — 한 번 답하고 닫던 서버에서는 풀이 그 연결을 다음 POST 에 다시 썼고, 닫힘과
    /// 경합하면 본문을 이미 보낸 요청이라 재시도 없이 <c>ResponseEnded</c> 로 갈렸다(CI .NET 8 두 번 · 등록부
    /// dotnet-rawserver-reads-once-flaky). 한 연결에 요청 셋 — 첫 요청은 헤더와 본문을 따로 보내 요청을 끝까지 읽는지도 본다.
    /// </summary>
    [Fact]
    public async Task Raw_server_answers_every_request_on_one_kept_alive_connection()
    {
        const string raw = "HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\n\r\n";
        using var server = new RawServer(raw);
        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        var url = new Uri(server.Url);
        using var tcp = new TcpClient();
        await tcp.ConnectAsync(url.Host, url.Port, cts.Token);
        var stream = tcp.GetStream();
        var body = Encoding.ASCII.GetBytes("grant_type=client_credentials");
        var head = Encoding.ASCII.GetBytes($"POST {Oidc}/token HTTP/1.1\r\nHost: {url.Authority}\r\n" +
            $"Content-Type: application/x-www-form-urlencoded\r\nContent-Length: {body.Length}\r\n\r\n");
        for (var i = 1; i <= 3; i++)
        {
            try
            {
                await stream.WriteAsync(head, cts.Token);
                if (i == 1)
                {
                    await Task.Delay(100, cts.Token);
                    Assert.True(tcp.Available == 0, "서버가 요청 본문을 받기 전에 답했다 — 요청을 끝까지 읽지 않는다");
                }
                await stream.WriteAsync(body, cts.Token);
                var got = new byte[raw.Length];
                for (var n = 0; n < got.Length;)
                {
                    var r = await stream.ReadAsync(got.AsMemory(n), cts.Token);
                    Assert.True(r > 0, $"요청 {i}: 응답 전에 서버가 연결을 닫았다({n} 바이트 받음)");
                    n += r;
                }
                Assert.Equal(raw, Encoding.ASCII.GetString(got));
            }
            catch (IOException e)
            {
                Assert.Fail($"요청 {i}: 서버가 연결을 닫았다 — {e.Message}");
            }
        }
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

    /// <summary>
    /// 요청마다 같은 원시 응답을 쓰는 최소 서버 — 연결마다 요청 전체(헤더 + Content-Length 본문, SDK 의 폼 요청)를 읽고 답하기를
    /// 클라이언트가 닫을 때까지 되풀이한다. ⚠️ 답하고 바로 닫지 않는다: 응답이 닫힘을 알리지 않으면 풀이 그 연결을 다음 POST 에
    /// 다시 쓰고, 닫힘이 그 뒤에 닿으면 본문을 보낸 요청이라 재시도 없이 <c>ResponseEnded</c> 다(SocketsHttpHandler
    /// <c>HttpConnection.SendAsync</c>). 그래서 응답에는 틀(Content-Length · chunked)이 있어야 한다 — 틀이 없으면 닫힘이 끝이라
    /// (RFC 9112 §6.3) 클라이언트가 오지 않을 닫힘을 기다린다.
    /// </summary>
    private sealed class RawServer : IDisposable
    {
        private readonly TcpListener _listener = new(IPAddress.Loopback, 0);
        private readonly CancellationTokenSource _cts = new();
        private readonly List<Task> _connections = new();
        private readonly byte[] _response;
        private readonly Task _loop;

        public RawServer(string raw)
        {
            _response = Encoding.ASCII.GetBytes(raw);
            _listener.Start();
            Url = $"http://127.0.0.1:{((IPEndPoint)_listener.LocalEndpoint).Port}";
            _loop = Task.Run(async () =>
            {
                while (!_cts.IsCancellationRequested)
                {
                    var client = await _listener.AcceptTcpClientAsync(_cts.Token);
                    lock (_connections)
                        _connections.Add(Task.Run(() => ServeAsync(client)));
                }
            });
        }

        public string Url { get; }

        private async Task ServeAsync(TcpClient client)
        {
            using (client)
            {
                try
                {
                    var stream = client.GetStream();
                    while (await ReadRequestAsync(stream, _cts.Token))
                    {
                        await stream.WriteAsync(_response, _cts.Token);
                        await stream.FlushAsync(_cts.Token);
                    }
                }
                catch (Exception e) when (e is IOException or OperationCanceledException or ObjectDisposedException)
                {
                    // 클라이언트가 끊었다(형식이 틀린 응답이면 연결을 버린다) · 서버 종료.
                }
            }
        }

        /// <summary>요청 하나를 끝까지 읽는다 — 그 전에 연결이 닫히면 <c>false</c>.</summary>
        private static async Task<bool> ReadRequestAsync(NetworkStream stream, CancellationToken ct)
        {
            var head = new List<byte>();
            var one = new byte[1];
            while (head.Count < 4 || head[^4] != '\r' || head[^3] != '\n' || head[^2] != '\r' || head[^1] != '\n')
            {
                if (await stream.ReadAsync(one, ct) == 0)
                    return false;
                head.Add(one[0]);
            }
            var length = 0;
            foreach (var line in Encoding.ASCII.GetString(head.ToArray()).Split("\r\n"))
            {
                if (line.StartsWith("Content-Length:", StringComparison.OrdinalIgnoreCase))
                    length = int.Parse(line["Content-Length:".Length..].Trim(), CultureInfo.InvariantCulture);
            }
            var body = new byte[length];
            for (var got = 0; got < length;)
            {
                var n = await stream.ReadAsync(body.AsMemory(got), ct);
                if (n == 0)
                    return false;
                got += n;
            }
            return true;
        }

        public void Dispose()
        {
            _cts.Cancel();
            _listener.Stop();
            try { _loop.Wait(TimeSpan.FromSeconds(5)); }
            catch (AggregateException) { /* 취소·리스너 종료 */ }
            Task[] connections;
            lock (_connections)
                connections = _connections.ToArray();
            Task.WaitAll(connections, TimeSpan.FromSeconds(5));
            _cts.Dispose();
        }
    }

    private static void Stub(WireMockServer idp, IRequestBuilder request, int status, string contentType, string body)
        => idp.Given(request).RespondWith(Response.Create().WithStatusCode(status)
            .WithHeader("Content-Type", contentType).WithBody(body));
}
