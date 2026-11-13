# Testing the action without GitHub releases

Review of `main` at `226db82`. Nothing here is implemented, and no workflow is changed by this document.
Claims are marked **(read)** when derived from reading code or documented tool behaviour, and
**(confirm in CI)** when a GitHub run must prove them before the change is trusted. Nothing was executed.

## 1. Problem

`ci-action.yaml` creates a draft release per job (`create_draft_release`), runs the action against it, then
deletes it in an `if: always()` step. This works, but it has costs:

- **Real state on the real repository.** A crashed or cancelled job can leave a draft or a `ci-*` tag
  behind. `make clean-throwaway-releases`, the `(throwaway, will be deleted)` title marker and the
  "never publish" rule in `CLAUDE.md` exist only to manage this.
- **Broad permissions.** The `sign` and `case` jobs need `contents: write`, even though the tests only
  need to observe what the action would do.
- **Scaffolding that is not the action.** Tag kinds (`new`, `same`, `draft`, `missing`), the two-tag logic of
  the setup step (`tag2`, the `prev` guard against HTTP 422), the cleanup step and four release assertions
  (`assert_no_release`, `assert_no_assets`, `assert_release_draft`, `create_/delete_release`) are all there
  to prepare and clean up a release.
- **Network flakiness unrelated to the action.** Release API calls can rate-limit or fail.

`durandtibo/build-pypi-package-action` has none of this because it never signs or releases: its tests build
fixture packages and assert on the produced files. This action cannot copy that approach as is, because
its output is a release. But only one step touches the release.

## 2. Where the release is touched

Reading `action.yml`: of the steps, only **3.1** (`gh release view/create/upload/edit/delete`) and the
link in **4.1** involve a release. Steps 0.1 to 2.3 (tag, download, `SHA256SUMS`, file set, checksums,
permission, signing, bundles) need a runner, the artifact service and OIDC, but **no release**. (read)

So the testing question is not "how do we avoid releases altogether" but "what stands in for `gh` in 3.1
while everything before it stays real".

## 3. Proposal: a fake `gh` over a local directory

Run the real action, with real Sigstore signing, but put a fake `gh` first on `PATH`. The fake keeps its
"releases" as directories on the runner. The tests then assert on that directory instead of on GitHub.

### 3.1 The fake

One script, `test/fake-gh/gh`, that implements exactly the calls `action.yml` makes and the ones the
assertions need, over a store directory `$FAKE_GH_ROOT`:

```text
$FAKE_GH_ROOT/tags                 one existing tag per line (what `git push` of a tag would have made)
$FAKE_GH_ROOT/<tag>/state          "draft" or "published"
$FAKE_GH_ROOT/<tag>/assets/<name>  the uploaded files
$FAKE_GH_ROOT/calls.log            one line per call, for assertions
```

| Call                               | Behaviour                                                                                       |
| ---------------------------------- | ----------------------------------------------------------------------------------------------- |
| `release view <tag>`               | exit 0 if `<tag>/` exists, 1 otherwise                                                          |
| `release create <tag> --draft …`   | fails if `--draft` is absent, or with `--verify-tag` and the tag is not in `tags`; else creates |
| `release upload <tag> <file>…`     | fails if the release is missing, or if **any** asset already exists (no `--clobber` support)    |
| `release edit <tag> --draft=false` | sets `state` to `published`                                                                     |
| `release delete <tag> --yes`       | removes `<tag>/`, never the line in `tags`; fails on `--cleanup-tag`                            |
| anything else                      | exit 99 with `unexpected gh call`, as the current stub in `scripts/test-steps.sh` does          |

This is the stub of `scripts/test-steps.sh` (step 3.1 section), made stateful instead of driven by
`STUB_*=1` switches. The same file then serves both `make test-local` and the end-to-end workflow, so there
is one description of "what `gh` does" in the repository.

