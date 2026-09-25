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

    /// <summary>Value the token's <c>aud</c> must contain (default: <see cref="ClientId"/>). A stock realm
    /// does not put the client id in a client-credentials token's <c>aud</c> — set the resource/audience your
    /// realm actually issues, or add an audience mapper to the client in Keycloak.</summary>
    public string? ExpectedAudience { get; init; }

    /// <summary>JWT signature algorithms accepted during validation (default ["RS256"]). Set for
    /// ES256/PS256-signed realms — a hardcoded RS256 would reject every otherwise-valid token there.</summary>
    public IReadOnlyList<string> SignatureAlgorithms { get; init; } = new[] { "RS256" };
    public int ConnectTimeoutMs { get; init; } = 10_000;
    public int ReadTimeoutMs { get; init; } = 30_000;
    public int ClockSkewSeconds { get; init; } = 30;

    /// <summary>Validates required fields and ServerUrl, and returns a normalized copy
    /// (trailing '/' stripped from ServerUrl).</summary>
    public KeycloakConfig Normalized()
    {
        Require(ServerUrl, nameof(ServerUrl));
        Require(Realm, nameof(Realm));
        Require(ClientId, nameof(ClientId));
        if (SignatureAlgorithms.Count == 0)
            throw new KeycloakConfigException("SignatureAlgorithms must be non-empty");
        // 타임아웃은 HttpClient.Timeout / SocketsHttpHandler.ConnectTimeout에 배선되며 ≤0이면
        // 사용 시점에 raw ArgumentOutOfRangeException을 던진다(Timeout.InfiniteTimeSpan만 예외 허용).
        // 여기서 KeycloakConfigException으로 fail-fast한다(Go의 음수 타임아웃 거부와 동형).
        RequirePositive(ConnectTimeoutMs, nameof(ConnectTimeoutMs));
        RequirePositive(ReadTimeoutMs, nameof(ReadTimeoutMs));
        if (ClockSkewSeconds < 0)
            throw new KeycloakConfigException($"{nameof(ClockSkewSeconds)} must be >= 0");
        var serverUrl = ServerUrl.TrimEnd('/');
        // 실측: 공백이 섞인 ServerUrl("http://kc example.com")은 생성을 통과한 뒤
        // ClientCredentialsTokenAsync에서 System.UriFormatException으로 공개 API를 빠져나간다.
        // 후행 슬래시를 뗀 값이 절대 http(s) URL이 아니면 KeycloakConfigException으로 fail-fast한다.
        RequireAbsoluteHttpUrl(serverUrl);
        return this with { ServerUrl = serverUrl };
    }

    private static void Require(string value, string name)
    {
        if (string.IsNullOrWhiteSpace(value))
            throw new KeycloakConfigException($"Missing required config: {name}");
    }

    private static void RequireAbsoluteHttpUrl(string value)
    {
        // 65536 처럼 범위 밖 포트도 여기서 거절된다 — net8 의 TryCreate 가 false 를 돌려준다(실측).
        if (!Uri.TryCreate(value, UriKind.Absolute, out var uri))
            throw InvalidServerUrl("not an absolute URI");
        if (uri.Scheme != Uri.UriSchemeHttp && uri.Scheme != Uri.UriSchemeHttps)
            throw InvalidServerUrl("scheme must be http or https");
    }

    private static KeycloakConfigException InvalidServerUrl(string reason) =>
        new($"ServerUrl must be an absolute http(s) URL: {reason}");

    private static void RequirePositive(int value, string name)
    {
        if (value <= 0)
            throw new KeycloakConfigException($"{name} must be > 0 (was {value})");
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
