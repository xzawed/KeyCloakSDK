using System.Reflection;
using System.Runtime.CompilerServices;
using System.Security.Cryptography;
using System.Text;
using Keycloak.AuthServices.Sdk.Admin.Models;
using Microsoft.IdentityModel.JsonWebTokens;
using Microsoft.IdentityModel.Tokens;
using WireMock.RequestBuilders;
using WireMock.ResponseBuilders;
using WireMock.Server;
using Xunit;
using Xunit.Abstractions;
using Xzawed.Keycloak.Admin;

namespace Xzawed.Keycloak.Sdk.Tests;

/// <summary>
/// 바닥 계약(기본 문자열 표현이 비밀을 찍지 않는다)을 <b>손으로 고른 값 타입이 아니라 도달 가능한 객체 전부</b>에
/// 건다. <c>MaskingTests</c>·<c>TokenProviderTests</c> 는 손으로 고른 자리를 재는데, 그 밖의 자리는 아무도 안
/// 잰다 — <c>ClientCredentialsTokenProvider+Cached</c> 가 캐시된 액세스 토큰을 원문으로 찍던 것(#594)이 바로
/// 그 「손 목록 밖」이었다. Go <c>facade_dump_test.go</c>·PHP <c>FacadeDumpTest.php</c> 와 같은 모양이다.
/// </summary>
/// <remarks>
/// <para>⚠️ <b>새 자리를 스스로 찾는 것이 요점이다</b>(등록부 <c>guard-detection-surface-hand-narrowed</c>).
/// 검사 대상은 (1) 공개 API 로 만든 뿌리에서 리플렉션으로 <b>닿는 SDK 어셈블리의 객체 전부</b>이고(비공개 필드까지),
/// (2) <c>typeof(KeycloakClient).Assembly.GetTypes()</c> 로 얻은 <b>선언 타입 전수</b>가 그 걷기에 걸렸는지
/// 대조한다. 인스턴스가 있을 수 없는 타입(정적 클래스·인터페이스)은 규칙으로 빠지고, 그 밖의 면제는
/// 이유와 함께 <see cref="Exempt"/> 에 적는다.</para>
/// <para>바닥 경로는 <c>obj.ToString()</c> 과 보간 <c>$"{obj}"</c> 둘이다. JSON·Serilog <c>{@}</c> 는 바닥
/// 밖이다(<c>.claude/rules/dotnet.md</c> 가 그 경계를 적는다).</para>
/// <para>⚠️ 하네스 위생: 카나리아는 <c>const</c>·지역값이고 테스트 인스턴스에 두지 않는다. 뿌리는 SDK 자신의
/// 타입만으로 만든다 — 주입 경로의 토큰 소스도 테스트가 만든 가짜가 아니라 <c>kc.Auth</c> 다. 테스트 타입이
/// 그래프에 끼면 그 타입이 쥔 SDK 객체가 「닿았다」로 잘못 세어진다.</para>
/// <para>⚠️ 한계 둘. (1) 카나리아는 뿌리를 만드는 호출이 흘려 넣은 비밀뿐이다 — 새 타입이 이 뿌리들이 안 밟는
/// 경로로 비밀을 받으면 여기 없다. 그때는 그 경로를 뿌리에 더한다. (2) 외부(비 SDK) 객체는
/// <see cref="ForeignHopBudget"/> 단계까지만 따라간다. 그 너머의 SDK <b>타입</b>은 대조가 「안 닿음」으로 잡지만,
/// 이미 닿은 타입의 <b>두 번째 인스턴스</b>가 그 너머에만 있으면 렌더링되지 않는다.</para>
/// </remarks>
[Trait("Category", "Unit")]
public sealed class FacadeDumpTests
{
    private const string Secret = "CANARY-DUMP-CLIENT-SECRET";
    private const string Access = "CANARY-DUMP-ACCESS-TOKEN";
    private const string Refresh = "CANARY-DUMP-REFRESH-TOKEN";
    private const string Id = "CANARY-DUMP-ID-TOKEN";
    private const string Garbage = "CANARY-DUMP-GARBAGE-TOKEN";
    private const string Password = "CANARY-DUMP-ADMIN-PASSWORD";
    private const string Oidc = "/realms/r/protocol/openid-connect";

