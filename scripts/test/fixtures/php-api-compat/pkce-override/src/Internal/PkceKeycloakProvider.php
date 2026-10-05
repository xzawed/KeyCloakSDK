<?php

declare(strict_types=1);

namespace Xzawed\Keycloak\Internal;

use Psr\Http\Message\RequestInterface;
use Psr\Http\Message\ResponseInterface;
use Stevenmaguire\OAuth2\Client\Provider\Keycloak;

final class PkceKeycloakProvider extends Keycloak
{
    protected function getPkceMethod(): string
    {
        return self::PKCE_METHOD_S256;
    }

    public function getResponse(RequestInterface $request): ResponseInterface
    {
        return parent::getResponse($request);
    }

    /**
     * @return string|array<string, mixed>
     */
    protected function parseResponse(ResponseInterface $response): string|array
    {
        return parent::parseResponse($response);
    }
}
