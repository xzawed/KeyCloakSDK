using System.Collections.Concurrent;
using System.Globalization;
using System.Net;
using System.Net.Sockets;
using System.Text;
using Xunit;

namespace Xzawed.Keycloak.Sdk.Tests;

/// <summary>
/// 토큰 · introspection 응답의 오류 계급 — 끝까지 온 응답을 쓸 수 없으면 <see cref="KeycloakAuthException"/>, 끝까지 오지 않은
/// 응답(네트워크 실패 · 1,048,576 바이트 상한 초과 · 끊긴 본문)은 <see cref="KeycloakTransportException"/> 이다. 등록부
/// <c>token-response-class-divergent</c> · 판정 D1–D4(2026-11-10 — python #1004 · go #1005 · node #1006 · php #1003 과 같은 칸).
/// </summary>
/// <remarks>
/// <para>같은 가짜 IdP(원시 소켓 — 바이트와 틀이 정확하다)로 여섯 면을 잰다: 세 그랜트(client credentials = S1 · refresh · code
/// 교환), SDK 의 공개 provider(S2), admin 파사드의 자기 그랜트(S5 — <c>KeycloakClient.AdminAsync</c> 가 만든 provider 가
/// 보낸다), introspection(INTRO).</para>
/// <para>main 실측(2026-11-10, 수정 전 — 이 파일의 RED): r2 200 HTML · r2j · r8 400 HTML · r8j 는 다섯 토큰 면과 INTRO 모두
/// <c>KeycloakTransportException</c> 이었다 — Duende 가 끝까지 온 본문의 JSON 파싱 실패를 예외로 냈고 SDK 가 그것을 전송 실패로
/// 옮겼다. r9 문자열 안의 잘못된 UTF-8 은 세 그랜트 · INTRO 에서 <b>성공</b>이었다(Duende 의 <c>ReadAsStringAsync</c> 가 U+FFFD 로
/// 바꿨다 — IdP 가 내지 않은 토큰 · 클레임; S2 · S5 는 b64token 검사가 우연히 막았다). r10 모르는 charset 은 여섯 면 모두
/// Transport 였다(.NET 이 charset 을 지켜 본문 읽기가 실패했다). INTRO r4 의 <c>active</c> 없음은 「비활성」 성공이었다.</para>
/// <para>판정 — D1: 2xx 본문은 UTF-8 이다(RFC 8259 §8.1). 원시 바이트로, 끝까지 온 뒤에만 본다(상한 초과 · 끊긴 본문은 그대로
/// Transport). D2: <c>application/json</c> 의 charset 은 효과가 없다(§11). D3: <c>active</c> 는 REQUIRED boolean 이다(RFC 7662
/// §2.2). D4: admin 의 토큰 실패는 끝까지 온 응답이면 상태와 무관하게 auth 레인과 같은 판정이다 — .NET 에서 admin ↔ auth 의
/// 접착제는 <c>ITokenProvider</c> 뿐이라(CLAUDE.md §4), admin 호출은 provider 의 오류를 그대로 낸다. 그래서 S5 의 기대는 손으로
/// 적지 않고 같은 응답에서 S2 가 낸 판정(형 · 메시지 · <c>OAuthError</c>)을 그대로 쓴다 — S5 에서만 무엇을 붙이거나 빼는 래퍼는
/// 실패한다. 코드 모양 비밀의 되울림(OAuth <c>error</c> 자리)은 S1 · S2 와 함께 언어 공통 항목이 다룬다(PM 판정 2026-11-10).</para>
/// </remarks>
[Trait("Category", "Unit")]
public sealed class TokenResponseClassTests
{
    private const string Oidc = "/realms/r/protocol/openid-connect";
    private const string Json = "application/json";
    private const string HtmlType = "text/html";
    private const string Secret = "CANARY-client-secret-5x9";
    private const string Canary = "CANARY-class-body-7q2";
    private const string UserPath = "/admin/realms/r/users/u1";

    /// <summary>The cap, written independently of <c>AuthClient.MaxTokenResponseBytes</c> (as <c>TokenResponseCapTests</c> does).</summary>
    private const int Cap = 1024 * 1024;

    private const string GoodToken = """{"access_token":"AT-ok-token","token_type":"Bearer","expires_in":300,"refresh_token":"RT-ok"}""";
    private const string GoodIntrospection = """{"active":true,"username":"svc"}""";

