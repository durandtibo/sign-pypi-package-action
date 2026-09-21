# sign-pypi-package-action

GitHub Action to sign Python package distributions with Sigstore and attach them to a GitHub release.

## What it does

1. Downloads the `dist` artifact (produced by an earlier job in the same workflow run).
2. Verifies that every `*.tar.gz`/`*.whl` file in it is listed in `dist/SHA256SUMS`
   and matches its recorded checksum, failing closed on any mismatch or
   unlisted file.
3. Signs the distributions with [Sigstore](https://www.sigstore.dev/) (keyless OIDC signing).
4. Uploads the resulting `*.sigstore.json` bundles as a `signatures` artifact.
5. Attaches the distributions, signature bundles, and `SHA256SUMS` to the
   GitHub release for the current tag.

## Requirements

- A prior job/step must upload a `dist` artifact containing the built
  `*.tar.gz`/`*.whl` files plus a `SHA256SUMS` file (`sha256sum -- *.tar.gz *.whl > SHA256SUMS`)
  generated at build time.
- The calling job needs `id-token: write` (for Sigstore's keyless signing)
  and `contents: write` (to create/attach release assets) permissions.

## Inputs

| Name       | Required | Default | Description                                                                                                                                                                             |
| ---------- | -------- | ------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `tag-name` | no       | `""`    | Tag/release to attach the signed assets to. Leave unset to use the tag that triggered the workflow (`github.ref_name`). Set explicitly when testing this action from a non-tag trigger. |

## Usage

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
