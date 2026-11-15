# Verifying a release
<!-- doc-budget: max-bytes=8275 -->

Every SDK in this repository is built and published by a GitHub Actions workflow from a release tag.
What you can check afterwards depends on the registry: four SDKs (Java, Kotlin, Python, Node.js)
carry signed provenance, Go has a checksum database, and the other four rest on what their registry
offers — a repository signature, a locked commit or a checksum — plus, for Rust and Ruby, a
byte-identical rebuild. This page gives the command for each and says what it does **not** prove.

Replace `<version>` with the version you use. `<commit>` is the commit of that release's tag —
release tags are lightweight, so this prints it directly:

```sh
git ls-remote https://github.com/xzawed/KeyCloakSDK refs/tags/<tag>
```

## At a glance

| SDK | Registry | Signed provenance | What you can check |
|---|---|---|---|
| Java · Kotlin | Maven Central | GitHub build provenance on every jar since 1.0.2 | PGP signature on every file · provenance on jars |
| Python | PyPI | PEP 740 attestations on wheel and sdist | publisher: this repository, `python-release.yml`, the tag |
| Node.js | npm | SLSA provenance | registry signature · provenance |
| Go | proxy.golang.org | — | checksum database: everyone gets the same bytes, equal to the tag |
| .NET | NuGet | — | NuGet.org repository signature (not an author signature) |
| PHP | Packagist | — | the locked commit equals the mirror tag, whose tree equals the monorepo tag |
| Rust | crates.io | — | registry checksum · byte-identical rebuild from the tag |
| Ruby | RubyGems | — | registry checksum · byte-identical rebuild from the tag |

## Java and Kotlin — Maven Central

**PGP.** Every file on Central has a detached `.asc` signature. The signing key is Ed25519,
fingerprint `95FC 7381 2A90 3BAA D9DD  45B8 4D4C 8A03 F0C7 4216`, expiring 2029-08-07. It is on
keyserver.ubuntu.com (not on keys.openpgp.org). Nobody else has certified it, so `gpg` warns that the
key is not certified — the fingerprint above is the anchor.

```sh
gpg --keyserver hkps://keyserver.ubuntu.com --recv-keys 95FC73812A903BAAD9DD45B84D4C8A03F0C74216
gpg --verify keycloak-sdk-core-<version>.jar.asc keycloak-sdk-core-<version>.jar
```

**Build provenance.** The release workflow attests every jar it uploads. With the GitHub CLI signed in:

```sh
gh attestation verify keycloak-sdk-core-<version>.jar --repo xzawed/KeyCloakSDK \
  --signer-workflow xzawed/KeyCloakSDK/.github/workflows/release.yml \
  --source-ref refs/tags/v<version> --source-digest <commit> \
  --deny-self-hosted-runners
```

For Kotlin use `.github/workflows/kotlin-release.yml` and `refs/tags/kotlin-v<version>`. Always pin
`--source-ref` and `--source-digest`: a re-release whose jars are byte-identical to the previous one
carries an attestation from each release, and `--repo` alone accepts either.

Without a GitHub login, fetch the attestation from the public API (60 unauthenticated requests an
hour) and hand it to the CLI, which then verifies offline:

```sh
sha=$(sha256sum keycloak-sdk-core-<version>.jar | cut -d' ' -f1)   # macOS: shasum -a 256
curl -s "https://api.github.com/repos/xzawed/KeyCloakSDK/attestations/sha256:$sha" \
  | jq -c '.attestations[].bundle' > bundles.jsonl
gh attestation verify keycloak-sdk-core-<version>.jar --repo xzawed/KeyCloakSDK --bundle bundles.jsonl \
  --signer-workflow xzawed/KeyCloakSDK/.github/workflows/release.yml \
  --source-ref refs/tags/v<version> --source-digest <commit> --deny-self-hosted-runners
```

Keep every bundle (`.attestations[]`, not the first): a byte-identical jar carries one attestation per
release, and the API does not promise their order — the pins pick the right one.