    private static readonly byte[] Html = Encoding.ASCII.GetBytes($"<html><body><h1>503 Service Unavailable</h1>{Canary}</body></html>");

    /// <summary>A scripted answer, exact bytes. <paramref name="DeclaredLength"/> above the body's length makes the server close
    /// the connection after the body — a body cut short.</summary>
    internal sealed record Answer(int Status, string ContentType, byte[] Body, int? DeclaredLength = null);

    private static Answer A(int status, string type, string body) => new(status, type, Encoding.UTF8.GetBytes(body));

    private static Answer A(int status, string type, byte[] body) => new(status, type, body);

    /// <summary>Text parts UTF-8 encoded, byte arrays as they are, int parts as raw bytes — how a body with bytes that are not
    /// UTF-8 is written.</summary>
    private static byte[] Bytes(params object[] parts) => parts.SelectMany(p => p switch
    {
        string s => Encoding.UTF8.GetBytes(s),
        byte[] b => b,
        _ => new[] { Convert.ToByte(p, CultureInfo.InvariantCulture) },
    }).ToArray();

    /// <summary><paramref name="head"/> followed by JSON whitespace up to <paramref name="total"/> bytes.</summary>
    private static Answer Padded(byte[] head, int total)
    {
        var body = new byte[total];
        Array.Fill(body, (byte)' ');
        head.CopyTo(body, 0);
        return A(200, Json, body);
    }

    // ── S1 · refresh · code exchange · S2 · S5 ──────────────────────────────────────────────────────────────────────

    /// <summary>The token endpoint's cells — the nine-language table's (503 HTML · 200 HTML · no <c>access_token</c> · 400 HTML ·
    /// invalid UTF-8 in a string · an unknown charset), the two bodies labelled JSON that are not, an error body with invalid
    /// UTF-8, the token endpoint's 401 · 403 · 404 · 409, and the controls that did not arrive.</summary>
    private static readonly Dictionary<string, Answer> TokenCells = new(StringComparer.Ordinal)
    {
        ["ok"] = A(200, Json, GoodToken),
        ["bom 200 UTF-8 BOM (control)"] = A(200, Json, Bytes(0xEF, 0xBB, 0xBF, GoodToken)),
        ["r1 503 HTML"] = A(503, HtmlType, Html),
        ["r2 200 HTML"] = A(200, HtmlType, Html),
        ["r2j 200 HTML typed as JSON"] = A(200, Json, Html),
        // Valid JSON, nested past the 64 levels Duende's parser allows — why the message says "could not be parsed".
        ["r2d 200 JSON nested past the parser's depth"] = A(200, Json,
            """{"access_token":"AT-ok-token","token_type":"Bearer","x":""" + new string('[', 65) + new string(']', 65) + "}"),
        ["r4 200 JSON without access_token"] = A(200, Json, """{"token_type":"Bearer","expires_in":300}"""),
        ["r8 400 HTML"] = A(400, HtmlType, Html),
        ["r8j 400 HTML typed as JSON"] = A(400, Json, Html),
        // An error body is not checked for UTF-8 — its status decides (the code is read leniently and is ASCII by grammar).
        ["r8u 400 invalid UTF-8 in the error body"] = A(400, Json, Bytes("""{"error":"invalid_grant","error_description":"x""", 0xFF, Canary, "\"}")),
        ["r9 200 invalid UTF-8 inside the token"] = A(200, Json,
            Bytes("""{"access_token":"AT-""", 0xFF, 0xFE, Canary, "\",\"token_type\":\"Bearer\",\"expires_in\":300}")),
        ["r9o 200 invalid UTF-8 outside the token"] = A(200, Json,
            Bytes("""{"access_token":"AT-ok-token","token_type":"Bearer","expires_in":300,"scope":"s""", 0xFF, Canary, "\"}")),
        ["r10 200 unknown charset"] = A(200, Json + "; charset=x-no-such-charset", GoodToken),
        ["r10q 200 unknown quoted charset"] = A(200, Json + "; charset=\"x-no-such-charset\"", GoodToken),
        ["401 invalid_client"] = A(401, Json, """{"error":"invalid_client"}"""),
        ["403 access_denied"] = A(403, Json, """{"error":"access_denied"}"""),
        ["404 realm missing"] = A(404, Json, """{"error":"Realm does not exist"}"""),
        ["409 conflict"] = A(409, Json, """{"error":"conflict"}"""),
        // Controls — the response did not arrive in full. Bad bytes before the cap or the cut change nothing (D1 waits for
        // the whole body).
        ["t over the cap"] = Padded(Encoding.UTF8.GetBytes(GoodToken), Cap + 1),
        ["t over the cap, invalid UTF-8 first"] = Padded(Bytes(0xFF), Cap + 1),
        ["t cut short"] = new(200, Json, Encoding.UTF8.GetBytes($$"""{"access_token":"AT-{{Canary}}"""), DeclaredLength: 400),
        ["t cut short after invalid UTF-8"] = new(200, Json, Bytes("""{"access_token":"AT-""", 0xFF, Canary), DeclaredLength: 400),
    };