    /// <summary>
    /// 연속된 외부(비 SDK) 객체를 몇 단계까지 따라가는가. SDK 객체는 외부 컨테이너 한두 단계 안에 있다
    /// (<c>TokenValidationParameters → BackoffConfigurationManager</c>, <c>ConfigurationManager →
    /// BoundedDocumentRetriever</c>, <c>HttpClient → BearerHandler</c>, 컬렉션의 배킹 배열). ⚠️ 한도를 풀면 걷기가
    /// <b>병렬로 도는 다른 테스트와 공유하는 프로세스 상태</b>로 들어간다 — 실측(2026-09-26, 한도 50): 방문 객체가
    /// 단독 실행 3591 → 전체 스위트 19004 로 옆 테스트에 따라 달라졌다(닿은 SDK 타입은 그 실행에서 같았다). 한도 3 은
    /// 두 경우 모두 310 이다. 이 값을 올리려면 같은 두 측정을 다시 하라.
    /// </summary>
    private const int ForeignHopBudget = 3;

    /// <summary>걷기에 안 닿아도 되는 (인스턴스가 있을 수 있는) 타입과 그 이유. ⚠️ 이유 없는 면제는 넣지 않는다.</summary>
    private static readonly Dictionary<string, string> Exempt = new(StringComparer.Ordinal)
    {
        // 셋 다 같은 이유다 — [JsonConverter] 특성을 보고 System.Text.Json 이 만들어 자기 캐시에 둔다. SDK 객체는
        // 인스턴스를 쥐지 않고, 자기 필드가 없다(인스턴스 상태는 JsonConverter 기반의 직렬화 플래그뿐, 실측).
        // 비밀은 Write 가 인자로 받아 곧바로 마스킹할 뿐 보관하지 않는다. JSON 경로 자체는 바닥 밖이다.
        ["Xzawed.Keycloak.AuthorizationRequestJsonConverter"] = "System.Text.Json 이 특성에서 만든다 — SDK 객체가 쥐지 않고 자기 필드가 없다",
        ["Xzawed.Keycloak.KeycloakConfigJsonConverter"] = "System.Text.Json 이 특성에서 만든다 — SDK 객체가 쥐지 않고 자기 필드가 없다",
        ["Xzawed.Keycloak.TokenSetJsonConverter"] = "System.Text.Json 이 특성에서 만든다 — SDK 객체가 쥐지 않고 자기 필드가 없다",
    };

    /// <summary>
    /// 알려진 누출 — <c>"뿌리|카나리아"</c>. ⚠️ 고쳐져 더 안 새면 <b>여기서 지워야 통과한다</b>(낡은 항목 검사).
    /// </summary>
    private static readonly Dictionary<string, string> KnownLeaks = new(StringComparer.Ordinal)
    {
    };

    private readonly ITestOutputHelper _out;

    public FacadeDumpTests(ITestOutputHelper output) => _out = output;

