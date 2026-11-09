namespace Kc;

public sealed class AuthClient
{
    private static readonly string[] Scopes = ["openid", "profile"];
    private readonly Config _config;

    public AuthClient(Config config)
    {
        _config = config;
    }

    public AuthClient(string serverUrl, string realm)
        : this(new Config(serverUrl, realm))
    {
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

    public string[] Prefixed(string prefix)
    {
        return Scopes
            .Select(s =>
            {
                var head = prefix.Trim();
                return head + s;
            })
            .ToArray();
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

    public int Unused(int n)
    {
        return Helper(n);

        static int Helper(int x) => x + 1;
    }

    public Func<Task<int>> Later()
    {
        return async () =>
        {
            await Task.Yield();
            return 1;
        };
    }

    public string[] Lower()
    {
        return Scopes
            .Select(s =>
            {
                return s.ToLowerInvariant();
            })
            .ToArray();
    }

    public async Task<string[]> NamesAsync()
    {
        await Task.Yield();
        return Scopes
            .Select(s =>
            {
                return s.ToUpperInvariant();
            })
            .ToArray();
    }

    public async Task<int> RetryAsync(bool fail)
    {
        await Task.Yield();
        if (fail)
        {
            Func<Task<int>> fallback = async () =>
            {
                await Task.Yield();
                return 0;
            };
            return await fallback();
        }
        return 1;
    }
}
