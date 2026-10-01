using System.Collections.Concurrent;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.IdentityModel.JsonWebTokens;
using Microsoft.IdentityModel.Tokens;
using WireMock;
using WireMock.Matchers;
using WireMock.RequestBuilders;
using WireMock.ResponseBuilders;
using WireMock.Server;
using WireMock.Types;
using WireMock.Util;
using Xunit;
using Xunit.Abstractions;

namespace Xzawed.Keycloak.Sdk.Tests;

/// <summary>
/// 적대 경로 행렬 — 분류표를 세우고, 적대 변형을 <b>메서드 손 목록이 아니라 계급에</b> 붙인다
/// (등록부 <c>guard-detection-surface-hand-narrowed</c>). Go <c>hostile_path_matrix_test.go</c> 의 .NET 이식이다.
/// </summary>
/// <remarks>
/// <para>nonce·콜드캐시 백오프·토큰응답 타입검증 축은 <c>scripts/test/test-security-defaults.sh</c> 가 손으로 고른
/// 자리에 앵커를 건다. 그래서 <b>새 공개 교환 경로</b>가 생기면 세 축 모두 그것을 모른다. 여기서는 경로를 파생한다.</para>
/// <list type="bullet">
/// <item><b>선언 집합</b>: <c>FacadeDumpTests</c> 의 뿌리·걷기(<c>Walker</c>)가 닿는 SDK 타입과, 인스턴스가 있을 수 없는
/// 정적 클래스(그 테스트의 <c>HasNoInstances</c> 규칙)의 공개 메서드·공개 생성자 전부 — 오버로드는 따로 센다. 어셈블리의
/// 나머지 타입(걷기가 못 닿는 것)의 공개 멤버는 <c>UNDETERMINED</c> 행이고, 이유 있는 면제가 없으면 실패한다.
/// 컴파일러가 만든 멤버(자동 속성 접근자·record 합성 멤버)와 본문 없는 추상 멤버는 규칙으로 빠진다 — 사람이 쓴 코드가 없다.
/// ⚠️ <b>명시적 인터페이스 구현도 행이다</b>(<c>T.[I.M]</c>) — 메타데이터에서는 private 이라 <c>GetMethods(Public)</c> 에 안 나오고
/// 인터페이스 쪽은 추상이라 규칙으로 빠지므로, 둘 사이로 새 교환 경로가 조용히 빠졌다(Grok 레그 지목, 변이 실측 SILENT).
/// <c>GetInterfaceMap</c> 으로 구현을 찾아 인터페이스 메서드로 부른다.</item>
/// <item><b>호출</b>: 메서드마다 <b>새</b> 클라이언트를 <b>기록하는</b> 가짜 IdP 위에 만들어 리플렉션으로 부른다. 가짜 IdP 는
/// WireMock 하나를 칸마다 고유한 경로 접두(<c>ServerUrl=/hpN</c>)로 가른다 — 칸이 끝난 뒤 늦게 도착한 요청(IdentityModel 의
/// 배경 재조회 류)은 다른 접두라 옆 칸에 섞이지 않는다. 인자는 타입만 보고 합성한다. ⚠️ <c>bool</c> 인자가 있으면 false·true 로
/// 두 번 불러 더 높은 계급을 행의 것으로 삼고, W3 도 그 값으로 부른다 — false 하나면 <c>if (!send) return …</c> 가 교환 경로를 요청
/// 없이 닫아 NONE 으로 읽혔다(Grok 레그 지목, 변이 실측 SILENT).</item>
/// <item><b>분류</b>: 그 호출이 실제로 보낸 요청으로 가른다(<see cref="Classify"/>). 기록은 라우팅 <b>앞</b>(콜백)에서 한다 —
/// WireMock 로그는 응답을 쓴 뒤에 붙을 수 있어 호출이 끝난 순간의 스냅숏에서 빠질 수 있다.</item>
/// </list>
/// <para>단언: (1) 면제 없는 <c>UNDETERMINED</c> 가 없다(낡은 면제는 실패) · (2) <c>CODE_EXCHANGE</c>·<c>TOKEN_GRANT</c>·
/// <c>JWKS_FETCH</c> 가 각각 비어 있지 않다 · (W1) 손으로 고른 테스트가 겨누는 메서드가 전부 기대 계급의 행이고 그 축의 파생
/// 대상이다 — 표는 앵커 본문·보안 기본값 가드의 dotnet 앵커와 대조해 썩지 않게 한다 · (W3a) 토큰 부여·코드 교환 행마다 형식이
/// 틀린 토큰 응답 변형(기존 테스트에서 가져온다) · (W3b) 서명에 nonce 파라미터가 있는 코드 교환 행마다 id_token 변형 — 서명한
/// 다섯과 「nonce 가 다른 인자의 값」, 그리고 기존 테스트가 nonce 교환에만 실패를 단언한 형식 변형 · 거부 오류는 카나리아를 찍지 않는다 ·
/// (W3c) 분류 실행에서 <c>/certs</c> 를 조회한 행마다 콜드 캐시 + 503 에서 k 회. 실패한 칸은 <see cref="KnownGaps"/> 에
/// 이유와 함께 있으면 GAP, 관측되지 않는 항목은 낡은 것이라 실패한다.</para>
/// <para>⚠️ .NET 이 Go 와 다른 자리 넷. (i) 정적 메서드·생성자도 공개 호출 경로다 — <c>AdminClient.CreateAsync</c> 는 정적이고
/// 토큰을 부여받는다. (ii) internal 타입의 public 메서드도 행이다(Go 의 비공개 타입 공개 메서드와 같다) — 다만 §4 의 「SDK 오류
/// 타입」 단언은 <b>공개 타입</b>의 행에만 건다(internal 메서드의 경계는 그것을 부르는 공개 메서드다). (iii) 표준 렌더링은
/// <c>ToString()</c>(InnerException 사슬·스택 포함)·사슬의 <c>Message</c> 전부·SDK 오류의 공개 문자열 속성(<c>OAuthError</c>)이다 —
/// Go 의 <c>%v</c>/<c>%+v</c>/<c>%#v</c> 자리이고, <c>MalformedTokenResponseTests</c> 와 같은 경로 이름을 써서 그 테스트의 계약상
/// 누출(<c>KnownLeaks</c>)을 그대로 적용한다. (iv) 콜드 캐시 검증이 요청 둘(디스커버리 + JWKS)을 낸다 — 세는 것은 <c>/certs</c> 뿐이다.</para>
/// <para>⚠️ 한계 — 전부 <c>NONE</c> 으로 읽힌다: 요청도 오류도 없이 끝나는 교환 경로(bool 이 아닌 합성 인자 — 정수 1·열거형 기본값·
/// 합성 문자열 — 가 요청 앞에서 갈라 세우는 것), 반환 뒤에 나가는 비동기 요청, 이 IdP 가 아닌 호스트로 나가 오류를 버리는 것.
/// grant_type 은 폼·JSON 본문·쿼리에서 읽는다 — 셋 다 아닌 모양의 코드 교환은 <c>TOKEN_GRANT</c> 로 읽힌다(교환 계급 안이다).</para>
/// </remarks>
[Trait("Category", "Unit")]
public sealed class HostilePathMatrixTests
{
    private const string CodeExchange = "CODE_EXCHANGE";
    private const string TokenGrant = "TOKEN_GRANT";
    private const string JwksFetch = "JWKS_FETCH";
    private const string OtherClass = "OTHER";
    private const string NoneClass = "NONE";
    private const string Undetermined = "UNDETERMINED";
    private static readonly string[] ClassOrder = { CodeExchange, TokenGrant, JwksFetch, OtherClass, NoneClass, Undetermined };

    // 분류는 realm 과 무관하게 **꼬리**로 본다 — 인자로 받은 realm 의 엔드포인트도 교환이다(Go 레그 실측과 같은 이유).
    private const string TokenSuffix = "/protocol/openid-connect/token";
    private const string CertsSuffix = "/protocol/openid-connect/certs";
    private const string Oidc = "/realms/r/protocol/openid-connect";
    private const int ColdK = 5;
    private const string AtRefreshCanary = "HP-AT-RT-canary-000";

    private static readonly Assembly Sdk = typeof(KeycloakClient).Assembly;
    private static readonly IReadOnlyDictionary<string, string> NoCanaries = new Dictionary<string, string>();

    /// <summary>
    /// UNDETERMINED 여도 되는 행과 그 이유. 키는 행 라벨이거나 <c>타입.*</c>(그 타입의 모든 행). <b>이유 없는 면제는 넣지 않는다.</b>
    /// 선언 집합에 없거나 더는 UNDETERMINED 가 아닌 항목은 낡은 면제로 실패한다.
    /// </summary>
    private static readonly Dictionary<string, string> UndeterminedExempt = new(StringComparer.Ordinal)
    {
        ["BoundedDocumentRetriever.GetDocumentAsync(String, CancellationToken)"] =
            "internal 문서 리트리버 — 주소는 ConfigurationManager 가 디스커버리에서 얻은 URL 이고 합성 문자열(JWS)은 URI 가 아니라 요청 전에 " +
            "실패한다. 이것이 내는 요청은 전부 그것을 모는 공개 메서드(ValidateAsync → JWKS_FETCH)의 행에 이미 잡힌다",
        ["AuthorizationRequestJsonConverter.*"] = JsonConverterReason,
        ["KeycloakConfigJsonConverter.*"] = JsonConverterReason,
        ["TokenSetJsonConverter.*"] = JsonConverterReason,
    };

    private const string JsonConverterReason =
        "System.Text.Json 이 [JsonConverter] 특성에서 만든다(FacadeDumpTests.Exempt 와 같은 이유) — 공개 API 뿌리에서 닿지 않아 수신자가 " +
        "없고, 필드가 없어 요청을 낼 HttpClient 를 쥘 수 없다(Read 는 NotSupportedException, Write 는 받은 writer 에만 쓴다)";

    /// <summary>W3b 에서 빠져도 되는 CODE_EXCHANGE 행과 그 이유. nonce 를 다른 이름으로 받는 새 교환 메서드가 조용히 빠지지 않게
    /// 이 표에 이유가 있어야만 빠진다. 오늘은 비어 있다.</summary>
    private static readonly Dictionary<string, string> NonceDropExempt = new(StringComparer.Ordinal);

    /// <summary>
    /// 현재 main 에서 실패하는 칸 — 키는 <c>W3&lt;축&gt; 행/변형</c>, 값은 <c>등록부 id: 한 줄 이유</c>. SDK 를 고치지 않고 드러내 둔다.
    /// 관측되지 않는(이제 통과하거나 칸이 없는) 항목은 낡은 것이라 실패한다. <b>이유 없는 항목은 넣지 않는다.</b>
    /// </summary>
    private static readonly Dictionary<string, string> KnownGaps = new(StringComparer.Ordinal);

