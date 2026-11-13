# A hybrid test strategy: unit tests with mocks, few integration tests

Review of `main` at `226db82`. Nothing here is implemented, and no workflow is changed by this document.
Claims are marked **(read)** when derived from reading code or documented tool behaviour, and
**(confirm in CI)** when a GitHub run must prove them before the change is trusted. Nothing was executed.

## 1. Problem

`ci-action.yaml` runs every row of `test/cases.json` (39 rows) as its own job against real infrastructure:
a real draft release, the real artifact service, real Sigstore signing. This has two costs.

**It hits GitHub rate limits.** A run failed with:

```text
HTTP 403: API rate limit exceeded for installation ... /repos/durandtibo/sign-pypi-package-action/releases
```

All jobs of a run, and of concurrent runs (pull requests, `main`, the nightly released-tag run), share the
`github.token` budget of the repository. That budget is documented as 1,000 REST requests per hour per
repository for `GITHUB_TOKEN`, plus secondary limits on content-creating requests such as creating releases.
(read, confirm the numbers for this account in the rate-limit headers.) The case job spends many calls per row:

| Source                                                        | Calls per `case` job |
| ------------------------------------------------------------- | -------------------- |
| "Wait until the staged artifact is visible" polls the API     | 1 to 30              |
| create draft release(s) (`new`, `same`, `draft`)              | 1 to 2               |
| the action: `release view/create/upload/edit`                 | 3 to 5               |
| assertions: `release view`, `release download`                | 2 to 4               |
| cleanup: `release delete` (also for rows that never made one) | 1 to 2               |

That is roughly 10 to 15 calls for a row with a fast artifact, more when the wait loop spins; times 39 rows,
plus two `sign` jobs, is several hundred calls per run, run on every pull request push, every merge to
`main`, and nightly for the released tag. A few overlapping runs exhaust the hour. A rate-limit failure is
reported as a failed test although the action did nothing wrong, and re-running makes it worse.

**Most rows do not need any of that.** A row such as `crlf-sums` or `tampered-file` tests the logic of
steps 1.2 to 1.4. The job spends minutes on a runner, an artifact upload, a release and API polling, to
learn what a few lines of bash can decide on a laptop. Only a handful of behaviours truly need GitHub.

## 2. Principle: test each behaviour at the cheapest layer that can show it

|                   | Unit tier                                         | Integration tier                                      |
| ----------------- | ------------------------------------------------- | ----------------------------------------------------- |
| Question          | Is the action's logic right, for every edge case? | Do the real systems behave as the logic assumes?      |
| Runs on           | laptop, and `ci-shell.yaml` (Linux, macOS)        | `ci-action.yaml` on runners with OIDC                 |
| Infrastructure    | all mocked                                        | all real                                              |
| GitHub API calls  | none                                              | a small, bounded number                               |
| Size              | every row of `test/cases.json`, every branch      | a few happy paths and the contracts that mocks assume |
| Speed             | seconds                                           | minutes                                               |
| Flakiness sources | none                                              | artifact service, Rekor/Fulcio, rate limits           |

The existing `make test-local` is already the unit tier (`scripts/test-local.sh` and
`scripts/test-steps.sh` run the steps extracted from `action.yml`). The proposal widens it until it covers
every row, and shrinks the integration tier to what only GitHub can prove.

## 3. What is mocked, and how

The action has four external dependencies. Each gets one mock, written once, shared by both tiers where
useful.

| Dependency             | Step | Unit-tier mock                                                                         | Integration tier         |
| ---------------------- | ---- | -------------------------------------------------------------------------------------- | ------------------------ |
| Artifact service       | 1.1  | the harness places the staged dist in `$RUNNER_TEMP/sign-pypi-package` (what 1.1 does) | real                     |
| OIDC permission        | 2.1  | the harness sets or unsets `ACTIONS_ID_TOKEN_REQUEST_URL`                              | real (`permissions` job) |
| Sigstore signing       | 2.2  | a fake signer writes `<file>.sigstore.json` for every input (or a subset, or none)     | real                     |
| GitHub releases (`gh`) | 3.1  | stateful fake `gh` over a local directory (section 3.1)                                | real, few calls          |

The harness runs the **real step scripts** extracted from `action.yml` in order (0.1, 0.2, 1.2, 1.3, 1.4,
2.1, 2.3, 3.1, 4.1, 4.2) with the mocks standing in for the three `uses:` steps and the infrastructure.
The logic under test is never copied: the steps are extracted by `extract_step`, as today. (read)

### 3.1 The fake `gh`

One script, `test/fake-gh/gh`, implementing exactly the calls `action.yml` makes, over a store directory
`$FAKE_GH_ROOT`:

```text
$FAKE_GH_ROOT/tags                 one existing tag per line (what pushing a tag would have made)
$FAKE_GH_ROOT/<tag>/state          "draft" or "published"
$FAKE_GH_ROOT/<tag>/assets/<name>  the uploaded files
$FAKE_GH_ROOT/calls.log            one line per call, for assertions
```

