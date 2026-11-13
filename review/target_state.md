# Target state for `sign-pypi-package-action`

Review of `main` at `c0463c3`. This replaces the first review, which was implemented in #46 to #50
(strict checks, `failed-check`, `gh` release upload, one test suite). Breaking changes are accepted:
the last release is `v0.0.1`, and everything below ships in the next exact tag. Future state wins over
past state.

Nothing here is implemented. The action can only run end to end on GitHub Actions. Claims are marked:

- **(read)**: derived from reading the code or the documented behaviour of a tool, not executed.
- **(confirm in CI)**: needs a GitHub run before the change is trusted.
- **(ran)**: executed locally. Only one claim is: the lint baseline in F11.

## 1. Properties of the action

The target state must satisfy all of these. Section 7 checks each one against the proposal. They are
the twelve properties of the first review and of `build-pypi-package-action`, so the two actions share
one contract. P2, P4, P8 and P9 are sharpened by this review.

| #   | Property           | Definition                                                                                                                                                                                                                                                             |
| --- | ------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| P1  | **Single purpose** | Take the `dist` artifact of a build job, prove it is exactly what was built, sign it with Sigstore and attach it to a GitHub release. It never builds, publishes to PyPI or writes release notes.                                                                      |
| P2  | **Fail closed**    | A check that cannot positively conclude "safe" fails the job before any signing or release call. A failed run never leaves a release that looks complete but is not (no half-attached assets on a release the action created). Nothing is guessed.                     |
| P3  | **Ground truth**   | One file list, derived once from `SHA256SUMS` and the directory, is checked, signed and released. Nothing is re-globbed. Every released file, `SHA256SUMS` included, has a signature bundle.                                                                           |
| P4  | **Reproducible**   | Every third-party action is pinned to a SHA. Nothing but the signing action installs anything at run time. No cache. Only `bash`, `gh` and `sha256sum`/`shasum` from the runner image are assumed.                                                                     |
| P5  | **Fast**           | Local checks run before network calls (tag, checksums, permissions, then Sigstore). No checkout, no second artifact upload. Sigstore signing is the only slow step and runs once.                                                                                      |
| P6  | **Simple**         | All logic is inline in `action.yml`, in steps of about 15 lines. Three inputs, one output. Tests are one table and one workflow, not copies.                                                                                                                           |
| P7  | **Portable**       | Same behaviour on Linux and macOS (Windows is not supported). Keep the `shasum -a 256` fallback.                                                                                                                                                                       |
| P8  | **Safe to chain**  | Re-entrant: the action can run several times in one job, with different artifacts, after the build action, and leaves no state that changes the next run. Fixed paths are cleaned first. It never touches the caller's workspace and never overwrites a release asset. |
| P9  | **Secure**         | Inputs and step outputs reach scripts through `env:` only. Untrusted text (file names, `SHA256SUMS` lines) is escaped before it becomes a workflow command. The caller grants `id-token: write` and `contents: write` only. The only secret is `github.token`.         |
| P10 | **Tested**         | Every check has one table row proving it fails with its `failed-check` id, or is a listed review-only exception. A check no row can fail does not exist. Every bug fix has a regression row. Tests are written once.                                                   |
| P11 | **Fail loudly**    | A failure states what failed, the values involved and how to fix it, in an annotation and the job summary. `failed-check` names the check, `unexpected` otherwise. Docs list exactly the ids the code can emit.                                                        |
| P12 | **Small steps**    | One purpose and one failure id per step, named `N.x` by topic. Adding a check touches one place.                                                                                                                                                                       |

## 2. What is good and stays

- **Composite action, bash steps, logic inline.** Steps are short and read alone.
- **`SHA256SUMS` as the contract** with the build job, with a strict line regex and the `shasum -a 256`
  fallback.
- **Verification before signing**: 1.2 (file), 1.3 (file set), 1.4 (checksums). One list (`steps.sums.outputs.files`)
  feeds 1.3, signing and release.
- **`fail` helper and `failed-check` output** with the `unexpected` default; tests assert ids, never text.
- **`gh` for the release**, no `--clobber`, `--verify-tag`. No third-party release action.
- **Keyless Sigstore** through `sigstore/gh-action-sigstore-python`, pinned, with both
  `*-signing-artifacts` flags set to `false`.
