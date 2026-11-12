# Target state for `sign-pypi-package-action`

Review of `main` at `7f79384`. Breaking changes are accepted: the last release is `v0.0.1`, so everything
below can ship in the next exact tag at no cost to users. The properties in section 1 are the same
twelve as in `durandtibo/build-pypi-package-action` (`review/target_state.md`), adapted to what this
action does. The two actions are meant to be chained (build, then sign), so they share one contract.

Nothing in this document has been implemented. The action can only be exercised end to end on GitHub
Actions. Claims marked **(verified locally)** were checked on macOS with `bash`, `shasum` and `awk`;
claims marked **(confirm in CI)** need a GitHub run.

## 1. Properties of the action

The target state must satisfy all of these. Section 6 checks each one against the proposal.

| #   | Property           | Definition                                                                                                                                                                                                                      |
| --- | ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| P1  | **Single purpose** | Take the `dist` artifact produced by a build job, prove it is exactly what was built, sign it with Sigstore, and attach it to a GitHub release. It never builds, publishes to PyPI, or writes release notes.                    |
| P2  | **Fail closed**    | A check that cannot positively conclude "safe" fails the job, before any signing or release call. Missing, empty, malformed or ambiguous `SHA256SUMS` fails; an extra file fails; nothing is guessed.                           |
| P3  | **Ground truth**   | The files that are verified are the files that are signed and the files that are released: one list, derived once from `SHA256SUMS` and the directory, never re-globbed. A planted file cannot ride along.                      |
| P4  | **Reproducible**   | Every third-party action is pinned to a SHA. Nothing is installed at run time except by the signing action. No cache is read or written. Only `gh`, `bash` and `sha256sum`/`shasum` from the runner image are assumed.          |
| P5  | **Fast**           | Local checks run before network calls: the tag is validated before the download, the checksums before signing. No checkout, no second artifact upload, no re-parsing. The only slow step is Sigstore signing, and it runs once. |
| P6  | **Simple**         | All logic is inline in `action.yml`. Three inputs, one output. Each step is readable alone and is about 15 lines.                                                                                                               |
| P7  | **Portable**       | Same behaviour on Linux, macOS and Windows (Git Bash). Keep the `shasum -a 256` fallback for macOS.                                                                                                                             |
| P8  | **Safe to chain**  | The action can be used more than once in a run and after the build action. It uses no fixed artifact name, does not touch the caller's workspace, and never overwrites a release asset.                                         |
| P9  | **Secure**         | Inputs and step outputs reach scripts through `env:` only. The caller grants `id-token: write` and `contents: write` and nothing else. No secret other than `github.token`.                                                     |
| P10 | **Tested**         | Every check has a fixture proving it fails with the expected `failed-check` id, or is listed as an explicit review-only exception. A check that no fixture can fail does not exist. Tests are written once, not twice.          |
| P11 | **Fail loudly**    | A failure says what failed, why, the values involved and how to fix it, in an annotation and in the job summary. The `failed-check` output names the check; it is `unexpected` when something outside a check failed.           |
| P12 | **Small steps**    | One purpose and one failure id per step, named `N.x` by topic (`0.x` setup, `1.x` verify, `2.x` sign, `3.x` release, `4.x` report). Adding a check touches one place.                                                           |

## 2. What is good and stays

- **Composite action with bash steps** and no `working-directory`, no PyPI publishing, no build.
- **`SHA256SUMS` as the contract** with the build job, and the `shasum -a 256` fallback.
- **Keyless Sigstore** through the official `sigstore/gh-action-sigstore-python`, pinned to a SHA. It
  manages Python and the OIDC flow; a hand-rolled `sigstore sign` would not be simpler.
- **`tag-name` and `dist-artifact-name` inputs** (the second is a normal input, not a test hook).
- **SHA-pinned actions with ratchet comments**, `permissions: {}` plus per-job least privilege,
  `timeout-minutes` everywhere, `env:` for every input.
- **Workflow layout** (`ci.yaml`, reusable `ci-*`, `lib-*`, `bot-*`, security workflows, `.make/`).
- **End-to-end tests on a throwaway release**, with real Sigstore verification of the bundles.

## 3. Findings

Ordered by value. "Verified" means checked, not assumed.

### F1. A planted `*.sigstore.json` is released (violates P2, P3)

