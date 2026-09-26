import { KeycloakConfigError } from './errors.js'
import { mask } from './masking.js'

const INSPECT = Symbol.for('nodejs.util.inspect.custom')

/** 불변 설정. `defineConfig`로만 생성한다. */
export interface KeycloakConfig {
  readonly serverUrl: string
  readonly realm: string
  readonly clientId: string
  readonly clientSecret?: string
  readonly scopes: readonly string[]
  /**
   * ⚠️ Node의 fetch/undici 스택(openid-client·admin-client)은 요청당 단일 총 타임아웃
   * ({@link readTimeoutMs})만 표현할 수 있어, 별도의 "연결(connect) 타임아웃"을 강제하지 못한다
   * (커스텀 undici dispatcher 주입이 필요하나 하위 라이브러리가 이를 노출하지 않음). 이 필드는
   * 언어 간 config 대칭을 위해 유지되나 fetch 경로에는 별도로 배선되지 않는다(문서화된 한계 —
   * sync/blocking-HTTP 언어인 Java·Go·PHP 등과 달리). 실효 타임아웃은 readTimeoutMs다.
   */
  readonly connectTimeoutMs: number
  readonly readTimeoutMs: number
  readonly clockSkewSeconds: number
  /** JWT 서명 검증 시 허용할 알고리즘 핀(기본 ['RS256']). ES256/PS256 realm을 위해 설정 가능. */
  readonly signatureAlgorithms: readonly string[]
  /**
   * 미해결 kid(키 회전)로 인한 JWKS 재조회의 최소 간격(초, 기본 30) — DoS 증폭 상한. 위조 kid를
   * 연속 주입해도 이 간격보다 자주 IdP를 때리지 못한다(jose `cooldownDuration`에 배선). 0이면 매
   * 미해결 kid마다 재조회를 허용한다(비권장).
   */
  readonly jwksMinRefetchSeconds: number
  /**
   * `validate()`가 토큰 `aud`에서 찾을 값. 미지정이면 {@link clientId}를 기대한다(기존 동작).
   * 기본 realm은 client-credentials 토큰 `aud`에 client_id를 넣지 않으므로(audience 매퍼를
   * 추가해야 들어간다), 리소스 서버처럼 API 이름이 aud인 경우 여기에 그 값을 설정한다.
   */
  readonly expectedAudience?: string
}

/** `defineConfig` 입력(선택값은 기본값으로 채워진다). */
export interface KeycloakConfigInput {
  serverUrl: string
  realm: string
  clientId: string
  clientSecret?: string
  scopes?: string[]
  connectTimeoutMs?: number
  readTimeoutMs?: number
  clockSkewSeconds?: number
  signatureAlgorithms?: string[]
  jwksMinRefetchSeconds?: number
  expectedAudience?: string
}

/**
 * 입력을 검증하고 기본값을 채워 불변 `KeycloakConfig`를 만든다. 필수값 누락 시 `KeycloakConfigError`.
 *
 * 보안: 반환 객체는 로깅/직렬화(`console.log`·`util.inspect`·`JSON.stringify`)에서 `clientSecret`을
 * 마스킹한다(Python `KeycloakConfig.__repr__`와 동형) — 실수로 시크릿을 로그에 흘리지 않게 한다.
 * 속성 접근(`config.clientSecret`)과 스프레드는 정상 동작하며, 마스킹 훅은 비열거(non-enumerable)다.
 */
// 후행 슬래시 제거. 정규식(`replace(/\/+$/, '')`)이 아니라 선형 스캔인 이유:
//  (1) `/+$`는 매칭 실패 위치마다 다시 시도하며 슬래시를 되짚어 입력 길이에 대해 초선형이 될 수
//      있다(SonarCloud typescript:S8786). `serverUrl`은 설정값이라 실위험은 낮지만 고칠 이유도 낮다.
//  (2) ⚠️ **동형성** — 같은 일을 하는 아홉 언어 중 go(`TrimRight`)·dotnet(`TrimEnd`)·php(`rtrim`)
//      ·rust(`trim_end_matches`)·kotlin(`trimEnd`) 다섯이 이미 선형 문자열 트림을 쓴다. 정규식을
//      쓰던 것은 java·node·ruby 셋뿐이었고, 그 셋을 나머지에 맞춘다.
// 동작은 정규식과 **동일**하다(후행 슬래시를 전부 제거, 내부 슬래시는 보존).
function stripTrailingSlashes(s: string): string {
  let end = s.length
  while (end > 0 && s[end - 1] === '/') end--
  return s.slice(0, end)
}

