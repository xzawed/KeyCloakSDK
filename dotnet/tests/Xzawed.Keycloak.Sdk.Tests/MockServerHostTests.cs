using Microsoft.AspNetCore.Builder;
using Microsoft.Extensions.Configuration;
using WireMock.Server;
using Xunit;

namespace Xzawed.Keycloak.Sdk.Tests;

/// <summary>목 서버의 호스트가 설정 파일을 감시하지 않는다(<see cref="TestHostDefaults"/> — 등록부 <c>dotnet-tests-exhaust-inotify</c>).</summary>
[Collection(MockServerHostCollection.Name)]
[Trait("Category", "Unit")]
public sealed class MockServerHostTests
{
    /// <summary>기전 — WireMock 의 net10.0 빌드가 부르는 그 빌더의 파일 설정 소스가 하나도 다시 읽기를 걸지 않는다. 모든 OS ·
    /// 두 대상에서 돈다(값을 두지 않은 main 에서는 <c>appsettings.json</c> · <c>appsettings.Production.json</c> 이 true 다).</summary>
    [Fact]
    public void TheHostBuilderOfTheMockServersWatchesNoConfigFile()
    {
        var builder = WebApplication.CreateBuilder(new WebApplicationOptions());
        try
        {
            var files = builder.Configuration.Sources.OfType<FileConfigurationSource>().ToList();
            Assert.NotEmpty(files); // 기본값이 파일 소스를 넣지 않게 바뀌면 이 시험은 아무것도 재지 않는다
            Assert.All(files, source => Assert.False(source.ReloadOnChange, source.Path));
        }
        finally
        {
            ((IDisposable)builder.Configuration).Dispose();
        }
    }

    /// <summary>끝에서 끝 — 목 서버 셋이 도는 동안 이 프로세스의 inotify 인스턴스가 늘지 않는다. 한도가 있는 것은 리눅스의
    /// inotify 라 리눅스에서만 잰다(CI 의 두 대상 잡이 ubuntu 다). 값을 두지 않은 main 의 net10.0 에서는 서버마다 하나씩 는다 —
    /// net8.0 은 WireMock 이 appsettings 를 넣지 않아 main 에서도 늘지 않는다(대조군).</summary>
    /// <remarks>⚠️ 다른 OS 에서 <c>Skip</c> 으로 비키지 않는다 — dotnet 장부 판독기(<c>scripts/integration-coverage.mjs</c>)는
    /// Passed 가 아닌 결과 하나를 실패한 실행으로 읽어, Windows · macOS 의 장부 실행이 전부 멈춘다. 모든 OS 에서 실패할 수 있는
    /// 단언은 위 기전 시험이 진다.</remarks>
    [Fact]
    public void RunningMockServersOpenNoInotifyInstance()
    {
        if (!OperatingSystem.IsLinux())
            return;
        // 앞선 시험이 버린 감시기는 종료자가 닫는다 — 먼저 닫아 두어야 그 사이의 닫힘이 늘어난 것을 가리지 않는다.
        GC.Collect();
        GC.WaitForPendingFinalizers();
        GC.Collect();
        var before = InotifyInstances();
        var servers = new List<WireMockServer>();
        try
        {
            for (var i = 0; i < 3; i++)
                servers.Add(WireMockServer.Start());
            var running = InotifyInstances();
            Assert.True(running <= before, $"inotify instances grew from {before} to {running} while {servers.Count} mock servers ran");
        }
        finally
        {
            foreach (var server in servers)
                server.Dispose();
        }
    }

    private static int InotifyInstances()
    {
        var count = 0;
        foreach (var fd in Directory.EnumerateFileSystemEntries("/proc/self/fd"))
        {
            try
            {
                if (new FileInfo(fd).LinkTarget == "anon_inode:inotify")
                    count++;
            }
            catch (IOException)
            {
                // 세는 사이에 닫힌 디스크립터 — 세지 않는다
            }
        }
        return count;
    }
}

/// <summary>inotify 계수는 다른 시험 클래스의 목 서버와 겹치지 않아야 한다 — 병렬 컬렉션이 다 끝난 뒤 혼자 돈다.</summary>
[CollectionDefinition(Name, DisableParallelization = true)]
public sealed class MockServerHostCollection
{
    public const string Name = "mock server host (not parallel)";
}
