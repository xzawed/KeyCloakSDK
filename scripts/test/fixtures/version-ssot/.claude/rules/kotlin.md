# Kotlin rules (fixture)

이 파일은 `test-check-versions.sh` 전용 픽스처다. 실제 규칙 문서가 아니다 — 아래 두 문장만
`check-versions.mjs` 의 3차 정의 자리 검사가 읽는 모양을 재현한다(값은 같은 픽스처의
`kotlin/build.gradle.kts` · `gradle-wrapper.properties` 와 일치시켜 둔다).

⚠️ **Do not install Gradle separately.** The wrapper fetches the distribution the build needs (`9.5.0`) by itself.

- ⚠️ **Keep the Gradle wrapper inside KGP's fully supported band** (KGP 2.4.10 → 7.6.3–9.5.0).