- **Inputs**: `tag-name`, `dist-artifact-name`, `github-token`; output `failed-check`.
- **Test design**: one `ci-action.yaml` for the checkout and the released tag, `test/cases.json`, a
  throwaway release per job, real Sigstore verification in the `sign` job, `permissions: {}` plus
  job-level least privilege, `timeout-minutes` everywhere.

## 3. Findings

Ordered by value. Each names the property it violates.

### F1. Two runs in one job collide on `${RUNNER_TEMP}/dist` (violates P8) **(read)**

Step 1.1 downloads into the fixed path `${RUNNER_TEMP}/dist`. `actions/download-artifact` extracts into
an existing directory without clearing it, so files of the first run stay. A second invocation in the
same job (the "chain" case the README invites, for example two packages from one repository) sees the
union of both artifacts. Step 1.3 then fails with `file-set` on a valid artifact, or, worse, the
second run signs and releases leftovers that 1.2 happens to list. The same applies to `fail.sh` and
`failed-check`, which are shared and are only reset by 0.1. The current `repeat` test does not catch
this because both runs use the same artifact.

**Fix:** step 0.1 does `rm -rf` on a namespaced work directory (`${RUNNER_TEMP}/sign-pypi-package`) before
anything else, and 1.1 downloads into it. Normalise `DIST` once with `${DIST//\\//}` so Windows
paths are forward slashes in every step (this also fixes the cosmetic `${DIST##*/}` in the 1.2
message on Windows, where it does not strip a backslash path).

### F2. A failed run can leave a published release with partial assets (violates P2, P8) **(read)**

When the action creates the release itself, `gh release create` publishes it at once. If the upload
then fails (network, a missing bundle, a rate limit), the release is public with some assets or none,
and the re-run fails with `release` because assets are never overwritten. Recovery is manual. It also
does not work with GitHub **immutable releases**: assets can only be added while a release is a draft,
so any caller with that setting enabled cannot use the action on a release it creates. **(confirm in
CI)** the exact `gh` behaviour.

**Fix:** if the release is missing, create it as a draft (`--draft --verify-tag`), upload, then publish
(`gh release edit --draft=false`). On failure, delete the draft **only if this run created it** (never
`--cleanup-tag`; the tag existed before). A release that already existed is only added to, as today.
The step still has one id, `release`. See the sketch in 4.3.

### F3. `SHA256SUMS` is released but not signed (violates P3) **(read)**

Consumers who verify wheels through bundles are fine. Consumers who download `SHA256SUMS` and verify
the set with `sha256sum -c` rely on a file with no provenance: anyone with write access to the release
can swap it. The file is the contract of the whole release, so it gets the same signature as the
distributions.

**Fix:** sign `SHA256SUMS` too; attach `SHA256SUMS.sigstore.json`. _Breaking_ (one more asset). Cost:
one more signature in the same Sigstore run.

### F4. A missing bundle surfaces as `release` or as a silent gap (violates P2, P11) **(read)**

3.1 uploads `<file>.sigstore.json` for each listed file and assumes step 2.1 wrote them next to the
inputs. If the signing action changes its output naming or skips a file, the failure shows up as a
`gh release upload` error with a misleading message, and which side failed (signing or release) is
unclear.

**Fix:** a short step after signing that checks `[ -s "<file>.sigstore.json" ]` for every file in the
list plus `SHA256SUMS`, and fails with a new id `bundle`. One loop, about 8 lines. No table row can
trigger it without breaking Sigstore, so it is a listed review-only exception like 2.2 (see 5.3).

### F5. A missing `id-token: write` is found after all the work (violates P2, P5, P11) **(read)**

Without `id-token: write` the job runs the download and every check, then fails in 2.1 as `unexpected`
with Sigstore's own message. The first review listed it as a manual check because the matrix cannot
vary permissions.

**Fix:** a step right before signing (`2.1 Check signing permission`) fails with id `permissions` if
`ACTIONS_ID_TOKEN_REQUEST_URL` is empty. The runner sets it only when the job has `id-token: write`
**(confirm in CI, including that composite steps see it)**. It runs after the checks 1.x so every
existing reject row still reaches its own id. It becomes a testable check: a row in a job without
`id-token` (see 5.2).

