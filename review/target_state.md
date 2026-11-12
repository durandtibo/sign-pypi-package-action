# Target state: `sign-pypi-package-action`

Review of the repository at commit `7f79384` and the proposed target state. Breaking changes are
accepted where they simplify the action or make it safer. Items that need a CLAUDE.md change are
marked **[CLAUDE.md]**.

## 1. Properties of the action

These are the properties the action must have. Everything in section 4 is derived from them.

| #   | Property                     | Meaning                                                                                                                                                                                    |
| --- | ---------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| P1  | **Single purpose**           | Take a built `dist` artifact, sign it with Sigstore, attach it to a GitHub release. It does not build, publish to PyPI, or create release notes.                                           |
| P2  | **Fail closed**              | Nothing is signed or released unless `dist/` contains exactly `SHA256SUMS` plus the files it lists, and every checksum matches. Any doubt is an error, before any signing or release call. |
| P3  | **Keyless**                  | Signing uses OIDC keyless Sigstore only. No secrets, no keys, no tokens beyond `github.token`.                                                                                             |
| P4  | **Immutable releases**       | Assets are never overwritten. Re-uploading an existing asset is an error.                                                                                                                  |
| P5  | **Portable**                 | Works on Linux, macOS and Windows runners (bash steps only, `shasum -a 256` fallback).                                                                                                     |
| P6  | **Minimal trust surface**    | Few third-party actions, all pinned to commit SHAs. Inputs reach scripts only through `env:`. Least-privilege permissions documented for callers.                                          |
| P7  | **Small and local-testable** | The security-relevant logic is a short script that can be tested locally in seconds. End-to-end runs only confirm the integration (OIDC, release API).                                     |
| P8  | **Predictable interface**    | Few inputs, safe defaults, every input documented identically in `action.yml` and `README.md`. No input exists only "for tests".                                                           |
| P9  | **Fast**                     | No unnecessary checkout, artifact round-trip or API call in the caller's job.                                                                                                              |

## 2. Current state: findings

### 2.1 Action (`action.yml`)

| #   | Finding                                                                                                                                                                                                                                                             | Property | Severity |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------- | -------- |
| A1  | **A pre-planted `*.sigstore.json` in the `dist` artifact is released.** The verify step only compares `*.tar.gz`/`*.whl` to `SHA256SUMS`. The release step then uploads `dist/*.sigstore.json`, which can include a file that was in the artifact before signing.   | P2       | High     |
| A2  | `awk '{print $2}'` breaks on binary-mode entries (`<hash> *name`, produced by `sha256sum -b` and by default on some Windows tools). The listed name becomes `*name`, so a valid artifact is rejected (false negative, but a reliability bug).                       | P2, P5   | Medium   |
| A3  | Missing `SHA256SUMS`, empty file, and "no `*.tar.gz`/`*.whl`" are caught only by accident: `awk` fails inside a process substitution and `printf` prints the literal unmatched glob. There is no explicit check and no clear `::error` message.                     | P2       | Medium   |
| A4  | The `signatures` artifact name is fixed. `upload-artifact` v4+ rejects duplicate names within a run, so the `ci-action.yaml` OS matrix (3 jobs, same name) or any caller using the action twice will conflict. The artifact also duplicates what is on the release. | P8, P9   | Medium   |
| A5  | `softprops/action-gh-release` is a large third-party dependency for one operation. It also silently creates a release if missing and overwrites assets with the same name, which conflicts with P4.                                                                 | P4, P6   | Medium   |
| A6  | `tag-name` is resolved inline in `with:` with no validation. On a branch trigger, `github.ref_name` is a branch name and the failure happens only at the very end, after signing.                                                                                   | P2, P9   | Low      |
| A7  | `dist-artifact-name` is documented as "only for tests". It is a legitimate input (callers may name artifacts differently) and the description should say so.                                                                                                        | P8       | Low      |
| A8  | The sigstore action's `release-signing-artifacts` defaults to `true` and would try to upload on `release` events, overlapping with our own upload. It should be set explicitly.                                                                                     | P4, P6   | Low      |
| A9  | `dist/` is hard-coded, and the verification is inline Bash that cannot be run or unit-tested locally. **[CLAUDE.md]**                                                                                                                                               | P7       | Medium   |

### 2.2 README

- README examples run `actions/checkout` in the `sign` job. The action does not need the repository,
  so this costs time and broadens the job for nothing (P9).
- Examples reference `actions/checkout@v7` by tag while the project rule is SHA pinning, and
  `<ref>` is not guidance. It should say: pin to a full commit SHA or an exact version tag.
- No section on the security model (what is verified, what is not), on outputs, or on how to verify a
  release (`sigstore verify github`).
