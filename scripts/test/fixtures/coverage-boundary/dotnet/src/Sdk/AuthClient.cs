namespace Sdk;

// class Fake {} — 주석
public sealed class AuthClient
{
    private readonly string _s = $"class {nameof(AuthClient)} {{ not a brace";
    private readonly string _v = @"interface I { ""quoted"" }";

    private sealed class Nested { }

    public System.Threading.Tasks.Task<string> TokenAsync() => System.Threading.Tasks.Task.FromResult(_s + _v);
}