    public static IEnumerable<object[]> TokenCellNames => TokenCells.Keys.Select(k => new object[] { k });

    private delegate Task<string> Run(KeycloakClient kc);

    /// <summary>A lane whose expectation is written by hand: its failure prefix and what it hands back on success.</summary>
    private sealed record Lane(string Name, string Prefix, string Success, Run Run);

    private static readonly Lane S2 = new("S2 ClientCredentialsTokenProvider", "Client credentials grant failed", "AT-ok-token",
        async kc => await new ClientCredentialsTokenProvider(kc.Auth).GetAccessTokenAsync());

    private static readonly Lane[] TokenLanes =
    {
        new("S1 ClientCredentialsTokenAsync", "Client credentials grant failed", "AT-ok-token",
            async kc => (await kc.Auth.ClientCredentialsTokenAsync()).AccessToken),
        new("RefreshAsync", "Token refresh failed", "AT-ok-token", async kc => (await kc.Auth.RefreshAsync("rt-sent")).AccessToken),
        new("ExchangeCodeAsync", "Authorization code exchange failed", "AT-ok-token",
            async kc => (await kc.Auth.ExchangeCodeAsync("code", "https://app/cb", new string('v', 43))).AccessToken),
        S2,
    };

    /// <summary>S5 — the admin facade's own token request, sent by the provider <c>KeycloakClient.AdminAsync</c> builds, then
    /// one admin read. Its expectation is never written by hand: see <see cref="S5Verdict"/>.</summary>
    private static async Task<(string? Result, Exception? Error)> S5Async(string url)
    {
        using var kc = Facade(url);
        return await AttemptAsync(async () => (await (await kc.AdminAsync()).Users.GetAsync("u1")).Id ?? "null");
    }

    /// <summary>What S5 must give: what S2 gave for the same reply — the same type, message and <c>OAuthError</c> — or, when S2
    /// got a token, the admin read's result.</summary>
    private static string S5Verdict((string? Result, Exception? Error) s2) => s2.Error is null ? Ok("u1") : Verdict(s2);

    /// <summary>A body that arrived but is not JSON — "could not be parsed", because valid JSON nested past the parser's depth
    /// limit fails the same way.</summary>
    private const string NotJson = "response body could not be parsed as JSON";

    private static string Ok(string result) => $"ok {result}";

    private static string Auth(string message, string? oauthError = null) => $"Auth: {message} | OAuthError={oauthError ?? "null"}";

    private static string Transport(string message) => $"Transport: {message}";

    /// <summary>What a lane must give for a token-endpoint cell.</summary>
    private static string TokenVerdict(string cell, Lane lane)
    {
        var p = lane.Prefix;
        string Coded(string reason, string code) => Auth($"{p}: {reason}", code);
        return cell switch
        {
            "ok" or "bom 200 UTF-8 BOM (control)" or "r10 200 unknown charset" or "r10q 200 unknown quoted charset" => Ok(lane.Success),
            "r1 503 HTML" => Auth($"{p}: Service Unavailable", "Service Unavailable"),
            "r2 200 HTML" or "r2j 200 HTML typed as JSON" or "r2d 200 JSON nested past the parser's depth" => Auth($"{p}: {NotJson} (HTTP 200)"),
            "r4 200 JSON without access_token" => Auth("token response missing access_token"),
            "r8 400 HTML" or "r8j 400 HTML typed as JSON" => Auth($"{p}: {NotJson} (HTTP 400)"),
            "r8u 400 invalid UTF-8 in the error body" => Auth($"{p}: invalid_grant", "invalid_grant"),
            "r9 200 invalid UTF-8 inside the token" or "r9o 200 invalid UTF-8 outside the token" => Auth($"{p}: response is not valid UTF-8"),
            "401 invalid_client" => Coded("Unauthorized", "invalid_client"),
            "403 access_denied" => Coded("Forbidden", "access_denied"),
            "404 realm missing" => Coded("Not Found", "Realm does not exist"),
            "409 conflict" => Coded("Conflict", "conflict"),
            "t over the cap" or "t over the cap, invalid UTF-8 first" => Transport($"{p}: response exceeds a size limit"),
            "t cut short" or "t cut short after invalid UTF-8" => Transport($"{p} (transport)"),
            _ => throw new InvalidOperationException($"no expectation for {cell}"),
        };
    }

