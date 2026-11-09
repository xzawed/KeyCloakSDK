namespace Kc;

public sealed record Config(string ServerUrl, string Realm)
{
    public string Issuer => $"{ServerUrl}/realms/{Realm}";
}
