<?php

declare(strict_types=1);

namespace Xzawed\Keycloak\Internal;

use Stevenmaguire\OAuth2\Client\Provider\Keycloak;

final class PkceKeycloakProvider extends Keycloak
{
    protected function getPkceMethod(): string
    {
        return self::PKCE_METHOD_S256;
    }
}
