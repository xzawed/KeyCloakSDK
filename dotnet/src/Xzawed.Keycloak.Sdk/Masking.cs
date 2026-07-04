namespace Xzawed.Keycloak;

/// <summary>Opaque masking for secrets and tokens — never exposes length or prefix.</summary>
public static class Masking
{
    public static string Mask(string? value) => "***";
}
