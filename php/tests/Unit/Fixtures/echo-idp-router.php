<?php

declare(strict_types=1);

/*
 * The echo IdP of `OAuthErrorCodeEchoTest` — a `php -S` router (the SDK builds its own Guzzle clients, so there is no
 * handler to inject; `bearer-idp-router.php` has the same reason).
 *
 * State is `state.json` in the `EI_STATE` directory: `{"fixed": <any JSON value>}` answers that value as `error`, and
 * `{"echo": "<form field>", "form": "whole|prefix|suffix|middle|extended|prefixed|wrapped|lowercased"}` answers what
 * THIS request sent in that field — the client secret from Basic (each part form-url-encoded) or from the form. Every
 * token POST answers `application/json` `{"error": …}` — at 400 unless `"status"` sets another, with `error_description`
 * when `"description"` is a string — and is logged to `requests.log` as `[path, sent form fields]`. fschmtt asks
 * `/admin/serverinfo` before its first resource call — that is where its grant happens.
 *
 * `{"bodies": {"token": "…", "introspect": "…"}, "status"?: <int>, "location"?: "…"}` answers those bodies as they are
 * instead — the token POST and the introspection at that status (200 when absent), with that `Location` header when set —
 * and the admin user `u1` (`{"id":"u1","username":"alice"}`); every request is logged then, the admin ones too (with no form
 * fields). Each log row ends in the request method. `/redirect-target` — where the 3xx cells point `Location` — is logged
 * and answers 400 `{"error":"redirect_target_reached"}` in either mode.
 */

$dir = getenv('EI_STATE');
if (!is_string($dir) || $dir === '') {
    http_response_code(500);

    return;
}
$uri = $_SERVER['REQUEST_URI'] ?? '/';
$path = parse_url(is_string($uri) ? $uri : '/', PHP_URL_PATH);
$path = is_string($path) ? $path : '/';

$state = json_decode((string) file_get_contents($dir . '/state.json'), true);
$state = is_array($state) ? $state : [];
$method = $_SERVER['REQUEST_METHOD'] ?? '?';
if ($path === '/redirect-target') {
    file_put_contents($dir . '/requests.log', json_encode([$path, [], $method], JSON_THROW_ON_ERROR) . "\n", FILE_APPEND | LOCK_EX);
    http_response_code(400);
    header('Content-Type: application/json');
    echo '{"error":"redirect_target_reached"}';

    return;
}
if (is_array($state['bodies'] ?? null)) {
    parse_str((string) file_get_contents('php://input'), $sent);
    file_put_contents($dir . '/requests.log', json_encode([$path, $sent, $method], JSON_THROW_ON_ERROR) . "\n", FILE_APPEND | LOCK_EX);
    $kind = match (true) {
        str_ends_with($path, '/protocol/openid-connect/token') => 'token',
        str_ends_with($path, '/protocol/openid-connect/token/introspect') => 'introspect',
        default => null,
    };
    $body = $kind === null ? null : $state['bodies'][$kind] ?? null;
    if (is_string($body)) {
        http_response_code(is_int($state['status'] ?? null) ? $state['status'] : 200);
        header('Content-Type: application/json');
        if (is_string($state['location'] ?? null)) {
            header('Location: ' . $state['location']);
        }
        echo $body;
    } elseif ($path === '/admin/serverinfo') {
        header('Content-Type: application/json');
        echo '{"systemInfo":{"version":"26.6.0"}}';
    } elseif ($path === '/admin/realms/r/users/u1') {
        header('Content-Type: application/json');
        echo '{"id":"u1","username":"alice"}';
    } else {
        http_response_code(404);
    }

    return;
}

if (!str_ends_with($path, '/protocol/openid-connect/token')) {
    if ($path === '/admin/serverinfo') {
        header('Content-Type: application/json');
        echo '{"systemInfo":{"version":"26.6.0"}}';

        return;
    }
    http_response_code(404);

    return;
}

parse_str((string) file_get_contents('php://input'), $sent);
$auth = $_SERVER['HTTP_AUTHORIZATION'] ?? '';
if (is_string($auth) && str_starts_with($auth, 'Basic ')) {
    $pair = explode(':', (string) base64_decode(substr($auth, 6), true), 2);
    $sent['client_secret'] = urldecode($pair[1] ?? '');
}
file_put_contents($dir . '/requests.log', json_encode([$path, $sent, $method], JSON_THROW_ON_ERROR) . "\n", FILE_APPEND | LOCK_EX);

if (array_key_exists('fixed', $state)) {
    $error = $state['fixed'];
} else {
    $value = $sent[is_string($state['echo'] ?? null) ? $state['echo'] : ''] ?? '';
    $value = is_string($value) ? $value : '';
    $error = match ($state['form'] ?? 'whole') {
        'prefix' => substr($value, 0, 11),
        'suffix' => substr($value, -11),
        'middle' => substr($value, 2, 9),
        'extended' => $value . '_x',
        'prefixed' => 'x_' . $value,
        'wrapped' => 'x_' . $value . '_x',
        'lowercased' => strtolower($value),
        default => $value,
    };
}
$answer = ['error' => $error];
if (is_string($state['description'] ?? null)) {
    $answer['error_description'] = $state['description'];
}
http_response_code(is_int($state['status'] ?? null) ? $state['status'] : 400);
header('Content-Type: application/json');
echo json_encode($answer, JSON_THROW_ON_ERROR);