| Call                               | Behaviour                                                                                    |
| ---------------------------------- | -------------------------------------------------------------------------------------------- |
| `release view <tag>`               | exit 0 if `<tag>/` exists, 1 otherwise                                                       |
| `release create <tag> --draft …`   | fails without `--draft`, or with `--verify-tag` when the tag is not in `tags`; else creates  |
| `release upload <tag> <file>…`     | fails if the release is missing, or if **any** asset exists already (no `--clobber` support) |
| `release edit <tag> --draft=false` | sets `state` to `published`                                                                  |
| `release delete <tag> --yes`       | removes `<tag>/`, keeps the line in `tags`; fails on `--cleanup-tag`                         |
| anything else                      | exit 99 `unexpected gh call`, as the stub of `scripts/test-steps.sh` does today              |

Failure injection replaces the `STUB_*` switches with environment variables of the fake
(`FAKE_GH_FAIL=create|upload|edit`), so the broken-network rows (create fails, upload fails after create,
publish fails) stay unit tests.

This makes the "no overwrite", "draft until complete", "a pre-existing draft stays a draft", "failed run
deletes only the release it created" and "nothing is left on a rejected run" properties observable from
`state`, `assets/` and `calls.log`, without a network. (read)

### 3.2 The fake signer

A 5-line script standing in for step 2.2: for each path in `inputs`, write `<path>.sigstore.json`. Variants
(skip one file, write an empty file, write none) drive step 2.3 (`bundle`), which has no table row today
because real Sigstore cannot fail that way. Unit tests prove the **logic around** signing; whether Sigstore
signs and verifies is an integration question and is never claimed by the unit tier.

## 4. The unit tier: every row, no GitHub

Extend `scripts/test-local.sh` from "rows that need no release" to **all rows of `test/cases.json`**, by
running the whole step sequence with the mocks:

| Row property today                  | In the unit tier                                                                                              |
| ----------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| `tag: new / same / draft / missing` | seed the fake store (`seed_fake_release <kind> <tag>`)                                                        |
| `tag: none / dash / space`          | unchanged (already local)                                                                                     |
| `runs: 2`                           | run the step sequence twice in the same `RUNNER_TEMP` (the re-entrancy check of step 0.1) with the same store |
| `artifact: dist-does-not-exist`     | the harness has no such dist: step 1.1 is mocked, so this row stays integration (see below)                   |
| `expected: ""` (accepted, 7 rows)   | the fake signer + fake `gh`; assert the store holds exactly the expected assets, byte-identical               |
| rejected rows                       | assert the id **and** that `calls.log` has no `upload` (and no `create`)                                      |

The assertions move from `gh release view/download` to reading the store (`assert_release_matches_dist`,
`assert_no_assets`, `assert_release_draft`, `assert_no_release` become small file checks). The table stays
the single source: a new case is still one row, and it runs in both tiers unless flagged otherwise.

New field, optional: `"integration": true` marks a row that needs the real service (for example
`missing-artifact`, which tests step 1.1 itself). Rows without it run in the unit tier; they run in the
integration tier only if they are also in its small selection (section 5).

What this gains for edge cases: they are cheap, so they can be added freely (hostile file names, odd tags,
partial uploads, a second run after a partial failure) without adding rate-limit pressure or CI minutes.

## 5. The integration tier: few jobs, bounded API use

The integration tier keeps only what a mock cannot establish:

| Check                                                      | Why a mock cannot show it                        | Job                                 |
| ---------------------------------------------------------- | ------------------------------------------------ | ----------------------------------- |
| Real artifact download works, including a missing artifact | step 1.1 is third-party and the service differs  | one `case` row (`missing-artifact`) |
| Real Sigstore signs, and `sigstore verify github` accepts  | OIDC identity, Fulcio, Rekor                     | `sign` on Linux and macOS           |
| Missing `id-token` permission is detected                  | permissions are per job                          | `permissions` job (unchanged)       |
| Real `gh` accepts the flags and semantics the action uses  | the fake only proves the action matches the fake | one real-release job (below)        |
| Contract with `build-pypi-package-action`                  | its artifact layout is the input of this action  | one sibling-contract job (below)    |

Everything else of the 39 rows leaves the integration tier. Remaining jobs: about 6 instead of 41.

**One real-release job.** Keep `create_draft_release`, a happy-path run on Linux, the existing
`assert_release_matches_dist` / `assert_release_verifies`, and `delete_release` under `if: always()`: about
10 API calls, once per run, not 39 times. It keeps the "drafts only, never public, title marker" rules of
`CLAUDE.md` unchanged, and `make clean-throwaway-releases` stays. This is the check that the real `gh`
behaves as the fake claims, so it is the guard against fake drift. Run it on pushes to `main`, the nightly
schedule and manual runs, and on pull requests only when `action.yml` or `test/fake-gh/` changes (a `paths`
filter or a `changes` job), so documentation PRs spend nothing.

**One sibling-contract job** (nightly): build the fixture with `build-pypi-package-action` pinned to a SHA,
then run this action (`uses: ./`) on its artifact with the fake `gh`. It checks the `dist` / `SHA256SUMS`
contract between the two actions without a release. The sibling's artifact name and layout must be read from
its `action.yml` when this is written. (confirm in CI)