    /// <summary>Every lane gets the class the decision gives the cell; S5 gets exactly what S2 got for the same reply, and sends
    /// its admin request only when the grant succeeded.</summary>
    [Theory]
    [MemberData(nameof(TokenCellNames))]
    public async Task A_token_endpoint_answer_gets_the_decided_class_on_every_lane(string cell)
    {
        using var idp = new ScriptedIdp((_, path) => path switch
        {
            $"{Oidc}/token" => TokenCells[cell],
            UserPath => A(200, Json, """{"id":"u1","username":"u"}"""),
            _ => A(404, Json, "{}"),
        });
        var wrong = new List<string>();
        (string? Result, Exception? Error) s2 = default;
        foreach (var lane in TokenLanes)
        {
            using var kc = Facade(idp.Url);
            var outcome = await AttemptAsync(() => lane.Run(kc));
            Check(wrong, lane.Name, outcome, TokenVerdict(cell, lane));
            if (lane == S2)
                s2 = outcome;
        }
        var before = idp.AdminRequests().Count;
        Check(wrong, "S5 AdminAsync", await S5Async(idp.Url), S5Verdict(s2));
        var sent = idp.AdminRequests().Skip(before).ToList();
        if (!sent.SequenceEqual(s2.Error is null ? new[] { $"GET {UserPath}" } : Array.Empty<string>()))
            wrong.Add($"S5 AdminAsync: admin requests [{string.Join(", ", sent)}] — want {(s2.Error is null ? "the one GET" : "none")}");
        Assert.True(wrong.Count == 0, $"[{cell}]\n" + string.Join("\n", wrong));
    }

    // ── INTRO ───────────────────────────────────────────────────────────────────────────────────────────────────────

    private static readonly Dictionary<string, Answer> IntrospectionCells = new(StringComparer.Ordinal)
    {
        ["ok"] = A(200, Json, GoodIntrospection),
        ["r4f 200 inactive (control)"] = A(200, Json, """{"active":false}"""),
        ["r1 503 HTML"] = A(503, HtmlType, Html),
        ["r2 200 HTML"] = A(200, HtmlType, Html),
        ["r2j 200 HTML typed as JSON"] = A(200, Json, Html),
        ["r4 200 JSON without active"] = A(200, Json, """{"username":"svc"}"""),
        ["r4s 200 active as the string \"true\""] = A(200, Json, """{"active":"true","username":"svc"}"""),
        ["r4n 200 active null"] = A(200, Json, """{"active":null,"username":"svc"}"""),
        ["r4i 200 active as the number 1"] = A(200, Json, """{"active":1,"username":"svc"}"""),
        ["r8 400 HTML"] = A(400, HtmlType, Html),
        ["r8j 400 HTML typed as JSON"] = A(400, Json, Html),
        ["r8u 400 invalid UTF-8 in the error body"] = A(400, Json, Bytes("""{"error":"invalid_grant","error_description":"x""", 0xFF, Canary, "\"}")),
        ["r9 200 invalid UTF-8 inside a string"] = A(200, Json, Bytes("""{"active":true,"username":"s""", 0xFF, 0xFE, Canary, "\"}")),
        ["r10 200 unknown charset"] = A(200, Json + "; charset=x-no-such-charset", GoodIntrospection),
        ["t over the cap"] = Padded(Encoding.UTF8.GetBytes(GoodIntrospection), Cap + 1),
        ["t cut short after invalid UTF-8"] = new(200, Json, Bytes("""{"active":true,"username":"s""", 0xFF, Canary), DeclaredLength: 400),
    };

