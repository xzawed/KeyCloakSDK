// Install-smoke(b1) — harness/install/quickstart/node/quickstart.mjs의 .NET 등가물.
//
// dotnet/examples/에는 quickstart 예제가 없어(부재) 이 하네스 전용 파일로 신설했다 — Xzawed.Keycloak.Sdk
// 배포 아티팩트(nupkg)에는 포함되지 않는다. consume/dotnet.Dockerfile이 BaGetter에서 설치한
// `Xzawed.Keycloak.Sdk@0.1.0`(소스 트리 접근 없음)을 실 Keycloak에 대해 최소 흐름(client-credentials
// 발급 → 자체 강화 validate)으로 구동해 "설치 후 첫 프로그램이 실제로 동작한다"를 증명한다.
//
// consume/dotnet-run.sh가 install-net에서 `dotnet run`으로 실행해야 KC_SERVER_URL(http://keycloak:8080)을
// install-net의 도커 DNS로 해석할 수 있다.
using Xzawed.Keycloak;

static string Env(string k, string d) =>
    Environment.GetEnvironmentVariable(k) is { Length: > 0 } v ? v : d;

try
{
    var config = new KeycloakConfig
    {
        ServerUrl = Env("KC_SERVER_URL", "http://localhost:8080"),
        Realm = Env("KC_REALM", "it-realm"),
        ClientId = Env("KC_CLIENT_ID", "it-client"),
        ClientSecret = Env("KC_CLIENT_SECRET", "it-secret"),
    };

    await using var kc = KeycloakClient.Create(config);

    // 1) client-credentials 토큰 발급.
    var token = await kc.Auth.ClientCredentialsTokenAsync();
    if (string.IsNullOrEmpty(token.AccessToken))
        throw new InvalidOperationException("quickstart-smoke: no access token issued");

    // 2) 발급받은 토큰을 자체 강화 검증(alg 핀·iss 정확일치·aud 포함검사·클록 스큐).
    var validated = await kc.Auth.ValidateAsync(token.AccessToken);
    if (string.IsNullOrEmpty(validated.Subject))
        throw new InvalidOperationException("quickstart-smoke: validate produced no subject");

    Console.WriteLine(
        $"quickstart-smoke OK: tokenType={token.TokenType} subject={validated.Subject} " +
        $"audience={string.Join(",", validated.Audience)}");
}
catch (Exception ex)
{
    Console.Error.WriteLine($"quickstart-smoke FAILED: {ex}");
    Environment.Exit(1);
}