    private readonly ITestOutputHelper _out;

    public HostilePathMatrixTests(ITestOutputHelper output) => _out = output;

    [Fact]
    public async Task Derived_exchange_paths_are_classified_and_hostile_variants_attach_by_class()
    {
        using var rsa = RSA.Create(2048);
        var key = new RsaSecurityKey(rsa) { KeyId = "k1" };
        using var idp = new Idp(key);

        var dumpTypes = await DumpReachedTypesAsync(key);
        var builderOf = await ProbeBuildersAsync(idp);
        var rows = DeclaredRows(dumpTypes);
        var called = 0;
        foreach (var row in rows)
        {
            if (row.Callable)
            {
                await ClassifyAsync(idp, row, builderOf, dumpTypes);
                called++;
            }
            else
            {
                row.Class = Undetermined;
                row.Recv = "없음";
                row.Outcome = "-";
                row.Note = " · 걷기가 닿지 않는 타입이라 수신자가 없다(FacadeDumpTests 의 뿌리에 닿게 하거나 이유와 함께 면제하라)";
            }
        }
        var counts = LogTable(rows, called);
        var byLabel = rows.ToDictionary(r => r.Label, StringComparer.Ordinal);
        var late = new List<string>(); // 판정표 뒤에 찍을 실패 — 변이 프로브는 출력 꼬리만 보여 준다

        // (1) UNDETERMINED 없음 — 면제는 이유와 함께, 낡은 면제는 실패.
        foreach (var r in rows.Where(r => r.Class == Undetermined && ExemptionFor(r.Label) is null))
            late.Add($"{r.Label}: 분류하지 못했다(UNDETERMINED) — 인자 합성·수신자를 고치거나 이유와 함께 면제하라{r.Note}");
        foreach (var (k, reason) in UndeterminedExempt)
        {
            if (!rows.Any(r => r.Class == Undetermined && ExemptionMatches(k, r.Label)))
                late.Add($"UndeterminedExempt[{k}]: 낡은 면제다 — 선언 집합에 없거나 더는 UNDETERMINED 가 아니다({reason})");
        }
        // (2) 세 교환 계급이 각각 비어 있지 않다 — 비면 분류기·가짜 IdP·인자 합성 중 하나가 공허해진 것이다.
        foreach (var c in new[] { CodeExchange, TokenGrant, JwksFetch })
        {
            if (counts.GetValueOrDefault(c) == 0)
                late.Add($"{c} 계급이 비었다 — 교환 경로를 하나도 못 찾았다");
        }

        // W3 — 대상은 전부 파생이다: (a) 계급 · (b) 계급 ∩ 서명 · (c) 분류 실행이 보낸 요청.
        var tgt = new Dictionary<string, List<string>> { ["a"] = new(), ["b"] = new(), ["c"] = new() };
        foreach (var r in rows.Where(r => r.Called))
        {
            if (r.Class is TokenGrant or CodeExchange)
                tgt["a"].Add(r.Label);
            if (r.Class == CodeExchange)
            {
                if (r.NonceParams.Count > 0)
                    tgt["b"].Add(r.Label);
                else if (NonceDropExempt.TryGetValue(r.Label, out var reason))
                    _out.WriteLine($"(b) nonce 파라미터가 없어 빠진 CODE_EXCHANGE 행: {r.Label} — {reason}");
                else
                    late.Add($"W3b {r.Label}: CODE_EXCHANGE 인데 이름에 nonce 가 든 파라미터가 없어 W3b 가 붙지 않는다 — " +
                             "nonce 를 그 이름으로 받게 하거나, 정말 nonce 없는 흐름이면 이유와 함께 NonceDropExempt 에 적어라");
            }
            if (r.Sent.Any(IsCertsGet))
                tgt["c"].Add(r.Label);
        }
        foreach (var (label, reason) in NonceDropExempt)
        {
            if (!byLabel.TryGetValue(label, out var r) || r.Class != CodeExchange || r.NonceParams.Count > 0)
                late.Add($"NonceDropExempt[{label}]: 낡은 면제다 — nonce 파라미터 없는 CODE_EXCHANGE 행이 아니다({reason})");
        }

        var cells = new List<HpCell>();
        cells.AddRange(await RunVariantsAAsync(idp, tgt["a"].Select(l => byLabel[l]), builderOf, dumpTypes));
        cells.AddRange(await RunNonceBAsync(idp, tgt["b"].Select(l => byLabel[l]), builderOf, dumpTypes));
        cells.AddRange(await RunColdJwksCAsync(idp, tgt["c"].Select(l => byLabel[l]), builderOf, dumpTypes));
        var fails = Judge(cells, out var summaries);

        // W1 — 손 목록 포함.
        fails.AddRange(late);
        fails.AddRange(CheckHand(byLabel, tgt));
        foreach (var f in fails)
            _out.WriteLine("FAIL " + f);
        // 요약은 실패 줄 **뒤에** 찍는다 — 변이 프로브는 출력 꼬리만 보여 준다.
        foreach (var s in summaries)
            _out.WriteLine(s);
        _out.WriteLine("계급별: " + string.Join(" · ", ClassOrder.Select(c => $"{c} {counts.GetValueOrDefault(c)}")));
        Assert.True(fails.Count == 0, $"적대 경로 행렬 실패 {fails.Count}건:\n" + string.Join("\n", fails));
    }

    // ── 선언 집합 ──────────────────────────────────────────────────────────────────────────────

    private sealed class HpRow
    {
        public required string Label { get; init; }

        /// <summary>부를 멤버 — 명시적 인터페이스 구현이면 인터페이스 메서드다(수신자에서 구현으로 디스패치된다).</summary>
        public required MethodBase Member { get; init; }

        /// <summary>수신자 타입 — 명시적 구현 행에서는 구현하는 SDK 타입이다(<c>Member.DeclaringType</c> 은 인터페이스).</summary>
        public required Type Owner { get; init; }

        public required bool Callable { get; init; }
        public required IReadOnlyList<int> NonceParams { get; init; }
        public string Class { get; set; } = "";
        public string Reqs { get; set; } = "-";
        public string Recv { get; set; } = "";
        public string Outcome { get; set; } = "";
        public string Note { get; set; } = "";
        public List<Req> Sent { get; set; } = new();
        public bool Called { get; set; }

        /// <summary>분류가 고른 bool 인자 값 — W3 도 이 값으로 부른다.</summary>
        public bool BoolArg { get; set; }

        public bool HasBool => Member.GetParameters().Any(p => (Nullable.GetUnderlyingType(p.ParameterType) ?? p.ParameterType) == typeof(bool));

        /// <summary>§4 의 경계 — 공개 타입의 멤버만 「SDK 오류 타입으로 끝난다」를 단언한다.</summary>
        public bool PublicSurface => Owner.IsVisible && Member.DeclaringType!.IsVisible;
    }

    /// <summary>FacadeDumpTests 의 뿌리를 같은 걷기로 돌려 닿는 SDK 타입을 얻는다(카나리아 단언은 그 테스트의 몫이다).</summary>
    private static async Task<HashSet<Type>> DumpReachedTypesAsync(RsaSecurityKey key)
    {
        using var dumpIdp = WireMockServer.Start();
        FacadeDumpTests.StubIdp(dumpIdp, key);
        await using var set = new FacadeDumpTests.RootSet();
        await FacadeDumpTests.BuildRootsAsync(set, dumpIdp, key);
        var walker = new FacadeDumpTests.Walker(Sdk, set.Canaries);
        foreach (var (name, value) in set.Roots)
            walker.Walk(name, value);
        return walker.Reached.Keys.ToHashSet();
    }

    /// <summary>
    /// 선언 집합 — 걷기가 닿는 타입 ∪ 정적 클래스의 공개 멤버는 부르고, 어셈블리의 나머지 타입의 공개 멤버는 부르지 않는 행으로 둔다.
    /// 전수는 손 목록이 아니라 어셈블리 자신(<c>GetTypes()</c>)에서 온다.
    /// </summary>
    private static List<HpRow> DeclaredRows(HashSet<Type> dumpTypes)
    {
        var rows = new List<HpRow>();
        foreach (var t in Sdk.GetTypes().Where(t => !FacadeDumpTests.IsCompilerGenerated(t)))
        {
            var declared = dumpTypes.Contains(t) || (FacadeDumpTests.HasNoInstances(t) && !t.IsInterface);
            var members = new List<MethodBase>();
            members.AddRange(t.GetMethods(BindingFlags.Public | BindingFlags.Instance | BindingFlags.Static | BindingFlags.DeclaredOnly)
                .Where(m => !m.IsAbstract && !IsGeneratedMember(m)));
            members.AddRange(t.GetConstructors(BindingFlags.Public | BindingFlags.Instance).Where(c => !IsGeneratedMember(c)));
            foreach (var m in members)
                rows.Add(new HpRow { Label = LabelOf(m), Member = m, Owner = t, Callable = declared, NonceParams = NonceParamsOf(m) });
            // 명시적 인터페이스 구현 — 메타데이터에서 private 이라 위의 GetMethods(Public) 에 없고, 인터페이스 쪽 메서드는 추상이라
            // 규칙으로 빠진다. 소비자는 인터페이스로 캐스트해 부를 수 있으므로 공개 호출 경로다.
            if (t.IsInterface)
                continue;
            foreach (var i in t.GetInterfaces())
            {
                var map = t.GetInterfaceMap(i);
                for (var k = 0; k < map.TargetMethods.Length; k++)
                {
                    var target = map.TargetMethods[k];
                    if (target.DeclaringType != t || target.IsPublic || target.IsStatic || IsGeneratedMember(target))
                        continue;
                    var im = map.InterfaceMethods[k];
                    rows.Add(new HpRow
                    {
                        Label = $"{TypeLabel(t)}.[{TypeLabel(i)}.{im.Name}]({string.Join(", ", im.GetParameters().Select(p => TypeLabel(p.ParameterType)))})",
                        Member = im,
                        Owner = t,
                        Callable = declared,
                        NonceParams = NonceParamsOf(im),
                    });
                }
            }
        }
        rows.Sort((a, b) => string.CompareOrdinal(a.Label, b.Label));
        return rows;
    }

    /// <summary>이름에 "nonce" 가 든(대소문자 무시) 파라미터의 위치 — <b>이름 목록이 아니라 서명에서</b> 얻는다.</summary>
    private static List<int> NonceParamsOf(MethodBase m) =>
        m.GetParameters().Where(p => p.Name?.Contains("nonce", StringComparison.OrdinalIgnoreCase) == true).Select(p => p.Position).ToList();