    public static IEnumerable<object[]> IntrospectionCellNames => IntrospectionCells.Keys.Select(k => new object[] { k });

    private const string IntroPrefix = "Token introspection failed";

    private static string IntrospectionVerdict(string cell) => cell switch
    {
        "ok" or "r10 200 unknown charset" => Ok("active=True username=svc"),
        "r4f 200 inactive (control)" => Ok("active=False username=null"),
        "r1 503 HTML" => Auth($"{IntroPrefix}: Service Unavailable", "Service Unavailable"),
        "r2 200 HTML" or "r2j 200 HTML typed as JSON" => Auth($"{IntroPrefix}: {NotJson} (HTTP 200)"),
        "r4 200 JSON without active" or "r4s 200 active as the string \"true\"" or "r4n 200 active null" or "r4i 200 active as the number 1"
            => Auth($"{IntroPrefix}: response has no boolean active"),
        "r8 400 HTML" or "r8j 400 HTML typed as JSON" => Auth($"{IntroPrefix}: {NotJson} (HTTP 400)"),
        "r8u 400 invalid UTF-8 in the error body" => Auth($"{IntroPrefix}: invalid_grant", "invalid_grant"),
        "r9 200 invalid UTF-8 inside a string" => Auth($"{IntroPrefix}: response is not valid UTF-8"),
        "t over the cap" => Transport($"{IntroPrefix}: response exceeds a size limit"),
        "t cut short after invalid UTF-8" => Transport("introspection transport failure"),
        _ => throw new InvalidOperationException($"no expectation for {cell}"),
    };

    [Theory]
    [MemberData(nameof(IntrospectionCellNames))]
    public async Task An_introspection_answer_gets_the_decided_class(string cell)
    {
        using var idp = new ScriptedIdp((_, path) => path == $"{Oidc}/token/introspect" ? IntrospectionCells[cell] : A(404, Json, "{}"));
        using var kc = Facade(idp.Url);
        var wrong = new List<string>();
        Check(wrong, "IntrospectAsync", await AttemptAsync(async () =>
        {
            var r = await kc.Auth.IntrospectAsync("tok-sent");
            return $"active={r.Active} username={r.Username ?? "null"}";
        }), IntrospectionVerdict(cell));
        Assert.True(wrong.Count == 0, $"[{cell}]\n" + string.Join("\n", wrong));
    }

    // ── a refused connection — the third control that did not arrive ─────────────────────────────────────────────────

    [Fact]
    public async Task A_refused_connection_is_transport_on_every_lane()
    {
        var url = ClosedPortUrl();
        var wrong = new List<string>();
        (string? Result, Exception? Error) s2 = default;
        foreach (var lane in TokenLanes)
        {
            using var kc = Facade(url);
            var outcome = await AttemptAsync(() => lane.Run(kc));
            Check(wrong, lane.Name, outcome, Transport($"{lane.Prefix} (transport)"));
            if (lane == S2)
                s2 = outcome;
        }
        Check(wrong, "S5 AdminAsync", await S5Async(url), S5Verdict(s2));
        using (var kc = Facade(url))
        {
            Check(wrong, "IntrospectAsync", await AttemptAsync(async () => (await kc.Auth.IntrospectAsync("tok-sent")).Active.ToString()),
                Transport("introspection transport failure"));
        }
        Assert.True(wrong.Count == 0, string.Join("\n", wrong));
    }

    // ── D1: what is UTF-8 — the edges of the check ──────────────────────────────────────────────────────────────────

    /// <summary>Bytes placed inside a JSON string of a 2xx body (or, for the last two, after the JSON value).</summary>
    private static readonly Dictionary<string, (byte[] Bytes, bool Valid)> Utf8Cases = new(StringComparer.Ordinal)
    {
        ["two-, three- and four-byte sequences"] = (Encoding.UTF8.GetBytes("é한😀"), true),
        ["a lone continuation byte"] = (Bytes(0x80), false),
        ["an overlong encoding of '/'"] = (Bytes(0xC0, 0xAF), false),
        ["a surrogate half encoded as UTF-8"] = (Bytes(0xED, 0xA0, 0x80), false),
        ["a code point past U+10FFFF"] = (Bytes(0xF4, 0x90, 0x80, 0x80), false),
        ["a three-byte sequence cut at the end of the body"] = (Bytes(0xE2, 0x82), false),
    };

