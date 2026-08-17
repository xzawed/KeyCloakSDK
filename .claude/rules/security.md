---
paths:
  - "java/**"
  - "kotlin/**"
  - "python/**"
  - "node/**"
  - "go/**"
  - "dotnet/**"
  - "php/**"
  - "rust/**"
  - "ruby/**"
---

# 교차언어 보안 불변식

루트 `CLAUDE.md`의 보안 게차 스텁이 가리키는 상세다. **언어 하나에만 적용되는 보안 사실은 여기 두지 않는다** — 그건 `.claude/rules/<lang>.md`다. 여기 있는 것은 아홉 언어가 **함께 움직여야** 하는 것뿐이라, 한 언어만 고치면 그 자체가 결함이다.

`paths:`가 9개 언어 디렉터리 전부인 이유가 그것이다 — 어느 언어를 건드리든 이 파일이 함께 온다.

## 기본값 정렬 — JWKS 재조회 최소 간격 · `clockSkew` (둘 다 30초)

⚠️ **JWKS 재조회 최소 간격 기본값은 아홉 언어 전부 30초다(2026-07-31 정렬).** 그 전엔 10·30·60초 세 갈래였는데, PR #71이 config화하며 각 언어 하드코딩 값을 둔 **산물**이었다(같은 위조 kid 폭주에 Ruby가 Python보다 IdP를 6배 자주 때렸다). 30초는 Nimbus `DEFAULT_RATE_LIMIT_MIN_INTERVAL`과 같아 **외부 근거가 있는 유일 후보**다.

⚠️ **60초를 버려서 잃은 것**: 30초는 키 로테이션 회복 창을 절반으로 줄이지만, rate-limit 상한은 60초에 1회 → 30초에 1회로 **DoS 증폭이 2배 느슨해진다**. 보안 문맥의 "창이 좁아짐"을 "더 조여졌다"로 읽지 말 것.

**`clockSkew`(JWT `exp`/`nbf` 허용 오차)도 같은 불변식이고 역시 30초다** — 한 언어만 커지면 거기서만 만료 토큰이 오래 산다.

둘 중 하나를 바꿀 땐 **아홉 함께**. 가드는 `scripts/test/test-security-defaults.sh`가 코드·문서·2차 정의 자리를 본다.

⚠️ 이 값에는 **언어별 상한**이 따로 있다 — Java·Kotlin은 Nimbus 캐시 TTL 미만이어야 한다(`.claude/rules/java.md`·`kotlin.md`. 여기 옮겨 적지 않는다 — 2차 정의 자리를 만들지 않는다).

## 시크릿 메모리 위생 — 경계가 있다 (과대광고 금지)

⚠️ **end-to-end 소거 보장이 아니다.** Java `KeycloakConfig`는 `char[]`(방어복사)로 보관하나 하위 라이브러리(Nimbus `Secret`·admin-client, Python `str`)가 `String`을 요구해 **사용 시점에 소거불가 `String`으로 복사된다**. `char[]`는 심층방어일 뿐이다.

PHP·Ruby는 언어 차원에서 아예 불가능하다(각각 `.claude/rules/php.md`·`.claude/rules/ruby.md`).

그래서 **소비자 문서에 "시크릿이 메모리에서 지워진다"라고 쓰지 않는다.** 이 부류의 과대광고는 소비자가 다른 완화(짧은 TTL·프로세스 격리)를 생략하게 만든다.
