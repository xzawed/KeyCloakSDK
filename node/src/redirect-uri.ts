import { KeycloakConfigError } from './errors.js'

/**
 * The redirect URI `exchangeCode` was given. One that does not parse as a URL is a `KeycloakConfigError`
 * (`invalid redirect_uri: <reason>`) before any request, discovery included — the same class as Rust's `redirect_url`
 * and Kotlin's `redirectUri`. It used to escape the SDK's error hierarchy as `new URL`'s `TypeError` (§4).
 *
 * It lives outside `auth.ts` on purpose: `auth.ts` is a network boundary excluded from unit coverage, and the
 * integration run never takes this failure branch, so there it hid from both gates.
 */
export function redirectUrl(value: string): URL {
  try {
    return new URL(value)
  } catch (e) {
    throw new KeycloakConfigError(`invalid redirect_uri: ${(e as Error).message}`, { cause: e })
  }
}