The verify step compares only `*.tar.gz` and `*.whl` to `SHA256SUMS`. The release step then uploads
`dist/*.sigstore.json`, which also matches a file that was already in the artifact. **(verified
locally)** With `evil.sigstore.json` next to a valid `SHA256SUMS`, `shasum --check --strict` passes and
the glob picks the file up.

**Fix:** the directory must hold exactly `SHA256SUMS` plus the files it lists (check 1.3). The sign
and release steps take the verified list, not a glob.

### F2. Valid binary-mode checksums are rejected (violates P2, P7)

`awk '{print $2}'` reads `*name` for a `<hash> *name` entry, which `sha256sum -b` and
`shasum -a 256 -b` write. **(verified locally)** A correct artifact is rejected with a misleading
"contents don't match" error.

**Fix:** parse the line with a strict regex that accepts the optional `*` (check 1.2).

### F3. Missing, empty or malformed `SHA256SUMS` fails by accident (violates P2, P11)

`awk` fails inside a process substitution and `diff` happens to see a difference. **(verified
locally)** The job fails, but nothing says why, and malformed lines, absolute paths, `../` and duplicate
entries are not examined at all.

**Fix:** an explicit check 1.2 with one `fail` per reason.

### F4. Failures cannot be told apart (violates P10, P11)

The three `reject-*` jobs use `continue-on-error` and assert `outcome == failure`. They pass when the
action fails for the wrong reason (artifact download, OIDC, tag). There is no `failed-check` output.

**Fix:** the same mechanism as the build action. `fail` writes the id to
`${RUNNER_TEMP}/failed-check`; a last step with `if: failure()` publishes it as the `failed-check`
output (`unexpected` if no id was written). Tests assert the id, never the message text. **(confirm in
CI)** that a composite step with `if: failure()` runs after a failed `run:` step and that the caller's
`steps.<id>.outputs.failed-check` is set with `continue-on-error`.

### F5. The `signatures` artifact has a fixed name (violates P8)

`upload-artifact` v4+ rejects a duplicate name within a run. The three-OS matrix in `ci-action.yaml`
uploads `signatures` three times, and any caller using the action twice does the same. **(confirm in
CI)** The artifact also duplicates what is on the release.

**Fix:** remove the step and the artifact. _Breaking._ A later job that needs the bundles can run
`gh release download`.

### F6. `softprops/action-gh-release` creates silently and overwrites (violates P4, P8)

One operation does not justify a large third-party action. It creates a missing release without being
asked and replaces assets that already exist, which breaks the "immutable release" rule in `CLAUDE.md`.

**Fix:** `gh release upload` without `--clobber`, after `gh release view || gh release create
--verify-tag`. `gh` is preinstalled on all hosted runners. _Breaking_ (overwrite behaviour). **(confirm
in CI)** `--verify-tag` when the tag was pushed in the same run, and the non-zero exit on an existing
asset on all three OSes.

### F7. The tag is validated at the very end (violates P2, P5)

On a branch trigger `github.ref_name` is a branch name, and the failure arrives after the download and
the signing.

**Fix:** step 0.2 resolves the tag first and fails if it is empty or if the run was not triggered by a
tag and `tag-name` is unset.

### F8. The signing action's own release upload is implicit (violates P8)

`release-signing-artifacts` defaults to `true` in `sigstore/gh-action-sigstore-python` and overlaps with
our upload on `release` events.

**Fix:** set `release-signing-artifacts: false` and `upload-signing-artifacts: false` explicitly.

### F9. The test suite is two 200-line copies (violates P10 "written once")

`ci-action.yaml` and `nightly-test-released.yaml` differ by one `uses:` line, a tag name, and
workaround code for the stable version not having `dist-artifact-name` (serialization with `needs`,
`delete_dist_artifacts`, `actions: write`). Each failure path is its own job that repeats checkout,
`uv` install, build and upload.

**Fix:** see section 5. One workflow with a `released` input, one `test/cases.json`, one build.

### F10. Fixture and helper leftovers (violates P6)

`test/fixtures/pkg/Makefile` and `tasks.py` are unused, the project is named
`pypi-release-action-fixture`, the fixture is copied into the repository root before every build, and
the `scripts/test-helper.sh` header mentions "a future nightly-test-released.yaml".

### F11. README (violates P11, P9)

The examples run `actions/checkout` in the `sign` job although the action does not need the repository,
cite `actions/checkout@v7` by tag and `<ref>` without guidance, and the `dist-artifact-name`
description differs from `action.yml`. There is no security model, no `failed-check`, and no "verify a
release" section.