- The `dist-artifact-name` description differs from `action.yml`.

### 2.3 Tests and CI

| #   | Finding                                                                                                                                                                                                                                                                                                      |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| T1  | `ci-action.yaml` and `nightly-test-released.yaml` are ~95% identical (~200 lines each). The only real difference is the `uses:` line. The rest is workaround code for the stable version lacking `dist-artifact-name` (serialization with `needs`, `delete_dist_artifacts`, `actions: write`).               |
| T2  | Each failure path (`reject-tampered-checksums`, `reject-unlisted-file`, `reject-missing-checksums`) is a full runner job: checkout, `uv` install, build, upload artifact, run the action, assert failure. About 1 to 2 minutes of runner time to test 10 lines of Bash, and the result can't be run locally. |
| T3  | `continue-on-error` + `outcome == failure` passes if the action fails for the **wrong** reason (e.g. artifact download fails). Failure tests don't assert the error message.                                                                                                                                 |
| T4  | Fixture is staged by `cp -r test/fixtures/pkg/. .` into the repo root, polluting the checkout. `uv build <dir> --out-dir dist` does the same without copying.                                                                                                                                                |
| T5  | `test/fixtures/pkg/Makefile` and `tasks.py` (invoke) are unused. The fixture project name `pypi-release-action-fixture` is a leftover from another repo.                                                                                                                                                     |
| T6  | `test-helper.sh` header mentions "a future nightly-test-released.yaml once a release is tagged", which is stale.                                                                                                                                                                                             |
| T7  | `assert_sigstore_valid` verifies only that the bundle exists for the repository, not the signing identity or the workflow ref. Using `--cert-identity`/`--cert-oidc-issuer` pinned to the test workflow gives a stronger assertion.                                                                          |
| T8  | Bumping the released tag requires manually editing `nightly-test-released.yaml` (SHA + comment).                                                                                                                                                                                                             |

## 3. Target design

### 3.1 Interface

```yaml
inputs:
  tag-name:
    description: Release tag to attach the assets to. Defaults to the tag that triggered the run.
    required: false
    default: ""
  dist-artifact-name:
    description: Name of the workflow artifact that holds the distributions and SHA256SUMS.
    required: false
    default: dist
  github-token:
    description: Token used to create/upload to the release (needs contents: write).
    required: false
    default: ${{ github.token }}
```

Changes with respect to today:

- **Removed:** the `signatures` workflow artifact (A4). The signature bundles are on the release; a
  later job that needs them can `gh release download`. _Breaking._ If a user need appears, add an
  opt-in `signatures-artifact-name` input (empty = disabled) rather than a fixed name.
- **Added:** `github-token`, so the token usage is explicit and callers can supply a different one.
  Default keeps today's behaviour.
- **Reworded:** `dist-artifact-name` is a normal input (A7).
- **Behaviour:** the release must either exist or is created with `--verify-tag` (tag must already
  exist; the action never creates tags). Existing assets are never overwritten (P4).

### 3.2 Steps

```text
1. Resolve tag        bash   tag = inputs.tag-name || github.ref_name; fail if empty or not refs/tags
                              (fails in ~1 s, before download and signing)  [A6]
2. Download dist      actions/download-artifact (pinned)  -> $RUNNER_TEMP/dist
3. Verify dist        bash   scripts/verify-dist.sh "$RUNNER_TEMP/dist"                [A1-A3, A9]
4. Sign               sigstore/gh-action-sigstore-python (pinned)
                              inputs: files listed by verify step
                              release-signing-artifacts: false                          [A8]
5. Upload to release  bash   gh release view || gh release create --verify-tag;
                              gh release upload "$TAG" <files> (no --clobber)           [A5, P4]
```

Notes:

- Same number of steps, but one third-party action fewer (`softprops` replaced by the `gh` CLI,
  preinstalled on all GitHub-hosted runners, including Windows and macOS) and no artifact upload.
- Download to `$RUNNER_TEMP`, not the workspace: the caller's workspace is not touched and cannot
  contain stray files that collide with the globs.
- The script receives paths through arguments/`env:`, never via `${{ }}` in `run:` (P6).
- `github.ref_name` is read via `env:` too.

### 3.3 `scripts/verify-dist.sh` (fail closed, testable) **[CLAUDE.md]**

Move the verification out of `action.yml` into a script next to the action, called with
`"${GITHUB_ACTION_PATH}/scripts/verify-dist.sh"`. CLAUDE.md currently says logic lives inline; update
it to say "security-relevant logic lives in `scripts/`, linted by `make lint`, unit-tested by
`make test`". Reasons: it is linted and formatted as a normal file, it runs locally, and it is the
only place where P2 is enforced.