    /// <summary>컴파일러가 만든 멤버 — 자동 속성 접근자·record 의 Equals/GetHashCode/Deconstruct/&lt;Clone&gt;$ 류. 사람이 쓴 본문이 없다.</summary>
    private static bool IsGeneratedMember(MemberInfo m) =>
        m.IsDefined(typeof(CompilerGeneratedAttribute), false) || m.Name.Contains('<');

    private static string TypeLabel(Type t)
    {
        if (t.IsByRef)
            return "ref " + TypeLabel(t.GetElementType()!);
        if (t.IsArray)
            return TypeLabel(t.GetElementType()!) + "[]";
        if (t.IsGenericType)
        {
            var name = t.Name[..t.Name.IndexOf('`', StringComparison.Ordinal)];
            return $"{name}<{string.Join(", ", t.GetGenericArguments().Select(TypeLabel))}>";
        }
        return t.DeclaringType is { } outer && t.Assembly == Sdk ? $"{TypeLabel(outer)}+{t.Name}" : t.Name;
    }

    private static string LabelOf(MethodBase m) =>
        $"{TypeLabel(m.DeclaringType!)}.{(m is ConstructorInfo ? ".ctor" : m.Name)}({string.Join(", ", m.GetParameters().Select(p => TypeLabel(p.ParameterType)))})";

    private static string MethodName(string label) => Regex.Match(label, @"\.(\.?[A-Za-z_][A-Za-z0-9_]*)\]?\(").Groups[1].Value;

    private static string? ExemptionFor(string label) =>
        UndeterminedExempt.FirstOrDefault(kv => ExemptionMatches(kv.Key, label)).Value;

    private static bool ExemptionMatches(string key, string label) =>
        key.EndsWith(".*", StringComparison.Ordinal) ? label.StartsWith(key[..^1], StringComparison.Ordinal) : key == label;

    // ── 뿌리·수신자·인자 ────────────────────────────────────────────────────────────────────────

    /// <summary>수신자를 얻는 공개 API 뿌리 — <b>덜 데운 것부터</b>. 타입은 자기를 처음 닿게 하는 뿌리의 새 인스턴스에서 불린다
    /// (<c>AdminAsync</c> 는 admin 이 아직 없는 <c>Create</c> 에서).</summary>
    private static readonly (string Name, Func<KeycloakConfig, Task<KeycloakClient>> Build)[] Builders =
    {
        ("Create", cfg => Task.FromResult(KeycloakClient.Create(cfg))),
        ("Create+AdminAsync", async cfg =>
        {
            var kc = KeycloakClient.Create(cfg);
            await kc.AdminAsync();
            return kc;
        }),
    };

    private const int RichestBuilder = 1;

    private static async Task<Dictionary<Type, int>> ProbeBuildersAsync(Idp idp)
    {
        var builderOf = new Dictionary<Type, int>();
        for (var i = 0; i < Builders.Length; i++)
        {
            using var cell = idp.NewCell();
            await using var kc = await Builders[i].Build(cell.Config);
            var walker = new FacadeDumpTests.Walker(Sdk, NoCanaries);
            walker.Walk(Builders[i].Name, kc);
            foreach (var t in walker.Reached.Keys)
                builderOf.TryAdd(t, i);
        }
        return builderOf;
    }

    /// <summary>한 칸 — 새 가짜 IdP 칸 위에 새 뿌리를 만들고 수신자·인자 원천을 꺼낸다.</summary>
    private sealed class Prepared : IAsyncDisposable
    {
        public required Cell Cell { get; init; }
        public required object? Receiver { get; init; }
        public required string RecvName { get; init; }
        public required Dictionary<Type, object> Instances { get; init; }
        public required bool BoolArg { get; init; }
        public List<object> Owned { get; } = new();

        public async ValueTask DisposeAsync()
        {
            foreach (var o in Owned)
            {
                try
                {
                    if (o is IAsyncDisposable a)
                        await a.DisposeAsync();
                    else if (o is IDisposable d)
                        d.Dispose();
                }
                catch (ObjectDisposedException)
                {
                    // 행 자신이 Dispose 였다 — 두 번째 정리는 무해하다.
                }
            }
            Cell.Dispose();
        }
    }

    private static async Task<Prepared> PrepareAsync(Idp idp, HpRow row, Dictionary<Type, int> builderOf, HashSet<Type> dumpTypes,
                                                     bool? boolArg = null)
    {
        var m = row.Member;
        var t = row.Owner;
        var cell = idp.NewCell();
        var instanceCall = m is MethodInfo { IsStatic: false };
        var b = instanceCall && builderOf.TryGetValue(t, out var bi) ? bi : RichestBuilder;
        var kc = await Builders[b].Build(cell.Config);
        var walker = new FacadeDumpTests.Walker(Sdk, NoCanaries);
        walker.Walk(Builders[b].Name, kc);
        object? recv = null;
        var recvName = m is ConstructorInfo ? "ctor" : "static";
        if (instanceCall)
        {
            if (builderOf.ContainsKey(t))
            {
                recv = walker.Instances.TryGetValue(t, out var inst) ? inst
                    : throw new InvalidOperationException($"{row.Label}: 뿌리 {Builders[b].Name} 가 탐침 때는 닿았는데 지금은 안 닿는다");
                recvName = Builders[b].Name;
            }
            else if (dumpTypes.Contains(t))
            {
                // 어느 뿌리에도 안 닿는 타입(값 타입·오류 타입)은 영값 수신자다 — 상태가 필요한 새 타입이면 그 호출이 요청 없이 실패해
                // UNDETERMINED 로 드러난다(Go 의 영값 수신자와 같다).
                recv = RuntimeHelpers.GetUninitializedObject(t);
                recvName = "zero";
            }
        }
        var p = new Prepared { Cell = cell, Receiver = recv, RecvName = recvName, Instances = walker.Instances, BoolArg = boolArg ?? row.BoolArg };
        p.Owned.Add(kc);
        return p;
    }

    /// <summary>인자 합성 — 타입만 본다. SDK 타입·인터페이스는 같은 뿌리의 걷기에서 꺼낸다(설정·엔드포인트·검증기·토큰 소스).</summary>
    private static object? Synth(Type t, Prepared p, int depth = 0)
    {
        if (t == typeof(CancellationToken))
            return CancellationToken.None;
        if (t == typeof(string))
            return p.Cell.Universal;
        if (Nullable.GetUnderlyingType(t) is { } under)
            return Synth(under, p, depth);
        if (t.IsByRef || t.IsPointer || t.IsByRefLike)
            throw new NotSupportedException($"{TypeLabel(t)} 인자는 리플렉션으로 합성할 수 없다");
        if (t.IsEnum)
            return Activator.CreateInstance(t);
        if (t == typeof(bool))
            return p.BoolArg;
        if (t.IsPrimitive || t == typeof(decimal))
            return Convert.ChangeType(1, t, System.Globalization.CultureInfo.InvariantCulture);
        if (t == typeof(Type))
            return typeof(object);
        if (p.Instances.Values.FirstOrDefault(t.IsInstanceOfType) is { } walked)
            return walked;
        if (t.IsArray)
        {
            var arr = Array.CreateInstance(t.GetElementType()!, 1);
            arr.SetValue(Synth(t.GetElementType()!, p, depth + 1), 0);
            return arr;
        }
        if (t.IsGenericType && t.IsInterface)
        {
            var args = t.GetGenericArguments();
            var def = t.GetGenericTypeDefinition();
            if (args.Length == 2 && (def == typeof(IReadOnlyDictionary<,>) || def == typeof(IDictionary<,>)))
                return Activator.CreateInstance(typeof(Dictionary<,>).MakeGenericType(args));
            if (args.Length == 1 && t.IsAssignableFrom(args[0].MakeArrayType()))
                return Synth(args[0].MakeArrayType(), p, depth + 1);
        }
        if (t.IsInterface || t.IsAbstract)
        {
            // 외부 인터페이스는 그 어셈블리의 공개 구현 중 매개변수 없는 생성자가 있는 첫 것(IServiceCollection → ServiceCollection).
            var impl = t.Assembly.GetExportedTypes()
                .Where(c => c is { IsClass: true, IsAbstract: false, ContainsGenericParameters: false } && t.IsAssignableFrom(c)
                            && c.GetConstructor(Type.EmptyTypes) is not null)
                .OrderBy(c => c.FullName, StringComparer.Ordinal).FirstOrDefault();
            return impl is null ? null : Own(p, Activator.CreateInstance(impl));
        }
        if (t.IsValueType)
            return Activator.CreateInstance(t);
        if (t.GetConstructor(Type.EmptyTypes) is null)
            return t.Assembly == Sdk ? RuntimeHelpers.GetUninitializedObject(t) : null;
        var value = Own(p, Activator.CreateInstance(t));
        if (t.Assembly == Sdk && depth < 2)
        {
            // SDK 옵션 타입(required init 속성)은 비어 있는 참조 속성을 채운다 — 비워 두면 생성자가 요청 전에 NRE 로 실패한다.
            foreach (var prop in t.GetProperties(BindingFlags.Public | BindingFlags.Instance).Where(x => x.CanWrite && !x.PropertyType.IsValueType))
            {
                if (prop.GetValue(value) is null)
                    prop.SetValue(value, Synth(prop.PropertyType, p, depth + 1));
            }
        }
        return value;
    }

    private static object? Own(Prepared p, object? value)
    {
        if (value is IDisposable or IAsyncDisposable)
            p.Owned.Add(value);
        return value;
    }

    /// <param name="blank">영값으로 둘 위치(W3a 가 nonce 를 비운다).</param>
    /// <param name="given">값을 정해 줄 위치(W3b 가 nonce 에 다른 인자와 <b>다른</b> 값을 준다).</param>
    private static object?[] ArgsFor(MethodBase m, Prepared p, IReadOnlyCollection<int>? blank, IReadOnlyDictionary<int, object?>? given)
    {
        var ps = m.GetParameters();
        var args = new object?[ps.Length];
        for (var i = 0; i < ps.Length; i++)
        {
            var t = ps[i].ParameterType;
            if (given is not null && given.TryGetValue(i, out var v))
                args[i] = v;
            else if (blank?.Contains(i) == true)
                args[i] = t.IsValueType && Nullable.GetUnderlyingType(t) is null ? Activator.CreateInstance(t) : null;
            else
                args[i] = Synth(t, p);
        }
        return args;
    }

