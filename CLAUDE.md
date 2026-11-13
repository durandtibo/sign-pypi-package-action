# CLAUDE.md

Guidance for coding agents working in this repository.

## Repository purpose

A GitHub composite action (`action.yml`) that signs Python package distributions with Sigstore and
attaches them, with their signatures, to a GitHub release. It downloads the `dist` artifact, verifies
`SHA256SUMS` (failing closed on mismatches or unlisted files), signs with keyless OIDC and attaches
everything to the release with `gh` (assets are never overwritten). The logic lives inline in `action.yml`
(bash steps that must work on Linux and macOS runners (Windows is not supported)), in steps named `N.x` by topic:
`0.1` failure helper, `0.2` tag, `1.1` download, `1.2` SHA256SUMS, `1.3` file set, `1.4` checksums,
`2.1` signing permission, `2.2` sign, `2.3` bundles, `3.1` release, `4.1` summary, `4.2` report. One purpose and one failure id per step. End-to-end testing is done by
workflows against throwaway draft releases (see "Tests"), using the fixture package in `test/fixtures/pkg/`, the shared
assertions and fakes in `scripts/test-helper.sh`, and the fake `gh` in `test/fake-gh/`. None is part of the action itself.

## Environment

- Use the `Makefile`; run `make help` to list targets.
- Do not edit `.make/`: it is a shared directory synced by `bot-sync-shared-makefile.yaml`.
- Run `make format` and `make lint` before committing; both pass on `main` and CI runs both. Fix what
  they report instead of disabling rules. The few tool settings that cannot fit prettier-formatted
  GitHub files (`.yamllint.yaml`, `.markdownlint.yaml`, `checkmake.ini`) live at the repository root,
  since `.make/` must not be edited; do not add to them to silence a real finding.
- The end-to-end tests (`ci-action.yaml`) need GitHub runners, OIDC and release
  permissions, so they cannot be run locally; say so in the PR instead of claiming they pass.

## Git workflow

- One branch and one PR per logical change, branched from an up-to-date `main`. Never commit or
  push to `main`.
- Name branches `<type>/<short-description>` in kebab-case, with type one of: `feat`, `bugfix`,
  `hotfix`, `docs`, `refactor`, `perf`, `test`, `chore`, `ci`.
- PR descriptions cover what changed, what was deliberately left alone, and any behaviour change.
- On conflicts with `main`, merge `origin/main` into the branch; do not rebase and force-push.
- Update `README.md` when inputs, behaviour, or workflows change.
- Releases are immutable exact version tags (`v0.0.1`, ...). Do not create or move floating tags
  (`v1`, `latest`) and do not document them as an option.

## Action rules (`action.yml`)

- Keep input names, defaults, and descriptions consistent with `README.md`. Renaming or removing
  an input is a breaking change and must be flagged.
- The README table of steps is the one list of `failed-check` ids: `action.yml` only points to it, so
  a new id is added there, and every id except the review-only ones has a row in `test/cases.json`.
- Pass inputs to scripts through `env:`, never by interpolating them in `run:`.
- Every `run:` step sets `shell: bash`.
- Pin third-party actions (in `action.yml` and workflows) to commit SHAs with a
  `# ratchet:<owner>/<repo>@<tag>` comment, never to tags or branches.
- Keep the checksum verification fail-closed: every `*.tar.gz`/`*.whl` must be listed in
  `SHA256SUMS` and match it, and nothing unlisted may reach the signing step.
- Stay portable: `sha256sum` is missing on macOS, so keep the `shasum -a 256` fallback.
- Workflows use least-privilege `permissions` and set `timeout-minutes` on jobs.

## Shell rules (`scripts/test-helper.sh` and `run:` blocks)

- Quote all variables; validate inputs early with clear `::error` messages.
- Keep shared assertions as small functions in `scripts/test-helper.sh` so the local and stable test
  workflows differ only in which action ref they exercise, not in verification logic.
- Code must pass `shellcheck` and `shfmt` via `make lint` / `make format`.

## Workflow structure (`.github/workflows/`)