## 4. Target design

### 4.1 Interface

| Kind   | Name                 | Description                                                                             |
| ------ | -------------------- | --------------------------------------------------------------------------------------- |
| input  | `tag-name`           | Release tag. Default: the tag that triggered the run. Unchanged.                        |
| input  | `dist-artifact-name` | Artifact with the distributions and `SHA256SUMS`. Default `dist`. Description reworded. |
| input  | `github-token`       | Token for the release. Default `${{ github.token }}`. **New.**                          |
| output | `failed-check`       | Id of the failed check, `unexpected` for any other failure, empty on success. **New.**  |

Removed: the `signatures` workflow artifact (F5). No input is renamed. This is the same shape as the
build action: its `failed-check` ids and the `unexpected` rule are identical.

### 4.2 Steps (10 steps, was 5)

| Step | Name                        | Failure id       | Change vs. today                                                                |
| ---- | --------------------------- | ---------------- | ------------------------------------------------------------------------------- |
| 0.1  | Define failure helper       |                  | writes `fail.sh`, clears a stale `failed-check` file (F4)                       |
| 0.2  | Resolve tag                 | `tag`            | new, runs before the download (F7)                                              |
| 1.1  | Download distributions      | `unexpected`     | now into `${RUNNER_TEMP}/dist`, not the workspace                               |
| 1.2  | Check `SHA256SUMS`          | `checksums-file` | new: exists, non-empty, strict line format, plain names, no duplicates (F2, F3) |
| 1.3  | Check distribution file set | `file-set`       | new: directory equals `SHA256SUMS` plus the listed files (F1)                   |
| 1.4  | Verify checksums            | `checksum`       | was inline; same `shasum` fallback                                              |
| 2.1  | Sign with Sigstore          | `unexpected`     | takes the verified list; explicit release flags (F8)                            |
| 3.1  | Attach to release           | `release`        | `gh` instead of `softprops`; no overwrite (F6)                                  |
| 4.1  | Write job summary           |                  | new on success: files, hashes, tag                                              |
| 4.2  | Report failed check         |                  | `if: failure()`, publishes the output (F4)                                      |

Removed: "Upload signature bundles" (F5). Step 2.1 is third-party, so it can only end in
`unexpected`; see the exceptions in section 5.

### 4.3 Sketch

Untested; written to show the shape, not to paste. Confirm in CI.

```bash
# 0.1  (written to ${RUNNER_TEMP}/fail.sh; every later step does `source` it)
rm -f "${RUNNER_TEMP}/failed-check"
fail() { # id, title, details, how to fix
  echo "$1" >"${RUNNER_TEMP}/failed-check"
  echo "::error title=$2::$3"
  printf '### :x: %s\n\n%s\n\n**How to fix:** %s\n' "$2" "$3" "$4" >>"$GITHUB_STEP_SUMMARY"
  exit 1
}

# 1.2  (DIST, from env)
cd "${DIST}"
[ -s SHA256SUMS ] || fail checksums-file "SHA256SUMS missing or empty" "..." "..."
bad="$(grep -nvE '^[0-9a-f]{64} [ *][A-Za-z0-9][A-Za-z0-9._+-]*\.(tar\.gz|whl)$' SHA256SUMS || true)"
[ -z "${bad}" ] || fail checksums-file "Malformed SHA256SUMS line" "${bad}" "..."
files="$(sed -E 's/^.{64} .//' SHA256SUMS | sort)"
[ -z "$(echo "${files}" | uniq -d)" ] || fail checksums-file "Duplicate entry" "..." "..."
echo "files=$(echo "${files}" | tr '\n' ' ')" >>"$GITHUB_OUTPUT"

# 1.3  (FILES from env; word splitting on purpose, names are restricted by 1.2)
# shellcheck disable=SC2086
expected="$(printf '%s\n' SHA256SUMS ${FILES} | sort)"
actual="$(ls -A | sort)"
[ "${expected}" = "${actual}" ] ||
  fail file-set "dist/ does not match SHA256SUMS" "$(diff <(echo "${expected}") <(echo "${actual}"))" "..."

# 3.1  (TAG, FILES from env)
gh release view "${TAG}" >/dev/null 2>&1 ||
  gh release create "${TAG}" --verify-tag --title "${TAG}" --notes "" ||
  fail release "Cannot create release ${TAG}" "..." "..."
# shellcheck disable=SC2086
gh release upload "${TAG}" SHA256SUMS ${FILES} $(printf '%s.sigstore.json ' ${FILES}) ||
  fail release "Cannot attach assets to ${TAG}" "..." "Delete the partial assets, then re-run."
```