    /// <summary>부르고, 비동기면 기다린다. 동기 throw·faulted task·합성 실패 모두 오류로 돌려준다(삼키지 않는다).</summary>
    private static async Task<(object? Result, Exception? Error)> InvokeAsync(HpRow row, Prepared p, IReadOnlyCollection<int>? blank,
                                                                            IReadOnlyDictionary<int, object?>? given = null)
    {
        try
        {
            var args = ArgsFor(row.Member, p, blank, given);
            var r = row.Member is ConstructorInfo c ? c.Invoke(args) : row.Member.Invoke(p.Receiver, args);
            var declared = row.Member is MethodInfo mi ? mi.ReturnType : row.Member.DeclaringType!;
            Task? task = r switch
            {
                Task tk => tk,
                ValueTask vt => vt.AsTask(),
                not null when r.GetType() is { IsGenericType: true } g && g.GetGenericTypeDefinition() == typeof(ValueTask<>)
                    => (Task)g.GetMethod(nameof(ValueTask<int>.AsTask))!.Invoke(r, null)!,
                _ => null,
            };
            if (task is not null)
            {
                await task.WaitAsync(TimeSpan.FromSeconds(30));
                r = declared.IsGenericType && declared.GetGenericTypeDefinition() is var d && (d == typeof(Task<>) || d == typeof(ValueTask<>))
                    ? task.GetType().GetProperty(nameof(Task<int>.Result))!.GetValue(task)
                    : null;
            }
            Own(p, r);
            return (r, null);
        }
        catch (TargetInvocationException e) when (e.InnerException is not null)
        {
            return (null, e.InnerException);
        }
        catch (Exception e)
        {
            return (null, e);
        }
    }

    // ── 분류 ───────────────────────────────────────────────────────────────────────────────────

    private sealed record Req(string Method, string Path, string? Grant);

    private static bool IsTokenPost(Req r) => r.Method == "POST" && r.Path.EndsWith(TokenSuffix, StringComparison.Ordinal);

    private static bool IsCertsGet(Req r) => r.Method == "GET" && r.Path.EndsWith(CertsSuffix, StringComparison.Ordinal);

    /// <summary>요청으로 가른다. 앞 줄이 이긴다: 코드 교환 &gt; 토큰 부여 &gt; JWKS 조회 &gt; 그 밖의 요청 &gt; 요청 없음.
    /// ⚠️ 토큰 엔드포인트 POST 는 grant_type 이 무엇이든 TOKEN_GRANT 다 — 새 grant 가 OTHER 로 새지 않게.</summary>
    private static string Classify(IReadOnlyList<Req> reqs, bool failed)
    {
        if (reqs.Any(r => IsTokenPost(r) && r.Grant == "authorization_code"))
            return CodeExchange;
        if (reqs.Any(IsTokenPost))
            return TokenGrant;
        if (reqs.Any(IsCertsGet))
            return JwksFetch;
        if (reqs.Count > 0)
            return OtherClass;
        return failed ? Undetermined : NoneClass;
    }

    private static string Format(IReadOnlyList<Req> reqs, string universal)
    {
        if (reqs.Count == 0)
            return "-";
        var order = new List<string>();
        var count = new Dictionary<string, int>(StringComparer.Ordinal);
        foreach (var r in reqs)
        {
            var path = r.Path.StartsWith(Oidc, StringComparison.Ordinal) ? r.Path[Oidc.Length..] : r.Path;
            if (universal.Length > 0)
                path = path.Replace(universal, "{U}", StringComparison.Ordinal);
            var k = $"{r.Method} {path}" + (r.Grant is null ? "" : $"[{r.Grant}]");
            if (!count.TryAdd(k, 1))
                count[k]++;
            else
                order.Add(k);
        }
        return string.Join(", ", order.Select(k => count[k] > 1 ? $"{k} ×{count[k]}" : k));
    }

    /// <summary>두 bool 실행 중 무엇을 행의 것으로 삼는가 — 교환에 가까울수록, 그다음 「요청 없이 실패」(UNDETERMINED)가 NONE 보다 앞이다.</summary>
    private static readonly string[] ClassRank = { CodeExchange, TokenGrant, JwksFetch, OtherClass, Undetermined, NoneClass };

    private async Task ClassifyAsync(Idp idp, HpRow row, Dictionary<Type, int> builderOf, HashSet<Type> dumpTypes)
    {
        var (cls, reqs, fmt, recv, err) = await ClassifyOnceAsync(idp, row, builderOf, dumpTypes, false);
        var chosenTrue = false;
        if (row.HasBool)
        {
            var second = await ClassifyOnceAsync(idp, row, builderOf, dumpTypes, true);
            if (Array.IndexOf(ClassRank, second.Class) < Array.IndexOf(ClassRank, cls))
            {
                (cls, reqs, fmt, recv, err) = second;
                chosenTrue = true;
            }
        }
        row.Called = true;
        row.BoolArg = chosenTrue;
        row.Sent = reqs;
        row.Class = cls;
        row.Reqs = fmt;
        row.Recv = recv + (row.HasBool ? $" · bool={(chosenTrue ? "true" : "false")}" : "");
        row.Outcome = err is null ? "ok" : "err";
        // 사유는 분류를 못 한 행에만 — 요청을 낸 행의 오류(admin 404 등)는 분류와 무관하다.
        row.Note = row.Class == Undetermined && err is not null ? $" · {err.GetType().Name}: {OneLine(err.Message)}" : "";
    }

    private static async Task<(string Class, List<Req> Reqs, string Format, string Recv, Exception? Error)> ClassifyOnceAsync(
        Idp idp, HpRow row, Dictionary<Type, int> builderOf, HashSet<Type> dumpTypes, bool boolArg)
    {
        await using var p = await PrepareAsync(idp, row, builderOf, dumpTypes, boolArg);
        p.Cell.ResetLog(); // 뿌리를 만들며 나간 요청(admin 워밍업 등)은 이 메서드의 몫이 아니다
        var (_, err) = await InvokeAsync(row, p, null);
        var reqs = p.Cell.Snapshot();
        return (Classify(reqs, err is not null), reqs, Format(reqs, p.Cell.Universal), p.RecvName, err);
    }

    private static string OneLine(string s) => s.ReplaceLineEndings(" ");

    private Dictionary<string, int> LogTable(List<HpRow> rows, int called)
    {
        var counts = new Dictionary<string, int>(StringComparer.Ordinal);
        _out.WriteLine($"선언 집합 {rows.Count} 멤버(부른 것 {called} + 걷기가 안 닿아 못 부른 것 {rows.Count - called}) — " +
                       $"경로의 {Oidc} 는 생략, {{U}} 는 보편 인자(서명된 JWS)");
        var width = rows.Max(r => r.Label.Length);
        foreach (var r in rows)
        {
            counts[r.Class] = counts.GetValueOrDefault(r.Class) + 1;
            _out.WriteLine($"{r.Label.PadRight(width)} → {r.Class,-13} · {r.Reqs}  [수신자 {r.Recv} · {r.Outcome}]{r.Note}");
        }
        _out.WriteLine("계급별: " + string.Join(" · ", ClassOrder.Select(c => $"{c} {counts.GetValueOrDefault(c)}")));
        return counts;
    }

    // ── W3: 계급별 적대 변형 ────────────────────────────────────────────────────────────────────

    private sealed record HostileResp(int Status, string ContentType, string Body);

    /// <summary>토큰 엔드포인트가 내는 형식이 틀린 응답 하나. <c>From</c> 이 비면 <b>측정만</b> 한다 — 기존 테스트가 단언하지 않는
    /// 변형에 새 계약을 만들지 않기 위해서다. <c>LeakKey</c> 는 <c>MalformedTokenResponseTests.KnownLeaks</c> 의 변형 이름이다.</summary>
    private sealed record TokenVariant(string Code, string? From, string[] Canaries, string[] Encoded, HostileResp Resp, Type? Expected, string? LeakKey);

    /// <summary>
    /// 변형 집합을 새로 만들지 않고 기존 테스트에서 가져온다.
    /// <list type="bullet">
    /// <item><c>MalformedTokenResponseTests.Variants</c> 중 <b>토큰 호출이 실패해야 한다고 단언된 것</b>(<c>Token != null</c>) — 기대 타입도
    /// 그 표의 것이다. 토큰 호출이 성공하는 것이 계약인 변형(a·c 계열: id_token 만 틀렸거나 Duende 가 강제변환하는 필드)은 여기서 빼고
    /// W3b 가 nonce 교환에 붙인다(그 표가 nonce 교환에만 실패를 단언한다).</item>
    /// <item><c>AuthClientTests.ClientCredentialsToken_rejects_non_string_access_token</c> 의 <c>[InlineData]</c> 전부(리플렉션으로 읽는다).</item>
    /// <item><c>at:missing</c> — access_token 이 없는 200. <c>TokensTests.Create_rejects_missing_access_token</c> 이 단언하는 계약이다
    /// (Go 에서는 측정만이었다 — 단언하는 테스트가 없었다. Grok 레그가 「측정만이라 받아들여도 초록」을 지목해 계약을 찾아 올렸다).</item>
    /// </list>
    /// ⚠️ 공허 함정: 이 본문들엔 쓸 수 있는 id_token 이 없다. nonce 를 준 ExchangeCodeAsync 는 정상 토큰 응답이어도 「id_token missing」
    /// 으로 실패하므로 적대 응답이 안 닿아도 통과한다 — 그래서 W3a 는 nonce 파라미터를 비워 <b>토큰 응답 형식만</b> 잰다(W3b 가 nonce 를 잰다).
    /// </summary>
    private static (List<TokenVariant> Variants, List<string> Skipped) TokenVariants()
    {
        var variants = new List<TokenVariant>();
        var skipped = new List<string>();
        foreach (var v in MalformedTokenResponseTests.Variants)
        {
            var code = v.Name.Split(' ')[0];
            if (v.Token is null)
            {
                skipped.Add($"{code}(토큰 호출은 성공이 계약)");
                continue;
            }
            variants.Add(new TokenVariant(code, "MalformedTokenResponseTests " + v.Name, v.Canaries, v.Encoded ?? Array.Empty<string>(),
                new HostileResp(v.Status, v.ContentType, v.Body), v.Token, v.Name));
        }
        var anchor = typeof(AuthClientTests).GetMethod(nameof(AuthClientTests.ClientCredentialsToken_rejects_non_string_access_token))!;
        foreach (var data in anchor.GetCustomAttributes<InlineDataAttribute>().SelectMany(a => a.GetData(anchor)))
        {
            var raw = (string)data[0];
            variants.Add(new TokenVariant("at:" + raw, "AuthClientTests " + anchor.Name, new[] { AtRefreshCanary }, Array.Empty<string>(),
                new HostileResp(200, "application/json",
                    $$"""{"access_token":{{raw}},"token_type":"Bearer","expires_in":300,"refresh_token":"{{AtRefreshCanary}}"}"""),
                typeof(KeycloakAuthException), null));
        }
        variants.Add(new TokenVariant("at:missing", $"TokensTests.{nameof(TokensTests.Create_rejects_missing_access_token)}",
            new[] { AtRefreshCanary }, Array.Empty<string>(),
            new HostileResp(200, "application/json", $$"""{"token_type":"Bearer","expires_in":300,"refresh_token":"{{AtRefreshCanary}}"}"""),
            typeof(KeycloakAuthException), null));
        return (variants, skipped);
    }

