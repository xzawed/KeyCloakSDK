namespace Xzawed.Keycloak;

/// <summary>Opaque masking for secrets/tokens — internal implementation detail (not public API).</summary>
internal static class Masking
{
    public static string Mask(string? value) => "***";
}
