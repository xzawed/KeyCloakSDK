<?php

declare(strict_types=1);

namespace Fixture\Keycloak;

// Not a boundary file — the unit gate measures it, so the integration report must not list it.
final class Config
{
    public function __construct(public readonly string $realm)
    {
    }
}