Not covered: the POMs (and Kotlin's `.module`) have PGP signatures but no provenance; versions before
1.0.2 have no provenance; Kotlin's artifacts come with `.md5`/`.sha1` checksum files but no `.sha256`.

## Python — PyPI

Both the wheel and the sdist carry PEP 740 attestations made by trusted publishing. From a virtual
environment:

```sh
pip install pypi-attestations
pypi-attestations verify pypi --repository https://github.com/xzawed/KeyCloakSDK \
  pypi:keycloak_sdk-<version>-py3-none-any.whl
pypi-attestations verify pypi --repository https://github.com/xzawed/KeyCloakSDK \
  pypi:keycloak_sdk-<version>.tar.gz
```

To pin the workflow and the tag as well, download the file, save its attestation next to it as
`<file>.publish.attestation`, and check the signing identity:

```sh
pip download keycloak-sdk==<version> --no-deps --only-binary :all:
curl -s https://pypi.org/integrity/keycloak-sdk/<version>/keycloak_sdk-<version>-py3-none-any.whl/provenance \
  | jq '.attestation_bundles[0].attestations[0]' > keycloak_sdk-<version>-py3-none-any.whl.publish.attestation
pypi-attestations verify attestation \
  --identity https://github.com/xzawed/KeyCloakSDK/.github/workflows/python-release.yml@refs/tags/py-v<version> \
  keycloak_sdk-<version>-py3-none-any.whl
```

Not covered: `verify pypi` checks the repository, not the workflow or tag (the identity check above
does); this is a publish attestation, not SLSA build provenance; `pip` does not check attestations.

## Node.js — npm

```sh
npm install @xzawed/keycloak-sdk@<version>
npm audit signatures
```

`npm audit signatures` checks the registry signature and the provenance attestation of every package
it installed, this SDK included. `npm view @xzawed/keycloak-sdk@<version> dist.attestations` shows the
SLSA provenance, which names `node-release.yml` and the `node-v<version>` tag.

Not covered: the audit reports on the whole dependency tree rather than this one package.

## Go

```sh
go get github.com/xzawed/KeyCloakSDK/go@v<version>
go mod verify
```

The `go` command checks the module against the checksum database (`sum.golang.org`) unless `GOSUMDB` is
turned off. To recompute the hash from the tag itself instead of the proxy, compare the `Sum` from

```sh
GOPROXY=direct GOSUMDB=off go mod download -json github.com/xzawed/KeyCloakSDK/go@v<version>
```

with the line `go get` wrote to `go.sum`. Not covered: there is no build provenance — the guarantee is
that everyone gets the same bytes and that they equal the tag.

## .NET — NuGet

```sh
dotnet nuget verify --all Xzawed.Keycloak.Sdk.<version>.nupkg
```

It reports `Signature type: Repository`: NuGet.org's signature that it received the package under
the owner `xzawed`. Not covered: there is no author signature and no build provenance; the `commit`
in the nuspec's `repository` element is self-reported.

## PHP — Packagist

Packagist serves the package from the mirror repository `xzawed/keycloak-sdk-php`, and Composer locks
a commit. The `reference` of `xzawed/keycloak-sdk` in `composer.lock` equals

```sh
git ls-remote https://github.com/xzawed/keycloak-sdk-php refs/tags/v<version>
```

and that commit's tree equals the `php/` directory of this repository's tag — in a clone,
`git rev-parse php-v<version>:php`. Not covered: nothing is signed, the mirror commit included, and
Packagist publishes no archive checksum (`dist.shasum` is empty).

## Rust — crates.io

Cargo checks every download against the index checksum. To tie the crate to the tag, rebuild it with
the cargo version shown in the release run's log:

```sh
git clone -c core.autocrlf=false https://github.com/xzawed/KeyCloakSDK
cd KeyCloakSDK && git checkout rust-v<version> && cd rust
cargo +<toolchain> package --no-verify --locked
sha256sum target/package/keycloak-sdk-<version>.crate
```

The hash equals the index `cksum`. Another cargo version writes different timestamps into the
archive, and a CRLF checkout changes the files. Not covered: no signature and no provenance.

## Ruby — RubyGems

```sh
gem fetch keycloak-sdk -v <version>
sha256sum keycloak-sdk-<version>.gem
```

The hash equals the `sha` that `https://rubygems.org/api/v1/versions/keycloak-sdk.json` lists for that
version. To tie it to the tag, `git archive ruby-v<version> ruby` and run `gem build keycloak-sdk.gemspec`
in the extracted `ruby/` with the RubyGems version recorded in the gem's metadata
(`rubygems_version`): the result is byte-identical. Not covered: the gem is unsigned
(`gem install --trust-policy HighSecurity` refuses it) and has no attestation.