    [Fact]
    public async Task Reachable_objects_do_not_render_secrets()
    {
        // 바닥은 IdentityModel 의 기본값(ShowPII=false) 위에서 잰다 — 켜면 검증 오류 메시지가 토큰 세그먼트를 싣는다
        // (실측: 점 있는 garbage 뿌리만 GARBAGE 를 찍었다). 프로세스 전역 값이라 누가 켰으면 여기서 멈춘다.
        Assert.False(Microsoft.IdentityModel.Logging.IdentityModelEventSource.ShowPII,
            "IdentityModelEventSource.ShowPII 가 켜져 있다 — 다른 테스트가 전역 값을 바꿨다. 이 상태의 누출은 SDK 기본값이 아니다");
        using var rsa = RSA.Create(2048);
        var key = new RsaSecurityKey(rsa) { KeyId = "k1" };
        using var idp = WireMockServer.Start();
        StubIdp(idp, key);
        await using var set = new RootSet();
        await BuildRootsAsync(set, idp, key);

        var sdk = typeof(KeycloakClient).Assembly;
        var walker = new Walker(sdk, set.Canaries);
        foreach (var (name, value) in set.Roots)
            walker.Walk(name, value);
        _out.WriteLine($"뿌리 {set.Roots.Count} · 방문 {walker.Visited} · 렌더링 {walker.Rendered}");
        Assert.True(walker.HarnessHits.Count == 0,
            "걷기가 테스트 자신의 객체에 들어갔다 — 오염을 없애라(면제하지 말 것):\n" + string.Join("\n", walker.HarnessHits));

        // ⚠️ 카나리아가 걷기가 잰 객체에 실제로 들어 있었는가 — 없으면 아래 누출 검사는 없는 것을 찾으며 통과한다.
        foreach (var (canary, holder) in new[]
                 {
                     ("SECRET", typeof(KeycloakConfig)),
                     ("ACCESS", typeof(TokenSet)),
                     ("ACCESS", typeof(ClientCredentialsTokenProvider).GetNestedType("Cached", BindingFlags.NonPublic)!),
                     ("REFRESH", typeof(TokenSet)),
                     ("ID", typeof(TokenSet)),
                     ("VERIFIER", typeof(AuthorizationRequest)),
                 })
        {
            Assert.True(walker.HeldBy.TryGetValue(canary, out var holders) && holders.Contains(holder),
                $"카나리아 {canary} 가 {holder.FullName} 에 안 흘렀다 — 가짜 IdP 응답이나 매핑이 바뀌었다 " +
                $"(실제 보유자: {(holders is null ? "없음" : string.Join(", ", holders.Select(h => h.FullName)))})");
        }

        Assert.True(walker.Leaks.Count == 0, "기본 표현이 비밀을 찍는다:\n" + string.Join("\n", walker.Leaks));
        var stale = KnownLeaks.Keys.Where(k => !walker.KnownSeen.Contains(k)).ToList();
        Assert.True(stale.Count == 0,
            "알려진 누출이 더 안 난다 — 고쳐졌으면 KnownLeaks 와 등록부 항목을 함께 닫아라: " + string.Join(", ", stale));

        // 대조 — 선언 타입 전수는 손 목록이 아니라 어셈블리 자신에서 파생한다.
        var declared = sdk.GetTypes().Where(t => !IsCompilerGenerated(t))
            .OrderBy(t => t.FullName, StringComparer.Ordinal).ToList();
        Assert.Contains(typeof(KeycloakClient), declared);
        var noInstances = declared.Where(HasNoInstances).ToList();
        _out.WriteLine($"선언 {declared.Count} · 닿음 {declared.Count(walker.Reached.ContainsKey)} · " +
                       $"인스턴스 없음(규칙) {noInstances.Count} · 면제 {Exempt.Count}");
        foreach (var t in declared)
        {
            var how = walker.Reached.TryGetValue(t, out var path) ? path
                : noInstances.Contains(t) ? "(인스턴스 없음)" : Exempt.ContainsKey(t.FullName!) ? "(면제)" : "(안 닿음)";
            _out.WriteLine($"  {t.FullName} ← {how}");
        }

        var problems = new List<string>();
        foreach (var t in declared)
        {
            var name = t.FullName!;
            var reached = walker.Reached.ContainsKey(t);
            var exempt = Exempt.ContainsKey(name);
            if (reached && exempt)
                problems.Add($"{name}: 걷기에 닿는데 면제 표에도 있다 — 면제를 지워라");
            else if (exempt && noInstances.Contains(t))
                problems.Add($"{name}: 인스턴스가 있을 수 없어 규칙으로 빠지는데 면제 표에도 있다 — 면제를 지워라");
            else if (!reached && !exempt && !noInstances.Contains(t))
                problems.Add($"{name}: 공개 API 뿌리에서 닿지 않는 타입이다 — 만드는 경로를 뿌리에 더하거나, 이유와 함께 면제하라");
        }
        foreach (var name in Exempt.Keys.Where(n => declared.All(t => t.FullName != n)))
            problems.Add($"{name}: 면제 표에 있지만 선언이 없다 — 낡은 면제다");
        Assert.True(problems.Count == 0, string.Join("\n", problems));
    }

    // ── 뿌리 ────────────────────────────────────────────────────────────────────────────────────

    private sealed class RootSet : IAsyncDisposable
    {
        public List<(string Name, object Value)> Roots { get; } = new();
        public Dictionary<string, string> Canaries { get; } = new(StringComparer.Ordinal);
        public List<IDisposable> Owned { get; } = new();

        public ValueTask DisposeAsync()
        {
            foreach (var d in Owned) d.Dispose();
            return ValueTask.CompletedTask;
        }
    }