    /// <summary>W3a 대조 — 변형들과 같은 모양(id_token 없음)의 쓸 수 있는 토큰 응답.</summary>
    private static readonly HostileResp WellFormed = new(200, "application/json",
        """{"access_token":"hp-access","token_type":"Bearer","expires_in":300,"refresh_token":"hp-refresh"}""");

    private sealed class HpCell
    {
        public required string Axis { get; init; }
        public required string Label { get; init; }
        public required string Variant { get; init; }
        public List<string> Why { get; } = new();
        public bool Measure { get; init; }
        public string Note { get; set; } = "";

        public string Key => $"W3{Axis} {Label}/{Variant}";
    }

    private sealed record CellRun(List<Req> Sent, object? Result, Exception? Error);

    /// <summary>수신자를 정상 응답으로 만든 <b>뒤에</b> 토큰 응답을 resp 로 바꾸고(null 이면 정상 그대로) 한 번 부른다.</summary>
    private static async Task<CellRun> RunOnceAsync(Idp idp, HpRow row, Dictionary<Type, int> builderOf, HashSet<Type> dumpTypes,
                                                    IReadOnlyCollection<int>? blank, Func<Cell, HostileResp?> resp,
                                                    Func<Cell, IReadOnlyDictionary<int, object?>>? given = null)
    {
        await using var p = await PrepareAsync(idp, row, builderOf, dumpTypes);
        p.Cell.ResetLog();
        p.Cell.TokenOverride = resp(p.Cell);
        var (result, err) = await InvokeAsync(row, p, blank, given?.Invoke(p.Cell));
        return new CellRun(p.Cell.Snapshot(), result, err);
    }

    private static (int TokenHits, List<Req> After) AfterToken(IEnumerable<Req> reqs)
    {
        var hits = 0;
        var after = new List<Req>();
        foreach (var r in reqs)
        {
            if (IsTokenPost(r))
                hits++;
            else if (hits > 0)
                after.Add(r);
        }
        return (hits, after);
    }

    private static readonly HashSet<Type> SdkErrorTypes =
        Sdk.GetTypes().Where(t => t.IsVisible && typeof(Exception).IsAssignableFrom(t)).ToHashSet();

    /// <summary>§4 — 반환 오류 <b>자체</b>가 SDK 의 공개 오류 타입인가(어셈블리에서 파생 — 손으로 적지 않는다).</summary>
    private static bool IsSdkError(Exception e) => SdkErrorTypes.Contains(e.GetType());

    /// <summary>로거가 찍는 표준 렌더링 — MalformedTokenResponseTests.Report 와 같은 경로 이름(그 KnownLeaks 가 그대로 맞는다).</summary>
    private static IEnumerable<(string Path, string Text)> Renderings(Exception e)
    {
        yield return ("ToString()", e.ToString());
        for (var x = e; x is not null; x = x.InnerException)
            yield return ("Message", x.Message);
        foreach (var prop in e.GetType().GetProperties(BindingFlags.Public | BindingFlags.Instance)
                     .Where(pr => pr.PropertyType == typeof(string) && pr.DeclaringType!.Assembly == Sdk))
        {
            if (prop.GetValue(e) is string s)
                yield return (prop.Name, s);
        }
    }

    /// <summary>
    /// 오류의 표준 렌더링 어디에 카나리아가 찍혔는가. <c>Prefix</c> 인 카나리아는 앞 10자도 본다(MalformedTokenResponseTests 와 같다) —
    /// JWS 는 헤더가 흔한 접두(<c>eyJhbGciOi</c>)라 전체만 본다. <c>leakKey</c> 의 변형이 출처 표에서 계약상 찍히는 경로는 건너뛴다.
    /// </summary>
    private static List<string> LeakWhy(Exception error, IEnumerable<(string Canary, bool Prefix)> canaries, string[] encoded, string? leakKey)
    {
        var why = new List<string>();
        var list = canaries.ToList();
        foreach (var (path, text) in Renderings(error))
        {
            if (leakKey is not null && MalformedTokenResponseTests.KnownLeaks.ContainsKey($"{leakKey}|{path}"))
                continue; // 출처 표가 계약으로 적은 누출(OAuth error 코드)
            foreach (var (c, prefix) in list)
            {
                var hit = text.Contains(c, StringComparison.Ordinal) ? "FULL"
                    : prefix && text.Contains(c[..Math.Min(10, c.Length)], StringComparison.Ordinal) ? "PREFIX10" : null;
                if (hit is not null)
                    why.Add($"카나리아 {c[..Math.Min(24, c.Length)]}… 가 {path} 에 찍혔다({hit})");
            }
            foreach (var c in encoded.Where(c => text.Contains(c, StringComparison.Ordinal)))
                why.Add($"카나리아 {c} 가 {path} 에 찍혔다(ENCODED)");
        }
        return why;
    }

    /// <summary>적대 토큰 응답 한 칸의 실패 사유 — 비면 통과. ctlHits 는 같은 행의 대조가 낸 토큰 요청 수다.</summary>
    private static List<string> HostileWhy(HpRow row, CellRun run, TokenVariant v, int ctlHits)
    {
        var why = new List<string>();
        if (run.Error is null)
            why.Add("오류 없이 성공했다");
        else
        {
            if (row.PublicSurface && !IsSdkError(run.Error))
                why.Add($"SDK 오류 타입이 아니다: {run.Error.GetType().FullName}: {OneLine(run.Error.Message)}");
            else if (row.PublicSurface && v.Expected is not null && run.Error.GetType() != v.Expected)
                why.Add($"{v.Expected.Name} 를 기대했는데(출처 표의 계약) {run.Error.GetType().Name}");
            why.AddRange(LeakWhy(run.Error, v.Canaries.Select(c => (c, true)), v.Encoded, v.LeakKey));
        }
        var (hits, after) = AfterToken(run.Sent);
        if (hits == 0)
            why.Add("토큰 엔드포인트에 한 번도 안 닿았다 — 변형이 공허하다");
        // 하한만 두면 틀린 응답마다 재시도하는 새 메서드가 통과한다(Go 레그 지목). 상한은 손 상수가 아니라 같은 행의 대조다.
        if (hits > ctlHits)
            why.Add($"토큰 요청 {hits} 건 — 정상 응답 대조({ctlHits} 건)보다 많다: 틀린 응답이 재시도를 부른다");
        if (after.Count > 0)
            why.Add($"적대 토큰 응답 뒤로 나아갔다: {Format(after, "")}");
        return why;
    }

    private async Task<List<HpCell>> RunVariantsAAsync(Idp idp, IEnumerable<HpRow> rows, Dictionary<Type, int> builderOf, HashSet<Type> dumpTypes)
    {
        var (variants, skipped) = TokenVariants();
        _out.WriteLine($"(a) 토큰응답 형식 변형 {variants.Count}(측정만 포함) — 기존 테스트에서 파생 · 뺀 것: {string.Join(", ", skipped)}");
        var cells = new List<HpCell>();
        foreach (var row in rows)
        {
            // 대조 — 변형과 **같은 모양의** 정상 응답(id_token 없음). 성공하면 「오류다」가, 토큰 뒤로 나아가면(admin 자원 → 404)
            // 「뒤로 안 나아갔다」가 무게를 진다. 둘 다 아니면 행 전체가 공허하다.
            var ctlRun = await RunOnceAsync(idp, row, builderOf, dumpTypes, row.NonceParams, _ => WellFormed);
            var (ctlHits, ctlAfter) = AfterToken(ctlRun.Sent);
            var ctl = new HpCell { Axis = "a", Label = row.Label, Variant = "대조" };
            if (ctlHits == 0)
                ctl.Why.Add("정상 응답에서 토큰 엔드포인트에 안 닿았다 — 이 행의 변형은 공허하다");
            else if (ctlRun.Error is not null && ctlAfter.Count == 0)
                ctl.Why.Add($"정상 응답에 실패했고 토큰 뒤로 나아가지도 않았다 — 변형이 무엇을 바꿨는지 가를 수 없다: {ctlRun.Error.GetType().Name}: {OneLine(ctlRun.Error.Message)}");
            ctl.Note = ctlRun.Error is null ? "ok" : "↓" + ctlAfter.Count;
            cells.Add(ctl);
            foreach (var v in variants)
            {
                var run = await RunOnceAsync(idp, row, builderOf, dumpTypes, row.NonceParams, _ => v.Resp);
                var c = new HpCell { Axis = "a", Label = row.Label, Variant = v.Code, Measure = v.From is null };
                c.Why.AddRange(HostileWhy(row, run, v, ctlHits));
                if (c.Measure)
                    c.Note = run.Error?.GetType().Name ?? "성공";
                cells.Add(c);
            }
        }
        return cells;
    }

    /// <summary>
    /// W3b 의 서명한 변형 — 대조(맞는 id_token)와 여섯. <c>Nonce</c>: <c>param</c> = 호출에 넘긴 nonce 값 · <c>other</c> = 다른 값 ·
    /// <c>universal</c> = <b>나머지 문자열 인자 전부의 값</b>(code·redirect_uri·verifier) · <c>absent</c> = nonce 클레임 없음. 다른 키로
    /// 서명할 때 kid 가 k1 이면 캐시된 키로 서명 검증이 실패하고(.NET 은 이때 JWKS 를 한 번 더 조회한다 — .claude/rules/dotnet.md),
    /// k2 면 키를 못 찾는다.
    /// </summary>
    /// <remarks>⚠️ nonce 파라미터에는 나머지 문자열 인자와 <b>다른</b> 값을 준다 — 모든 문자열 인자가 같은 값이면 nonce 를
    /// <c>code</c> 와 비교하는 교환도 대조를 통과한다(Grok 레그 지목, 변이 실측 SILENT). <c>universal</c> 행은 그 반대쪽을 잰다.</remarks>
    private static readonly (string Code, string? Kid, bool OtherKey, string Nonce, bool NoIdToken, string Want)[] NonceVariants =
    {
        ("대조", "k1", false, "param", false, "ok"),
        ("nonce≠", "k1", false, "other", false, "reject"),
        ("nonce=다른인자", "k1", false, "universal", false, "reject"),
        ("key≠·kid=k1", "k1", true, "param", false, "reject"),
        ("key≠·kid=k2", "k2", true, "param", false, "reject"),
        ("id_token없음", null, false, "param", true, "reject"),
        ("nonce클레임없음", "k1", false, "absent", false, "reject"),
    };

