<?php

declare(strict_types=1);

namespace Fixture\Unit;

/** Outside the boundary — the unit coverage gate measures it. */
final class Config
{
    public function __construct(public readonly string $realm)
    {
    }

    public function valid(): bool
    {
        return $this->realm !== '';
    }
}