The regex excludes `/`, a leading `.` or `-`, and spaces, so a name cannot be a path, an option or two
words. The sign step receives `inputs: ${{ steps.files.outputs.files }}` as absolute paths under
`${RUNNER_TEMP}/dist`; a step output in `with:` is not script interpolation.

## 5. Tests and repository

### 5.1 Case table

`test/cases.json` holds every row, in two lists, `accept` and `reject`. A new case is one row: a name, a `stage`
snippet that mutates a copy of the good `dist/`, the expected id, and a `released` flag for rows the
stable version supports. The OS matrix for `valid` comes from `lib-get-test-matrix.yaml`.

| Case                   | Stage                                        | Expected `failed-check` |
| ---------------------- | -------------------------------------------- | ----------------------- |
| `valid` (3 OSes)       | none                                         | empty, release verified |
| `binary-mode-entry`    | rewrite `SHA256SUMS` with `shasum -b`        | empty                   |
| `tampered-file`        | append to the sdist                          | `checksum`              |
| `missing-sums`         | delete `SHA256SUMS`                          | `checksums-file`        |
| `empty-sums`           | truncate `SHA256SUMS`                        | `checksums-file`        |
| `malformed-line`       | add a line without a hash                    | `checksums-file`        |
| `path-traversal`       | list `../x.whl`                              | `checksums-file`        |
| `duplicate-entry`      | list the wheel twice                         | `checksums-file`        |
| `disallowed-extension` | list a `.zip`                                | `checksums-file`        |
| `unlisted-file`        | copy the wheel under another name            | `file-set`              |
| `planted-bundle`       | add `evil.sigstore.json` (regression for F1) | `file-set`              |
| `subdirectory`         | add `dist/sub/`                              | `file-set`              |
| `listed-file-absent`   | delete the wheel, keep its entry             | `file-set`              |
| `no-tag`               | run from a branch, `tag-name` unset          | `tag`                   |
| `second-run`           | run the action twice on the same tag         | `release`               |

Review-only exceptions, listed under "Tests" in `CLAUDE.md`: step 1.1 (artifact download) and step 2.1
(Sigstore signing, for example a missing `id-token` permission). Both are `unexpected`, and neither is
a check of this action. The matrix cannot vary job permissions, so the OIDC case stays a documented
manual check.

### 5.2 Workflows

```text
ci.yaml                       unchanged entry point, calls ci-action.yaml with released: false
nightly.yaml                  calls ci-action.yaml with released: true
ci-action.yaml                one suite, input `released: boolean`, matrices from test/cases.json
nightly-test-released.yaml    deleted
lib-get-test-matrix.yaml      unchanged
test/cases.json               all rows
test/fixtures/pkg/            fixture, renamed, Makefile and tasks.py removed
scripts/test-helper.sh        assertions; delete_dist_artifacts removed
```

`ci-action.yaml` jobs:

1. `build`: `uv build test/fixtures/pkg --out-dir dist` (no copy into the repository root), generate
   `SHA256SUMS`, upload `dist-base`. Built once for all cases.
2. `sign` (OS matrix): create a throwaway release, run the action, assert the Sigstore bundles verify
   with `--cert-identity` pinned to this workflow, assert the asset set is exactly the expected one,
   always delete the release.
3. `accept` and `reject` (matrix over `test/cases.json`, `ubuntu-latest`): download `dist-base`, run the
   row's `stage`, upload it as `dist-<case>`, run the action with `dist-artifact-name: dist-<case>`
   and `continue-on-error`, assert `failed-check` equals the expected id with `assert_failed_check`.
   No per-case build, so a case costs one short job.

The action is invoked by two steps, `uses: ./` with `if: !inputs.released` and
`uses: durandtibo/sign-pypi-package-action@<sha>` with `if: inputs.released`, read through
`steps.local.outputs.x || steps.released.outputs.x`. This is the same approach as the build action. The
released version in `v0.0.1` has no `failed-check` output, so until the next release the nightly runs
only the rows marked `released`. At release time: set `released` rows, bump the SHA, and delete the
helpers that only existed for the old tag.

### 5.3 Documentation

