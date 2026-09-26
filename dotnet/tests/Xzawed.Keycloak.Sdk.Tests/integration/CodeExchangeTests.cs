using System.Collections;
using System.Collections.Concurrent;
using System.Diagnostics.Tracing;
using System.Text;
using System.Web;
using Microsoft.IdentityModel.Tokens;
using Xunit;
using Xunit.Abstractions;
using Xzawed.Keycloak;

namespace Xzawed.Keycloak.Sdk.Tests.Integration;

/// <summary>
/// 인가 코드 교환 E2E — 실제 Keycloak 이 발급한 코드·id_token 으로.
/// <c>ExchangeCodeAsync</c> 의 nonce 대조와 id_token 서명 검증은 지금까지 목 토큰(WireMock)으로만 돌았다. 여기서는
/// <see cref="BrowserLogin"/> 으로 실제 로그인해 받은 코드를 교환하고, <b>서버가 서명한</b> 토큰에 대고 거부 경로까지 돈다.
/// realm 은 <c>testdata/it-realm-realm.json</c> 의 <c>it-web</c>(RS256 · PKCE S256 강제 · aud 매퍼)과
/// <c>it-web-hs256</c>(id_token 을 realm 의 HMAC 키로 서명) — python 사본과 같은 객체다.
/// 서명만 틀린 RS256 id_token(nonce 일치)은 실서버가 만들 수 없다 — 단위 <c>AuthClientTests.ExchangeCode_untrusted_idtoken_throws</c> 가 잰다.
/// id_token 부재 · 길이가 같은 틀린 nonce · 호출자의 redirect_uri · 새 refresh token · 성공 교환의 출력은 Grok 레그가
/// 「이 스위트가 초록인 채 남는 변이」로 지목해 실측한 뒤 더했다.
/// </summary>
[Collection("keycloak")]
[Trait("Category", "Integration")]
public sealed class CodeExchangeTests
{
    private const string RedirectUri = "http://localhost/it-callback";
    private const string AliceName = "alice";
    private const string AlicePassword = "alice-password";

    // ⚠️ it-web 의 audience 매퍼는 introspect 용이다 — `aud` 가 없는 접근 토큰을 Keycloak 26.6 은 발급한 그
    // 클라이언트가 물어도 {"active": false} 로 답한다(python 파일럿 실측; aud=it-web 을 넣으면 true).
    private static readonly Dictionary<string, string> WebClientSecrets = new()
    {
        ["it-web"] = "it-web-secret",
        ["it-web-hs256"] = "it-web-hs256-secret",
    };

    private readonly KeycloakFixture _kc;
    private readonly ITestOutputHelper _out;

    public CodeExchangeTests(KeycloakFixture kc, ITestOutputHelper output)
    {
        _kc = kc;
        _out = output;
    }

    private KeycloakClient WebClient(string clientId = "it-web", string[]? algorithms = null, string[]? scopes = null) =>
        KeycloakClient.Create(new KeycloakConfig
        {
            ServerUrl = _kc.BaseUrl,
            Realm = KeycloakFixture.Realm,
            ClientId = clientId,
            ClientSecret = WebClientSecrets[clientId],
            SignatureAlgorithms = algorithms ?? new[] { "RS256" },
            Scopes = scopes ?? Array.Empty<string>(),
        });

    private static async Task<(AuthorizationRequest Request, string Code)> LoginAsync(KeycloakClient kc)
    {
        var request = kc.Auth.CreateAuthorizationRequest(RedirectUri);
        return (request, await BrowserLogin.LoginAsync(request, RedirectUri, AliceName, AlicePassword));
    }

    /// <summary>alice 의 사용자 id — 토큰의 <c>sub</c> 와 대조할 <b>독립 원천</b>(admin API)에서 읽는다.</summary>
    private async Task<string> AliceIdAsync()
    {
        await using var kc = KeycloakClient.Create(new KeycloakConfig
        {
            ServerUrl = _kc.BaseUrl,
            Realm = KeycloakFixture.Realm,
            ClientId = KeycloakFixture.ClientId,
            ClientSecret = KeycloakFixture.ClientSecret,
        });
        var admin = await kc.AdminAsync();
        var alice = Assert.Single(await admin.Users.SearchAsync(AliceName), u => u.Username == AliceName);
        Assert.False(string.IsNullOrEmpty(alice.Id));
        return alice.Id!;
    }

