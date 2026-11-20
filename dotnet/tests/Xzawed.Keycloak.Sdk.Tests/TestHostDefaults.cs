using System.Runtime.CompilerServices;

namespace Xzawed.Keycloak.Sdk.Tests;

/// <summary>이 시험 어셈블리가 처음 올라올 때 — 어떤 시험보다 먼저 — 프로세스 환경에 두는 값.</summary>
/// <remarks>
/// ⚠️ 목 서버(WireMock.Net 2.31.0)는 net10.0 빌드에서 <c>WebApplication.CreateBuilder</c> 로 호스트를 만들고
/// (net8.0 빌드는 <c>new WebHostBuilder()</c> — appsettings 를 넣지 않는다), 그 기본값이 <c>appsettings.json</c> 을
/// <c>reloadOnChange</c> 로 넣는다. 그 감시기(리눅스에서는 inotify 인스턴스 하나)는 WireMock 이 곧바로 부르는
/// <c>Configuration.Sources.Clear()</c> 뒤에도 남아, 서버마다 하나씩 쌓였다 — ubuntu 러너의 한도 128 을 넘겨 net10.0 잡에서
/// 1268 중 44 가 <c>IOException</c> 이었다(등록부 <c>dotnet-tests-exhaust-inotify</c>, 재실행 통과). 호스트 기본값은
/// <c>hostBuilder:reloadConfigOnChange</c> 를 <c>DOTNET_</c> 환경 변수에서도 읽는다 — 그래서 runsettings(CI 의 단위 실행은
/// <c>--settings</c> 를 넘기지 않는다)가 아니라 여기서 둔다. 고정: <see cref="MockServerHostTests"/>.
/// </remarks>
internal static class TestHostDefaults
{
    internal const string ReloadConfigOnChange = "DOTNET_hostBuilder__reloadConfigOnChange";

    [ModuleInitializer]
    internal static void Apply() => Environment.SetEnvironmentVariable(ReloadConfigOnChange, "false");
}
