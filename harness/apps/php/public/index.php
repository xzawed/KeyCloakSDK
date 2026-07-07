<?php

declare(strict_types=1);

require __DIR__ . '/../vendor/autoload.php';

use Fschmtt\Keycloak\Http\Criteria;
use Fschmtt\Keycloak\Representation\Client as ClientRepresentation;
use Fschmtt\Keycloak\Representation\Group as GroupRepresentation;
use Fschmtt\Keycloak\Representation\Realm as RealmRepresentation;
use Fschmtt\Keycloak\Representation\Role as RoleRepresentation;
use Fschmtt\Keycloak\Representation\User as UserRepresentation;
use GuzzleHttp\Client as GuzzleClient;
use GuzzleHttp\Exception\GuzzleException;
use Psr\Http\Message\ResponseInterface as Response;
use Psr\Http\Message\ServerRequestInterface as Request;
use Slim\Factory\AppFactory;
use Xzawed\Keycloak\Exception\KeycloakConflictError;
use Xzawed\Keycloak\Exception\KeycloakForbiddenError;
use Xzawed\Keycloak\Exception\KeycloakNotFoundError;
use Xzawed\Keycloak\KeycloakClient;
use Xzawed\Keycloak\KeycloakConfig;

// ---- helpers (라우트 클로저보다 먼저 정의 — PHP는 무조건부 최상위 함수선언을 파스타임에 호이스트하지만
// 가독성을 위해 사용 지점 이전에 배치한다) ----

function jsonResponse(Response $res, mixed $data, int $status = 200): Response
{
    $res->getBody()->write((string) json_encode($data));

    return $res->withHeader('Content-Type', 'application/json')->withStatus($status);
}

function errorResponse(Response $res, int $status, string $message): Response
{
    return jsonResponse($res, ['error' => $message], $status);
}

/** SDK 오류 → HTTP 상태(계약 오류 매핑 규약: NotFound→404·Conflict→409·Forbidden→403·기타→500). */
function mapAdminError(\Throwable $e): int
{
    return match (true) {
        $e instanceof KeycloakNotFoundError => 404,
        $e instanceof KeycloakConflictError => 409,
        $e instanceof KeycloakForbiddenError => 403,
        default => 500,
    };
}

/** @return array<string,mixed> */
function bodyArray(Request $req): array
{
    $parsed = $req->getParsedBody();

    return is_array($parsed) ? $parsed : [];
}

function generateUuidV4(): string
{
    $data = random_bytes(16);
    $data[6] = chr((ord($data[6]) & 0x0f) | 0x40);
    $data[8] = chr((ord($data[8]) & 0x3f) | 0x80);
    $hex = bin2hex($data);

    return sprintf(
        '%s-%s-%s-%s-%s',
        substr($hex, 0, 8),
        substr($hex, 8, 4),
        substr($hex, 12, 4),
        substr($hex, 16, 4),
        substr($hex, 20, 12),
    );
}

/**
 * refresh 토큰 파일 저장소 — PHP 내장 서버(`php -S`)는 요청마다 스크립트를 처음부터 재실행하므로
 * (Sinatra/Express류 상주 프로세스와 달리) 전역변수가 요청 간 보존되지 않는다. /refresh·/logout이
 * 직전 /token/password의 refresh_token을 쓰려면 파일 백업이 필요하다(단일 프로세스 데모 하네스 전용).
 */
function storeRefreshToken(string $file, ?string $token): void
{
    if ($token === null || $token === '') {
        return;
    }
    file_put_contents($file, $token, LOCK_EX);
}

function loadRefreshToken(string $file): ?string
{
    if (!is_file($file)) {
        return null;
    }
    $v = file_get_contents($file);

    return $v === false || $v === '' ? null : $v;
}