    private const string BAccess = "HP-B-AT-canary-0001";
    private const string BRefresh = "HP-B-RT-canary-0001";

    private static string NonceValueFor(Cell cell) => "hp-nonce-" + cell.Prefix.TrimStart('/');

    private async Task<List<HpCell>> RunNonceBAsync(Idp idp, IEnumerable<HpRow> rows, Dictionary<Type, int> builderOf, HashSet<Type> dumpTypes)
    {
        using var otherRsa = RSA.Create(2048);
        var list = rows.ToList();
        // 기존 테스트가 nonce 교환에만 실패를 단언한 형식 변형(토큰 호출은 성공이 계약) — 기대 타입은 그 표의 `Token ?? Auth` 다.
        var imported = MalformedTokenResponseTests.Variants.Where(v => v.Token is null).ToList();
        _out.WriteLine("(b) nonce 대상(서명에서 파생 — 파라미터 위치): " +
                       string.Join(", ", list.Select(r => $"{r.Label}[{string.Join(",", r.NonceParams)}]")) +
                       $" · 가져온 nonce 교환 변형 {imported.Count}: {string.Join(", ", imported.Select(v => v.Name.Split(' ')[0]))}");
        var cells = new List<HpCell>();
        foreach (var row in list)
        {
            IReadOnlyDictionary<int, object?> Given(Cell cell) => row.NonceParams.ToDictionary(i => i, _ => (object?)NonceValueFor(cell));
            foreach (var nv in NonceVariants)
            {
                string? idToken = null;
                var run = await RunOnceAsync(idp, row, builderOf, dumpTypes, null, cell =>
                {
                    var body = $"\"access_token\":\"{BAccess}\",\"token_type\":\"Bearer\",\"expires_in\":300,\"refresh_token\":\"{BRefresh}\"";
                    if (!nv.NoIdToken)
                    {
                        SecurityKey signer = nv.OtherKey ? new RsaSecurityKey(otherRsa) { KeyId = nv.Kid } : new RsaSecurityKey(idp.Rsa) { KeyId = nv.Kid };
                        var claims = new Dictionary<string, object>();
                        if (nv.Nonce != "absent")
                        {
                            claims["nonce"] = nv.Nonce switch
                            {
                                "param" => NonceValueFor(cell),
                                "universal" => cell.Universal,
                                _ => "hp-other-nonce",
                            };
                        }
                        idToken = Sign(signer, cell.Issuer, claims);
                        body += $",\"id_token\":\"{idToken}\"";
                    }
                    return new HostileResp(200, "application/json", "{" + body + "}");
                }, Given);
                var c = new HpCell { Axis = "b", Label = row.Label, Variant = nv.Code };
                var certs = run.Sent.Count(IsCertsGet);
                c.Note = $"certs {certs}";
                if (!run.Sent.Any(IsTokenPost))
                    c.Why.Add("토큰 엔드포인트에 안 닿았다 — 변형이 공허하다");
                // id_token 이 있는 변형은 검증기에 닿아야 한다(콜드 캐시라 JWKS 를 조회한다) — 아니면 다른 이유로 실패한 것이다.
                if (certs == 0 && !nv.NoIdToken)
                    c.Why.Add("JWKS 를 조회하지 않았다 — id_token 이 검증기에 닿지 않았다");
                if (nv.Want == "ok" && run.Error is not null)
                    c.Why.Add($"맞는 id_token 에 실패했다 — 아래 변형의 실패가 아무것도 증명하지 않는다: {run.Error.GetType().Name}: {OneLine(run.Error.Message)}");
                else if (nv.Want != "ok" && run.Error is null)
                    c.Why.Add("틀린 id_token 을 받아들였다");
                else if (nv.Want != "ok" && row.PublicSurface && !IsSdkError(run.Error!))
                    c.Why.Add($"SDK 오류 타입이 아니다: {run.Error!.GetType().FullName}");
                if (run.Error is not null)
                    c.Why.AddRange(LeakWhy(run.Error, BCanaries(idToken), Array.Empty<string>(), null));
                cells.Add(c);
            }
            foreach (var v in imported)
            {
                var run = await RunOnceAsync(idp, row, builderOf, dumpTypes, null,
                    _ => new HostileResp(v.Status, v.ContentType, v.Body), Given);
                var expected = v.Token ?? typeof(KeycloakAuthException);
                var c = new HpCell { Axis = "b", Label = row.Label, Variant = v.Name.Split(' ')[0] };
                if (!run.Sent.Any(IsTokenPost))
                    c.Why.Add("토큰 엔드포인트에 안 닿았다 — 변형이 공허하다");
                if (run.Error is null)
                    c.Why.Add("형식이 틀린 id_token 응답을 받아들였다");
                else
                {
                    if (row.PublicSurface && run.Error.GetType() != expected)
                        c.Why.Add($"{expected.Name} 를 기대했는데(출처 표의 계약) {run.Error.GetType().Name}");
                    c.Why.AddRange(LeakWhy(run.Error, v.Canaries.Select(x => (x, true)), v.Encoded ?? Array.Empty<string>(), v.Name));
                }
                cells.Add(c);
            }
        }
        return cells;
    }

    /// <summary>W3b 서명 변형의 카나리아 — 응답의 access·refresh 토큰(앞 10자까지)과 id_token 전체·서명 조각(전체만).</summary>
    private static IEnumerable<(string, bool)> BCanaries(string? idToken)
    {
        yield return (BAccess, true);
        yield return (BRefresh, true);
        if (idToken is null)
            yield break;
        yield return (idToken, false);
        yield return (idToken[(idToken.LastIndexOf('.') + 1)..], false);
    }

    private async Task<List<HpCell>> RunColdJwksCAsync(Idp idp, IEnumerable<HpRow> rows, Dictionary<Type, int> builderOf, HashSet<Type> dumpTypes)
    {
        var list = rows.ToList();
        _out.WriteLine("(c) 콜드 캐시 JWKS 대상(분류 실행이 /certs 를 조회한 행): " + string.Join(", ", list.Select(r => r.Label)));
        var cells = new List<HpCell>();
        foreach (var row in list)
        {
            await using var p = await PrepareAsync(idp, row, builderOf, dumpTypes); // 새 클라이언트 — 캐시가 비어 있다
            p.Cell.ResetLog();
            p.Cell.CertsDown = true;
            var c = new HpCell { Axis = "c", Label = row.Label, Variant = $"503×{ColdK}" };
            for (var i = 1; i <= ColdK; i++)
            {
                var (_, err) = await InvokeAsync(row, p, null);
                if (err is null)
                    c.Why.Add($"{i}번째 호출이 JWKS 503 인데 성공했다");
                else if (row.PublicSurface && !IsSdkError(err))
                    c.Why.Add($"{i}번째 호출의 오류가 SDK 오류 타입이 아니다: {err.GetType().FullName}");
            }
            var hits = p.Cell.Snapshot().Count(IsCertsGet);
            c.Note = $"certs {hits}";
            if (hits < 1)
                c.Why.Add($"/certs 요청 {hits} — 콜드 경로에 닿지 않았다(하한 1)");
            if (hits > ColdK - 1)
                c.Why.Add($"/certs 요청 {hits} — 실패한 조회가 물러서지 않았다(상한 {ColdK - 1})");
            cells.Add(c);
        }
        return cells;
    }

    /// <summary>칸마다 통과·GAP·FAIL 을 정하고 판정표를 찍는다. 실패 사유는 돌려주고(표 뒤에 찍힌다), 요약은 summaries 로 낸다.</summary>
    private List<string> Judge(List<HpCell> cells, out List<string> summaries)
    {
        var verdict = new Dictionary<string, string>(StringComparer.Ordinal);
        var fails = new List<string>();
        var observed = new HashSet<string>(StringComparer.Ordinal);
        foreach (var c in cells)
        {
            string v;
            if (c.Measure)
                v = c.Why.Count == 0 ? "m:rej" : "m:ACC";
            else if (c.Why.Count == 0)
                v = "pass";
            else if (KnownGaps.ContainsKey(c.Key))
            {
                v = "GAP";
                observed.Add(c.Key);
            }
            else
            {
                v = "FAIL";
                fails.Add($"{c.Key}: {string.Join(" · ", c.Why)}");
            }
            if (c.Note.Length > 0 && (c.Axis != "a" || c.Variant == "대조"))
                v += $"({c.Note})";
            verdict[c.Key] = v;
        }
        foreach (var axis in new[] { "a", "b", "c" })
            LogVerdicts(axis, cells, verdict);
        // 측정 칸은 변형마다 한 줄로 모은다 — 받아들인 행만 이름과 사유를 적는다.
        foreach (var g in cells.Where(c => c.Measure).GroupBy(c => $"W3{c.Axis} {c.Variant}"))
        {
            var rejected = g.Where(c => c.Why.Count == 0).Select(c => c.Note).Distinct().OrderBy(x => x, StringComparer.Ordinal);
            var accepted = g.Where(c => c.Why.Count > 0).Select(c => $"{c.Label}({string.Join(" · ", c.Why)})").ToList();
            _out.WriteLine($"측정(단언 안 함) {g.Key} — 거부 {g.Count(c => c.Why.Count == 0)} · 받아들임 {accepted.Count} · " +
                           $"거부 오류 [{string.Join(", ", rejected)}] · 받아들인 행 [{string.Join(", ", accepted)}]");
        }
        foreach (var (k, reason) in KnownGaps)
        {
            if (!observed.Contains(k))
                fails.Add($"KnownGaps[{k}]: 더는 관측되지 않는다 — 낡은 항목을 지워라({reason})");
        }
        summaries = new List<string>();
        foreach (var axis in new[] { "a", "b", "c" })
        {
            var mine = cells.Where(c => c.Axis == axis).ToList();
            string V(HpCell c) => verdict[c.Key].Split('(')[0];
            var failedBy = mine.Where(c => V(c) == "FAIL").GroupBy(c => c.Variant).Select(g => $"{g.Key}×{g.Count()}");
            summaries.Add($"W3{axis} 요약: pass {mine.Count(c => V(c) == "pass")} · GAP {mine.Count(c => V(c) == "GAP")} · " +
                          $"FAIL {mine.Count(c => V(c) == "FAIL")} · 측정 {mine.Count(c => c.Measure)}(m:rej {mine.Count(c => V(c) == "m:rej")} · " +
                          $"m:ACC {mine.Count(c => V(c) == "m:ACC")}) · FAIL 열 [{string.Join(", ", failedBy)}]");
        }
        return fails;
    }