// ⚠️ 형식이 틀린 serverUrl 은 여기서 거부한다 — 상대 URL·공백이 든 URL 은 클라이언트 조립 중 `new URL()` 의
// TypeError 로 공개 API 에 샜다(실측 2026-09-25). JVM 짝·ruby·dotnet 과 같은 분류(KeycloakConfigError)다.
// 범위 밖 포트는 URL 파서가 거절하고, 밑줄 호스트(docker compose 서비스 이름)는 받는다. 메시지에는 사유만
// 싣는다 — TypeError 의 message 는 입력을 되울린다.
function requireAbsoluteHttpUrl(value: string): void {
  let url: URL
  try {
    url = new URL(value)
  } catch {
    throw new KeycloakConfigError('serverUrl must be an absolute http(s) URL: unparseable')
  }
  if (url.protocol !== 'http:' && url.protocol !== 'https:') {
    throw new KeycloakConfigError(
      'serverUrl must be an absolute http(s) URL: scheme must be http or https',
    )
  }
}

export function defineConfig(input: KeycloakConfigInput): KeycloakConfig {
  for (const key of ['serverUrl', 'realm', 'clientId'] as const) {
    if (!input[key] || input[key].trim().length === 0) {
      throw new KeycloakConfigError(`Missing required config: ${key}`)
    }
  }
  requireAbsoluteHttpUrl(stripTrailingSlashes(input.serverUrl))
  if (input.signatureAlgorithms && input.signatureAlgorithms.length === 0) {
    // 빈 집합은 알고리즘 핀을 무력화한다(핀 없이는 alg 혼동 공격에 노출).
    throw new KeycloakConfigError('signatureAlgorithms must be non-empty')
  }
  // ⚠️ 0 이하·NaN·Infinity·2^31 이상의 타임아웃은 여기서 거부한다 — 조용히 받으면 쓸 수 없는 클라이언트가
  // 된다(실측 2026-09-26: -1 은 logout 이 항상 실패(AbortSignal.timeout 범위 오류), 0 은 즉시 abort,
  // 2^31 이상은 Node 타이머가 TimeoutOverflowWarning 과 함께 1ms 로 바꿔 즉시 abort, cc·introspect 는 1 초로
  // 클램프). ruby·dotnet·JVM 과 같이 생성 시 KeycloakConfigError 다. connectTimeoutMs 는 fetch 경로에
  // 배선되지 않지만(위 인터페이스 주석) 설정 대칭을 위해 같이 본다.
  for (const key of ['connectTimeoutMs', 'readTimeoutMs'] as const) {
    const v = input[key]
    if (v !== undefined && !(Number.isFinite(v) && v > 0 && v <= 2_147_483_647)) {
      throw new KeycloakConfigError(`${key} must be > 0 and <= 2147483647`)
    }
  }
  // 음수·NaN·Infinity 는 의미가 없다 — 자매(go·ruby·dotnet·JVM)처럼 생성 시 거부한다. NaN 은 `< 0` 비교를
  // 통과하므로 유한성을 따로 본다.
  for (const key of ['clockSkewSeconds', 'jwksMinRefetchSeconds'] as const) {
    const v = input[key]
    if (v !== undefined && !(Number.isFinite(v) && v >= 0)) {
      throw new KeycloakConfigError(`${key} must be >= 0`)
    }
  }
  const config: KeycloakConfig = {
    serverUrl: stripTrailingSlashes(input.serverUrl),
    realm: input.realm,
    clientId: input.clientId,
    clientSecret: input.clientSecret,
    scopes: input.scopes ?? [],
    connectTimeoutMs: input.connectTimeoutMs ?? 10_000,
    readTimeoutMs: input.readTimeoutMs ?? 30_000,
    clockSkewSeconds: input.clockSkewSeconds ?? 30,
    signatureAlgorithms: input.signatureAlgorithms ?? ['RS256'],
    jwksMinRefetchSeconds: input.jwksMinRefetchSeconds ?? 30,
    expectedAudience: input.expectedAudience,
  }
  const masked = (): Record<string, unknown> => ({
    ...config,
    clientSecret: config.clientSecret === undefined ? undefined : mask(config.clientSecret),
  })
  Object.defineProperties(config, {
    toJSON: { value: masked, enumerable: false },
    [INSPECT]: { value: masked, enumerable: false },
  })
  return config
}