// ---- SDK 조립(앱 기동 시 1회. redirectUri는 config에서 고정 —
// PHP SDK의 createAuthorizationRequest()는 인자를 받지 않는다. 하네스는 오프라인 URL 조립만
// 검증하므로 고정값으로 충분하다) ----
$config = new KeycloakConfig(
    serverUrl: getenv('KC_SERVER_URL') ?: 'http://localhost:8080',
    realm: getenv('KC_REALM') ?: 'it-realm',
    clientId: getenv('KC_CLIENT_ID') ?: 'it-client',
    clientSecret: getenv('KC_CLIENT_SECRET') ?: null,
    redirectUri: 'http://x/cb',
);
$kc = KeycloakClient::create($config);

// ---- ROPC(Resource Owner Password Credentials)는 SDK 표면에 없다(SDK 표면 불변 원칙).
// 하네스 앱이 Keycloak 토큰 엔드포인트로 직접 POST한다(8개 앱 동일 패턴, CONTRACT.md 참고). ----
$ropcHttp = new GuzzleClient([
    'base_uri' => $config->serverUrl . '/',
    'connect_timeout' => $config->connectTimeout,
    'timeout' => $config->readTimeout,
    'http_errors' => false,
]);

$refreshFile = sys_get_temp_dir() . '/app-php-refresh-token';

$app = AppFactory::create();
$app->addBodyParsingMiddleware();

$app->get('/healthz', function (Request $req, Response $res): Response {
    return jsonResponse($res, ['status' => 'ok']);
});

$app->post('/token', function (Request $req, Response $res) use ($kc): Response {
    try {
        $t = $kc->auth()->clientCredentialsToken();

        return jsonResponse($res, ['tokenType' => $t->tokenType, 'expiresIn' => $t->expiresIn]);
    } catch (\Throwable $e) {
        return errorResponse($res, 500, $e->getMessage());
    }
});

$app->post('/token/password', function (Request $req, Response $res) use ($ropcHttp, $config, $refreshFile): Response {
    $body = bodyArray($req);
    try {
        $resp = $ropcHttp->post("realms/{$config->realm}/protocol/openid-connect/token", [
            'form_params' => [
                'grant_type' => 'password',
                'client_id' => $config->clientId,
                'client_secret' => $config->clientSecret ?? '',
                'username' => (string) ($body['username'] ?? ''),
                'password' => (string) ($body['password'] ?? ''),
            ],
        ]);
        $json = json_decode((string) $resp->getBody(), true);
        if ($resp->getStatusCode() >= 400 || !is_array($json)) {
            $detail = (is_array($json) && isset($json['error_description']))
                ? (string) $json['error_description']
                : sprintf('ROPC(password) grant failed: HTTP %d', $resp->getStatusCode());

            return errorResponse($res, 401, $detail);
        }
        storeRefreshToken($refreshFile, isset($json['refresh_token']) ? (string) $json['refresh_token'] : null);

        return jsonResponse($res, [
            'tokenType' => (string) ($json['token_type'] ?? 'Bearer'),
            'expiresIn' => (int) ($json['expires_in'] ?? 0),
            'hasRefresh' => isset($json['refresh_token']),
        ]);
    } catch (GuzzleException $e) {
        return errorResponse($res, 401, 'ROPC transport error: ' . $e->getMessage());
    } catch (\Throwable $e) {
        return errorResponse($res, 401, $e->getMessage());
    }
});

$app->post('/refresh', function (Request $req, Response $res) use ($kc, $refreshFile): Response {
    try {
        $refreshToken = loadRefreshToken($refreshFile);
        if ($refreshToken === null) {
            return errorResponse($res, 401, 'no refresh token on file (call /token/password first)');
        }
        $t = $kc->auth()->refresh($refreshToken);
        if ($t->refreshToken !== null) {
            storeRefreshToken($refreshFile, $t->refreshToken);
        }

        return jsonResponse($res, ['tokenType' => $t->tokenType, 'expiresIn' => $t->expiresIn]);
    } catch (\Throwable $e) {
        return errorResponse($res, 401, $e->getMessage());
    }
});

$app->post('/logout', function (Request $req, Response $res) use ($kc, $refreshFile): Response {
    try {
        $refreshToken = loadRefreshToken($refreshFile);
        if ($refreshToken !== null) {
            $kc->auth()->logout($refreshToken);
        }

        return $res->withStatus(204);
    } catch (\Throwable $e) {
        return errorResponse($res, 500, $e->getMessage());
    }
});