- `ci.yaml`: entry point for pull requests, pushes to `main`, a nightly schedule and manual runs. It
  holds no steps, only jobs that call the reusable workflows below.
  - `lib-get-test-matrix.yaml`: loads the OS (and Python version) lists from
    `durandtibo/workflow-config-action` once and passes them down as `test-matrix`.
  - `ci-format.yaml`: the format check (`make format`, no diff allowed) and the whole `make lint`.
  - `ci-shell.yaml`: runs `make test-local` and the escaping assertion of the `fail` helper on
    Linux/macOS, from the same `test-matrix`.
  - `ci-action.yaml`: the integration tier, with `released` and `real-release` inputs. `released: false`
    tests this checkout (`uses: ./`), `released: true` the pinned last release. The `sign` job covers
    Linux/macOS with the fake `gh`; the `release` job is the real-release contract test (skipped when
    `real-release` is false); the `case` job is a matrix over the `"integration"` rows of
    `test/cases.json`; the `permissions` job has no `id-token`.
  - `changes` (a job of `ci.yaml`, not a workflow): sets `real-release` to false for pull requests that
    touch nothing that could make the fake `gh` drift from the real one (see "Tests").
- `nightly.yaml`: scheduled entry point (and manual runs) calling `ci-action.yaml` with
  `released: true`, to catch regressions in what users run today.
- `ci-verify-workflows.yaml`: lints the workflow files themselves. It has its own triggers and is not
  called from `ci.yaml`, so it can be a required check.
- `security-dependency-review.yaml`: dependency review on pull requests.
- `bot-*.yaml`: scheduled automation (pin actions, sync `.make/`, format files, cancel stale queued runs).
- `security-scorecard.yaml`: OSSF Scorecard analysis (needs the `TIBOT_*` GitHub App secrets).
- `.github/dependabot.yml` keeps the GitHub Actions dependencies up to date (the repository has no Python project at the root, so no pip or uv entries).

The workflow names and structure mirror `durandtibo/cancel-queued-runs-action` and
`durandtibo/build-pypi-package-action` (the sibling action that builds the `dist` artifact and
`SHA256SUMS` this one consumes); keep them aligned.

Conventions:

- Every workflow has `permissions: {}` at the workflow level; give jobs the narrowest permissions they need, including jobs that call a reusable
  workflow.
- Reusable workflows that need no input also have `workflow_dispatch`, so they can be run alone;
  `ci-action.yaml` takes the `test-matrix`, `released` and `real-release` inputs from its caller.
- Put `make` targets in the steps rather than duplicating commands, so local runs and CI match.
- Start each file with a comment saying what it does, and update it when the behaviour changes.
- When a released tag is bumped, update the pinned SHA and ratchet comment of the released action in `ci-action.yaml`,
  flag the rows of `test/cases.json` the new version supports with `"released": true`, and delete the
  helpers that only existed for the old tag.

## Tests

- There are two tiers. The unit tier (`make test-local`, below) runs every row of `test/cases.json`
  against fakes, makes no GitHub API call and is where every behaviour and edge case of `action.yml`
  must be covered. The integration tier (`ci-action.yaml`) has few jobs and covers only what needs the
  real services: the artifact download, Sigstore signing and verification, the missing `id-token`
  permission and the real `gh` (the contract test of the fake). It also runs against the released tag
  for the rows flagged `"released": true`. Do not add a job per row or a call to the GitHub API to the
  integration tier: the token has a rate limit shared by all runs (`HTTP 403: API rate limit exceeded`),
  so a new edge case is a row of the unit tier.
- Every check calls `fail <id> ...` and has a row in `test/cases.json` with the expected
  `failed-check` id. A new case is one row: `name`, a `stage` snippet that mutates a copy of the good
  `dist/`, `expected` (`""` = accepted), and optionally `released`, `runs` (`2` runs the action twice)
  `artifact` (download another artifact than the staged one, with `"integration": true`) and `tag` (`new` default, `same`,
  `missing`, `none`, `dash`, `space`, `draft`), and the `local` fields below. A rejected single run
  must also leave no asset on the release, and an accepted run must leave exactly the expected assets,
  byte-identical to the dist (`assert_fake_release_matches_dist`; `assert_release_matches_dist` for the
  real release of the `release` job). The `case` job of `ci-action.yaml` runs only the rows flagged
  `"integration": true`, which name an `artifact` to download and must be rejected before any release
  call, so that job needs no release, no `gh` and no staging.
- Never create public releases or tags in tests: they are permanent noise on the repository's releases
  and tags pages. Only the `release` job of `ci-action.yaml` creates a release, a draft
  (`create_draft_release`: visible to writers only, no tag), and deletes it in an `if: always()` step. The title of every throwaway
  release must include `(throwaway, will be deleted)`, which `make clean-throwaway-releases` matches. Behaviour that needs a real tag, such as the action
  creating and publishing a release, is tested in the unit tier against the fake `gh`. Do not
  add a test that pushes a tag or publishes a release; `make clean-throwaway-releases` only removes
  the old ones.