    public static IEnumerable<object[]> Utf8CaseNames => Utf8Cases.Keys.Select(k => new object[] { k });

    [Theory]
    [MemberData(nameof(Utf8CaseNames))]
    public async Task A_2xx_body_is_checked_as_UTF8_on_its_raw_bytes(string name)
    {
        var (bad, valid) = Utf8Cases[name];
        var atEnd = name.Contains("end of the body", StringComparison.Ordinal);
        var token = atEnd ? Bytes(GoodToken, bad) : Bytes("""{"access_token":"AT-ok-token","token_type":"Bearer","expires_in":300,"scope":"s""", bad, "\"}");
        var introspection = atEnd ? Bytes(GoodIntrospection, bad) : Bytes("""{"active":true,"username":"svc","sub":"s""", bad, "\"}");
        using var idp = new ScriptedIdp((_, path) => path switch
        {
            $"{Oidc}/token" => A(200, Json, token),
            $"{Oidc}/token/introspect" => A(200, Json, introspection),
            _ => A(404, Json, "{}"),
        });
        var wrong = new List<string>();
        using (var kc = Facade(idp.Url))
        {
            Check(wrong, "ClientCredentialsTokenAsync", await AttemptAsync(async () => (await kc.Auth.ClientCredentialsTokenAsync()).AccessToken),
                valid ? Ok("AT-ok-token") : Auth("Client credentials grant failed: response is not valid UTF-8"));
            Check(wrong, "IntrospectAsync", await AttemptAsync(async () => (await kc.Auth.IntrospectAsync("tok-sent")).Username ?? "null"),
                valid ? Ok("svc") : Auth($"{IntroPrefix}: response is not valid UTF-8"));
        }
        Assert.True(wrong.Count == 0, $"[{name}]\n" + string.Join("\n", wrong));
    }

    // ── S5 inside an admin call ─────────────────────────────────────────────────────────────────────────────────────

    /// <summary>Cells for the refetch below — a code, the status deciding over invalid UTF-8, a body that is not JSON, one that
    /// is not UTF-8, and one that did not arrive.</summary>
    public static IEnumerable<object[]> RefetchCells =>
        new[] { "401 invalid_client", "r8u 400 invalid UTF-8 in the error body", "r2 200 HTML", "r9 200 invalid UTF-8 inside the token", "t cut short" }
            .Select(c => new object[] { c });

    /// <summary>The admin facade fetches its token again inside an admin call once the cached one lapses. That failure is the
    /// provider's too: the admin call ends in exactly what S2 gives for the same reply — the same type, message and
    /// <c>OAuthError</c> — and its admin request is not sent.</summary>
    [Theory]
    [MemberData(nameof(RefetchCells))]
    public async Task An_admin_calls_own_token_refetch_ends_in_what_S2_gives_for_the_same_reply(string cell)
    {
        var failing = 0;
        using var idp = new ScriptedIdp((_, path) => path switch
        {
            // expires_in 1 is inside the provider's 30 s skew, so every admin request fetches a new token.
            $"{Oidc}/token" => Volatile.Read(ref failing) == 1
                ? TokenCells[cell]
                : A(200, Json, """{"access_token":"AT-ok-token","token_type":"Bearer","expires_in":1}"""),
            UserPath => A(200, Json, """{"id":"u1","username":"u"}"""),
            _ => A(404, Json, "{}"),
        });
        using var kc = Facade(idp.Url);
        var admin = await kc.AdminAsync();
        Assert.Equal("u1", (await admin.Users.GetAsync("u1")).Id);
        var sent = idp.AdminRequests().Count;

        Volatile.Write(ref failing, 1);
        var s5 = await AttemptAsync(async () => (await admin.Users.GetAsync("u1")).Id ?? "null");
        var s2 = await AttemptAsync(() => new ClientCredentialsTokenProvider(kc.Auth).GetAccessTokenAsync());

        Assert.NotNull(s2.Error); // the cell fails S2 — otherwise the comparison below proves nothing
        var wrong = new List<string>();
        Check(wrong, "S5 refetch", s5, S5Verdict(s2));
        Assert.True(wrong.Count == 0, $"[{cell}]\n" + string.Join("\n", wrong));
        Assert.Equal(sent, idp.AdminRequests().Count);
    }