### F6. Untrusted text is written into workflow commands with incomplete escaping (violates P9) **(read)**

`fail` replaces `\n` by `%0A` but not `%` or `\r`. Details come from the artifact: `SHA256SUMS` lines in
1.2 and file names in 1.3. The artifact is built by an earlier job and is not trusted by this action
(that is why 1.2 to 1.4 exist). The injection surface is small (the text sits after `::error title=..::`
on one line), but the escaping rule is one known function, and the summary code fence can be closed by a
line containing three backticks.

**Fix:** escape per the toolkit rules (`%` → `%25`, `\r` → `%0D`, `\n` → `%0A`) in the annotation, and
print details in the summary inside a fence longer than any fence in the text (use `~~~~~~`, or
indent the block). One regression row: `hostile-line` (a `SHA256SUMS` line with `%0A::error::x`) expects
`checksums-file`, and the annotation is checked in the `case` job by grepping the step log for exactly
one `::error` (see 5.2).

### F7. Docs disagree with the code (violates P11) **(read)**

- The `failed-check` description in `action.yml` lists `tag, checksums-file, file-set, checksum` and
  omits `release`; the README lists it. The new ids of this review (`permissions`, `bundle`) would drift
  the same way.
- The `dist-artifact-name` description in `action.yml` is a paragraph about this repository's own tests.
  It describes the input, not the project's CI.
- The README "How it works" table and the `CLAUDE.md` step list repeat the step ids by hand.

**Fix:** one list of ids, written in the README table, and the output description in `action.yml` says
"see the README table" plus the ids by name. Rewrite the input description in one sentence.
The case table is the check: every id in the README table has a row (5.1).

### F8. The success summary is thin (violates P11) **(read)**

4.1 prints the checksums but not the release link, the bundles, or the command to verify. The reader of
a green run is the person who has to announce the release.

**Fix:** add the release URL (`${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/releases/tag/${TAG}`), the
asset names, and the `uvx sigstore verify github ...` line. No extra API call.

### F9. The test suite repeats a 60-line job four times (violates P6, P10 "written once") **(read)**

`ci-action.yaml` is 431 lines. `accept`, `reject` and `repeat` differ in a few lines each (permissions,
the tag, one run or two) and repeat checkout, download, stage, upload, release create, run twice
(`local` and `released`) and delete. The `reject` job runs with `contents: read` on purpose, but that
proves little: a regression that signs before failing would still fail on permissions. A stronger proof
is to run every case with the real permissions and assert that nothing was attached.

**Fix:** one `case` job over one flat table, plus the `sign` job. See 5.2.

### F10. Test coverage gaps (violates P10) **(read)**

Missing rows for behaviours of `action.yml`:

- Release creation failure (tag not pushed): 3.1 can fail on `gh release create` and no row reaches it.
- A release the action creates: every current row uses a release that the test created, so the
  `gh release create` branch has no positive test.
- Chained runs with different artifacts (F1).
- Missing OIDC (F5), bundle check is a review-only exception (F4), hostile input (F6).

### F11. Lint baseline is red and CI hides it (violates the "run `make lint`" rule) **(ran)**

`make lint` fails today on `lint-yaml` (yamllint errors such as `line-length` in workflow files, and
warnings in `.make/`). `ci-format.yaml` runs only `lint-shell` and `lint-actions` and says in a comment
that `lint-yaml`, `lint-markdown` and `lint-makefile` "currently fail repo-wide". So CLAUDE.md requires a
command that cannot pass, and CI does not enforce it. `.make/` must not be edited, so the fix is a repo
configuration that makes `.make/` linting skippable, or a `.yamllint.yaml` override at the root, not
disabling rules for our own files (CLAUDE.md: fix what they report instead of disabling rules).
Not investigated further; it needs its own PR.

### F12. Minor

- `0.2` only rejects tags that start with `-` or contain whitespace. That is enough for `gh` argument
  safety and is kept.