Why stateful matters: today the "no overwrite" property is tested end to end by a second run hitting a real
release (`runs: 2`, `tag: same`). With the fake, the same row passes or fails on the same rule, enforced by
the fake, with no network. The properties the current rows check (a rejected run leaves no asset, a
pre-existing draft stays a draft, the action never publishes a release it did not create, nothing is
published if the upload fails) all become observable from `state`, `assets/` and `calls.log`. (read)

### 3.2 Putting it in front of the action

A workflow step before the action:

```yaml
- name: Use a fake gh
  shell: bash
  run: |
    root="${RUNNER_TEMP}/fake-gh-root"
    mkdir -p "${root}"
    echo "${GITHUB_WORKSPACE}/test/fake-gh" >>"${GITHUB_PATH}"
    echo "FAKE_GH_ROOT=${root}" >>"${GITHUB_ENV}"
```

Entries added to `GITHUB_PATH` apply to all later steps of the job, composite action steps included, and
`GITHUB_ENV` likewise. (read, **confirm in CI** on both Linux and macOS.) The composite action needs no
change: step 3.1 already calls plain `gh`. This is also why `GH_TOKEN` is irrelevant: the fake ignores it,
so the jobs can drop `contents: write` and keep `id-token: write` only (plus `actions: read` while the
artifact wait step exists).

One guard against the fake silently not being used: the first assertion of every job checks that
`calls.log` exists and is non-empty for an accepted run. If `PATH` did not take effect, the action would have
called the real `gh` and the job would fail on `contents: read` instead of passing by accident.

### 3.3 Mapping the current cases

The `tag` field of `test/cases.json` keeps its meaning but becomes a seed for the store, written by a small
`seed_fake_release <kind> <tag>` helper, instead of a call to the API:

| Kind            | Today                       | With the fake                                                           |
| --------------- | --------------------------- | ----------------------------------------------------------------------- |
| `new`           | draft release exists        | `tags` has the tag; `<tag>/state` = `draft`                             |
| `same`          | as `new`, second run reuses | as `new`; the second run uploads again and must fail on existing assets |
| `draft`         | draft must stay a draft     | as `new`; assert `state` is still `draft`                               |
| `missing`       | no tag, no release          | `tags` empty, no `<tag>/`; the run fails with `release`                 |
| `none`          | `tag-name` unset            | unchanged (no seed)                                                     |
| `dash`, `space` | invalid tag name            | unchanged (no seed)                                                     |

`create_draft_release`, `delete_release`, the `tag2`/`prev` logic, the "Delete throwaway draft releases"
steps and `assert_no_release` (replaced by "`<tag>/` is absent in the store") go away. `assert_release_matches_dist`
and `assert_release_verifies` keep their logic but read `$FAKE_GH_ROOT/<tag>/assets` instead of calling
`gh release view/download`, so they get simpler too.

### 3.4 What stays real

Everything the action is for, except the last hop:

- real artifact upload and download (steps 1.1 and the case staging),
- real Sigstore keyless signing with the job's OIDC token, and `sigstore verify github --repository`
  against the bundles of the store (`assert_sigstore_valid` is unchanged),
- real `SHA256SUMS` checks on Linux and macOS,
- the `permissions` job, which needs no release at all.

Signing writes entries to the public Rekor log, as it does today. That is already the case and does not
change. Sigstore's staging instance would avoid it, but `action.yml` does not expose `staging`, and
`sigstore verify` would then need `--staging` too, so it is not worth a change here.

## 4. What the fake cannot catch, and how to cover it

A fake only proves the action uses `gh` the way the fake says `gh` works. The remaining risk is that the
real `gh` differs: a renamed flag, `--verify-tag` semantics, `release upload` on an immutable release, the
draft-then-publish behaviour. The current design catches this on every run. Options, cheapest first:

1. **Flag contract check** (recommended, cheap, offline): in `make test-local` assert that
   `gh release create --help` mentions `--draft` and `--verify-tag`, and `gh release upload --help`
   mentions `--clobber` (the flag the action must never pass). This catches renames, not semantics. (read)
