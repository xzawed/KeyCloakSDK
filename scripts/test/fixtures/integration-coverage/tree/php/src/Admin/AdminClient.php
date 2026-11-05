<?php

declare(strict_types=1);

namespace Fixture\Keycloak\Admin;

trait Masked
{
    public function masked(): string
    {
        return '***';
    }
}

final class AdminClient
{
    use Masked;

    // A promoted constructor with an empty body still has one executable line (the closing brace).
    public function __construct(private readonly string $url)
    {
    }

    /** @return array<string, string> */
    public function users(): array
    {
        return ['url' => $this->url];
    }

    /** @return list<string> */
    public function groups(): array
    {
        return [];
    }
}

// A file-level function — php-code-coverage reports it under a pseudo-class named after the file.
function adminHelper(int $n): int
{
    return $n + 1;
}