    /// <summary>한 축의 판정표 — 행은 메서드, 열은 변형.</summary>
    private void LogVerdicts(string axis, List<HpCell> cells, Dictionary<string, string> verdict)
    {
        var mine = cells.Where(c => c.Axis == axis).ToList();
        var labels = mine.Select(c => c.Label).Distinct().ToList();
        var cols = mine.Select(c => c.Variant).Distinct().ToList();
        if (labels.Count == 0)
        {
            _out.WriteLine($"W3{axis} 판정표: 대상 행이 없다");
            return;
        }
        string At(string label, string col) => verdict.GetValueOrDefault($"W3{axis} {label}/{col}", "");
        var first = Math.Max(labels.Max(l => l.Length), 10);
        var width = cols.Select(col => Math.Max(col.Length, labels.Max(l => At(l, col).Length))).ToList();
        string Line(string head, Func<int, string> val) =>
            (head.PadRight(first) + " " + string.Join(" ", cols.Select((_, i) => val(i).PadRight(width[i])))).TrimEnd();
        _out.WriteLine($"W3{axis} 판정표 — {labels.Count}행 × {cols.Count}열 (pass · GAP=알려진 틈 · FAIL · m:rej/m:ACC=측정만: 거부/받아들임)");
        _out.WriteLine(Line("행 \\ 변형", i => cols[i]));
        foreach (var l in labels)
            _out.WriteLine(Line(l, i => At(l, cols[i])));
    }

    // ── W1: 손 목록 포함 ───────────────────────────────────────────────────────────────────────

    private const string ExchangeLabel = "AuthClient.ExchangeCodeAsync(String, String, String, String, CancellationToken)";
    private const string CcLabel = "AuthClient.ClientCredentialsTokenAsync(CancellationToken)";
    private const string RefreshLabel = "AuthClient.RefreshAsync(String, CancellationToken)";
    private const string IntrospectLabel = "AuthClient.IntrospectAsync(String, CancellationToken)";
    private const string LogoutLabel = "AuthClient.LogoutAsync(String, CancellationToken)";
    private const string BackoffLabel = "BackoffConfigurationManager.GetBaseConfigurationAsync(CancellationToken)";
    private const string MalformedCalls = "MalformedTokenResponseTests.cs|Calls";
    private const string MalformedWire = "MalformedTokenResponseTests.cs|Malformed_wire_response_errors_do_not_print_its_secrets";

    /// <summary>
    /// 손으로 고른 테스트가 겨누는 메서드 — 파생 집합이 이것 밑으로 <b>조용히</b> 줄지 않게 한다. <c>Anchor</c> 는 그 손 테스트
    /// (<c>파일|멤버</c>), <c>Call</c> 은 그 멤버 본문이 실제로 부르는 이름이다. <c>Axis</c>: a·b·c = 그 W3 축의 파생 대상에 있어야 한다 ·
    /// row = 행이고 계급이 맞기만 하면 된다(교환 계급 밖).
    /// </summary>
    private static readonly (string Label, string Class, string Axis, string Anchor, string Call)[] HandTargets =
    {
        // #617–#624 형식이 틀린 토큰 응답 테스트의 호출 표(MalformedTokenResponseTests.Calls)와 선 수준 테스트.
        (CcLabel, TokenGrant, "a", MalformedCalls, "ClientCredentialsTokenAsync"),
        (RefreshLabel, TokenGrant, "a", MalformedCalls, "RefreshAsync"),
        (ExchangeLabel, CodeExchange, "a", MalformedCalls, "ExchangeCodeAsync"),
        ("ClientCredentialsTokenProvider.GetAccessTokenAsync(CancellationToken)", TokenGrant, "a", MalformedCalls, "GetAccessTokenAsync"),
        ("KeycloakClient.AdminAsync(CancellationToken)", TokenGrant, "a", MalformedCalls, "AdminAsync"),
        (IntrospectLabel, OtherClass, "row", MalformedCalls, "IntrospectAsync"),
        (CcLabel, TokenGrant, "a", MalformedWire, "ClientCredentialsTokenAsync"),
        (RefreshLabel, TokenGrant, "a", MalformedWire, "RefreshAsync"),
        (ExchangeLabel, CodeExchange, "a", MalformedWire, "ExchangeCodeAsync"),
        (IntrospectLabel, OtherClass, "row", MalformedWire, "IntrospectAsync"),
        (LogoutLabel, OtherClass, "row", MalformedWire, "LogoutAsync"),
        // 보안 기본값 가드(scripts/test/test-security-defaults.sh)의 dotnet 행위 앵커 — nonce · 토큰 타입 · 백오프.
        (ExchangeLabel, CodeExchange, "b", "AuthClientTests.cs|ExchangeCode_nonce_mismatch_throws", "ExchangeCodeAsync"),
        (ExchangeLabel, CodeExchange, "b", "AuthClientTests.cs|ExchangeCode_missing_idtoken_with_nonce_throws", "ExchangeCodeAsync"),
        (CcLabel, TokenGrant, "a", "AuthClientTests.cs|ClientCredentialsToken_rejects_non_string_access_token", "ClientCredentialsTokenAsync"),
        (BackoffLabel, JwksFetch, "c", "BackoffConfigurationManagerTests.cs|ColdCacheFailingIdp_CollapsesToOneFetch", "GetBaseConfigurationAsync"),
        (BackoffLabel, JwksFetch, "c", "BackoffConfigurationManagerTests.cs|BackoffWindowExpires_AndAllowsARetry", "GetBaseConfigurationAsync"),
        (BackoffLabel, JwksFetch, "c", "BackoffConfigurationManagerTests.cs|SuccessResetsTheFailureCounter", "GetBaseConfigurationAsync"),
    };

    /// <summary>보안 기본값 가드가 dotnet 행위 앵커를 적는 모양 — nonce·백오프·토큰 타입 세 축이 이 모양이다.</summary>
    private static readonly Regex ScriptAnchor =
        new(@"dotnet/tests/Xzawed\.Keycloak\.Sdk\.Tests/([A-Za-z0-9_]+\.cs)\|public (?:async Task|void) ([A-Za-z0-9_]+)\(", RegexOptions.Compiled);

    private List<string> CheckHand(Dictionary<string, HpRow> byLabel, Dictionary<string, List<string>> tgt)
    {
        var why = new List<string>();
        var dotnet = DotnetRoot();
        if (dotnet is null)
            return new List<string> { "W1 dotnet/Keycloak.Sdk.sln 을 못 찾았다 — 테스트는 저장소 안에서 돈다(bin 위로 올라간다)" };
        var testsDir = Path.Combine(dotnet, "tests", "Xzawed.Keycloak.Sdk.Tests");
        // 요청을 내는 행의 이름 — 손 테스트 본문에서 이 이름을 부르면 표에 있어야 한다(NONE·설정 호출은 무관하다).
        var exchangeNames = byLabel.Values.Where(r => r.Called && r.Class is not (NoneClass or Undetermined))
            .Select(r => MethodName(r.Label)).ToHashSet(StringComparer.Ordinal);
        var anchors = HandTargets.Select(h => h.Anchor).Distinct().ToList();
        foreach (var h in HandTargets)
        {
            if (!byLabel.TryGetValue(h.Label, out var r))
                why.Add($"W1 {h.Label}: 손 테스트({h.Anchor})가 겨누는데 파생 집합에 행이 없다");
            else if (r.Class != h.Class)
                why.Add($"W1 {h.Label}: 손 테스트({h.Anchor})가 겨누는 계급은 {h.Class} 인데 파생은 {r.Class} 다");
            else if (h.Axis != "row" && !tgt[h.Axis].Contains(h.Label))
                why.Add($"W1 {h.Label}: 손 테스트({h.Anchor})가 겨누는데 W3{h.Axis} 의 파생 대상에 없다");
            if (MethodName(h.Label) != h.Call)
                why.Add($"W1 {h.Label}: 표의 호출 이름 {h.Call} 가 행의 메서드가 아니다 — 비공개 호출이면 그 공개 입구를 라벨로 적어라");
        }
        var nCalls = 0;
        foreach (var anchor in anchors)
        {
            var (file, member) = (anchor.Split('|')[0], anchor.Split('|')[1]);
            var body = MemberBody(Path.Combine(testsDir, file), member);
            if (body is null)
            {
                why.Add($"W1 {anchor}: 앵커 멤버가 없다 — 손 테스트가 옮겨졌으면 표를 따라 고쳐라");
                continue;
            }
            var calls = CallsIn(body);
            var mine = HandTargets.Where(h => h.Anchor == anchor).Select(h => h.Call).ToHashSet(StringComparer.Ordinal);
            foreach (var c in mine.Where(c => !calls.Contains(c)))
                why.Add($"W1 {anchor}: 앵커가 .{c}( 를 부르지 않는다 — 손 테스트의 대상이 바뀌었다");
            // 앵커가 부르는, 요청을 내는 공개 이름은 전부 표에 있다 — 손 테스트에 대상이 늘면 여기가 먼저 운다.
            foreach (var c in calls.Where(exchangeNames.Contains))
            {
                nCalls++;
                if (!mine.Contains(c))
                    why.Add($"W1 {anchor} 가 {c} 를 부르는데 HandTargets 에 그 앵커로 없다");
            }
        }
        if (nCalls == 0)
            why.Add("W1 앵커 본문에서 요청을 내는 공개 호출을 하나도 못 읽었다 — 대조가 공허하다");
        // 보안 기본값 가드의 dotnet 행위 앵커는 전부 표의 앵커다 — 그 가드에 dotnet 앵커가 늘면 여기가 운다.
        var script = Path.Combine(dotnet, "..", "scripts", "test", "test-security-defaults.sh");
        if (!File.Exists(script))
        {
            why.Add($"W1 보안 기본값 가드를 못 읽었다: {script}");
            return why;
        }
        var found = ScriptAnchor.Matches(File.ReadAllText(script)).Select(m => $"{m.Groups[1].Value}|{m.Groups[2].Value}").Distinct().ToList();
        _out.WriteLine($"W1 손 목록 {HandTargets.Length} 항목 · 앵커 {anchors.Count} — 앵커 본문의 요청 내는 공개 호출 {nCalls} · " +
                       $"보안 기본값 가드의 dotnet 행위 앵커 {found.Count} 와 대조");
        if (found.Count == 0)
            why.Add("W1 test-security-defaults.sh 에서 dotnet 행위 앵커를 하나도 못 읽었다 — 적는 모양이 바뀌었나?");
        foreach (var a in found.Where(a => !anchors.Contains(a)))
            why.Add($"W1 보안 기본값 가드의 dotnet 앵커 {a} 가 HandTargets 에 없다");
        return why;
    }