- `1.2` rejects `SHA256SUMS` written with CRLF (a file written with Windows line endings) as a malformed
  line, which is correct (fail closed) but the fix text should say "use LF line endings".
- The test fixture `test/fixtures/pkg/` builds one sdist and one wheel; a second wheel would exercise
  the list handling (sorting, word splitting) with more than two files. Add one pure-Python wheel tag
  variant only if a bug appears; not worth a build step today.
- `.github/dependabot.yml` has `pip` and `uv` entries but the repository has no Python project at the
  root. They add noise only; keep only `github-actions` unless the fixture is meant to be covered.

## 4. Target design

### 4.1 Interface

| Kind   | Name                 | Description                                                                                                                                            |
| ------ | -------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| input  | `tag-name`           | Release tag. Default: the tag that triggered the run. Unchanged.                                                                                       |
| input  | `dist-artifact-name` | Artifact with the distributions and `SHA256SUMS`. Default `dist`. One-sentence description (F7).                                                       |
| input  | `github-token`       | Token for the release. Default `${{ github.token }}`. Unchanged.                                                                                       |
| output | `failed-check`       | Id of the failed check: `tag`, `checksums-file`, `file-set`, `checksum`, `permissions`, `bundle`, `release`; `unexpected` otherwise; empty on success. |

No input is renamed or removed. Behaviour changes (breaking, listed in the migration note): the extra
asset `SHA256SUMS.sigstore.json` (F3); a release the action creates is only published after all assets
are attached (F2); a missing `id-token` fails early with `permissions` instead of `unexpected` (F5).

No new input and no new output. Rejected: a `tag` or `release-url` output (nobody asked; the caller has the
tag and the summary has the URL), a `publish` input (F2 behaviour is the only sensible one).

### 4.2 Steps (12 steps, was 10)

| Step | Name                        | Failure id       | Change vs. today                                                    |
| ---- | --------------------------- | ---------------- | ------------------------------------------------------------------- |
| 0.1  | Define failure helper       |                  | also `rm -rf` the work directory; complete escaping (F1, F6)        |
| 0.2  | Resolve tag                 | `tag`            | unchanged                                                           |
| 1.1  | Download distributions      | `unexpected`     | into `${RUNNER_TEMP}/sign-pypi-package` (F1)                        |
| 1.2  | Check `SHA256SUMS`          | `checksums-file` | unchanged; CRLF hint                                                |
| 1.3  | Check distribution file set | `file-set`       | unchanged                                                           |
| 1.4  | Verify checksums            | `checksum`       | unchanged                                                           |
| 2.1  | Check signing permission    | `permissions`    | new (F5)                                                            |
| 2.2  | Sign with Sigstore          | `unexpected`     | inputs now include `SHA256SUMS` (F3)                                |
| 2.3  | Check signature bundles     | `bundle`         | new (F4)                                                            |
| 3.1  | Attach to release           | `release`        | draft, upload, publish, cleanup of a draft created by this run (F2) |
| 4.1  | Write job summary           |                  | URL, assets, verify command (F8)                                    |
| 4.2  | Report failed check         |                  | unchanged                                                           |

Steps 2.2 and 1.1 are third-party, so they can only end in `unexpected`; 2.3 is a guard on a third-party
output. See 5.3.

### 4.3 Sketches

Untested; they show the shape, not text to paste. Confirm in CI.