    [Fact]
    public async Task Exchange_code_binds_tokens_to_the_nonce_and_user()
    {
        await using var kc = WebClient();
        var (request, code) = await LoginAsync(kc);
        var tokens = await kc.Auth.ExchangeCodeAsync(code, RedirectUri, request.CodeVerifier, request.Nonce);
        Assert.False(string.IsNullOrEmpty(tokens.AccessToken));
        Assert.False(string.IsNullOrEmpty(tokens.RefreshToken));
        Assert.False(string.IsNullOrEmpty(tokens.IdToken));
        var id = await kc.Auth.ValidateAsync(tokens.IdToken!);
        Assert.Equal(request.Nonce, Assert.IsType<string>(id.Claims["nonce"]));
        Assert.Equal(await AliceIdAsync(), id.Subject);

        // refresh: 새 접근 토큰을 준다 — 같은 사용자의 활성 토큰이다.
        var refreshed = await kc.Auth.RefreshAsync(tokens.RefreshToken!);
        Assert.False(string.IsNullOrEmpty(refreshed.AccessToken));
        Assert.NotEqual(tokens.AccessToken, refreshed.AccessToken);
        Assert.False(string.IsNullOrEmpty(refreshed.RefreshToken));
        // 새 refresh token 이다 — 입력을 되돌려주는 SDK 도 아래 logout 까지 통과한다(Keycloak 은 옛 것으로도 logout 을 받는다).
        Assert.NotEqual(tokens.RefreshToken, refreshed.RefreshToken);
        var active = await kc.Auth.IntrospectAsync(refreshed.AccessToken);
        Assert.True(active.Active);
        Assert.Equal(AliceName, active.Username);

        // logout: 세션을 끝낸다 — 그 refresh token 은 더는 갱신되지 않고 접근 토큰은 비활성이 된다.
        await kc.Auth.LogoutAsync(refreshed.RefreshToken!);
        var ended = await Assert.ThrowsAsync<KeycloakAuthException>(() => kc.Auth.RefreshAsync(refreshed.RefreshToken!));
        Assert.Equal("invalid_grant", ended.OAuthError);
        Assert.False((await kc.Auth.IntrospectAsync(refreshed.AccessToken)).Active);
    }

    [Fact]
    public async Task Exchange_code_refuses_a_nonce_the_server_did_not_sign()
    {
        await using var kc = WebClient();
        var (request, code) = await LoginAsync(kc);
        // 길이가 같고 마지막 한 글자만 다르다 — 길이·접두만 보는 비교는 이 nonce 를 통과시킨다.
        var wrong = request.Nonce[..^1] + (request.Nonce[^1] == 'A' ? 'B' : 'A');
        var refused = await Assert.ThrowsAsync<KeycloakAuthException>(
            () => kc.Auth.ExchangeCodeAsync(code, RedirectUri, request.CodeVerifier, wrong));
        Assert.Equal("id_token nonce mismatch", refused.Message);
        Assert.Null(refused.OAuthError);      // 서버가 아니라 SDK 가 거부했다
        Assert.Null(refused.InnerException);  // 서명·iss·aud·exp 는 통과했다 — 거부 사유는 nonce 하나다
    }

    /// <summary>nonce 를 빼고 인가받은 코드 — 서버는 nonce 없는 id_token 을 낸다. 부재도 거부다.</summary>
    [Fact]
    public async Task Exchange_code_refuses_an_id_token_that_carries_no_nonce()
    {
        await using var kc = WebClient();
        var request = BrowserLogin.StripNonce(kc.Auth.CreateAuthorizationRequest(RedirectUri));
        // 전제: 서버가 정말 nonce 없이 서명한다(아니면 아래는 부재가 아니라 불일치를 잰다).
        var code = await BrowserLogin.LoginAsync(request, RedirectUri, AliceName, AlicePassword);
        var unchecked_ = await kc.Auth.ExchangeCodeAsync(code, RedirectUri, request.CodeVerifier);
        Assert.False(string.IsNullOrEmpty(unchecked_.IdToken));
        Assert.False((await kc.Auth.ValidateAsync(unchecked_.IdToken!)).Claims.ContainsKey("nonce"));

        code = await BrowserLogin.LoginAsync(request, RedirectUri, AliceName, AlicePassword);
        var refused = await Assert.ThrowsAsync<KeycloakAuthException>(
            () => kc.Auth.ExchangeCodeAsync(code, RedirectUri, request.CodeVerifier, request.Nonce));
        Assert.Equal("id_token nonce mismatch", refused.Message);
        Assert.Null(refused.InnerException);
    }