    // ── the wrapper is invisible to System.Net.Http's telemetry ─────────────────────────────────────────────────────

    /// <summary>Each token and introspection request is one request to System.Net.Http's telemetry, as it was before these
    /// requests went through the SDK's wrapper (<c>TokenEndpointInvoker</c>). Measured on the first cut of the wrapper — a plain
    /// <see cref="HttpMessageInvoker"/> around a handler: <c>HttpMessageInvoker.SendAsync</c> logs <c>RequestStart</c> for a
    /// request no <see cref="HttpClient"/> has sent yet, and the client then logs its own — 6 for these 3 requests.</summary>
    [Fact]
    public async Task A_token_or_introspection_request_is_one_request_to_the_telemetry()
    {
        using var idp = new ScriptedIdp((_, path) => path switch
        {
            $"{Oidc}/token" => A(200, Json, GoodToken),
            $"{Oidc}/token/introspect" => A(200, Json, GoodIntrospection),
            _ => A(404, Json, "{}"),
        });
        using var starts = new RequestStarts(new Uri(idp.Url).Port);
        using var kc = Facade(idp.Url);

        await kc.Auth.ClientCredentialsTokenAsync();
        await kc.Auth.RefreshAsync("rt-sent");
        await kc.Auth.IntrospectAsync("tok-sent");

        Assert.Equal(3, starts.Count);
    }

    /// <summary>Counts System.Net.Http's <c>RequestStart</c> events for one port — the fake IdP's, so requests other tests send
    /// meanwhile are not counted.</summary>
    private sealed class RequestStarts : System.Diagnostics.Tracing.EventListener
    {
        private readonly int _port;
        private int _count;

        public RequestStarts(int port) => _port = port;

        public int Count => Volatile.Read(ref _count);

        protected override void OnEventSourceCreated(System.Diagnostics.Tracing.EventSource eventSource)
        {
            if (eventSource.Name == "System.Net.Http")
                EnableEvents(eventSource, System.Diagnostics.Tracing.EventLevel.Informational);
        }

        protected override void OnEventWritten(System.Diagnostics.Tracing.EventWrittenEventArgs eventData)
        {
            // RequestStart(scheme, host, port, pathAndQuery, …)
            if (eventData.EventName == "RequestStart" && eventData.Payload is { Count: > 2 } payload && payload[2] is int port && port == _port)
                Interlocked.Increment(ref _count);
        }
    }

    // ── helpers ─────────────────────────────────────────────────────────────────────────────────────────────────────

    private static KeycloakClient Facade(string url) =>
        KeycloakClient.Create(new KeycloakConfig { ServerUrl = url, Realm = "r", ClientId = "c", ClientSecret = Secret });

    private static async Task<(string? Result, Exception? Error)> AttemptAsync(Func<Task<string>> run)
    {
        try { return (await run(), null); }
        catch (Exception e) { return (null, e); }
    }

    private static string Verdict((string? Result, Exception? Error) outcome) => outcome.Error switch
    {
        null => Ok(outcome.Result ?? "null"),
        KeycloakAuthException a => Auth(a.Message, a.OAuthError),
        KeycloakTransportException t => Transport(t.Message),
        var e => $"{e.GetType().FullName}: {e.Message}",
    };

    /// <summary>The verdict, and — for a failure — that nothing the response or the request carried reaches the error:
    /// not the body (its canary), not the client secret.</summary>
    private static void Check(List<string> wrong, string lane, (string? Result, Exception? Error) outcome, string want)
    {
        var got = Verdict(outcome);
        if (got != want)
            wrong.Add($"{lane}: {got}\n      want {want}");
        if (outcome.Error is { } e)
        {
            var printed = e.ToString();
            foreach (var secret in new[] { Canary, Secret })
            {
                if (printed.Contains(secret, StringComparison.Ordinal))
                    wrong.Add($"{lane}: ToString() carries {secret}");
            }
        }
    }

    /// <summary>A loopback URL nothing listens on — a refused connection.</summary>
    private static string ClosedPortUrl()
    {
        var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        var port = ((IPEndPoint)listener.LocalEndpoint).Port;
        listener.Stop();
        return $"http://127.0.0.1:{port}";
    }