```bash
# 0.1 (written to ${RUNNER_TEMP}/fail.sh, sourced by later steps)
rm -rf "${RUNNER_TEMP}/failed-check" "${RUNNER_TEMP}/sign-pypi-package"
fail() { # id, title, details, how to fix
  local msg="${3//'%'/%25}"
  msg="${msg//$'\r'/%0D}"
  msg="${msg//$'\n'/%0A}"
  echo "$1" >"${RUNNER_TEMP}/failed-check"
  echo "::error title=$2::${msg}"
  printf '### :x: %s\n\n~~~~~~text\n%s\n~~~~~~\n\n**How to fix:** %s\n' "$2" "$3" "$4" >>"${GITHUB_STEP_SUMMARY}"
  exit 1
}

# 2.1 (before the Sigstore step; no network call)
[ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] || fail permissions "Cannot sign: no OIDC token" \
  "The job has no id-token permission." "Add 'permissions: id-token: write' to the job."

# 2.3 (DIST, FILES from env; names are plain, see 1.2)
cd "${DIST}" || exit
for f in SHA256SUMS ${FILES}; do # shellcheck disable=SC2086
  [ -s "${f}.sigstore.json" ] || fail bundle "Missing signature bundle" "${f}.sigstore.json was not written." \
    "Check the Sigstore signing step above."
done

# 3.1 (TAG, FILES from env; created=1 only when this run made the release)
created=0
if ! gh release view "${TAG}" >/dev/null 2>&1; then
  gh release create "${TAG}" --draft --verify-tag --title "${TAG}" --notes "" ||
    fail release "Cannot create release ${TAG}" "gh release create failed." "Push the tag first; the token needs contents: write."
  created=1
fi
# shellcheck disable=SC2086
if gh release upload "${TAG}" SHA256SUMS SHA256SUMS.sigstore.json ${FILES} $(printf '%s.sigstore.json ' ${FILES}) &&
  { [ "${created}" = 0 ] || gh release edit "${TAG}" --draft=false; }; then
  :
else
  [ "${created}" = 0 ] || gh release delete "${TAG}" --yes # a draft: never touches the tag
  fail release "Cannot attach assets to ${TAG}" "gh failed; an asset may already exist (assets are never overwritten)." \
    "Fix the cause and re-run; a release created by this run was removed."
fi
```

The signing step gets `inputs: ${{ steps.sums.outputs.inputs }}` with `SHA256SUMS` appended in 1.2. A
step output in `with:` is not script interpolation, so P9 holds.

## 5. Tests and repository

### 5.1 Case table (one flat list)

`test/cases.json` becomes one list. A row: `name`, `stage` (mutates a copy of the good `dist/`),
`expected` (`""` = accepted), and optional `released`, `tag` (`new` default, `none`, `missing`), and
`runs` (`1` default, `2`). The OS matrix for the valid case still comes from `lib-get-test-matrix.yaml`.

| Case                     | Stage / setup                                                      | Expected `failed-check`  | New |
| ------------------------ | ------------------------------------------------------------------ | ------------------------ | --- |
| `valid` (3 OSes)         | none (the `sign` job)                                              | empty, bundles verify    |     |
| `binary-mode-entry`      | rewrite `SHA256SUMS` with `-b`                                     | empty                    |     |
| `action-creates-release` | `tag: new-unreleased` (no pre-created release)                     | empty, release published | yes |
| `tampered-file`          | append to the sdist                                                | `checksum`               |     |
| `missing-sums`           | delete `SHA256SUMS`                                                | `checksums-file`         |     |
| `empty-sums`             | truncate `SHA256SUMS`                                              | `checksums-file`         |     |
| `malformed-line`         | line without a hash                                                | `checksums-file`         |     |
| `path-traversal`         | list `../x.whl`                                                    | `checksums-file`         |     |
| `duplicate-entry`        | list the wheel twice                                               | `checksums-file`         |     |
| `disallowed-extension`   | list a `.zip`                                                      | `checksums-file`         |     |
| `hostile-line`           | line containing `%0A::error::x` and three backticks                | `checksums-file`         | yes |
| `unlisted-file`          | copy the wheel under another name                                  | `file-set`               |     |
| `planted-bundle`         | add `evil.sigstore.json`                                           | `file-set`               |     |
| `subdirectory`           | add `dist/sub/`                                                    | `file-set`               |     |
| `listed-file-absent`     | delete the wheel, keep its entry                                   | `file-set`               |     |
| `no-tag`                 | `tag: none`                                                        | `tag`                    |     |
| `tag-not-pushed`         | `tag: missing` (tag does not exist)                                | `release`                | yes |
| `second-run`             | `runs: 2`, same tag                                                | `release`                |     |
| `chained-runs`           | `runs: 2`, new tag, second artifact only sdist (regression for F1) | empty                    | yes |
| `no-oidc`                | the `permissions` job (5.2)                                        | `permissions`            | yes |

Every reject row also asserts that the release has no assets after the run (or does not exist), which
proves that nothing was signed or attached before the failure.