2. **One real smoke job, nightly only**, not on pull requests: create a draft release, run the real
   action on it, delete it, as today but for a single happy path on Linux. It keeps the existing helpers
   (`create_draft_release`, `delete_release`) and the "drafts only, never public" rule. Failures there do
   not block merges and the leftover risk is bounded to one draft a night.
3. **Accept the gap.** The first real release of a new tag is itself the real test of 3.1, and the README
   tells users how to recover from a failed one.

Recommendation: 1, plus 2 if the first real-world failure shows the fake drifted. Do not keep real
releases in the pull request path.

## 5. Generating the builds

The inputs are already generated, not committed: the `build` job runs `uv build test/fixtures/pkg` and
`sha256sum`, and each case stages a modified copy (`stage` snippet in `test/cases.json`). That is the
approach of the sibling action and it should stay: it keeps binary files out of the repository and exercises
the real sdist/wheel naming. No change proposed, except one addition:

- **Contract test with the sibling action.** `build-pypi-package-action` produces the `dist` artifact
  and `SHA256SUMS` this action consumes. Today the tests deliberately build with plain `uv build` to stay
  independent, so a change to the sibling's output format would go unnoticed until a user hit it. Add one
  job to `nightly.yaml`: build the fixture with the sibling pinned to a SHA (ratchet comment as usual),
  then run this action (`uses: ./`) on its artifact with the fake `gh`, and assert the store holds the files
  and verifying bundles. One job, one happy path, not a copy of the case table. The sibling's artifact name
  and the build layout (it expects the package at the repo root) need to be read from its `action.yml` when
  this is written. (confirm in CI)

## 6. Resulting test layers

| Layer                        | Runs where              | Needs                  | Covers                                                          |
| ---------------------------- | ----------------------- | ---------------------- | --------------------------------------------------------------- |
| `make test-local`            | laptop, `ci-shell.yaml` | nothing                | each step in isolation, table rows without signing, consistency |
| `ci-action.yaml` (fake `gh`) | Linux and macOS runners | OIDC, artifact service | the whole action, real signing, byte-identical assets, verify   |
| nightly sibling contract     | Linux runner            | OIDC, artifact service | the `dist` contract between the two actions                     |
| nightly real smoke (option)  | Linux runner            | `contents: write`      | real `gh` behaviour on one happy path                           |

The first row already exists. The second is today's workflow with the release scaffolding replaced.

## 7. Migration, in small PRs

Each PR is independent and leaves CI green. The `CLAUDE.md` "Tests" section must change with PR 2.

1. **Fake `gh`.** Add `test/fake-gh/gh`; make `scripts/test-steps.sh` use it instead of its inline stub
   (the `release_case` table stays the same, `STUB_*` become seeds). Add the help-text contract check.
   Verifiable locally: `make test-local`.
2. **Switch `ci-action.yaml`.** Add the "Use a fake gh" step, `seed_fake_release`, the store-based
   assertions; drop `contents: write`, the create/delete steps and `tag2`. Keep the `released: true`
   path working: the pinned `v0.0.1` also calls plain `gh`, so the fake applies to it too. (confirm in CI)
   Update `CLAUDE.md` (release/throwaway rules) and the header comment of the workflow.
3. **Retire the release plumbing.** Remove `create_draft_release`, `delete_release`,
   `clean-throwaway-releases`, and the throwaway wording, unless the nightly smoke job of section 4 keeps them.
4. **Nightly additions.** The sibling contract job, and the real smoke job if chosen.

## 8. Risks and open questions

- **`GITHUB_PATH` on a composite action** is documented to work but is the single mechanism the whole
  proposal depends on. Prove it with a throwaway job first (PR 2 can start with that alone). (confirm in CI)
- **Fake drift.** Mitigated by section 4; the fake is small (about 40 lines) and shared with the local tests.
- **`released: true`.** The released `v0.0.1` has fewer checks, but its release step is the same `gh`
  usage, so it should run against the fake unchanged. Not verified: its `action.yml` was not re-read for this review.
- **Decision for the maintainer:** keep a real-release smoke job nightly (section 4, option 2) or rely on
  the flag check alone (option 1)? The rest of the proposal does not depend on the answer.