- **README:** remove `actions/checkout` from the `sign` job examples; pin examples to a full SHA with a
  version comment and say "no floating tags"; add **Security model** (what is verified; the checksums
  only prove the artifact was not changed between jobs, not that the build was trustworthy),
  **Verifying a release** (`uvx sigstore verify github --repository <owner>/<repo> <file>`),
  **Permissions**, the `failed-check` ids, and a **Migration** note (no `signatures` artifact; assets
  are never overwritten).
- **CLAUDE.md:** replace "logic lives inline" with a list of step ids, add the rule "every check calls
  `fail <id> ...` and has a row in `test/cases.json`", the review-only exceptions, and the
  `released` workflow input in place of `nightly-test-released.yaml`.

## 6. Properties check

| #   | Met by                                                                                                                     |
| --- | -------------------------------------------------------------------------------------------------------------------------- |
| P1  | Five unchanged responsibilities, none added. `signatures` artifact removed.                                                |
| P2  | Checks 1.2 to 1.4 run before signing and each has a failing row. 0.2 runs before the download.                             |
| P3  | `files` is produced once by 1.2, confirmed by 1.3, signed by 2.1 and released by 3.1. No glob after 1.3.                   |
| P4  | One third-party signing action, pinned; `softprops` and `upload-artifact` removed. `gh` comes from the image.              |
| P5  | Tag first, checksums before signing, no checkout, no second upload. Per-case jobs do not rebuild.                          |
| P6  | All inline; steps of about 15 lines; three inputs, one output.                                                             |
| P7  | Bash and `shasum` fallback only. Windows is in the `valid` matrix. **(confirm in CI)** `${RUNNER_TEMP}` paths in Git Bash. |
| P8  | No fixed artifact name; download goes to `${RUNNER_TEMP}`; no `--clobber`.                                                 |
| P9  | `env:` for every input and output; permissions documented; `github-token` explicit.                                        |
| P10 | 15 rows, one per check reason; two explicit exceptions; one suite for local and released.                                  |
| P11 | `fail` writes an annotation and a summary; `failed-check` published; tests assert ids.                                     |
| P12 | Ten steps with `N.x` names and one failure id each.                                                                        |

## 7. Considered and rejected

- **Verification in `scripts/verify-dist.sh` with a local `make test`.** The local feedback would be
  faster, but it breaks P6 (all logic inline, one file to read) and P10 (a second test mechanism next to
  the case table), and it diverges from the build action. The case table runs short jobs on
  `ubuntu-latest`, which is enough. Revisit only if the checks grow past about 15 lines each.
- **A `signatures-artifact-name` input.** No user needs it yet; `gh release download` covers the
  chaining case. Add it when a user asks.
- **`--clobber` for re-runs.** Convenient, but a re-run could replace an asset that was already
  downloaded by consumers. Failing is the safe default and the message says how to recover.
- **Checking the released tag out into `action/` and using `uses: ./action`.** Avoids the second `uses:`
  step but differs from the build action. Same-repo consistency wins.
- **Re-verifying the bundles after signing in the action.** It costs a network call for every caller and
  Sigstore signing already fails closed. The test suite verifies them instead.

## 8. Migration order

One PR per logical change, branched from `main`.

| Order | Branch                              | Content                                                                            | Breaking               |
| ----- | ----------------------------------- | ---------------------------------------------------------------------------------- | ---------------------- |
| 1     | `feat/failed-check-and-checks`      | Steps 0.x, 1.x, 4.x, `failed-check` output, `test/cases.json` rows for 0.x and 1.x | No (stricter file-set) |
| 2     | `refactor/release-with-gh-cli`      | Step 3.1, `github-token`, `release` rows, explicit sigstore flags                  | Yes (no overwrite)     |
| 3     | `refactor/drop-signatures-artifact` | Remove the `upload-artifact` step                                                  | Yes                    |
| 4     | `test/single-suite`                 | One `ci-action.yaml` with `released`, delete the nightly copy, fixture cleanup     | No                     |
| 5     | `docs/readme-and-claude-md`         | README and `CLAUDE.md` from 5.3                                                    | No                     |

Release 1 to 3 together as the next exact tag (for example `v0.1.0`) with the migration note. No
floating tags.

## 9. What was not done

- Nothing was implemented or run on GitHub; every `(confirm in CI)` item is open.
- The sketches in 4.3 are untested.
- The `build-pypi-package-action` review was read for its properties and structure only. Aligning
  `CLAUDE.md` rules that mention "mirror `cancel-queued-runs-action`" with it is left to the PRs above.