### 5.2 Workflows

```text
ci.yaml                 unchanged
nightly.yaml            unchanged
lib-get-test-matrix.yaml unchanged
ci-action.yaml          build, sign (OS matrix), case (matrix over test/cases.json), permissions
ci-format.yaml          runs make lint once F11 is fixed
test/cases.json         one flat list
scripts/test-helper.sh  + assert_no_assets, assert_single_error; assert_failure/assert_success removed
```

- **`build`**: unchanged, plus the `released` filter in `jq`.
- **`sign`**: unchanged.
- **`case`** (one matrix job, `id-token: write` and `contents: write`, `ubuntu-latest`): download
  `dist-base`, run `stage`, upload `dist-<case>`, create the throwaway release unless `tag != new`
  or the case is `action-creates-release`, run the action once or twice, assert the id with
  `assert_failed_check`, assert no assets on rejected rows, always delete the release. It replaces
  `accept`, `reject` and `repeat` (about 250 lines fewer). The extra permissions are acceptable
  because the job runs the repository's own code on pushes and pull requests of the repository, as the
  `sign` job already does.
- **`permissions`** (one small job, `contents: read` only): runs the action on the valid dist and
  asserts `permissions`. It is the only job that cannot share `case`, because permissions are per job.
- The action is still invoked with two `uses:` steps (`if: !inputs.released` and `if: inputs.released`),
  read with `steps.local.outputs.x || steps.released.outputs.x`, as in the build action.
  With a single flat job that is 4 steps instead of 10 pairs.

At the next release: bump the pinned SHA and ratchet comment in `ci-action.yaml`, flag the rows the new
version supports with `"released": true` (all but the new ones), delete `assert_failure`/`assert_success`
and the `released` branches of the assertion steps (the released tag then has `failed-check`), and drop
the extra `dist` upload of the `build` job.

### 5.3 Review-only exceptions

Listed under "Tests" in `CLAUDE.md`; add to it:

- 1.1 artifact download and 2.2 Sigstore signing (third-party, `unexpected`).
- 2.3 bundle check: Sigstore cannot be made to succeed without writing the bundle, so no row can fail
  it. It is an eight-line guard against a signing-action change. If a row becomes possible
  (for example a stub signing action), move it into the table.
- 3.1 draft publish failure and cleanup path: GitHub cannot be made to fail on demand; covered by
  `second-run` for the cleanup condition (`created=0`: nothing is deleted) and by reading for `created=1`.

### 5.4 Documentation

- **README:** one table of ids (the single source for F7), the `permissions` and `bundle` ids, the extra
  `SHA256SUMS.sigstore.json` asset, "a release created by the action is a draft until all assets are
  attached; with immutable releases enabled, let the action create the release", a re-run note, and a
  migration section for the next tag.
- **CLAUDE.md:** step list `0.1 .. 4.2` updated (2.1 permission, 2.2 sign, 2.3 bundles), the row schema
  (`tag`, `runs`), the new review-only exceptions, and a fix for the `make lint` rule once F11 is solved.
  Mentions of "mirror `cancel-queued-runs-action`" should also name `build-pypi-package-action`, which is
  the real sibling.
- **Release notes of the next tag:** extra asset, draft-then-publish, new ids.

## 6. Considered and rejected

- **Sign only `SHA256SUMS`** (one signature instead of one per file). Fastest, but consumers and tools
  such as `sigstore verify` expect a bundle per file, and PyPI attestations are per file. Per-file
  bundles plus a signed `SHA256SUMS` is only one more signature.
- **A `publish: false` input or `draft` output** for people who want to review the release. Nobody asked,
  and a draft left by the action when something fails is the thing F2 removes.
- **`--clobber` on re-run.** A consumer may already have downloaded an asset. Failing is the safe default.
- **Verifying the bundles inside the action** (`sigstore verify`). One more network call per run for
  every caller; signing already fails closed, and the `sign` test verifies the bundles with a pinned
  identity.
- **`uses: ./action` with a second checkout for the released tag** instead of two `uses:` steps. It
  removes the pairs but no longer tests how users resolve the action, and it breaks the alignment with
  the build action.
