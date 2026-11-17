<?php

declare(strict_types=1);

namespace Xzawed\Keycloak\Internal;

use Fschmtt\Keycloak\Representation\Representation;
use Fschmtt\Keycloak\Serializer\Serializer;
use Xzawed\Keycloak\Exception\KeycloakTransportError;
use Xzawed\Keycloak\Exception\SanitizedCause;

/**
 * An admin write whose representation cannot be written as JSON (invalid UTF-8, NAN, INF) fails **before any request**
 * with the same `KeycloakTransportError` and message as node and python — registry php-admin-unencodable-body-class.
 * fschmtt serialises the body only when it sends the command, after the token grant and the serverinfo lookup, so the
 * failure used to arrive late and fell through to `ErrorTranslation`'s bottom net (`admin request failed unexpectedly`,
 * no status).
 *
 * The body is written with fschmtt's own serializer — the encoder that will write it for real (its Symfony `JsonEncoder`
 * throws on what `json_encode` refuses). ⚠️ fschmtt's serializer drops fields the server version does not know, and that
 * version needs the serverinfo request, so this check runs without it: it writes **every** field, a superset of what is
 * sent. A value that cannot be encoded is refused even in a field that version filtering would have dropped. ⚠️ The
 * serializer is `@internal` to fschmtt — what makes using it safe is the exact pin in `composer.json` (as for
 * `RenamableRoles`); `AdminUnencodableBodyTest` drives the real stack, so it is the drift guard when that pin moves.
 *
 * Whatever the serializer throws is refused the same way (the request could not have been sent either). The cause is the
 * sanitised copy — the original's trace arguments hold the representation, which can carry secrets.
 *
 * @internal
 */
final class EncodableBody
{
    public const MESSAGE = 'admin request failed: the request body could not be encoded as JSON';

    private static ?Serializer $serializer = null;

    public static function check(#[\SensitiveParameter] Representation $representation): void
    {
        try {
            (self::$serializer ??= new Serializer())->serialize($representation);
        } catch (\Throwable $e) {
            throw new KeycloakTransportError(self::MESSAGE, previous: SanitizedCause::of($e));
        }
    }
}