Contract:

1. `dist` directory exists, else error.
2. `SHA256SUMS` exists and is non-empty.
3. Every line matches `^[0-9a-f]{64}  ?\*?[^/]+$` (hash, optional `*` binary marker, a plain file
   name: no `/`, no `..`). Anything else is an error. [A2]
4. Listed names must all end in `.tar.gz` or `.whl`, have at least one entry, and have no duplicates.
5. The set of files in `dist/` (including hidden files and sub-directories) must equal
   `listed names + SHA256SUMS`. Any extra file, including `*.sigstore.json`, fails. [A1]
6. Checksums match: `sha256sum --check --strict` or the `shasum -a 256` fallback (P5).
7. On success, print the verified file names, one per line, to stdout (used for the sign step input
   and the release upload so both operate on the same list, not on re-globbed patterns).
8. Every failure prints `::error::<reason>` and exits 1.

Expected length: ~40 lines of Bash.

### 3.4 Release upload

```bash
gh release view "$TAG" >/dev/null 2>&1 || gh release create "$TAG" --verify-tag --title "$TAG" --notes ""
gh release upload "$TAG" "${files[@]}" SHA256SUMS
```

- Files are the verified list plus their `.sigstore.json` bundles plus `SHA256SUMS`. A missing bundle
  is an error (replaces `fail_on_unmatched_files`).
- No `--clobber`: re-running a failed job on a release where some assets already exist fails with a
  clear message instead of silently replacing published assets. Document "delete the partial
  assets, then re-run".

### 3.5 Pinned dependencies

| Action                               | Keep? | Note                                     |
| ------------------------------------ | ----- | ---------------------------------------- |
| `actions/download-artifact`          | Yes   | Needed, official.                        |
| `sigstore/gh-action-sigstore-python` | Yes   | Handles Python/sigstore setup. Pin kept. |
| `actions/upload-artifact`            | No    | Removed with the `signatures` artifact.  |
| `softprops/action-gh-release`        | No    | Replaced by `gh` (preinstalled).         |

Two third-party actions remain (one of them official GitHub). Dependabot and `bot-pin-action.yaml`
keep working unchanged.

## 4. Tests: target state

Principle: test the security logic locally and cheaply; test the integration end-to-end once per OS.

### 4.1 Local script tests (new) **[CLAUDE.md]**

`test/verify-dist.test.sh` plus a `make test` target (in the repo `Makefile`, outside `.make/`),
using plain Bash and temporary directories, no new dependency. One case per rule in 3.3:

| Case                                  | Expected                   |
| ------------------------------------- | -------------------------- |
| valid dist                            | exit 0, prints file names  |
| valid dist, binary-mode `*name` entry | exit 0                     |
| tampered file                         | exit 1, `checksum` error   |
| unlisted `.whl` / `.tar.gz`           | exit 1                     |
| planted `*.sigstore.json`             | exit 1 (regression for A1) |
| subdirectory / hidden file            | exit 1                     |
| missing `SHA256SUMS`                  | exit 1                     |
| empty `SHA256SUMS`                    | exit 1                     |
| entry listed but file absent          | exit 1                     |
| entry with `../` or `/`               | exit 1                     |
| duplicate entry                       | exit 1                     |
| disallowed extension (`.zip`)         | exit 1                     |

Each failure case asserts both the exit code **and** the `::error::` message (T3). It runs in the
CI `format`/lint job on a Linux/macOS/Windows matrix in a few seconds and replaces the three
`reject-*` runner jobs (T2). Bug fixes then get a regression test by adding one table row.

### 4.2 End-to-end (one reusable workflow, `ci-action.yaml`)

Keep **one** reusable workflow that has an input `action-ref`:

- Empty (CI): `uses: ./`.
- Set (nightly): check out this repository at that ref into `action/`, then `uses: ./action`.
  Local actions are resolved at step time, so this works for any tag. The nightly caller resolves
  the latest release tag itself (`gh release view --json tagName`), so there is no pinned SHA to
  bump (T8).

This deletes `nightly-test-released.yaml` (T1) and the `delete_dist_artifacts` workaround and the
`actions: write` permission it needs. Verify this works on runners before merging, as it cannot be
tested locally.

Jobs:

1. `build`: `uv build test/fixtures/pkg --out-dir dist` (no staging copy, T4), generate
   `SHA256SUMS`, upload `dist`.
2. `sign` (matrix: Linux, macOS, Windows): create throwaway release, run the action, then assert:
   - bundles verify with `--cert-identity` of this workflow and the GitHub OIDC issuer (T7),
   - release has exactly the expected assets (compare the full list, not four regexes),
   - the action cannot overwrite: a second run fails (P4).
     Always delete the throwaway release in an `if: always()` step.