    /// <summary>공개 API 로 뿌리를 만들고, 그 과정이 흘려 넣은 비밀 전부를 카나리아로 남긴다.</summary>
    private static async Task BuildRootsAsync(RootSet set, WireMockServer idp, RsaSecurityKey key)
    {
        var url = idp.Urls[0];
        var cfg = new KeycloakConfig { ServerUrl = url, Realm = "r", ClientId = "c", ClientSecret = Secret };

        var kc = KeycloakClient.Create(cfg);
        set.Owned.Add(kc);
        // 기본 경로의 admin — 내부에서 만든 provider 가 워밍업에서 토큰을 캐시한 뒤라야 그 캐시가 걷기에 걸린다.
        var admin = await kc.AdminAsync();
        var ts = await kc.Auth.ClientCredentialsTokenAsync();
        var ar = kc.Auth.CreateAuthorizationRequest("https://app/cb");
        var ir = await kc.Auth.IntrospectAsync(Access);
        var jwt = Sign(key, $"{url}/realms/r", "c");
        var vt = await kc.Auth.ValidateAsync(jwt);

        // 주입 경로 — 소비자가 직접 만드는 provider 와 admin. 소스는 SDK 자신의 AuthClient 다(하네스 위생).
        var provider = new ClientCredentialsTokenProvider(kc.Auth);
        var providerToken = await provider.GetAccessTokenAsync();
        var injected = await AdminClient.CreateAsync(cfg, provider);
        set.Owned.Add(injected);

        // 저수준 공개 생성자 — JwtValidatorOptions 는 이 경로에서만 소비자 손에 있다(파사드는 값을 복사하고 버린다).
        var http = new HttpClient();
        set.Owned.Add(http);
        var ep = OidcEndpoints.For(url, "r");
        var opts = new JwtValidatorOptions { Issuer = ep.Issuer, Audiences = new[] { "c" } };
        var validator = new JwtValidator(ep.Issuer, opts, http);
        var lowLevel = new AuthClient(cfg, ep, validator, http);

        // ⚠️ 카나리아가 실제로 흘러 들어갔는가 — 공개 값으로 먼저 본다(걷기 쪽 확인은 HeldBy).
        Assert.Equal((Access, Refresh, Id), (ts.AccessToken, ts.RefreshToken, ts.IdToken));
        Assert.Equal(Access, providerToken);
        Assert.False(string.IsNullOrEmpty(ar.CodeVerifier));
        Assert.Equal("u1", vt.Subject);
        Assert.True(ir.Active);

        // 오류 뿌리 — 전부 실제 실패 호출에서 얻는다(직접 생성하는 것은 없다).
        var bad = KeycloakClient.Create(cfg with { Realm = "bad" });
        var down = KeycloakClient.Create(cfg with { ServerUrl = "http://127.0.0.1:1" });
        var noSecret = KeycloakClient.Create(cfg with { ClientSecret = null });
        // 형식이 틀린 200 응답 둘 — 하위 예외가 응답을 인용하는 자리(MalformedTokenResponseTests 가 모양 전부를 잰다).
        var form = KeycloakClient.Create(cfg with { Realm = "form" });
        var junk = KeycloakClient.Create(cfg with { Realm = "junk" });
        set.Owned.Add(bad);
        set.Owned.Add(down);
        set.Owned.Add(noSecret);
        set.Owned.Add(form);
        set.Owned.Add(junk);
        // provider 는 이미 토큰을 캐시했으므로 워밍업이 네트워크를 안 탄다 — 실패는 그다음 호출에서 난다.
        var downAdmin = await AdminClient.CreateAsync(cfg with { ServerUrl = "http://127.0.0.1:1" }, provider);
        set.Owned.Add(downAdmin);
        var jwtWrongAud = Sign(key, $"{url}/realms/r", "someone-else");
        var user = new UserRepresentation
        {
            Username = "u",
            Credentials = new[] { new CredentialRepresentation { Type = "password", Value = Password, Temporary = false } },
        };

        var transport = await Task.WhenAll(
            FailureOf(() => down.Auth.IntrospectAsync(Access)),
            FailureOf(() => down.Auth.LogoutAsync(Refresh)),
            FailureOf(() => down.Auth.ClientCredentialsTokenAsync()),
            FailureOf(() => downAdmin.Users.GetAsync("u1")));
        var errors = new (string Name, Type Expected, Exception Error)[]
        {
            ("auth error (401 client credentials)", typeof(KeycloakAuthException), await FailureOf(() => bad.Auth.ClientCredentialsTokenAsync())),
            ("auth error (401 refresh)", typeof(KeycloakAuthException), await FailureOf(() => bad.Auth.RefreshAsync(Refresh))),
            ("auth error (id_token rejected)", typeof(KeycloakAuthException),
                await FailureOf(() => kc.Auth.ExchangeCodeAsync("code", "https://app/cb", ar.CodeVerifier, ar.Nonce))),
            // 헤더가 JSON 이 아닌 id_token — IdentityModel 은 PII 를 가린 자기 메시지 밑에 디코드된 헤더를 인용하는 예외를 단다.
            ("auth error (id_token header not JSON)", typeof(KeycloakAuthException),
                await FailureOf(() => junk.Auth.ExchangeCodeAsync("code", "https://app/cb", ar.CodeVerifier, ar.Nonce))),
            ("transport error (200 form-encoded token body)", typeof(KeycloakTransportException),
                await FailureOf(() => form.Auth.ClientCredentialsTokenAsync())),
            ("validation error (garbage)", typeof(KeycloakTokenValidationException), await FailureOf(() => kc.Auth.ValidateAsync(Garbage))),
            // 점이 있으면 IdentityModel 은 다른 경로(헤더 디코드 실패)로 간다 — 그 메시지가 세그먼트를 싣는지 따로 잰다.
            ("validation error (JWT-shaped garbage)", typeof(KeycloakTokenValidationException),
                await FailureOf(() => kc.Auth.ValidateAsync($"{Garbage}.e30.e30"))),
            ("validation error (wrong aud)", typeof(KeycloakTokenValidationException), await FailureOf(() => kc.Auth.ValidateAsync(jwtWrongAud))),
            ("transport error (introspect)", typeof(KeycloakTransportException), transport[0]),
            ("transport error (logout)", typeof(KeycloakTransportException), transport[1]),
            ("transport error (client credentials)", typeof(KeycloakTransportException), transport[2]),
            ("transport error (admin)", typeof(KeycloakTransportException), transport[3]),
            ("config error (Create)", typeof(KeycloakConfigException), FailureOf(() => KeycloakClient.Create(cfg with { ServerUrl = "" }))),
            ("config error (AdminAsync)", typeof(KeycloakConfigException), await FailureOf(() => noSecret.AdminAsync())),
            ("admin 404 (typed users)", typeof(KeycloakNotFoundException), await FailureOf(() => admin.Users.GetAsync("missing"))),
            ("admin 404 (raw clients)", typeof(KeycloakNotFoundException), await FailureOf(() => admin.Clients.GetAsync("missing"))),
            ("admin 409 (create user with password)", typeof(KeycloakConflictException), await FailureOf(() => admin.Users.CreateAsync(user))),
            ("admin 409 (typed update user with password)", typeof(KeycloakConflictException), await FailureOf(() => admin.Users.UpdateAsync("u1", user))),
            ("admin 403 (raw roles)", typeof(KeycloakForbiddenException), await FailureOf(() => admin.Roles.CreateAsync(new RoleRepresentation { Name = "x" }))),
            ("admin 500 (typed groups)", typeof(KeycloakAdminException), await FailureOf(() => admin.Groups.GetAsync("boom"))),
        };
        foreach (var (name, expected, error) in errors)
            Assert.True(error.GetType() == expected, $"{name}: {expected.Name} 가 아니라 {error.GetType().FullName} 이 났다 — {error.Message}");

        // SDK 객체가 쥐지 않는 카나리아는 **선 위에서** 흘렀는지 본다 — 안 실렸으면 그 카나리아의 부재는 아무것도 증명하지 않는다.
        var basic = Convert.ToBase64String(Encoding.UTF8.GetBytes($"c:{Secret}"));
        var wire = idp.LogEntries.Select(e => e.RequestMessage).ToList();
        Assert.True(wire.Count(m => m?.Body?.Contains(Password, StringComparison.Ordinal) == true) >= 2,
            "admin 비밀번호가 create·update 요청 본문에 안 실렸다 — 409 뿌리가 비밀을 거치지 않았다");
        Assert.True(wire.Any(m => m?.Headers is { } h && h.TryGetValue("Authorization", out var v) && v.Contains($"Basic {basic}")),
            "introspect 가 Basic 헤더로 시크릿을 안 보냈다 — BASIC 카나리아의 인코딩이 실제와 다르다");
        Assert.True(wire.Any(m => m?.Body?.Contains(ar.CodeVerifier, StringComparison.Ordinal) == true),
            "code exchange 가 PKCE verifier 를 안 보냈다 — id_token 거절 뿌리가 verifier 를 거치지 않았다");

        // 좁은 뿌리를 먼저 걷는다 — 객체는 처음 닿은 뿌리 이름으로 보고되므로(KnownLeaks 키), 예컨대 기본 경로의
        // 캐시는 KeycloakClient.Create 가 아니라 AdminAsync 아래로 잡힌다.
        set.Roots.AddRange(new (string, object)[]
        {
            ("ClientCredentialsTokenAsync", ts), ("CreateAuthorizationRequest", ar), ("IntrospectAsync", ir),
            ("ValidateAsync", vt), ("ClientCredentialsTokenProvider", provider), ("AdminAsync", admin),
            ("AdminClient.CreateAsync (injected provider)", injected), ("KeycloakClient.Create", kc),
            ("KeycloakConfig", cfg), ("OidcEndpoints.For", ep), ("JwtValidatorOptions", opts),
            ("JwtValidator (public ctor)", validator), ("AuthClient (public ctor)", lowLevel),
        });
        set.Roots.AddRange(errors.Select(e => (e.Name, (object)e.Error)));

        set.Canaries["SECRET"] = Secret;
        set.Canaries["ACCESS"] = Access;
        set.Canaries["REFRESH"] = Refresh;
        set.Canaries["ID"] = Id;
        set.Canaries["GARBAGE"] = Garbage;
        set.Canaries["PASSWORD"] = Password;
        set.Canaries["VERIFIER"] = ar.CodeVerifier;
        set.Canaries["JWT"] = jwt;
        set.Canaries["JWT_WRONG_AUD"] = jwtWrongAud;
        // introspect 의 Basic 헤더 값 — 시크릿의 인코딩된 형태도 비밀이다(위에서 선 위에 실린 것을 확인했다).
        set.Canaries["BASIC"] = basic;
    }

