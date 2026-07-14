using System.Text.Json;
using System.Text.Json.Serialization;

namespace Xzawed.Keycloak;

/// <summary>Immutable SDK configuration. Build with an object initializer, then pass to
/// <c>KeycloakClient.Create</c> which validates and normalizes it.</summary>
[JsonConverter(typeof(KeycloakConfigJsonConverter))]   // masks clientSecret in ToString() and System.Text.Json serialization.
                                                       // NOTE: reflection-based destructuring loggers (Serilog {@}) read raw
                                                       // properties and bypass this — do not @-destructure KeycloakConfig.
public sealed record KeycloakConfig
{
    public required string ServerUrl { get; init; }
    public required string Realm { get; init; }
    public required string ClientId { get; init; }
    public string? ClientSecret { get; init; }
    public IReadOnlyList<string> Scopes { get; init; } = Array.Empty<string>();

    /// <summary>JWT signature algorithms accepted during validation (default ["RS256"]). Set for
    /// ES256/PS256-signed realms — a hardcoded RS256 would reject every otherwise-valid token there.</summary>
    public IReadOnlyList<string> SignatureAlgorithms { get; init; } = new[] { "RS256" };
    public int ConnectTimeoutMs { get; init; } = 10_000;
    public int ReadTimeoutMs { get; init; } = 30_000;
    public int ClockSkewSeconds { get; init; } = 30;

    /// <summary>Validates required fields and returns a normalized copy (trailing '/' stripped from ServerUrl).</summary>
    public KeycloakConfig Normalized()
    {
        Require(ServerUrl, nameof(ServerUrl));
        Require(Realm, nameof(Realm));
        Require(ClientId, nameof(ClientId));
        if (SignatureAlgorithms.Count == 0)
            throw new KeycloakConfigException("SignatureAlgorithms must be non-empty");
        return this with { ServerUrl = ServerUrl.TrimEnd('/') };
    }

    private static void Require(string value, string name)
    {
        if (string.IsNullOrWhiteSpace(value))
            throw new KeycloakConfigException($"Missing required config: {name}");
    }

    public override string ToString() =>
        $"KeycloakConfig {{ ServerUrl = {ServerUrl}, Realm = {Realm}, ClientId = {ClientId}, " +
        $"ClientSecret = {(ClientSecret is null ? "(none)" : Masking.Mask(ClientSecret))}, " +
        $"Scopes = [{string.Join(", ", Scopes)}] }}";
}

/// <summary>Masks clientSecret when a KeycloakConfig is JSON-serialized via System.Text.Json.
/// NOTE: reflection-based destructuring loggers (Serilog {@}) read raw properties and bypass this
/// converter entirely — do not @-destructure KeycloakConfig.</summary>
internal sealed class KeycloakConfigJsonConverter : JsonConverter<KeycloakConfig>
{
    public override KeycloakConfig Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
        => throw new NotSupportedException("KeycloakConfig is not deserializable from JSON.");

    public override void Write(Utf8JsonWriter writer, KeycloakConfig value, JsonSerializerOptions options)
    {
        writer.WriteStartObject();
        writer.WriteString("serverUrl", value.ServerUrl);
        writer.WriteString("realm", value.Realm);
        writer.WriteString("clientId", value.ClientId);
        if (value.ClientSecret is null) writer.WriteNull("clientSecret");
        else writer.WriteString("clientSecret", Masking.Mask(value.ClientSecret));
        writer.WriteStartArray("scopes");
        foreach (var s in value.Scopes) writer.WriteStringValue(s);
        writer.WriteEndArray();
        writer.WriteEndObject();
    }
}
