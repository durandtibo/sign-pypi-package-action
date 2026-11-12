# sign-pypi-package-action

[![CI](https://github.com/durandtibo/sign-pypi-package-action/actions/workflows/ci.yaml/badge.svg)](https://github.com/durandtibo/sign-pypi-package-action/actions/workflows/ci.yaml)
[![Nightly](https://github.com/durandtibo/sign-pypi-package-action/actions/workflows/nightly.yaml/badge.svg)](https://github.com/durandtibo/sign-pypi-package-action/actions/workflows/nightly.yaml)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/durandtibo/sign-pypi-package-action/badge)](https://scorecard.dev/viewer/?uri=github.com/durandtibo/sign-pypi-package-action)
[![License](https://img.shields.io/badge/license-BSD--3--Clause-blue)](LICENSE)
[![Latest release](https://img.shields.io/github/v/tag/durandtibo/sign-pypi-package-action?label=release)](https://github.com/durandtibo/sign-pypi-package-action/tags)

A composite GitHub Action that signs Python package distributions with Sigstore and attaches them,
along with their signatures, to a GitHub release.

Point it at a job that already produced a `dist` artifact (wheel + sdist + `SHA256SUMS`), and it verifies
the checksums, signs every distribution with Sigstore's keyless OIDC signing, and attaches the
distributions, their signature bundles and `SHA256SUMS` to the release for the tag.

## Why use it

Attaching unsigned or tampered build artifacts to a release makes it hard for consumers to verify what
they're installing actually came from your build. This action makes that verification possible and
catches problems before a release goes out with bad assets:

- `SHA256SUMS` must be well formed, and every listed file must match its checksum.
- The artifact must contain `SHA256SUMS` and exactly the files it lists. An extra file (for example a
  planted `*.sigstore.json`) fails the job instead of being signed or released.
- Every distribution is signed with [Sigstore](https://www.sigstore.dev/), so consumers can verify
  provenance without you managing signing keys.
- Release assets are never overwritten.

## How it works

Steps run in this order; each check that fails reports its id in the `failed-check` output.

| Step | What it does                                                                | `failed-check`   |
| ---- | --------------------------------------------------------------------------- | ---------------- |
| 0.2  | Resolves the release tag before anything is downloaded                      | `tag`            |
| 1.1  | Downloads the distribution artifact into `${RUNNER_TEMP}/sign-pypi-package` | `unexpected`     |
| 1.2  | Checks `SHA256SUMS`: exists, strict line format, plain names, no dups       | `checksums-file` |
| 1.3  | Checks the artifact holds exactly `SHA256SUMS` plus the listed files        | `file-set`       |
| 1.4  | Verifies the checksums (`sha256sum`, or `shasum -a 256` on macOS)           | `checksum`       |
| 2.1  | Checks that the job can get an OIDC token (`id-token: write`)               | `permissions`    |
| 2.2  | Signs the verified files with Sigstore (keyless OIDC)                       | `unexpected`     |
| 2.3  | Checks that every signed file has a non-empty `.sigstore.json` bundle       | `bundle`         |
| 3.1  | Attaches files, bundles and `SHA256SUMS` to the release with `gh`           | `release`        |

The same verified file list is checked, signed and released: nothing is globbed after step 1.3.

## Running it several times

The action can run more than once in a job (for example for two packages), each time with its own
artifact. It removes its work directory first, so a run never sees the files of the previous one.

## Requirements

- A prior job uploads an artifact (default name `dist`) with the built `*.tar.gz`/`*.whl` files plus a
  `SHA256SUMS` file (`sha256sum -- *.tar.gz *.whl > SHA256SUMS`). File names may only contain letters,
  digits, `.`, `_`, `+` and `-`, and must not start with `.` or `-`.
- The tag must already exist. The action creates the release if it is missing and otherwise reuses it.

## Inputs

| Name                 | Description                                                                                                  | Required | Default               |
| -------------------- | ------------------------------------------------------------------------------------------------------------ | -------- | --------------------- |
| `tag-name`           | Release tag. Leave unset to use the tag that triggered the run; fails if the run was not triggered by a tag. | No       | `""`                  |
| `dist-artifact-name` | Name of the artifact with the distributions and `SHA256SUMS`.                                                | No       | `"dist"`              |
| `github-token`       | Token used to create the release if needed and attach the assets. Needs `contents: write`.                   | No       | `${{ github.token }}` |

## Outputs

| Name           | Description                                                                                                                                                         |
| -------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `failed-check` | Id of the failed check (`tag`, `checksums-file`, `file-set`, `checksum`, `permissions`, `bundle`, `release`), `unexpected` for any other failure, empty on success. |

A failure also writes an annotation and a job summary with the values involved and how to fix it.

## Permissions

The calling job needs `id-token: write` (Sigstore keyless signing) and `contents: write` (release
assets), and nothing else. The action does not need `actions/checkout` and does not touch the workspace.

## Usage

Pin the action to a full commit SHA with the version in a comment. Releases are immutable exact tags
(`v0.1.0`, ...); there are no floating tags such as `v1`.

```yaml
name: Release

on:
  push:
    tags:
      - "v*"

permissions: {}

jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@<sha> # <version>
      - name: Build package
        uses: durandtibo/build-pypi-package-action@239defb64fe09080292442db058bddd02f498eb3 # ratchet:durandtibo/build-pypi-package-action@v0.1.0

  sign:
    needs: build
    runs-on: ubuntu-latest
    permissions:
      id-token: write
      contents: write
    steps:
      - name: Sign and release package
        uses: durandtibo/sign-pypi-package-action@<sha> # <version>
```

## Security model

The checksums only prove that the artifact was not changed between the build job and this job. They do
not prove that the build itself was trustworthy: the Sigstore signature attests that this workflow, in
this repository, signed the files. Steps 1.2 to 1.4 run before any signing or release call and fail
closed. Inputs reach scripts through `env:` only, and the only secret used is `github.token`. Text that comes from the artifact (file names, `SHA256SUMS` lines) is escaped before it is written to an annotation
and fenced in the job summary.

## Verifying a release

```bash
uvx sigstore verify github --repository <owner>/<repo> <file>.whl
```

## Migration from `v0.0.1`

- The `signatures` workflow artifact is gone; use `gh release download <tag> --pattern '*.sigstore.json'`.
- Release assets are never overwritten: re-running on a tag that already has them fails with
  `failed-check=release`. Delete the assets, then re-run.
- The artifact must contain exactly `SHA256SUMS` and the files it lists; extra files now fail.
- The `dist` artifact is downloaded to `${RUNNER_TEMP}/sign-pypi-package`, no longer to the workspace `dist/`.
- `actions/checkout` is no longer needed in the signing job.

## License

Distributed under the [BSD 3-Clause License](LICENSE).
