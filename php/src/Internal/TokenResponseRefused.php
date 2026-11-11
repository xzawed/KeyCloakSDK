<?php

declare(strict_types=1);

namespace Xzawed\Keycloak\Internal;

/**
 * A token response that arrived in full and was refused for a reason the SDK names — a value league's `AccessToken` will not
 * take, or a body whose content coding could not be decoded. Like `TokenResponseUnusable` it carries the verdict from inside
 * league's call stack (`PkceKeycloakProvider`) to `AuthClient::getAccessToken`, which turns it into a **new**
 * `KeycloakAuthError` with this message and no cause. The message is the SDK's own words, never the response's. @internal
 */
final class TokenResponseRefused extends \UnexpectedValueException
{
    public function __construct(string $why)
    {
        parent::__construct('token response ' . $why);
    }
}