3. `reject-tampered` (ubuntu only): one end-to-end negative test that proves the verify step
   is wired in before signing, asserting the failure comes from the **verify step** (check the step
   `conclusion`, and that the sign step was skipped), not from any step. All other negative cases
   live in 4.1.

Result: three jobs of E2E per workflow instead of six, and one workflow file instead of two.

### 4.3 Fixture and helper cleanup

- Delete `test/fixtures/pkg/Makefile` and `tasks.py`. Rename the project to
  `sign-pypi-package-action-fixture` (T5).
- Keep `scripts/test-helper.sh` for E2E assertions only. Drop `delete_dist_artifacts` and
  `assert_signatures_artifact_uploaded`. Replace the header comment (T6). Make
  `assert_release_assets` compare the exact set.

## 5. Documentation changes

### README

- Remove `actions/checkout` from the `sign` job examples (P9).
- Pin examples to a full SHA with a `# v0.x.y` comment; say "do not use floating tags".
- Add a short **Security model** section: what is verified (checksums, exact file set), what is not
  (the content was trustworthy at build time; `SHA256SUMS` only protects the artifact in transit
  between jobs).
- Add **Verifying a release**: `uvx sigstore verify github --repository <owner>/<repo> <file>`.
- Add **Permissions** table: `id-token: write`, `contents: write`.
- Update the inputs table (new `github-token`, reworded `dist-artifact-name`) and remove every
  mention of the `signatures` artifact.
- Add a **Migration** note: the `signatures` artifact is gone; re-runs no longer overwrite assets.

### CLAUDE.md

- Replace "The logic lives inline in `action.yml`" with: steps in `action.yml`, verification in
  `scripts/verify-dist.sh`.
- Add `make test` to the environment list and the reporting list (it can be run locally).
- Update "Tests": negative paths are covered by `test/verify-dist.test.sh`; E2E covers success,
  overwrite refusal and one wired-in negative case.
- Update workflow structure: no `nightly-test-released.yaml`, `nightly.yaml` calls `ci-action.yaml`
  with `action-ref`. Note that `durandtibo/cancel-queued-runs-action` should be aligned the same
  way, or the "mirror" rule relaxed.

## 6. Migration plan (one PR per logical change, per CLAUDE.md)

| Order | Branch                              | Content                                                                                                       | Breaking                  |
| ----- | ----------------------------------- | ------------------------------------------------------------------------------------------------------------- | ------------------------- |
| 1     | `feat/verify-dist-script`           | `scripts/verify-dist.sh`, `test/verify-dist.test.sh`, `make test`, CI job, action uses the script (A1-A3, A9) | No                        |
| 2     | `refactor/release-with-gh-cli`      | Replace `softprops`, add `github-token`, resolve/validate tag early, no overwrite (A5, A6, A8)                | Yes (overwrite behaviour) |
| 3     | `refactor/drop-signatures-artifact` | Remove `upload-artifact` step and `signatures` artifact (A4)                                                  | Yes                       |
| 4     | `test/merge-e2e-workflows`          | Single parametrised E2E workflow, delete nightly duplicate and workarounds, fixture cleanup (T1-T8)           | No                        |
| 5     | `docs/readme-and-claude-md`         | README and CLAUDE.md updates from section 5                                                                   | No                        |

Release the breaking changes (2, 3) together as a new exact tag, for example `v0.1.0`, with the
migration note in the release text. No floating tags.

## 7. Deliberately left unchanged

- Composite action form and Bash-only steps (P5).
- Keyless Sigstore via the official `sigstore/gh-action-sigstore-python` rather than a hand-rolled
  `sigstore sign` call (it manages Python and the OIDC flow).
- `SHA256SUMS` as the integrity contract between the build job and this action.
- Workflow layout (`ci.yaml`, reusable `ci-*`, `lib-*`, `bot-*`, security workflows), `permissions: {}`
  at workflow level, `timeout-minutes`, SHA pinning with ratchet comments.
- `.make/` and the shared Makefile.

## 8. Open points to confirm on a runner

These cannot be validated locally and should be checked in the PRs before they are relied on:

1. `uses: ./action` after a second `actions/checkout` with `path: action` (4.2), including on Windows.
2. `gh release create --verify-tag` behaviour when the tag was pushed in the same workflow run.
3. `gh release upload` without `--clobber` returns non-zero for an existing asset on all three OSes.
4. `${GITHUB_ACTION_PATH}` expansion in a composite step on Windows with `shell: bash`.
