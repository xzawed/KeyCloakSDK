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
}