    private static async Task<Exception> FailureOf(Func<Task> call)
    {
        try { await call(); }
        catch (Exception e) { return e; }
        throw new Xunit.Sdk.XunitException("실패 뿌리를 못 만들었다 — 가짜 IdP 가 실패를 안 냈다");
    }

    private static Exception FailureOf(Action call)
    {
        try { call(); }
        catch (Exception e) { return e; }
        throw new Xunit.Sdk.XunitException("실패 뿌리를 못 만들었다 — 호출이 실패하지 않았다");
    }

    /// <summary>가짜 IdP — 토큰·introspect·디스커버리+JWKS·실패 realm·admin 4xx/5xx 를 한 서버가 낸다.</summary>
    private static void StubIdp(WireMockServer idp, RsaSecurityKey key)
    {
        var issuer = $"{idp.Urls[0]}/realms/r";
        var p = key.Rsa!.ExportParameters(false);
        Json(idp, Request.Create().WithPath($"{Oidc}/token").UsingPost(), 200,
            $$"""{"access_token":"{{Access}}","token_type":"Bearer","expires_in":300,"refresh_token":"{{Refresh}}","id_token":"{{Id}}"}""");
        Json(idp, Request.Create().WithPath($"{Oidc}/token/introspect").UsingPost(), 200,
            """{"active":true,"username":"svc","client_id":"c","sub":"u1"}""");
        Json(idp, Request.Create().WithPath("/realms/r/.well-known/openid-configuration").UsingGet(), 200,
            $$"""{"issuer":"{{issuer}}","jwks_uri":"{{issuer}}/protocol/openid-connect/certs"}""");
        Json(idp, Request.Create().WithPath($"{Oidc}/certs").UsingGet(), 200,
            $$"""{"keys":[{"kty":"RSA","kid":"k1","use":"sig","alg":"RS256","n":"{{Base64UrlEncoder.Encode(p.Modulus)}}","e":"{{Base64UrlEncoder.Encode(p.Exponent)}}"}]}""");
        Json(idp, Request.Create().WithPath("/realms/bad/protocol/openid-connect/token").UsingPost(), 401,
            """{"error":"invalid_client","error_description":"Invalid client or Invalid client credentials"}""");
        // System.Text.Json 은 't' 로 시작하는 본문을 첫 구분자까지 전부 인용한다 — 폼 인코딩 본문이면 살아 있는 토큰째.
        idp.Given(Request.Create().WithPath("/realms/form/protocol/openid-connect/token").UsingPost())
            .RespondWith(Response.Create().WithStatusCode(200).WithHeader("Content-Type", "application/x-www-form-urlencoded")
                .WithBody($"token_type=bearer&access_token={Access}"));
        Json(idp, Request.Create().WithPath("/realms/junk/protocol/openid-connect/token").UsingPost(), 200,
            $$"""{"access_token":"x","token_type":"Bearer","expires_in":300,"id_token":"{{Base64UrlEncoder.Encode("t" + Id)}}.e30.c2ln"}""");
        Json(idp, Request.Create().WithPath("/admin/realms/r/users/missing").UsingGet(), 404, """{"error":"User not found"}""");
        Json(idp, Request.Create().WithPath("/admin/realms/r/clients/missing").UsingGet(), 404, """{"error":"Could not find client"}""");
        Json(idp, Request.Create().WithPath("/admin/realms/r/users").UsingPost(), 409, """{"errorMessage":"User exists with same username"}""");
        Json(idp, Request.Create().WithPath("/admin/realms/r/users/u1").UsingPut(), 409, """{"errorMessage":"User exists with same email"}""");
        Json(idp, Request.Create().WithPath("/admin/realms/r/roles").UsingPost(), 403, """{"error":"HTTP 403 Forbidden"}""");
        Json(idp, Request.Create().WithPath("/admin/realms/r/groups/boom").UsingGet(), 500, """{"error":"unknown_error"}""");
    }

