using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;
using System.Text.Json.Serialization.Metadata;

namespace Xzawed.Keycloak;

/// <summary>Refuses an admin request body holding an unpaired UTF-16 surrogate — a <see cref="KeycloakTransportException"/>
/// with the message of every body JSON cannot carry, before the token is asked for and before any request (registry
/// <c>admin-unencodable-body-residuals</c>). System.Text.Json does not refuse one: it writes U+FFFD in its place, so the
/// server stored a value the caller never sent (measured: <c>UnpairedSurrogateRequestBodyTests</c>).</summary>
/// <remarks>
/// <para>Every admin body is a <c>JsonContent</c> written with System.Net.Http.Json's defaults — the typed client passes no
/// options (measured: its assembly has no <see cref="JsonSerializerOptions"/> field and no method taking or returning one)
/// and the raw writes call
/// <c>JsonContent.Create</c> — so the body is written once beforehand with those options, into nothing, by observers that see
/// each string the serializer writes: string values and dictionary keys, a <see cref="char"/>, a <see cref="JsonNode"/>'s keys
/// and strings. An extension-data dictionary is written key by key past every converter, so here it is written as the
/// ordinary dictionary it is. <c>JsonSerializer.SerializeToNode</c> cannot see the surrogate: it writes UTF-8 first, so the
/// node already holds U+FFFD. A <see cref="JsonElement"/> holding one is refused by the serializer itself.</para>
/// <para>Anything else the serializer refuses — a cycle, NaN, a <see cref="Type"/> — or a getter's own failure is not
/// answered here: the transport meets it again when it writes the body and answers as it always did.</para>
/// </remarks>
internal static class EncodableBody
{
    private static readonly JsonSerializerOptions Observing = CreateObserving();

    /// <summary>Throws <see cref="KeycloakTransportException"/> when <paramref name="value"/>, written as
    /// <paramref name="declaredType"/>, would carry an unpaired surrogate.</summary>
    internal static void Require(object? value, Type declaredType)
    {
        try
        {
            JsonSerializer.Serialize(Stream.Null, value, declaredType, Observing);
        }
        catch (UnpairedSurrogateException)
        {
            throw new KeycloakTransportException(Admin.AdminClient.UnencodableBody);
        }
        catch (Exception)
        {
            // Left to the transport (remarks): it writes the same body and answers as it always did.
        }
    }

    /// <summary>A high surrogate with no low one after it, or a low one with no high one before it.</summary>
    private static bool HasUnpairedSurrogate(string text)
    {
        for (var i = 0; i < text.Length; i++)
        {
            if (char.IsHighSurrogate(text[i]) && i + 1 < text.Length && char.IsLowSurrogate(text[i + 1]))
                i++;   // a pair is one character
            else if (char.IsSurrogate(text[i]))
                return true;
        }
        return false;
    }

    private static void Observe(string text)
    {
        if (HasUnpairedSurrogate(text))
            throw new UnpairedSurrogateException();
    }

    private static JsonSerializerOptions CreateObserving()
    {
        var resolver = new DefaultJsonTypeInfoResolver();
        resolver.Modifiers.Add(info =>
        {
            foreach (var property in info.Properties)
                property.IsExtensionData = false;
        });
        var options = new JsonSerializerOptions(JsonSerializerDefaults.Web) { TypeInfoResolver = resolver };
        options.Converters.Add(new StringObserver());
        options.Converters.Add(new CharObserver());
        options.Converters.Add(new NodeObserver());
        return options;
    }

    /// <summary>The signal an observer raises; never leaves <see cref="Require"/>.</summary>
    private sealed class UnpairedSurrogateException : Exception
    {
    }

    // The observers only write: the options are never read with.
    private sealed class StringObserver : JsonConverter<string>
    {
        public override string Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
            => throw new NotSupportedException("The observing options are write-only.");

        public override void Write(Utf8JsonWriter writer, string value, JsonSerializerOptions options)
        {
            Observe(value);
            writer.WriteStringValue(value);
        }

        public override void WriteAsPropertyName(Utf8JsonWriter writer, string value, JsonSerializerOptions options)
        {
            Observe(value);
            writer.WritePropertyName(value);
        }
    }

    private sealed class CharObserver : JsonConverter<char>
    {
        public override char Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
            => throw new NotSupportedException("The observing options are write-only.");

        public override void Write(Utf8JsonWriter writer, char value, JsonSerializerOptions options)
        {
            Observe(value.ToString());
            writer.WriteStringValue(value.ToString());
        }
    }

    /// <summary>A <see cref="JsonNode"/> writes its own keys and strings, past every converter — so its tree is walked
    /// first, without recursion (a deep node fails the writer's depth limit, not the stack).</summary>
    private sealed class NodeObserver : JsonConverter<JsonNode>
    {
        public override bool CanConvert(Type typeToConvert) => typeof(JsonNode).IsAssignableFrom(typeToConvert);

        public override JsonNode Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
            => throw new NotSupportedException("The observing options are write-only.");

        public override void Write(Utf8JsonWriter writer, JsonNode value, JsonSerializerOptions options)
        {
            var pending = new Stack<JsonNode?>();
            pending.Push(value);
            while (pending.TryPop(out var node))
            {
                switch (node)
                {
                    case JsonObject obj:
                        foreach (var (key, child) in obj)
                        {
                            Observe(key);
                            pending.Push(child);
                        }
                        break;
                    case JsonArray array:
                        foreach (var child in array)
                            pending.Push(child);
                        break;
                    case JsonValue scalar when scalar.TryGetValue(out string? text):
                        Observe(text);
                        break;
                    case JsonValue scalar when scalar.TryGetValue(out char c):
                        Observe(c.ToString());
                        break;
                }
            }
            value.WriteTo(writer, options);
        }
    }
}
