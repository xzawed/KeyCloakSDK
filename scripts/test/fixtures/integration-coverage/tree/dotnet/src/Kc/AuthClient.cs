namespace Kc;

public sealed class AuthClient
{
    private static readonly string[] Scopes = ["openid", "profile"];
    private readonly Config _config;

    public AuthClient(Config config)
    {
        _config = config;
    }

    public string Issuer => _config.Issuer;

    public int Retries { get; set; } = 3;

    public async Task<string> TokenAsync(string code)
    {
        await Task.Yield();
        if (code.Length == 0)
        {
            return "none";
        }
        return $"{_config.Realm}:{code}";
    }

    public string[] Upper() => Scopes.Select(s => s.ToUpperInvariant()).ToArray();

    public string Joined(string sep)
    {
        var prefix = _config.Realm;
        return string.Join(sep, Scopes.Select(s => prefix + s));
    }

    public int Count(int n)
    {
        return Twice(n) + 1;

        static int Twice(int x) => x * 2;
    }

    public string Describe() => "auth";

    public string Describe(int depth) => depth > 0 ? "auth+" : "auth";

    public IEnumerable<int> Items()
    {
        yield return 1;
        yield return 2;
    }

    public async Task<int> SumAsync()
    {
        Func<int, Task<int>> next = async x =>
        {
            await Task.Yield();
            return x + 1;
        };
        return await next(1);
    }

    public async Task<T> EchoAsync<T>(T value)
    {
        await Task.Yield();
        return value;
    }

    public async Task LogoutAsync()
    {
        await Task.Delay(1);
    }

    public static AuthClient Build(Config config) => new(config);
}