$app->get('/authz-url', function (Request $req, Response $res) use ($kc): Response {
    try {
        $r = $kc->auth()->createAuthorizationRequest();

        return jsonResponse($res, ['url' => $r->url, 'state' => $r->state]);
    } catch (\Throwable $e) {
        return errorResponse($res, 500, $e->getMessage());
    }
});

$app->post('/validate', function (Request $req, Response $res) use ($kc): Response {
    $body = bodyArray($req);
    try {
        $v = $kc->auth()->validate((string) ($body['token'] ?? ''));

        return jsonResponse($res, [
            'subject' => $v->subject,
            'audience' => $v->audience,
            'issuer' => $v->issuer,
            'expiresAt' => $v->expiresAt,
        ]);
    } catch (\Throwable $e) {
        return errorResponse($res, 401, $e->getMessage());
    }
});

$app->post('/introspect', function (Request $req, Response $res) use ($kc): Response {
    $body = bodyArray($req);
    try {
        $r = $kc->auth()->introspect((string) ($body['token'] ?? ''));

        return jsonResponse($res, ['active' => $r->active, 'username' => $r->username, 'clientId' => $r->clientId]);
    } catch (\Throwable $e) {
        return errorResponse($res, 500, $e->getMessage());
    }
});

// ---- admin: users ----
$app->post('/admin/users', function (Request $req, Response $res) use ($kc): Response {
    $body = bodyArray($req);
    $username = (string) ($body['username'] ?? '');
    try {
        $users = $kc->admin()->users();
        $users->create(new UserRepresentation(
            email: isset($body['email']) ? (string) $body['email'] : null,
            enabled: true,
            username: $username,
        ));
        $id = $users->findIdByUsername($username);

        return jsonResponse($res, ['id' => $id], 201);
    } catch (\Throwable $e) {
        return errorResponse($res, mapAdminError($e), $e->getMessage());
    }
});

$app->get('/admin/users/{id}', function (Request $req, Response $res, array $args) use ($kc): Response {
    try {
        $u = $kc->admin()->users()->get($args['id']);

        return jsonResponse($res, ['id' => $u->getId(), 'username' => $u->getUsername()]);
    } catch (\Throwable $e) {
        return errorResponse($res, mapAdminError($e), $e->getMessage());
    }
});

$app->get('/admin/users', function (Request $req, Response $res) use ($kc): Response {
    try {
        $username = $req->getQueryParams()['username'] ?? null;
        $criteria = ($username !== null && $username !== '')
            ? new Criteria(['username' => $username, 'exact' => true])
            : null;
        $out = [];
        foreach ($kc->admin()->users()->search($criteria) as $u) {
            $out[] = ['id' => $u->getId(), 'username' => $u->getUsername()];
        }

        return jsonResponse($res, $out);
    } catch (\Throwable $e) {
        return errorResponse($res, mapAdminError($e), $e->getMessage());
    }
});

$app->delete('/admin/users/{id}', function (Request $req, Response $res, array $args) use ($kc): Response {
    try {
        $kc->admin()->users()->delete($args['id']);

        return $res->withStatus(204);
    } catch (\Throwable $e) {
        return errorResponse($res, mapAdminError($e), $e->getMessage());
    }
});

// ---- admin: clients ----
$app->post('/admin/clients', function (Request $req, Response $res) use ($kc): Response {
    $body = bodyArray($req);
    try {
        // fschmtt import()는 POST 후 getId()로 재-GET한다(Location 헤더 미사용) — id를 미리 생성해 넘긴다.
        $imported = $kc->admin()->clients()->import(new ClientRepresentation(
            id: generateUuidV4(),
            clientId: (string) ($body['clientId'] ?? ''),
            enabled: true,
            publicClient: true,
            protocol: 'openid-connect',
        ));

        return jsonResponse($res, ['id' => $imported->getId()], 201);
    } catch (\Throwable $e) {
        return errorResponse($res, mapAdminError($e), $e->getMessage());
    }
});