    private static void Json(WireMockServer idp, IRequestBuilder request, int status, string body)
        => idp.Given(request).RespondWith(Response.Create().WithStatusCode(status)
            .WithHeader("Content-Type", "application/json").WithBody(body));

    private static string Sign(RsaSecurityKey key, string issuer, string audience)
    {
        var now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        return new JsonWebTokenHandler { SetDefaultTimesOnTokenCreation = false }.CreateToken(
            $$"""{"iss":"{{issuer}}","sub":"u1","aud":"{{audience}}","exp":{{now + 300}},"iat":{{now}}}""",
            new SigningCredentials(key, SecurityAlgorithms.RsaSha256));
    }

    // ── 선언 대조 규칙 ───────────────────────────────────────────────────────────────────────────

    /// <summary>컴파일러가 만든 타입(클로저·상태 기계·임베드 특성) — 선언이 아니다. 감싸는 타입까지 본다.</summary>
    private static bool IsCompilerGenerated(Type t)
    {
        for (var c = t; c is not null; c = c.DeclaringType)
        {
            if (c.IsDefined(typeof(CompilerGeneratedAttribute), false) || c.Name.Contains('<') || c.Name.Contains('>'))
                return true;
        }
        return false;
    }

    /// <summary>
    /// 인스턴스가 있을 수 없는 타입(인터페이스·정적 클래스) — 바닥 경로로 렌더링할 객체가 애초에 없다.
    /// ⚠️ 「인스턴스 필드가 없다」로 넓히지 말 것 — 필드 없는 클래스도 ToString 이 정적 상태를 찍을 수 있다
    /// (변이 실측 2026-09-26: 정적 필드를 찍는 ToString 을 가진 무필드 공개 클래스가 그 규칙으로 빠져 SILENT 였다).
    /// </summary>
    private static bool HasNoInstances(Type t) => t.IsInterface || (t.IsAbstract && t.IsSealed);

