# sign-pypi-package-action

[![CI](https://github.com/durandtibo/sign-pypi-package-action/actions/workflows/ci.yaml/badge.svg)](https://github.com/durandtibo/sign-pypi-package-action/actions/workflows/ci.yaml)
[![License](https://img.shields.io/badge/license-BSD--3--Clause-blue)](LICENSE)
[![Latest release](https://img.shields.io/github/v/tag/durandtibo/sign-pypi-package-action?label=release)](https://github.com/durandtibo/sign-pypi-package-action/tags)

A composite GitHub Action that signs Python package distributions with Sigstore and attaches them,
along with their signatures, to a GitHub release.

Point it at a job that already produced a `dist` artifact (wheel + sdist + `SHA256SUMS`), and it verifies
the checksums, signs every distribution with Sigstore's keyless OIDC signing, uploads the signature
bundles as a workflow artifact, and attaches everything to the release for the current tag.

## Why use it

Attaching unsigned or tampered build artifacts to a release makes it hard for consumers to verify what
they're installing actually came from your build. This action exists to make that verification possible
and to catch problems before a release goes out with bad assets:

- Distribution files that don't match their recorded `SHA256SUMS` checksum are rejected.
- Files present in `dist/` but not listed in `SHA256SUMS` (or vice versa) fail the job instead of being
  silently skipped or silently signed.
- Every distribution is signed with [Sigstore](https://www.sigstore.dev/), so consumers can verify
  provenance without you managing signing keys.

## How it works

1. Downloads the `dist` artifact (produced by an earlier job in the same workflow run).
2. Verifies that every `*.tar.gz`/`*.whl` file in it is listed in `dist/SHA256SUMS` and matches its
   recorded checksum, failing closed on any mismatch or unlisted file.
3. Signs the distributions with [Sigstore](https://www.sigstore.dev/) (keyless OIDC signing).
4. Uploads the resulting `*.sigstore.json` bundles as a `signatures` artifact.
5. Attaches the distributions, signature bundles, and `SHA256SUMS` to the GitHub release for the
   current tag.

## Requirements

- A prior job/step must upload a `dist` artifact containing the built `*.tar.gz`/`*.whl` files plus a
  `SHA256SUMS` file (`sha256sum -- *.tar.gz *.whl > SHA256SUMS`) generated at build time.
- The calling job needs `id-token: write` (for Sigstore's keyless signing) and `contents: write` (to
  create/attach release assets) permissions.

## Inputs

| Name       | Description                                                                                                                                                                             | Required | Default |
| ---------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------- | ------- |
| `tag-name` | Tag/release to attach the signed assets to. Leave unset to use the tag that triggered the workflow (`github.ref_name`). Set explicitly when testing this action from a non-tag trigger. | No       | `""`    |

## Usage

### Basic

```yaml
jobs:
  sign:
    runs-on: ubuntu-latest
    permissions:
      id-token: write
      contents: write
    steps:
      - uses: actions/checkout@v7
      - uses: durandtibo/sign-pypi-package-action@<ref>
```

### End-to-end release workflow

Builds the package, then signs and attaches the distributions to the release triggered by the tag push:

```yaml
name: Release

on:
  push:
    tags:
      - "v*"

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7

      - name: Build package
        uses: durandtibo/build-pypi-package-action@<ref>

  sign:
    needs: build
    runs-on: ubuntu-latest
    permissions:
      id-token: write
      contents: write
    steps:
      - uses: actions/checkout@v7

      - name: Sign and release package
        uses: durandtibo/sign-pypi-package-action@<ref>
```

## License

Distributed under the [BSD 3-Clause License](LICENSE).
