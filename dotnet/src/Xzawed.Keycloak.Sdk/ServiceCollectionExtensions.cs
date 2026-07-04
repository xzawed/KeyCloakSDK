using Microsoft.Extensions.DependencyInjection;

namespace Xzawed.Keycloak;

/// <summary>DI integration. Registers a singleton KeycloakClient built from the config.</summary>
public static class ServiceCollectionExtensions
{
    public static IServiceCollection AddKeycloak(this IServiceCollection services, KeycloakConfig config)
    {
        var normalized = config.Normalized();
        services.AddSingleton(normalized);
        services.AddSingleton(_ => KeycloakClient.Create(normalized));
        return services;
    }
}