- **Moving the checks to `scripts/verify-dist.sh`.** Faster local feedback, but a second mechanism next to
  the table, and it breaks "all logic inline". Revisit only if the checks grow past about 15 lines.
- **Merging 1.2, 1.3 and 1.4 into one step** to save about two seconds of step overhead: it breaks "one
  failure id per step" for little gain.
- **A `tag` or `release-url` output.** See 4.1.

## 7. Properties check

| #   | Met by                                                                                                                                              |
| --- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| P1  | Same five responsibilities; only `SHA256SUMS` gets a bundle too. No build, no PyPI, no notes.                                                       |
| P2  | 0.2, 1.x, 2.1 all before the first network write; F2 removes the half-released state; reject rows assert nothing was attached.                      |
| P3  | One list from 1.2, confirmed by 1.3, signed in 2.2 with `SHA256SUMS`, checked by 2.3, released in 3.1.                                              |
| P4  | One third-party signing action, pinned; `gh` and `shasum` from the image. **(confirm)** whether the signing action pins its own `sigstore` version. |
| P5  | Tag, checksums and permission are local checks; one signing run; no checkout or upload.                                                             |
| P6  | All inline; steps of 8 to 20 lines; three inputs, one output; tests shrink from four near-identical jobs to one.                                    |
| P7  | Bash only; `shasum` fallback; Linux and macOS in the `valid` matrix.                                                                                |
| P8  | Work directory removed in 0.1 and namespaced (F1); `chained-runs` row; no `--clobber`; only a draft created by this run is ever deleted.            |
| P9  | `env:` for every input; complete escaping (F6) with a hostile-input row; permissions documented.                                                    |
| P10 | 20 rows, one per failure reason, bug-fix rows for F1 and F6; exceptions listed in 5.3.                                                              |
| P11 | One id table in the README, same ids in `action.yml`; success summary with URL, assets and verify command.                                          |
| P12 | Twelve steps, `N.x` names, one id each.                                                                                                             |

## 8. Migration order

One PR per logical change, branched from `main`, each with its test rows.

| Order | Branch                            | Content                                                                          | Breaking                |
| ----- | --------------------------------- | -------------------------------------------------------------------------------- | ----------------------- |
| 1     | `bugfix/reentrant-work-dir`       | F1: namespaced work dir, `rm -rf` in 0.1, `chained-runs` row                     | No                      |
| 2     | `bugfix/escape-workflow-commands` | F6: escaping, fence, `hostile-line` row, `assert_single_error`                   | No                      |
| 3     | `feat/signing-guards`             | F4, F5: steps 2.1 and 2.3, `permissions` job and id                              | No (new id)             |
| 4     | `feat/sign-checksums-file`        | F3: sign and attach `SHA256SUMS.sigstore.json`; test and `assert_release_assets` | Yes (new asset)         |
| 5     | `feat/draft-then-publish-release` | F2: draft, publish, cleanup; `action-creates-release`, `tag-not-pushed` rows     | Yes (timing of publish) |
| 6     | `test/single-case-job`            | F9, F10: one `case` job and flat `test/cases.json`; no-assets assertion          | No                      |
| 7     | `docs/ids-summary-and-claude-md`  | F7, F8: one id table, success summary, README and CLAUDE.md                      | No                      |
| 8     | `ci/make-lint-green`              | F11: make `make lint` pass and run it in `ci-format.yaml`                        | No                      |

Release 1 to 7 together as the next exact tag (for example `v0.1.0`) with the migration note. No
floating tags. PR 6 could go first because the new rows of 1 to 5 are one-line additions there; do it
first if the four-job duplication slows the work.

## 9. What was not done

- Nothing was implemented and nothing was run on GitHub; every **(confirm in CI)** is open.
- F1, F2, F4, F5 and F6 are derived from reading the code and the documented behaviour of
  `actions/download-artifact`, `gh` and the runner, not from a failing run. The sketches in 4.3 are
  untested. The `make lint` result in F11 is the only thing that was executed.
- The behaviour of `sigstore/gh-action-sigstore-python` (bundle naming, whether it pins `sigstore`) was
  not read in its source for this review.
- `build-pypi-package-action` was not re-read; the properties are carried over from the first review.
