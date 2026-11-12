# CLAUDE.md

Guidance for coding agents working in this repository.

## Repository purpose

A GitHub composite action (`action.yml`) that signs Python package distributions with Sigstore and
attaches them, with their signatures, to a GitHub release. It downloads the `dist` artifact, verifies
`SHA256SUMS` (failing closed on mismatches or unlisted files), signs with keyless OIDC, uploads a
`signatures` artifact and attaches everything to the release. The logic lives inline in `action.yml`
(bash steps that must work on Linux, macOS and Windows runners). End-to-end testing is done by
workflows against a throwaway release, using the fixture package in `test/fixtures/pkg/` and the shared
assertions in `scripts/test-helper.sh`. Neither is part of the action itself.

## Environment

- Use the `Makefile`; run `make help` to list targets.
- Do not edit `.make/`: it is a shared directory synced by `bot-sync-shared-makefile.yaml`.
- Run `make format` and `make lint` before committing. Fix what they report instead of disabling
  rules.
- The end-to-end tests (`test-local.yaml`, `test-stable.yaml`) need GitHub runners, OIDC and release
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
  - `test-local.yaml`: end-to-end test of the action from this checkout (`uses: ./`), i.e. the
    version not released yet. Covers Linux/macOS/Windows plus the checksum failure paths
    (`reject-tampered-checksums`, `reject-unlisted-file`, `reject-missing-checksums`).
  - `test-stable.yaml`: the same tests against the last released tag, to catch regressions in what
    users run today.
- `format.yaml`: YAML, Makefile, shell and Markdown format checks (runs `make` targets).
- `ci-verify-workflows.yaml`: lints the workflow files themselves. It has its own triggers and is not
  called from `ci.yaml`, so it can be a required check.
- `dependency-review.yml`: dependency review on pull requests.
- `bot-*.yaml`: scheduled automation (pin actions, sync `.make/`, cancel stale queued runs).
- `.github/dependabot.yml` keeps pip, uv and GitHub Actions dependencies up to date.

Conventions:

- Every workflow has `permissions` at the workflow level (`{}` or read-only, never a write grant
  there); give jobs the narrowest permissions they need, including jobs that call a reusable
  workflow.
- Reusable workflows also have `workflow_dispatch`, so they can be run alone.
- Put `make` targets in the steps rather than duplicating commands, so local runs and CI match.
- Start each file with a comment saying what it does, and update it when the behaviour changes.
- When a released tag is bumped, update the version referenced in `test-stable.yaml` and its header
  comment.

## Tests

- Every behaviour of `action.yml` must be covered by an end-to-end job in `test-local.yaml` (and
  `test-stable.yaml` where the released version supports it).
- Cover success and failure paths (tampered checksum, unlisted file, missing `SHA256SUMS`).
- Reuse the assertions in `scripts/test-helper.sh` rather than inlining new verification logic.
- Every bug fix needs a regression test that fails without the fix.
- If a check fails for a real reason, report it rather than weakening the test.

## Reporting

- State which checks ran (`make lint`, `make format`) and which did not (end-to-end workflows).
- Note that CI was not awaited.
- Report failures that already exist on `main` rather than hiding them.