- Tests assert the `failed-check` id, never the message text.
- The escaping of `fail` (annotation and summary) is tested locally and in `ci-shell.yaml` by
  `assert_fail_helper_escapes`, which runs the helper extracted from `action.yml` on hostile text.
- Review-only exception: step 2.2 (Sigstore signing) is third-party and can only end in `unexpected`.
  Step 1.1 (artifact download) is covered by the `missing-artifact` row.
- The `sign` job runs the action with the fake `gh` (`use_fake_gh`: a release in a local store, no API
  call, no `contents: write`) and the real download and signing, and also checks what a consumer does:
  the assets of the release verify with their bundles (`assert_fake_release_verifies`). The `release` job
  does the same with a real draft release (`assert_release_verifies`), on Linux for this checkout and on
  every OS for the released tag: `v0.0.1` attaches with `softprops/action-gh-release`, which calls the API
  and not `gh`, so the fake cannot stand in for it and `sign` is skipped for it. The `release` job is
  skipped on pull requests that change none of `action.yml`, `test/fake-gh/`, `test/fixtures/`,
  `scripts/test-helper.sh`, `scripts/fake-runner.sh` or the workflows that run them (the `changes` job of
  `ci.yaml`).
- `make test-local` is the unit tier. It needs no runner and makes no API call, and has two parts.
  `scripts/test-local.sh` runs every row of the table through the whole action with
  `scripts/fake-runner.sh`: the real steps, extracted from `action.yml`, run in order against a fake
  artifact download, a fake signer, the fake `gh` and a set or unset OIDC token. It asserts the id, the
  assets of the fake release (byte-identical to the dist), that a rejected run attached nothing and left
  no release it created, that drafts stay drafts, that no tag is created or removed and that a check
  before the release made no `gh` call. Rows flagged `"integration": true` need the real artifact
  service and are left to `ci-action.yaml`. `scripts/test-steps.sh` runs the extracted steps in
  isolation: 0.1, 0.2 (including output injection), 1.2 outputs, 1.4 with the `shasum` fallback, 2.1,
  2.3, 3.1 against the fake `gh` of `test/fake-gh/` (draft creation, publish, deletion of a draft created
  by the run, nothing deleted when the release pre-existed, never `--cleanup-tag` or `--clobber`, no tag
  created), 4.1 and 4.2, the fake itself and the `gh` flags it models. It also checks that the ids of
  `action.yml`, the README table, the output description and `test/cases.json` agree, that every `run:`
  sets `shell: bash` and has no `${{ }}`, and that every `uses:` is pinned. A new step or id needs its
  test there.
- Rows that need the fakes are flagged `"local": true` and are not run by `ci-action.yaml`: the tag kinds
  `published` (a published release exists) and `tagged` (the tag is pushed and there is no release, so the
  action creates and publishes one: a public release that the end-to-end tests must never make), and the
  fields `gh-fail` (a verb of the fake `gh` that fails), `sign` (a mode of `fake_sigstore_sign`), `oidc`
  (`false` = no `id-token`) and `ref` (`tag` = a tag push without the `tag-name` input).
- Step 2.1 (`permissions`) cannot be tested for real in the `case` job, because permissions are per job:
  the integration tier has its own `permissions` job without `id-token`. The unit tier has the
  `no-id-token` row.
- Reuse the assertions in `scripts/test-helper.sh` rather than inlining new verification logic.
- `test/fake-gh/fake-gh.sh` (the `gh` symlink next to it) is a stateful fake of the `gh release` calls of
  `action.yml` over a directory (`FAKE_GH_ROOT`); any other call exits 99. A new `gh` call in the action
  needs support in the fake and a test of it in `scripts/test-steps.sh`, and each rule of the fake models a
  documented behaviour of the real `gh`. The same file also checks that the `gh` flags the action uses exist.
- Every bug fix needs a regression test that fails without the fix.
- If a check fails for a real reason, report it rather than weakening the test.

## Reporting

- State which checks ran (`make lint`, `make format`) and which did not (end-to-end workflows).
- Note that CI was not awaited.
- Report failures that already exist on `main` rather than hiding them.