    /// <summary><c>openid</c> 없이 인가받은 코드 — 서버는 id_token 을 내지 않는다. nonce 를 기대했으면 그 부재도 거부다
    /// (id_token 을 벗겨 nonce 대조를 건너뛰게 하는 공격의 모양).</summary>
    [Fact]
    public async Task Exchange_code_refuses_a_response_without_an_id_token_when_a_nonce_is_expected()
    {
        await using var kc = WebClient(scopes: new[] { "profile" });
        var (request, code) = await LoginAsync(kc);
        Assert.Equal("profile", HttpUtility.ParseQueryString(new Uri(request.Url).Query)["scope"]);
        // 전제: 서버가 정말 id_token 을 빼고 답한다(아니면 아래는 부재가 아니라 다른 것을 잰다).
        var plain = await kc.Auth.ExchangeCodeAsync(code, RedirectUri, request.CodeVerifier);
        Assert.Null(plain.IdToken);

        (request, code) = await LoginAsync(kc);
        var refused = await Assert.ThrowsAsync<KeycloakAuthException>(
            () => kc.Auth.ExchangeCodeAsync(code, RedirectUri, request.CodeVerifier, request.Nonce));
        Assert.Equal("id_token missing for nonce validation", refused.Message);
    }

    /// <summary>교환은 호출자가 준 redirect_uri 를 보낸다 — 인가 때와 다르면 서버가 거부한다(RFC 6749 §4.1.3).
    /// 다른 테스트는 전부 같은 상수를 넘기므로, SDK 가 값을 고정해 보내도 그쪽은 초록이다.</summary>
    [Fact]
    public async Task Exchange_code_sends_the_callers_redirect_uri()
    {
        await using var kc = WebClient();
        var (request, code) = await LoginAsync(kc);
        var refused = await Assert.ThrowsAsync<KeycloakAuthException>(
            () => kc.Auth.ExchangeCodeAsync(code, RedirectUri + "-elsewhere", request.CodeVerifier, request.Nonce));
        Assert.Equal("invalid_grant", refused.OAuthError);
    }

    [Fact]
    public async Task Reused_code_is_refused_without_leaking_it()
    {
        await using var kc = WebClient();
        var (request, code) = await LoginAsync(kc);

        // 로그인 자체의 기록(콜백 URL 에 코드가 실린다)은 SDK 의 누출이 아니다 — 교환부터 잰다. 성공한 첫 교환도 창 안에
        // 둔다: 성공 경로에서 찍는 SDK 도 실패 경로만 보면 통과한다.
        TokenSet tokens;
        KeycloakAuthException reused;
        string streams;
        string events;
        var (stdout, stderr) = (Console.Out, Console.Error);
        using (var capturedOut = new StringWriter())
        using (var capturedErr = new StringWriter())
        using (var listener = new EventCapture())
        {
            Console.SetOut(capturedOut);
            Console.SetError(capturedErr);
            try
            {
                tokens = await kc.Auth.ExchangeCodeAsync(code, RedirectUri, request.CodeVerifier, request.Nonce);
                reused = await Assert.ThrowsAsync<KeycloakAuthException>(
                    () => kc.Auth.ExchangeCodeAsync(code, RedirectUri, request.CodeVerifier, request.Nonce));
            }
            finally
            {
                Console.SetOut(stdout);
                Console.SetError(stderr);
            }
            streams = capturedOut.ToString() + capturedErr.ToString();
            events = listener.Text;
        }
        Assert.Equal("invalid_grant", reused.OAuthError);
        // 계측이 살아 있었다는 대조 — 교환 요청이 이벤트에 찍혔다(안 찍혔으면 아래 「없음」은 공허하다).
        Assert.Contains("/protocol/openid-connect/token", events);
        _out.WriteLine($"captured {events.Length} chars of EventSource payloads, {streams.Length} chars of console output");

        // 문자열·디버그 표현 · 예외 사슬 전부(ToString 이 사슬을 걷는다) · Data · EventSource(= .NET 의 DEBUG 로그) · 콘솔
        var printed = string.Join("\n", Chain(reused).SelectMany(Rendered)) + $"\n{reused}\n" + streams + events;
        var secret = WebClientSecrets["it-web"];
        var hidden = new[]
        {
            code, request.CodeVerifier, secret, tokens.AccessToken, tokens.RefreshToken!, tokens.IdToken!,
            // 시크릿의 와이어 형태 — Duende 는 client_secret_basic 으로 보낸다(Authorization: Basic base64(id:secret)).
            Convert.ToBase64String(Encoding.UTF8.GetBytes($"it-web:{secret}")),
        };
        foreach (var value in hidden)
        {
            Assert.False(string.IsNullOrEmpty(value));
            Assert.DoesNotContain(value, reused.Message);
            Assert.DoesNotContain(value, reused.ToString());
            Assert.DoesNotContain(value, printed);
        }
    }

