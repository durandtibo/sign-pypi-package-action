# CLAUDE.md

Guidance for coding agents working in this repository.

## Repository purpose

A GitHub composite action (`action.yml`) that signs Python package distributions with Sigstore and
attaches them, with their signatures, to a GitHub release. It downloads the `dist` artifact, verifies
`SHA256SUMS` (failing closed on mismatches or unlisted files), signs with keyless OIDC and attaches
everything to the release with `gh` (assets are never overwritten). The logic lives inline in `action.yml`
(bash steps that must work on Linux, macOS and Windows runners), in steps named `N.x` by topic:
`0.1` failure helper, `0.2` tag, `1.1` download, `1.2` SHA256SUMS, `1.3` file set, `1.4` checksums,
`2.1` signing permission, `2.2` sign, `2.3` bundles, `3.1` release, `4.1` summary, `4.2` report. One purpose and one failure id per step. End-to-end testing is done by
workflows against a throwaway release, using the fixture package in `test/fixtures/pkg/` and the shared
assertions in `scripts/test-helper.sh`. Neither is part of the action itself.

## Environment

- Use the `Makefile`; run `make help` to list targets.
- Do not edit `.make/`: it is a shared directory synced by `bot-sync-shared-makefile.yaml`.
- Run `make format` and `make lint` before committing. Fix what they report instead of disabling
  rules.
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

- `ci.yaml`: entry point for pull requests, pushes to `main`, a weekly schedule and manual runs. It
  holds no steps, only jobs that call the reusable workflows below.
  - `lib-get-test-matrix.yaml`: loads the OS (and Python version) lists from
    `durandtibo/workflow-config-action` once and passes them down as `test-matrix`.
  - `ci-format.yaml`: YAML, Makefile, shell and Markdown format checks plus shell lint and `actionlint` (runs `make`
    targets).
  - `ci-action.yaml`: the one end-to-end suite, with a `released` input. `released: false` tests this
    checkout (`uses: ./`), `released: true` the pinned last release. The `sign` job covers
    Linux/macOS/Windows; the `case` job is a matrix over the flat list in `test/cases.json`.
- `nightly.yaml`: scheduled entry point (and manual runs) calling `ci-action.yaml` with
  `released: true`, to catch regressions in what users run today.
- `ci-verify-workflows.yaml`: lints the workflow files themselves. It has its own triggers and is not
  called from `ci.yaml`, so it can be a required check.
- `security-dependency-review.yaml`: dependency review on pull requests.
- `bot-*.yaml`: scheduled automation (pin actions, sync `.make/`, format files, cancel stale queued runs).
- `security-scorecard.yaml`: OSSF Scorecard analysis (needs the `TIBOT_*` GitHub App secrets).
- `.github/dependabot.yml` keeps pip, uv and GitHub Actions dependencies up to date.

The workflow names and structure mirror `durandtibo/cancel-queued-runs-action`; keep them aligned.

Conventions:

- Every workflow has `permissions: {}` at the workflow level; give jobs the narrowest permissions they need, including jobs that call a reusable
  workflow.
- Reusable workflows that need no input also have `workflow_dispatch`, so they can be run alone;
  `ci-action.yaml` takes the `test-matrix` and `released` inputs from its caller.
- Put `make` targets in the steps rather than duplicating commands, so local runs and CI match.
- Start each file with a comment saying what it does, and update it when the behaviour changes.
- When a released tag is bumped, update the pinned SHA and ratchet comment of the released action in `ci-action.yaml`,
  flag the rows of `test/cases.json` the new version supports with `"released": true`, and delete the
  helpers that only existed for the old tag.

## Tests

- Every behaviour of `action.yml` must be covered by an end-to-end job in `ci-action.yaml`, which
  also runs against the released tag for rows flagged `"released": true`.
- Every check calls `fail <id> ...` and has a row in `test/cases.json` with the expected
  `failed-check` id. A new case is one row: `name`, a `stage` snippet that mutates a copy of the good
  `dist/`, `expected` (`""` = accepted), and optionally `released`, `runs` (`2` runs the action twice)
  and `tag` (`new` default, `same`, `unreleased`, `missing`, `none`; see the `case` job). A rejected
  single run must also leave no asset on the release.
- Tests assert the `failed-check` id, never the message text.
- The escaping of `fail` (annotation and summary) is tested locally and in the `build` job by
  `assert_fail_helper_escapes`, which runs the helper extracted from `action.yml` on hostile text.
- Review-only exceptions, because they are third-party and can only end in `unexpected`: step 1.1
  (artifact download) and step 2.2 (Sigstore signing).
- Step 2.3 (bundle check) has no row: Sigstore cannot succeed without writing the bundle. It is a
  guard against a change of the signing action. If a row becomes possible (for example a stub
  signing action), move it into the table.
- Step 2.1 (`permissions`) cannot share the `case` job, because permissions are per job: it has its
  own `permissions` job without `id-token`.
- Reuse the assertions in `scripts/test-helper.sh` rather than inlining new verification logic.
- Every bug fix needs a regression test that fails without the fix.
- If a check fails for a real reason, report it rather than weakening the test.

## Reporting

- State which checks ran (`make lint`, `make format`) and which did not (end-to-end workflows).
- Note that CI was not awaited.
- Report failures that already exist on `main` rather than hiding them.