    // ── 걷기 ────────────────────────────────────────────────────────────────────────────────────

    private sealed class Walker
    {
        private readonly Assembly _sdk;
        private readonly IReadOnlyDictionary<string, string> _canaries;
        private readonly HashSet<object> _seenOwn = new(ReferenceEqualityComparer.Instance);
        // 외부 객체는 **가장 얕게 닿은 단계**를 기억한다 — 깊게 먼저 닿아 잘린 객체를 얕은 경로가 다시 열 수 있어야
        // 걷기가 뿌리 순서에 좌우되지 않는다.
        private readonly Dictionary<object, int> _foreignBest = new(ReferenceEqualityComparer.Instance);

        public Walker(Assembly sdk, IReadOnlyDictionary<string, string> canaries)
        {
            _sdk = sdk;
            _canaries = canaries;
        }

        /// <summary>닿은 SDK 타입(기반 타입 포함) → 처음 닿은 경로.</summary>
        public Dictionary<Type, string> Reached { get; } = new();

        /// <summary>카나리아 이름 → 그 문자열을 (직접 또는 외부 컨테이너 너머로) 쥔 가장 가까운 SDK 타입들.</summary>
        public Dictionary<string, HashSet<Type>> HeldBy { get; } = new(StringComparer.Ordinal);