    /// <summary><c>it-web-hs256</c> 의 id_token 은 realm 의 HMAC 키로 서명된다 — 대칭키는 JWKS 에 없다.</summary>
    /// <remarks>⚠️ <b>두 행은 .NET 에서 같은 이유로 거부된다</b>(python 은 둘이 갈린다: 핀 → 서명 오류, 핀 해제 → 키 오류).
    /// IdentityModel 은 알고리즘 핀보다 kid 조회를 먼저 해서, RS256 만 허용해도 IDX10503(kid 가 JWKS 에 없다)이 난다(실측).
    /// 그래서 실서버로는 핀 자체가 판정하는 경로에 닿지 않는다 — 핀은 단위 <c>JwtValidatorTests.Algorithm_pin_violation_rejected</c>
    /// 와 <c>Hs256_forged_with_rsa_public_key_rejected</c> 가 잰다. 여기서 두 행이 지키는 것은 「HS256 을 허용으로 열어도 JWKS
    /// 밖 키는 통과하지 않는다」와 그 사유다.</remarks>
    [Theory]
    [InlineData("RS256")]
    [InlineData("RS256,HS256")]
    public async Task Id_token_signed_by_a_key_outside_the_jwks_is_refused(string algorithms)
    {
        await using var kc = WebClient("it-web-hs256", algorithms: algorithms.Split(','));
        var (request, code) = await LoginAsync(kc);
        var refused = await Assert.ThrowsAsync<KeycloakAuthException>(
            () => kc.Auth.ExchangeCodeAsync(code, RedirectUri, request.CodeVerifier, request.Nonce));
        Assert.Equal("id_token validation failed", refused.Message);
        var validation = Assert.IsType<KeycloakTokenValidationException>(refused.InnerException);
        Assert.IsType<SecurityTokenSignatureKeyNotFoundException>(validation.InnerException);
    }

    private static IEnumerable<Exception> Chain(Exception e)
    {
        for (Exception? x = e; x is not null; x = x.InnerException)
            yield return x;
    }

    private static IEnumerable<string> Rendered(Exception e)
    {
        yield return e.GetType().FullName ?? "";
        yield return e.Message;
        yield return e.ToString();
        yield return $"{e}";
        foreach (DictionaryEntry entry in e.Data)
            yield return $"{entry.Key}={entry.Value}";
    }

    /// <summary>SDK 경계가 쓰는 두 라이브러리의 공개 EventSource 를 Verbose 로 켜 페이로드를 모은다 — .NET 에서 「모든
    /// 로거의 DEBUG」에 해당한다: IdentityModel(<c>Microsoft.IdentityModel.EventSource</c>)과 HttpClient 텔레메트리(<c>System.Net.*</c>).
    /// <list type="bullet">
    /// <item>⚠️ 전부 켜면 안 된다 — <c>ArrayPoolEventSource</c> 는 이 리스너가 문자열을 만들 때 빌리는 버퍼마다 이벤트를 내
    /// 스택이 넘친다(실측: 테스트 호스트 Stack overflow).</item>
    /// <item>⚠️ <c>Private.InternalDiagnostics.System.Net.*</c> 는 뺀다 — 런타임의 <b>와이어 트레이스</b>다. <c>Sockets/DumpBuffer</c>
    /// 는 소켓 버퍼 원문(= 폼 본문의 code·verifier)을, <c>Http/HandlerMessage</c> 는 요청 헤더(<c>Authorization: Basic</c>)를 싣는다
    /// (실측). 어느 .NET HTTP 클라이언트든 같고, SDK 가 자기 요청 바이트를 소켓 트레이스에서 감출 길은 없다.</item>
    /// </list></summary>
    private sealed class EventCapture : EventListener
    {
        // ⚠️ 필드 초기화자는 기반 생성자보다 먼저 돈다 — 기반 생성자가 OnEventSourceCreated 를 부르며 이벤트가 곧바로 올 수 있다.
        private readonly ConcurrentQueue<string> _lines = new();

        public string Text => string.Join("\n", _lines);

        protected override void OnEventSourceCreated(EventSource eventSource)
        {
            if (eventSource.Name.StartsWith("Microsoft.IdentityModel", StringComparison.Ordinal)
                || eventSource.Name.StartsWith("System.Net.", StringComparison.Ordinal))
            {
                EnableEvents(eventSource, EventLevel.Verbose, EventKeywords.All);
            }
        }

        protected override void OnEventWritten(EventWrittenEventArgs eventData)
        {
            // 바이트 페이로드는 글자로 푼다 — "System.Byte[]" 로 찍으면 그 안의 비밀이 검사에서 사라진다.
            var payload = eventData.Payload is { } p
                ? string.Join(" | ", p.Select(x => x is byte[] bytes ? Encoding.UTF8.GetString(bytes) : x))
                : "";
            _lines?.Enqueue($"{eventData.EventSource.Name}/{eventData.EventName}: {eventData.Message} {payload}");
        }
    }
}
