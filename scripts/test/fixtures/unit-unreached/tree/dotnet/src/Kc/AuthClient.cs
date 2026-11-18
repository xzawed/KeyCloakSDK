namespace Kc;

// Fixture boundary class for the unit-unreached ledger — the unit drive (tests/Kc.Tests/DriveTests.cs) reaches part of it.
public sealed class AuthClient
{
    private static readonly string[] Scopes = ["openid", "profile"];
    private readonly Config _config;

    public AuthClient(Config config)
    {
        _config = config;
    }

    // Fully reached by the drive — not in the ledger.
    public string Realm => $"{_config.Realm}:{Scopes.Length}";

    // A failure branch on its own lines: the drive never sends an empty code.
    public string Exchange(string code)
    {
        if (code.Length == 0)
        {
            throw new ArgumentException("empty code");
        }
        return code.ToUpperInvariant();
    }

    // A failure branch on a line the happy path already runs: no line is left unreached, the branch is.
    public string Pick(string? value) => value ?? throw new InvalidOperationException("none");

    // A lambda's branch counts for the method that defines it: the drive never passes an empty string.
    public int[] Lengths(string[] values) => values.Select(v => v.Length == 0 ? -1 : v.Length).ToArray();

    // An async method's body is its state machine's, folded into the method: the drive never sends an empty code. The await never
    // suspends (a completed Task), so if its IsCompleted test were a branch, the suspending arm would be unreached here too —
    // coverlet does not report that test for a Task or ValueTask awaiter (it does for Task.Yield's — the tool's header).
    public async Task<string> TokenAsync(string code)
    {
        await Task.CompletedTask.ConfigureAwait(false);
        if (code.Length == 0)
        {
            return "none";
        }
        return $"{_config.Realm}:{code}";
    }

    // A decision inside a catch filter is not a branch: the drive throws without an inner TimeoutException, so the filter runs
    // and declines — what it skipped shows only as the catch body's lines.
    public string Guarded(Func<string> call)
    {
        try
        {
            return call();
        }
        catch (InvalidOperationException e) when (e.InnerException is TimeoutException)
        {
            return "timed out";
        }
    }

    // Overloads are told apart by signature, their branches with them: the drive calls Describe(int) with a positive depth only.
    public string Describe() => "auth";

    public string Describe(int depth) => depth > 0 ? "auth+" : "auth";

    // Never called by the drive (the integration test below calls it — the unit run leaves that test out).
    public string LogoutUrl(string redirect) => "https://kc/logout?redirect_uri=" + Uri.EscapeDataString(redirect);
}