$app->get('/admin/clients/{id}', function (Request $req, Response $res, array $args) use ($kc): Response {
    try {
        $c = $kc->admin()->clients()->get($args['id']);

        return jsonResponse($res, ['id' => $c->getId(), 'clientId' => $c->getClientId()]);
    } catch (\Throwable $e) {
        return errorResponse($res, mapAdminError($e), $e->getMessage());
    }
});

$app->delete('/admin/clients/{id}', function (Request $req, Response $res, array $args) use ($kc): Response {
    try {
        $kc->admin()->clients()->delete($args['id']);

        return $res->withStatus(204);
    } catch (\Throwable $e) {
        return errorResponse($res, mapAdminError($e), $e->getMessage());
    }
});

// ---- admin: roles (realm role — client role 아님·name 키) ----
$app->post('/admin/roles', function (Request $req, Response $res) use ($kc): Response {
    $body = bodyArray($req);
    $name = (string) ($body['name'] ?? '');
    try {
        $kc->admin()->roles()->create(new RoleRepresentation(name: $name));

        return jsonResponse($res, ['name' => $name], 201);
    } catch (\Throwable $e) {
        return errorResponse($res, mapAdminError($e), $e->getMessage());
    }
});

$app->get('/admin/roles/{name}', function (Request $req, Response $res, array $args) use ($kc): Response {
    try {
        $r = $kc->admin()->roles()->get($args['name']);

        return jsonResponse($res, ['name' => $r->getName()]);
    } catch (\Throwable $e) {
        return errorResponse($res, mapAdminError($e), $e->getMessage());
    }
});

$app->delete('/admin/roles/{name}', function (Request $req, Response $res, array $args) use ($kc): Response {
    try {
        $kc->admin()->roles()->delete($args['name']);

        return $res->withStatus(204);
    } catch (\Throwable $e) {
        return errorResponse($res, mapAdminError($e), $e->getMessage());
    }
});

// ---- admin: groups ----
$app->post('/admin/groups', function (Request $req, Response $res) use ($kc): Response {
    $body = bodyArray($req);
    $name = (string) ($body['name'] ?? '');
    try {
        $groups = $kc->admin()->groups();
        $groups->create(new GroupRepresentation(name: $name));
        // fschmtt create()는 void — id 조회를 위해 name으로 재조회(UsersResource::findIdByUsername과 동형;
        // GroupsResource는 전용 헬퍼가 없어 all()을 순회한다).
        $id = null;
        foreach ($groups->all() as $g) {
            if ($g->getName() === $name) {
                $id = $g->getId();
                break;
            }
        }

        return jsonResponse($res, ['id' => $id], 201);
    } catch (\Throwable $e) {
        return errorResponse($res, mapAdminError($e), $e->getMessage());
    }
});

$app->get('/admin/groups/{id}', function (Request $req, Response $res, array $args) use ($kc): Response {
    try {
        $g = $kc->admin()->groups()->get($args['id']);

        return jsonResponse($res, ['id' => $g->getId(), 'name' => $g->getName()]);
    } catch (\Throwable $e) {
        return errorResponse($res, mapAdminError($e), $e->getMessage());
    }
});

$app->delete('/admin/groups/{id}', function (Request $req, Response $res, array $args) use ($kc): Response {
    try {
        $kc->admin()->groups()->delete($args['id']);

        return $res->withStatus(204);
    } catch (\Throwable $e) {
        return errorResponse($res, mapAdminError($e), $e->getMessage());
    }
});

// ---- admin: realms (master 전용 — 하네스는 realm SA라 항상 403, CONTRACT.md 참고) ----
$app->post('/admin/realms', function (Request $req, Response $res) use ($kc): Response {
    $body = bodyArray($req);
    $realm = (string) ($body['realm'] ?? '');
    try {
        $kc->admin()->realms()->import(new RealmRepresentation(realm: $realm, enabled: true));

        return jsonResponse($res, ['realm' => $realm], 201);
    } catch (\Throwable $e) {
        return errorResponse($res, mapAdminError($e), $e->getMessage());
    }
});

$app->run();