**Where the fake `gh` is used in the integration tier.** The `sign` and `case` jobs that remain can still
run with the fake in front of `PATH` when they only need signing and artifact download, not a real release:

```yaml
- name: Use a fake gh
  shell: bash
  run: |
    mkdir -p "${RUNNER_TEMP}/fake-gh-root"
    echo "${GITHUB_WORKSPACE}/test/fake-gh" >>"${GITHUB_PATH}"
    echo "FAKE_GH_ROOT=${RUNNER_TEMP}/fake-gh-root" >>"${GITHUB_ENV}"
```

Entries in `GITHUB_PATH` and `GITHUB_ENV` apply to later steps, composite action steps included. (read,
**confirm in CI** on Linux and macOS.) Those jobs then need no `contents: write`. Only the one real-release
job keeps it. A guard avoids passing by accident when the `PATH` change did not apply: an accepted run must
find a non-empty `calls.log`.

**Cutting the other API consumer.** The "Wait until the staged artifact is visible" loop calls
`gh api` every 2 seconds and is the largest single API spender. Remove it where the unit tier replaced the
job; for the remaining `missing-artifact` row, no wait is needed at all (the artifact never exists). The
`sign` job downloads an artifact uploaded by an earlier job, so it has no eventual-consistency window.

## 6. Mock fidelity: how the unit tier is kept honest

A mock proves the action matches the mock, not the real service. Three guards:

1. **The real-release job** (section 5) is the contract test of the fake `gh`, run on every merge and
   nightly. If the fake and the real `gh` diverge, that job fails and the fake is fixed first.
2. **Flag check in the unit tier**, offline: `gh release create --help` mentions `--draft` and
   `--verify-tag`; `gh release upload --help` mentions `--clobber` (the flag the action must never pass).
   Catches renames, not semantics. (read)
3. **Fake rules are copied from documented behaviour** and each has a comment naming the real behaviour it
   models, so a reviewer can check the fake against the `gh` manual, not against the action.

## 7. Resulting layers

| Layer                         | Runs where                  | API calls | Covers                                                                |
| ----------------------------- | --------------------------- | --------- | --------------------------------------------------------------------- |
| Unit: `make test-local`       | laptop, `ci-shell.yaml`     | 0         | every row, every branch of every step, failure injection, re-entrancy |
| Integration: sign (fake `gh`) | Linux, macOS runners        | ~0        | real artifact, real Sigstore, byte-identical assets, consumer verify  |
| Integration: permissions      | Linux runner                | 0         | missing `id-token`                                                    |
| Integration: missing artifact | Linux runner                | ~0        | real step 1.1 failure                                                 |
| Integration: real release     | Linux runner, merge/nightly | ~10       | real `gh` behaves as the fake claims                                  |
| Integration: sibling contract | Linux runner, nightly       | 0         | `dist` contract with `build-pypi-package-action`                      |

## 8. Migration, in small PRs

Each PR is independent and leaves CI green. `CLAUDE.md` ("Tests") changes with PR 3.

1. **Fake `gh` and fake signer.** Add `test/fake-gh/gh` and the signer; make `scripts/test-steps.sh` use
   them instead of its inline stub (`STUB_*` become `FAKE_GH_FAIL`). Add the flag check. Verifiable locally
   with `make test-local`.
2. **Widen the unit tier.** `scripts/test-local.sh` runs all rows with `seed_fake_release`, `runs: 2` and
   store assertions; add the `integration` field to `missing-artifact`. At the end of this PR, every row is
   covered by `make test-local`, and CI is unchanged, so nothing is lost.
3. **Shrink `ci-action.yaml`.** Only after PR 2: `case` runs the `integration` rows only; `sign` uses the
   fake `gh` and drops `contents: write`; one new real-release job with a `paths` filter; remove the wait
   loop where unused. Update `CLAUDE.md` and the header comment of the workflow. Keep the `released: true`
   path working: the released `v0.0.1` also calls plain `gh`, so the fake applies to it too. (confirm in CI)
4. **Nightly sibling contract job.**

## 9. Risks and open questions

- **`GITHUB_PATH` in composite actions** is the one mechanism the integration-tier fake depends on. The unit
  tier does not (it sets `PATH` itself), so PRs 1 and 2 are safe to merge before it is proven. (confirm in CI)
- **Fake drift** is the price of the unit tier. It is bounded by the real-release job and the flag check;
  the fake is about 40 lines, shared by both tiers.
- **Rows moved out of the integration tier lose end-to-end coverage** of their path through the artifact
  service. The rows only mutate files after download, so the service adds nothing to them; `missing-artifact`
  and the `sign` job cover the service itself.
- **Rate-limit numbers** above are from documentation, not from this repository. Before PR 3, read the
  `x-ratelimit-*` headers (`gh api -i rate_limit`) at the start and end of a run to measure the real spend.
- **Decision for the maintainer:** run the real-release job on every pull request that touches
  `action.yml` (safer, small spend), or only after merge (cheaper, a drift is found one merge late)?