    /// <summary>
    /// An HTTP/1.1 IdP on a raw socket — one request per connection (<c>Connection: close</c>), and the answer its route gives,
    /// byte for byte: the <c>Content-Type</c> as written, the body's own bytes, and a <c>Content-Length</c> that can promise more
    /// than is sent.
    /// </summary>
    private sealed class ScriptedIdp : IDisposable
    {
        private readonly TcpListener _listener = new(IPAddress.Loopback, 0);
        private readonly CancellationTokenSource _cts = new();
        private readonly Func<string, string, Answer> _route;
        private readonly ConcurrentQueue<string> _seen = new();
        private readonly Task _loop;

        public ScriptedIdp(Func<string, string, Answer> route)
        {
            _route = route;
            _listener.Start();
            Url = $"http://127.0.0.1:{((IPEndPoint)_listener.LocalEndpoint).Port}";
            _loop = Task.Run(AcceptLoopAsync);
        }

        public string Url { get; }

        /// <summary>Every admin request seen so far, as <c>"METHOD /path"</c>.</summary>
        public List<string> AdminRequests() => _seen.Where(r => r.Split(' ')[1].StartsWith("/admin/", StringComparison.Ordinal)).ToList();

        private async Task AcceptLoopAsync()
        {
            while (!_cts.IsCancellationRequested)
            {
                TcpClient client;
                try { client = await _listener.AcceptTcpClientAsync(_cts.Token); }
                catch (Exception e) when (e is OperationCanceledException or SocketException or ObjectDisposedException) { return; }
                _ = Task.Run(() => ServeAsync(client));
            }
        }

        private async Task ServeAsync(TcpClient client)
        {
            using (client)
            {
                try
                {
                    var stream = client.GetStream();
                    var (method, path) = await ReadRequestAsync(stream);
                    _seen.Enqueue($"{method} {path}");
                    var answer = _route(method, path);
                    var head = $"HTTP/1.1 {answer.Status} X\r\nContent-Type: {answer.ContentType}\r\nConnection: close\r\n" +
                               $"Content-Length: {answer.DeclaredLength ?? answer.Body.Length}\r\n\r\n";
                    await stream.WriteAsync(Encoding.ASCII.GetBytes(head), _cts.Token);
                    await stream.WriteAsync(answer.Body, _cts.Token);
                    await stream.FlushAsync(_cts.Token);
                }
                catch (Exception e) when (e is IOException or SocketException or ObjectDisposedException or OperationCanceledException)
                {
                    // The client stopped reading — what a cap does.
                }
            }
        }

        private async Task<(string Method, string Path)> ReadRequestAsync(NetworkStream stream)
        {
            var buf = new MemoryStream();
            var chunk = new byte[16384];
            int headEnd;
            while ((headEnd = IndexOfHeaderEnd(buf)) < 0)
            {
                var n = await stream.ReadAsync(chunk, _cts.Token);
                if (n == 0)
                    throw new IOException("request ended before its headers");
                buf.Write(chunk, 0, n);
            }
            var head = Encoding.ASCII.GetString(buf.GetBuffer(), 0, headEnd).Split("\r\n");
            var length = head.Skip(1).Select(l => l.Split(':', 2))
                .Where(kv => kv.Length == 2 && kv[0].Trim().Equals("Content-Length", StringComparison.OrdinalIgnoreCase))
                .Select(kv => int.Parse(kv[1].Trim(), CultureInfo.InvariantCulture)).FirstOrDefault();
            while (buf.Length - (headEnd + 4) < length)
            {
                var n = await stream.ReadAsync(chunk, _cts.Token);
                if (n == 0)
                    throw new IOException("request ended before its body");
                buf.Write(chunk, 0, n);
            }
            var line = head[0].Split(' ');
            return (line[0], line[1].Split('?')[0]);
        }

        private static int IndexOfHeaderEnd(MemoryStream buf)
        {
            var b = buf.GetBuffer();
            for (var i = 0; i + 3 < buf.Length; i++)
            {
                if (b[i] == '\r' && b[i + 1] == '\n' && b[i + 2] == '\r' && b[i + 3] == '\n')
                    return i;
            }
            return -1;
        }

        public void Dispose()
        {
            _cts.Cancel();
            _listener.Stop();
            try { _loop.Wait(TimeSpan.FromSeconds(5)); }
            catch (AggregateException) { /* the accept loop ended on the cancellation */ }
            _cts.Dispose();
        }
    }
}
