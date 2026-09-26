using System.Text.Json;
using Xunit;
using Xzawed.Keycloak;

namespace Xzawed.Keycloak.Sdk.Tests;

public class ErrorsTests
{
    [Fact]
    public void MapHttpError_404_is_NotFound_and_AdminException_and_base()
    {
        var ex = KeycloakErrorMapping.MapHttpError(404, "gone");
        Assert.IsType<KeycloakNotFoundException>(ex);
        Assert.IsAssignableFrom<KeycloakAdminException>(ex);
        Assert.IsAssignableFrom<KeycloakException>(ex);
        Assert.Equal(404, ((KeycloakAdminException)ex).StatusCode);
    }

    [Fact]
    public void MapHttpError_409_and_403()
    {
        Assert.IsType<KeycloakConflictException>(KeycloakErrorMapping.MapHttpError(409, "x"));
        Assert.IsType<KeycloakForbiddenException>(KeycloakErrorMapping.MapHttpError(403, "x"));
    }

    [Fact]
    public void MapHttpError_other_is_AdminException_with_status_in_message()
    {
        var ex = KeycloakErrorMapping.MapHttpError(500, "boom");
        Assert.IsType<KeycloakAdminException>(ex);
        Assert.Contains("500", ex.Message);
    }

    [Fact]
    public void Exceptions_preserve_inner()
    {
        var inner = new System.Exception("root");
        var ex = new KeycloakAuthException("auth failed", inner) { OAuthError = "invalid_grant" };
        Assert.Same(inner, ex.InnerException);
        Assert.Equal("invalid_grant", ex.OAuthError);
    }

    // ── 입력을 인용하는 하위 예외 — 원인 사슬 정화(MalformedTokenResponseTests 가 경로로 잰다) ─────────────────

    private const string Canary = "LK-SCRUB-AT-canary";

    /// <summary>진짜 System.Text.Json 예외 — 본문이 't' 로 시작하면 첫 구분자까지 전부를 인용한다(실측).</summary>
    private static JsonException ParseError(string body)
    {
        try { JsonDocument.Parse(body); }
        catch (JsonException e) { return e; }
        throw new Xunit.Sdk.XunitException("파싱이 실패하지 않았다");
    }

    [Fact]
    public void Inner_json_error_that_quotes_the_body_is_replaced_by_a_copy_that_keeps_type_and_position()
    {
        var raw = ParseError($"token_type=bearer&access_token={Canary}");
        Assert.Contains(Canary, raw.Message); // 대조군 — 하위 예외는 정말 인용한다

        var ex = new KeycloakTransportException("Client credentials grant failed (transport)", raw);

        Assert.DoesNotContain(Canary, ex.ToString());
        var inner = Assert.IsAssignableFrom<JsonException>(ex.InnerException);
        Assert.NotSame(raw, inner);
        Assert.Equal((raw.LineNumber, raw.BytePositionInLine), (inner.LineNumber, inner.BytePositionInLine));
        Assert.Equal("Client credentials grant failed (transport)", ex.Message);
    }

    [Fact]
    public void Quoting_error_nested_under_a_pii_safe_lower_error_is_withheld_but_the_outer_message_survives()
    {
        // IdentityModel 모양 — PII 를 가린 자기 메시지 밑에 디코드된 헤더를 인용하는 JSON 예외를 단다(실측 a3).
        var nested = new ArgumentException("IDX14102: Unable to decode the header '[PII is hidden]'", ParseError($"t{Canary}"));
        var ex = new KeycloakTokenValidationException(nested.Message, nested);

        Assert.DoesNotContain(Canary, ex.ToString());
        Assert.Contains("System.ArgumentException", ex.ToString());
        Assert.Contains("IDX14102", ex.ToString());
        Assert.IsAssignableFrom<JsonException>(ex.InnerException!.InnerException);
    }

    [Fact]
    public void Lower_error_whose_message_repeats_the_quoting_inner_message_is_withheld()
    {
        var json = ParseError($"f{Canary}");
        var ex = new KeycloakAuthException("x", new InvalidOperationException($"wrapped: {json.Message}", json));

        Assert.DoesNotContain(Canary, ex.ToString());
    }

    [Fact]
    public void Invalid_http_response_error_is_replaced_by_a_copy_that_keeps_type_and_error_kind()
    {
        var raw = new HttpRequestException(HttpRequestError.InvalidResponse, "Error while copying content to a stream.",
            new HttpIOException(HttpRequestError.InvalidResponse, $"Received an invalid header line: '{Canary}'."));
        var ex = new KeycloakTransportException("introspection transport failure", raw);

        Assert.DoesNotContain(Canary, ex.ToString());
        var inner = Assert.IsType<HttpRequestException>(ex.InnerException);
        Assert.Equal(HttpRequestError.InvalidResponse, inner.HttpRequestError);
        Assert.Equal(HttpRequestError.InvalidResponse, Assert.IsType<HttpIOException>(inner.InnerException).HttpRequestError);
    }

    [Fact]
    public void Transport_error_that_quotes_nothing_is_kept_as_is()
    {
        var raw = new HttpRequestException(HttpRequestError.ConnectionError, "No connection could be made (127.0.0.1:1)");
        Assert.Same(raw, new KeycloakTransportException("x", raw).InnerException);
    }

    [Fact]
    public void Sdk_error_in_the_chain_is_kept_as_is_because_its_own_chain_was_already_scrubbed()
    {
        var validation = new KeycloakTokenValidationException("IDX14102", new ArgumentException("IDX14102", ParseError($"t{Canary}")));
        var ex = new KeycloakAuthException("id_token validation failed", validation);

        Assert.Same(validation, ex.InnerException);
        Assert.DoesNotContain(Canary, ex.ToString());
    }
}