    private static string? DotnetRoot()
    {
        for (var d = new DirectoryInfo(AppContext.BaseDirectory); d is not null; d = d.Parent)
        {
            if (File.Exists(Path.Combine(d.FullName, "Keycloak.Sdk.sln")))
                return d.FullName;
        }
        return null;
    }

    /// <summary>
    /// 파일에서 멤버(메서드·필드) 하나의 본문 — 멤버 들여쓰기(4칸)의 선언 줄부터 다음 멤버 시작 줄 앞까지. <c>dotnet format</c> 이
    /// 들여쓰기를 강제하므로 중괄호를 세지 않는다(원시 문자열 속 JSON 중괄호를 셀 수 없다).
    /// </summary>
    private static string? MemberBody(string file, string member)
    {
        if (!File.Exists(file))
            return null;
        var lines = File.ReadAllLines(file);
        var decl = new Regex($@"^    \S.*\b{Regex.Escape(member)}\s*(\(|=(?![=>]))");
        var start = Array.FindIndex(lines, l => decl.IsMatch(l));
        if (start < 0)
            return null;
        var next = new Regex(@"^    (\[|///|public |private |internal |protected |static |// ─)");
        var end = start + 1;
        while (end < lines.Length && !next.IsMatch(lines[end]))
            end++;
        return string.Join("\n", lines[start..end]);
    }

    private static HashSet<string> CallsIn(string body) =>
        Regex.Matches(body, @"\.([A-Z][A-Za-z0-9_]*)\s*[(<]").Select(m => m.Groups[1].Value).ToHashSet(StringComparer.Ordinal);

    // ── 기록하는 가짜 IdP ───────────────────────────────────────────────────────────────────────

    private static string Sign(SecurityKey key, string issuer, IReadOnlyDictionary<string, object>? extra)
    {
        var now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        var claims = new Dictionary<string, object> { ["iss"] = issuer, ["sub"] = "u1", ["aud"] = "c", ["exp"] = now + 300, ["iat"] = now };
        foreach (var (k, v) in extra ?? new Dictionary<string, object>())
            claims[k] = v;
        return new JsonWebTokenHandler { SetDefaultTimesOnTokenCreation = false }
            .CreateToken(JsonSerializer.Serialize(claims), new SigningCredentials(key, SecurityAlgorithms.RsaSha256));
    }

    /// <summary>
    /// 기록하는 가짜 IdP — WireMock 하나에 모든 요청을 받는 콜백 매핑 하나. 칸은 경로 접두(<c>/hpN</c>)로 갈린다. 콜백이 먼저 기록하고
    /// 그다음 라우팅하므로 라우트가 없는 경로(admin 404 포함)도 남는다: 분류는 SDK 가 무엇을 <b>시도했나</b>를 본다.
    /// </summary>
    private sealed class Idp : IDisposable
    {
        private readonly WireMockServer _server;
        private readonly ConcurrentDictionary<string, Cell> _cells = new(StringComparer.Ordinal);
        private readonly string _jwks;
        private int _next;

        public Idp(RsaSecurityKey key)
        {
            Key = key;
            Rsa = key.Rsa!;
            var p = Rsa.ExportParameters(false);
            _jwks = $$"""{"keys":[{"kty":"RSA","kid":"k1","use":"sig","alg":"RS256","n":"{{Base64UrlEncoder.Encode(p.Modulus)}}","e":"{{Base64UrlEncoder.Encode(p.Exponent)}}"}]}""";
            _server = WireMockServer.Start();
            _server.Given(Request.Create().WithPath(new RegexMatcher(".*")).UsingAnyMethod())
                .RespondWith(Response.Create().WithCallback(Handle));
        }

        public RsaSecurityKey Key { get; }
        public RSA Rsa { get; }

        public Cell NewCell()
        {
            var prefix = $"/hp{Interlocked.Increment(ref _next)}";
            var cell = new Cell(this, prefix, _server.Urls[0] + prefix);
            _cells[prefix] = cell;
            _server.ResetLogEntries(); // 기록은 칸이 쥔다 — WireMock 자신의 로그가 수천 건으로 불지 않게
            return cell;
        }

        public void Forget(string prefix) => _cells.TryRemove(prefix, out _);

        private IResponseMessage Handle(IRequestMessage req)
        {
            var path = req.AbsolutePath;
            var slash = path.IndexOf('/', 1);
            var prefix = slash > 0 ? path[..slash] : path;
            if (!_cells.TryGetValue(prefix, out var cell))
                return Respond(404, "application/json", """{"error":"stale cell"}""");
            var rest = path[prefix.Length..];
            var method = req.Method.ToUpperInvariant();
            string? grant = null;
            if (method == "POST" && rest.EndsWith(TokenSuffix, StringComparison.Ordinal))
            {
                // 폼(RFC 6749)만 읽으면 JSON 본문으로 보낸 코드 교환이 TOKEN_GRANT 로 읽혀 W3b(nonce)를 비켜 간다(Grok 레그 지목,
                // 변이 실측 SILENT) — JSON 본문과 쿼리의 grant_type 도 읽는다.
                var raw = req.Body ?? (req.BodyAsBytes is { } b ? Encoding.UTF8.GetString(b) : "");
                grant = FormValue(raw, "grant_type") ?? JsonValue(raw, "grant_type")
                        ?? (req.Query is { } q && q.TryGetValue("grant_type", out var qv) && qv.Count > 0 ? qv[0] : null);
            }
            cell.Record(new Req(method, rest, grant));
            return (method, rest) switch
            {
                ("POST", Oidc + "/token") => cell.TokenOverride is { } o
                    ? Respond(o.Status, o.ContentType, o.Body)
                    : Respond(200, "application/json",
                        $$"""{"access_token":"hp-access","token_type":"Bearer","expires_in":1,"refresh_token":"hp-refresh","id_token":"{{cell.IdToken}}","scope":"openid"}"""),
                ("POST", Oidc + "/token/introspect") => Respond(200, "application/json", """{"active":true,"username":"svc","client_id":"c","sub":"u1"}"""),
                ("GET", "/realms/r/.well-known/openid-configuration") => Respond(200, "application/json",
                    $$"""{"issuer":"{{cell.Issuer}}","jwks_uri":"{{cell.Issuer}}/protocol/openid-connect/certs"}"""),
                ("GET", Oidc + "/certs") => cell.CertsDown ? Respond(503, null, null) : Respond(200, "application/json", _jwks),
                ("POST", Oidc + "/logout") => Respond(204, null, null),
                _ => Respond(404, "application/json", """{"error":"not found"}"""),
            };
        }

        private static string? FormValue(string body, string name)
        {
            foreach (var pair in body.Split('&'))
            {
                var eq = pair.IndexOf('=', StringComparison.Ordinal);
                if (eq > 0 && Uri.UnescapeDataString(pair[..eq]) == name)
                    return Uri.UnescapeDataString(pair[(eq + 1)..].Replace('+', ' '));
            }
            return null;
        }

        private static string? JsonValue(string body, string name)
        {
            if (!body.TrimStart().StartsWith('{'))
                return null;
            try
            {
                using var doc = JsonDocument.Parse(body);
                return doc.RootElement.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
            }
            catch (JsonException)
            {
                return null;
            }
        }

        private static ResponseMessage Respond(int status, string? contentType, string? body)
        {
            var msg = new ResponseMessage { StatusCode = status, Headers = new Dictionary<string, WireMockList<string>>() };
            if (contentType is not null)
                msg.Headers["Content-Type"] = new WireMockList<string>(contentType);
            if (body is not null)
                msg.BodyData = new BodyData { DetectedBodyType = BodyType.String, BodyAsString = body, Encoding = Encoding.UTF8 };
            return msg;
        }

        public void Dispose() => _server.Dispose();
    }

    /// <summary>가짜 IdP 의 한 칸 — 새 IdP 와 같다(요청 기록·토큰 응답 교체·JWKS 다운). 보편 인자와 id_token 은 이 칸의 발급자로 서명한다.</summary>
    private sealed class Cell : IDisposable
    {
        private readonly Idp _idp;
        private readonly object _gate = new();
        private readonly List<Req> _reqs = new();
        private HostileResp? _tokenOverride;
        private bool _certsDown;

        public Cell(Idp idp, string prefix, string baseUrl)
        {
            _idp = idp;
            Prefix = prefix;
            BaseUrl = baseUrl;
            Issuer = baseUrl + "/realms/r";
            // ⚠️ 평문이면 토큰을 받는 메서드(ValidateAsync 둘)가 JWS 파싱에서 요청 없이 실패해 UNDETERMINED 가 되고 JWKS_FETCH 가 빈다
            // — 그래서 이 IdP 키로 서명한 **유효한 JWS** 다. URL·경로·폼에 안전한 문자만 쓴다.
            Universal = Sign(idp.Key, Issuer, null);
            IdToken = Sign(idp.Key, Issuer, new Dictionary<string, object> { ["nonce"] = Universal });
        }

        public string Prefix { get; }
        public string BaseUrl { get; }
        public string Issuer { get; }
        public string Universal { get; }
        public string IdToken { get; }

        // expires_in 을 기본 skew(30s)보다 짧게 준다(정상 응답의 1) — provider 캐시가 늘 식어 있어, 부여에 **닿을 수 있는** 메서드는 실제로
        // 닿는다(admin 메서드가 뿌리 때 데운 토큰에 가려 OTHER 로 읽히지 않게).
        public KeycloakConfig Config => new() { ServerUrl = BaseUrl, Realm = "r", ClientId = "c", ClientSecret = "hp-client-secret" };

        public HostileResp? TokenOverride
        {
            get { lock (_gate) return _tokenOverride; }
            set { lock (_gate) _tokenOverride = value; }
        }

        public bool CertsDown
        {
            get { lock (_gate) return _certsDown; }
            set { lock (_gate) _certsDown = value; }
        }

        public void Record(Req r)
        {
            lock (_gate)
                _reqs.Add(r);
        }

        public void ResetLog()
        {
            lock (_gate)
                _reqs.Clear();
        }

        public List<Req> Snapshot()
        {
            lock (_gate)
                return new List<Req>(_reqs);
        }

        public void Dispose() => _idp.Forget(Prefix);
    }
}