        public List<string> Leaks { get; } = new();
        public HashSet<string> KnownSeen { get; } = new(StringComparer.Ordinal);

        /// <summary>걷기가 들어간 테스트 어셈블리 객체 — 있으면 그 너머의 「닿음」과 「누출」은 SDK 가 아니라 하네스 것이다.</summary>
        public List<string> HarnessHits { get; } = new();
        public int Visited { get; private set; }
        public int Rendered { get; private set; }

        public void Walk(string root, object value) => Visit(root, root, value, null, 0);

        private void Visit(string root, string path, object? value, Type? owner, int foreignHops)
        {
            switch (value)
            {
                case null:
                case Pointer:
                    return;
                case string s:
                    NoteHeld(s, owner);
                    return;
            }
            var type = value.GetType();
            if (type.IsPrimitive || type.IsEnum)
                return;
            if (type.Assembly == typeof(FacadeDumpTests).Assembly)
            {
                HarnessHits.Add($"{path} [{type.FullName}]");
                return;
            }

            var own = type.Assembly == _sdk;
            if (own)
            {
                if (!type.IsValueType && !_seenOwn.Add(value))
                    return;
                owner = type;
                foreignHops = 0;
                // 닫힌 제네릭은 GetTypes() 가 내놓는 열린 정의로 센다 — 안 그러면 대조가 영영 「안 닿음」이라 한다.
                for (var t = type; t is not null && t.Assembly == _sdk; t = t.BaseType)
                    Reached.TryAdd(t.IsGenericType ? t.GetGenericTypeDefinition() : t, path);
                Render(root, path, value);
            }
            else
            {
                if (++foreignHops > ForeignHopBudget)
                    return;
                if (!type.IsValueType)
                {
                    if (_foreignBest.TryGetValue(value, out var best) && best <= foreignHops)
                        return;
                    _foreignBest[value] = foreignHops;
                }
            }
            Visited++;

            if (value is Array array)
            {
                if (type.GetElementType() is { IsPrimitive: true })
                    return;
                var i = 0;
                foreach (var item in array)
                    Visit(root, $"{path}[{i++}]", item, owner, foreignHops);
                return;
            }
            for (var t = type; t is not null; t = t.BaseType)
            {
                foreach (var f in t.GetFields(BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.DeclaredOnly))
                    Visit(root, $"{path}.{f.Name}", Read(f, value, own), owner, foreignHops);
            }
        }

        // SDK 필드를 못 읽으면 걷기가 그 자리를 못 잰다 — 삼키지 않고 테스트를 깬다. 외부 내부 구현은 우리 렌더링 대상이 아니다.
        private static object? Read(FieldInfo f, object target, bool own)
        {
            try { return f.GetValue(target); }
            catch (Exception) when (!own) { return null; }
        }

        private void NoteHeld(string s, Type? owner)
        {
            if (owner is null)
                return;
            foreach (var (name, canary) in _canaries)
            {
                if (!s.Contains(canary, StringComparison.Ordinal))
                    continue;
                if (!HeldBy.TryGetValue(name, out var holders))
                    HeldBy[name] = holders = new HashSet<Type>();
                holders.Add(owner);
            }
        }

        private void Render(string root, string path, object value)
        {
            Rendered++;
            var outs = new (string How, string Text)[] { ("ToString()", value.ToString() ?? ""), ("$\"{obj}\"", $"{value}") };
            foreach (var (how, text) in outs)
            {
                foreach (var (name, canary) in _canaries)
                {
                    if (!text.Contains(canary, StringComparison.Ordinal))
                        continue;
                    var key = $"{root}|{name}";
                    if (KnownLeaks.ContainsKey(key))
                    {
                        KnownSeen.Add(key);
                        continue;
                    }
                    Leaks.Add($"{path} [{value.GetType().FullName}] {how}: 비밀 {name} 이 원문으로 찍혔다");
                }
            }
        }
    }
}
