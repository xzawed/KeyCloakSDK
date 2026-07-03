# 배포 가이드 (DEPLOY)

두 SDK 모두 **태그 드리븐 릴리스 CI**가 준비돼 있다. 실제 배포는 **사람이 태그를 push**해야만 트리거되는 승인 게이트(human-gated)이며, 아래 사전 준비(계정·키·토큰)는 리포지토리 소유자만 수행할 수 있다.

- Java → Maven Central (Central Portal), 태그 `v*`, 워크플로 `.github/workflows/release.yml`
- Python → PyPI (Trusted Publisher/OIDC), 태그 `py-v*`, 워크플로 `.github/workflows/python-release.yml`

> ⚠️ 배포는 되돌릴 수 없다(같은 좌표/버전 재배포 불가). dry-run으로 산출물을 먼저 검증하라(각 절 마지막).

---

## A. Java → Maven Central

### A-1. 네임스페이스 검증 (1회)
1. https://central.sonatype.com 에 **GitHub 계정(`xzawed`)으로 로그인** → `io.github.xzawed` 네임스페이스가 자동 검증/프로비저닝된다(안 되면 View Namespaces에서 `io.github.xzawed` 추가 → 표시된 키 이름의 **공개 임시 리포지토리**를 GitHub에 생성해 소유 확인).

### A-2. Central Portal 토큰 발급 (1회)
2. Central Portal → Account → **Generate User Token** → username/password 확보.

### A-3. GPG 서명키 생성·배포 (1회)
```bash
gpg --gen-key                          # 이름/이메일(xzawed31@gmail.com)/패스프레이즈 입력
gpg --list-secret-keys --keyid-format=long   # KEYID 확인
gpg --keyserver keyserver.ubuntu.com --send-keys <KEYID>   # 공개키 배포(필수)
gpg --armor --export-secret-keys <KEYID> > private.asc     # 개인키 armored 내보내기
```

### A-4. GitHub Secrets 등록 (Settings → Secrets and variables → Actions)
| Secret | 값 |
|---|---|
| `MAVEN_GPG_PRIVATE_KEY` | `private.asc` 전체 내용(armored) |
| `MAVEN_GPG_PASSPHRASE` | GPG 패스프레이즈 |
| `CENTRAL_TOKEN_USER` | A-2의 토큰 username |
| `CENTRAL_TOKEN_PW` | A-2의 토큰 password |

### A-5. 배포 트리거
```bash
git tag v0.1.0 && git push origin v0.1.0     # release.yml이 태그값으로 버전 set 후 -Prelease deploy
```
> ℹ️ 태그 `vX.Y.Z`가 **릴리스 버전을 결정**한다 — 워크플로가 POM의 `-SNAPSHOT`을 태그값(`X.Y.Z`)으로 덮어써 배포하므로 main POM은 계속 `-SNAPSHOT`이다(Maven Central은 SNAPSHOT 좌표를 거부하므로 이 자동 치환이 필수). 태그를 원하는 릴리스 버전과 일치시킬 것.

Central Portal의 Deployments에서 검증 후 **Publish**(또는 autoPublish 설정 시 자동).

### A-6. dry-run (배포 없이 산출물 검증)
```bash
JAVA_HOME='/c/Program Files/Eclipse Adoptium/jdk-21.0.8.9-hotspot' PATH="/c/Users/dirtc/tools/apache-maven-3.9.9/bin:$PATH" \
  mvn -f java/pom.xml -Prelease -DskipTests -DskipITs=true -Dgpg.skip=true package
# → core/auth/admin/keycloak-sdk 각 target/에 *-sources.jar / *-javadoc.jar 생성 확인
```

---

## B. Python → PyPI

### B-1. Trusted Publisher 설정 (1회, 시크릿 불필요)
1. https://pypi.org 로그인 → [Publishing 설정](https://pypi.org/manage/account/publishing/)에서 **Pending Publisher로 반드시 미리 등록**한다. `keycloak-sdk`는 아직 PyPI에 없어 프로젝트별 등록 화면이 없으므로, 계정 레벨의 **"Add a pending publisher"** 로 등록해야 한다(첫 배포 성공 시 자동으로 일반 Trusted Publisher로 전환).
2. **Trusted Publisher 추가** (Publishing → GitHub):
   - Owner: `xzawed` · Repository: `KeyCloakSDK` · Workflow: `python-release.yml` · Environment: (비움)
   - OIDC로 인증하므로 저장 토큰/시크릿 불필요.

### B-2. 배포 트리거
```bash
git tag py-v0.1.0 && git push origin py-v0.1.0   # python-release.yml이 build + publish 실행
```

### B-3. dry-run (배포 없이 빌드 검증)
```bash
cd python && /d/Source/KeyCloakSDK/python/.venv/Scripts/python.exe -m build
# → dist/keycloak_sdk-0.1.0-py3-none-any.whl + .tar.gz 생성 확인
```

---

## 공통 주의
- **버전 올릴 때**: Java는 `java/pom.xml`(및 모듈) `<version>`, Python은 `python/pyproject.toml` `[project].version`을 함께 올리고, 태그(`v*`/`py-v*`)를 그에 맞춘다.
- 배포 후 좌표: Java `io.github.xzawed:keycloak-sdk:<v>` (+ BOM), Python `pip install keycloak-sdk`.
- SemVer는 SDK 자체 API 기준이며 Keycloak/의존 라이브러리 버전과 분리한다(호환은 README 매트릭스로 안내).
