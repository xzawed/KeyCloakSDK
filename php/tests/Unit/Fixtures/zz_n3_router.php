<?php

declare(strict_types=1);

/*
 * measurement only — not for merge (task n3). The router both origins (A and B) of `zz_n3_redirect_measureTest` run under
 * `php -S`. `N3_ORIGIN` names the origin, `N3_DIR` holds `state.json` (the current cell, written by the test) and
 * `requests.log` (one JSON row per request this origin received: origin · method · path · Authorization · Content-Type ·
 * Referer · body).
 *
 * state.json: {"cell": {"origin_path", "status", "location", "target"}|null, "bounce": bool, "jwks": "<JSON text>",
 *              "a": "<A base URL>", "b": "<B base URL>"}
 * - A answers `cell.origin_path` with `cell.status` + `Location: cell.location`;
 * - the target origin answers every `/moved/...` path with a usable success body (token · introspection · logout 204 · JWKS ·
 *   admin: POST 201 + Location, PUT 204, GET `[]`);
 * - admin cells (`cell.admin`): A answers fschmtt's grant with a dummy JWT and `/admin/serverinfo` with a version;
 * - detect probes: `/start` on A redirects like a cell, `/moved/start` answers 200; with `bounce`, A `/token` answers 307 →
 *   B `/hop` the first time and 200 after, and B `/hop` answers 307 → A `/token`.
 */

$origin = (string) getenv('N3_ORIGIN');
$dir = (string) getenv('N3_DIR');
$uri = $_SERVER['REQUEST_URI'] ?? '/';
$path = parse_url(is_string($uri) ? $uri : '/', PHP_URL_PATH);
$path = is_string($path) ? $path : '/';
$method = $_SERVER['REQUEST_METHOD'] ?? '?';
$body = (string) file_get_contents('php://input');
file_put_contents($dir . '/requests.log', json_encode([
    'origin' => $origin,
    'method' => $method,
    'path' => $path,
    'authorization' => $_SERVER['HTTP_AUTHORIZATION'] ?? null,
    'content_type' => $_SERVER['CONTENT_TYPE'] ?? ($_SERVER['HTTP_CONTENT_TYPE'] ?? null),
    'referer' => $_SERVER['HTTP_REFERER'] ?? null,
    'body' => $body,
], JSON_THROW_ON_ERROR | JSON_UNESCAPED_SLASHES) . "\n", FILE_APPEND | LOCK_EX);

$state = json_decode((string) file_get_contents($dir . '/state.json'), true);
$state = is_array($state) ? $state : [];

$json = static function (int $status, string $text): void {
    http_response_code($status);
    header('Content-Type: application/json');
    echo $text;
};
$redirect = static function (int $status, string $location): void {
    http_response_code($status);   // first — header('Location') keeps a 3xx already set
    header('Location: ' . $location);
};

if (($state['bounce'] ?? false) === true) {
    if ($origin === 'A' && $path === '/token') {
        $counter = $dir . '/bounce.count';
        $hits = (int) @file_get_contents($counter) + 1;
        file_put_contents($counter, (string) $hits);
        $hits === 1 ? $redirect(307, $state['b'] . '/hop') : $json(200, '{"access_token":"AT","token_type":"Bearer"}');

        return;
    }
    if ($origin === 'B' && $path === '/hop') {
        $redirect(307, $state['a'] . '/token');

        return;
    }
}
$cell = is_array($state['cell'] ?? null) ? $state['cell'] : null;
if ($cell !== null && $origin === 'A' && $path === $cell['origin_path']) {
    $redirect((int) $cell['status'], (string) $cell['location']);

    return;
}
if ($cell !== null && $origin === $cell['target'] && str_starts_with($path, '/moved/')) {
    if (str_contains($path, '/admin/')) {
        // A real collection answers a POST with 201 + Location, a PUT with 204, a GET with a list.
        if ($method === 'POST') {
            http_response_code(201);   // first — header('Location') keeps a 201 already set
            header('Location: ' . ($origin === 'A' ? $state['a'] : $state['b']) . $path . '/target-id');
        } elseif ($method === 'PUT') {
            http_response_code(204);
        } else {
            $json(200, '[]');
        }

        return;
    }
    if (str_ends_with($path, '/certs')) {
        $json(200, (string) $state['jwks']);
    } elseif (str_ends_with($path, '/token/introspect')) {
        $json(200, '{"active":true,"username":"target-user","client_id":"target-client"}');
    } elseif (str_ends_with($path, '/logout')) {
        http_response_code(204);
    } elseif ($path === '/moved/start') {
        $json(200, '{}');
    } else {
        $json(200, '{"access_token":"TARGET-AT","token_type":"Bearer","expires_in":300,"refresh_token":"TARGET-RT"}');
    }

    return;
}
// The admin cells: fschmtt's grant (the consumer-built client's and the SDK's own) and its version probe answer normally on A
// — fschmtt reads the access token as a JWT (its exp), so the token is an unsigned-looking dummy one.
if ($cell !== null && ($cell['admin'] ?? false) === true && $origin === 'A' && str_ends_with($path, '/protocol/openid-connect/token')) {
    $b64 = static fn (string $s): string => rtrim(strtr(base64_encode($s), '+/', '-_'), '=');
    $jwt = $b64('{"alg":"RS256","typ":"JWT"}') . '.' . $b64((string) json_encode(['exp' => time() + 300, 'iat' => time(), 'sub' => 'svc']))
        . '.' . str_repeat('A', 43);
    $json(200, (string) json_encode(['access_token' => $jwt, 'token_type' => 'Bearer', 'expires_in' => 300]));

    return;
}
if ($origin === 'A' && $path === '/admin/serverinfo') {
    $json(200, '{"systemInfo":{"version":"26.6.0"}}');

    return;
}
$json(404, '{}');
