# Testing strategy for the GitHub actions

Review date: 2026-11-17. The strategy applies to the 11 action repositories of
`durandtibo`: `build-pypi-package-action`, `cancel-queued-runs-action`,
`extract-pyproject-metadata-action`, `format-files-action`, `read-json-action`,
`setup-venv-uv-action`, `sign-pypi-package-action`, `uv-install-package-action`,
`verify-github-workflow-action`, `verify-uv-build-action`,
`workflow-config-action`.

This review replaces a first draft that was written from file names only. Some of
its claims were wrong (it said `read-json-action` and `sign-pypi-package-action`
had no test of the released action, and it treated the two-file mirror as the
only pattern). This version is based on the content of the 11 repositories.

## 0. What was read, and what was not

All 11 repositories were cloned at `main` and read, except as listed below.

Read in full or in the relevant part:

- `action.yaml` or `action.yml` of every repo (full for 7, the inputs and the
  first steps for `setup-venv-uv-action`, `sign-pypi-package-action`,
  `verify-github-workflow-action`, `build-pypi-package-action`).
- `CLAUDE.md` of every repo (test rules, workflow structure, supported platforms).
- The list of jobs, the matrices and the `uses:` lines of every `ci-action*.yaml`
  and `nightly*.yaml`, and the `diff` between `ci-action.yaml` and
  `nightly-test-released.yaml` for `build-pypi-package-action`.
- The test sections of every `review/target_state.md`, and
  `sign-pypi-package-action/review/testing_without_releases.md` in full.
- `tests/TESTING.md` of `uv-install-package-action`, the case tables
  (`cases.json`) of three repos, `test_workflow_mirror.bats`.

Not read: the full body of the large `ci-action.yaml` files (874 lines for
`setup-venv-uv-action`, 721 for `verify-github-workflow-action`), the full READMEs,
the bats and pytest test code, the `bot-*` and `security-*` workflows.

Nothing was run. Job counts in section 2 are computed from the matrix
expressions and `configs/versions.json`, not measured on a real run.

## 1. Goal

Every action is tested at three levels, on every OS (and Python version) that
the action claims to support.

1. **Code.** The code the action runs (shell, Python) is tested alone, without
   GitHub: fast, local, with mocks.
2. **Local action.** The action as it is in the branch (`uses: ./`) is run in a
   real workflow.
3. **Released action.** The latest stable release (`uses: owner/repo@<sha>`) is
   run on a schedule, with the same cases as level 2.

## 2. What exists today

### 2.1 The 11 repositories

| Repo                                | Logic lives in                                          | Level 1 (code)                                                                     | Levels 2 and 3 (how)                                                                                                         | OS and Python                                |
| ----------------------------------- | ------------------------------------------------------- | ---------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------- |
| `cancel-queued-runs-action`         | `scripts/cancel.sh`                                     | bats (one file per function), bash 3.2, mutation check                             | two files: `ci-action` (3 jobs), `nightly-test-released`                                                                     | Linux and macOS                              |
| `extract-pyproject-metadata-action` | Python package `src/`, started by `scripts/run.sh`      | pytest: unit, integration, properties, 100% coverage, golden                       | two files: `ci-action` (8 jobs, `golden` runs 3 cases), `nightly-test-released`                                              | Linux and macOS, Python 3.11+                |
| `uv-install-package-action`         | `scripts/*.sh`                                          | bats, bash 3.2, pytest functional, `ci-export`                                     | `ci-action` calls `ci-action-deps` and `ci-action-edge-cases` with `action-ref: local`; nightly calls the same with `stable` | Linux and macOS, Python 3.10 to 3.14 and `t` |
| `verify-uv-build-action`            | `scripts/*.sh` (libraries sourced by `verify.sh`)       | bats, bash 3.2, `test_workflow_mirror.bats`, `test_readme.bats`                    | two files, `tests/cases.json` with a `released` flag, `load-cases.sh`                                                        | Linux and macOS, `os x python_versions`      |
| `sign-pypi-package-action`          | inline steps in `action.yml`, extracted by test scripts | `ci-shell`: `test-local.sh` runs the real steps with a fake `gh` and a fake signer | one file `ci-action` with input `released`; `nightly.yaml` calls it; `ci-contract` with the sibling action                   | Linux and macOS                              |
| `read-json-action`                  | inline bash plus `scripts/validate-json.py`             | none apart from the cases                                                          | one file `ci-action` with input `use-released`; `test-data/cases.json`; `nightly.yaml` calls it                              | Linux and macOS                              |
| `build-pypi-package-action`         | inline steps in `action.yml`                            | none (all through the action)                                                      | two files, `test/cases.json` with a `released` flag, `load-cases.sh`, `test-helper.sh`                                       | **Linux, macOS and Windows**                 |
| `format-files-action`               | inline steps plus the shared `.make/`                   | none                                                                               | two files: 9 jobs vs 6 jobs                                                                                                  | Linux and macOS                              |
| `setup-venv-uv-action`              | inline steps (431 lines), dummy project `myproject`     | none (one README check script)                                                     | two files: 27 jobs, 874 lines vs 852 lines                                                                                   | Linux and macOS, `python_versions_standard`  |
| `verify-github-workflow-action`     | inline steps                                            | none                                                                               | two files: **15 jobs vs 2** (the released file tests the v0.0.3 inputs only)                                                 | Linux and macOS                              |
| `workflow-config-action`            | inline `jq` step, `configs/versions.json`               | none                                                                               | two files: 8 jobs vs 9 jobs (the released one has `downloaded-files`)                                                        | `os_latest` (the `*-latest` runners)         |

### 2.2 Findings

Each finding names the property it breaks (properties are in section 3).

**F1. Four ways to run the local and the released action (T6, T7).**

- Two mirrored files, kept in step by hand: 8 repos. The drift is real:
  `verify-github-workflow-action` (15 jobs vs 2), `format-files-action` (9 vs 6),
  `setup-venv-uv-action` (874 vs 852 lines, `test-tasklib-self` only local),
  `workflow-config-action` (8 vs 9). `verify-uv-build-action` added a bats test
  (`test_workflow_mirror.bats`) to detect the drift, with a list of jobs allowed
  to differ.
- One reusable file with a boolean input and two `uses:` steps guarded by `if`
  (`read-json-action`: `use-released`, `sign-pypi-package-action`: `released`);
  the verify step reads `steps.local.outputs.x || steps.released.outputs.x`.
- One reusable file with a string input `action-ref: local|stable`
  (`uv-install-package-action`).
- `build-pypi-package-action` plans to move to the boolean-input pattern
  (its `target_state.md`, F8). `format-files-action` leaves it open.

The reason for the two files is that `uses:` cannot be an expression. The
single-file patterns pay for it with one extra `uses:` step per job and make
drift impossible by construction.

**F2. The matrix is large (T10).** `lib-get-test-matrix.yaml` exposes
`os_matrix` = `os_unix` = 8 Ubuntu labels + 5 macOS labels = 13 runners, and
`python_versions` = 5 standard + 3 free-threaded = 8 versions
(`workflow-config-action/configs/versions.json`). A job that crosses them
(`extract-pyproject-metadata-action` `test`, `verify-uv-build-action` `test`)
has up to 13 x 8 = 104 cells, run on every push and every night, for local
**and** released. The full matrix on PRs and pushes is a decision of the
maintainer (T4, section 6); the cost is controlled by what crosses the matrix
(T16), not by shrinking the matrix. A job that only crosses OS has 13. These numbers are computed;
how many cells run today was not measured.

**F3. `lib-get-test-matrix.yaml` is copied 11 times, and the copies differ (T3).**
Each copy picks different keys and builds a different JSON:
`format-files-action` only `os_matrix`; `build-pypi-package-action` uses
`os_all` (Windows included); `workflow-config-action` adds `os_latest`;
`read-json-action` and others add `os_macos`. A change of config shape means 11
edits.

**F4. `uses: ./` hides packaging mistakes (T9).** The local test runs the action
from the whole checkout. The released action is the `git archive`. When a file
the action needs is `export-ignore`d, the local test passes and the release is
broken. Only `uv-install-package-action` checks the exported set
(`ci-export.yaml`, `make check-export`). `read-json-action`, `setup-venv-uv-action`
and `workflow-config-action` also have a `.gitattributes`, without the check.

**F5. Two philosophies on how much to run on GitHub (T4, T10).**

- `sign-pypi-package-action`: 39 case jobs against real infrastructure hit
  `HTTP 403: API rate limit exceeded`. The fix (implemented, its section 10):
  every row in a unit tier with a fake `gh` and a fake signer, and about 6
  integration jobs.
- `extract-pyproject-metadata-action`: the golden files are checked without
  GitHub by `test_golden.py`; the action job runs only 3 cases to check the
  wiring (about 38 jobs down to about 22).
- Elsewhere (`setup-venv-uv-action`, `verify-github-workflow-action`,
  `build-pypi-package-action`, `format-files-action`), every behaviour is a job
  on the real runner, because the logic is inline in `action.yaml` and cannot be
  run another way.

**F6. The released test is questioned in one repo (T6).**
`verify-uv-build-action/review/target_state.md` (section 3.6, P14) proposes to
delete `nightly-test-released.yaml`: the scheduled `ci.yaml` already exercises
uv, twine, pyright and the runner with the full case table, and the released
run adds signal only when `main` and the release differ. Decision of the
maintainer: the nightly of the released action is kept in every repo. The
argument about cost is answered by the single file and the case table (T7, T8),
and by the split of T16.

**F7. Behaviour that CI cannot test as such (T11).**

- `format-files-action`: pull-request creation (`peter-evans/create-pull-request`)
  is not tested against this repo; `bot-format-files.yaml` (released action)
  covers it, and its review says so.
- `build-pypi-package-action`: `reject-manual` needs `workflow_dispatch` and
  `reject-tag-mismatch` needs a tag ref; a pull-request run cannot reproduce
  them.
- `sign-pypi-package-action`: a real draft release is needed to prove that the
  real `gh` behaves like the fake.

**F8. Names differ (T2).** `ci-python` (extract) vs `ci-test` (uv-install);
`ci-action-deps` and `ci-action-edge-cases` (uv-install); `ci-contract`
(sign); `use-released` vs `released` vs `action-ref`. `extract` documents the
rule ("name test workflows by what they test"), the others do not follow one
name.

**F9. Platform claims differ, and are mostly stated (T4).** Windows is
explicitly out of scope for `extract-pyproject-metadata-action` ("a deliberate,
final decision"), `format-files-action`, `setup-venv-uv-action`,
`sign-pypi-package-action`, `uv-install-package-action`. It is supported and
tested only by `build-pypi-package-action`. `read-json-action`,
`verify-github-workflow-action`, `verify-uv-build-action` and
`cancel-queued-runs-action` do not say it in the files read.

**F10. What is already good, and is kept.**

- The `failed-check` id asserted instead of the message
  (`build-pypi-package-action`, `sign-pypi-package-action`).
- A negative test preceded by a positive run on the same runner
  (`verify-github-workflow-action`), so it cannot pass for the wrong reason.
- Case tables in a JSON file: a new case is a row, not a job
  (`read-json-action`, `build-pypi-package-action`, `sign-pypi-package-action`,
  `verify-uv-build-action`, `uv-install-package-action` edge cases).
- A check that the README matches `action.yaml`: `action_readme_sync.bats`
  (cancel), `test_contract.py` (extract), `test_readme.bats` (verify-uv-build),
  `check_readme_inputs.py` (setup-venv).
- The mutation check and the bash 3.2 run (cancel; bash 3.2 also in uv-install and
  verify-uv-build).
- A contract test between two actions (`sign` x `build-pypi`: `ci-contract`).
- A "tests that depend on a release carry a flag" rule
  (`released: false` until the release has the feature).

## 3. Properties of the testing

The target state must satisfy these 16 properties.

| #   | Property                | Meaning                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| --- | ----------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| T1  | Three levels            | Each repo has code, local action and released action tests. A level is empty only when there is no code outside `action.yaml`, and the README says so.                                                                                                                                                                                                                                                                                          |
| T2  | Same shape              | The 11 repos use the same file names and the same entry points: `ci.yaml`, `ci-<code-check>.yaml`, `ci-action.yaml`, `nightly.yaml`. A reader who knows one repo finds the files in the others.                                                                                                                                                                                                                                                 |
| T3  | One matrix source       | OS and Python lists come from `workflow-config-action`. The loader `lib-get-test-matrix.yaml` is the same file in every repo (same keys), or a call to a reusable workflow of one repo.                                                                                                                                                                                                                                                         |
| T4  | Supported equals tested | Every OS and Python version the README claims is in a matrix, and every cell is claimed. Windows is tested only where the README supports it. The claim is written in `CLAUDE.md` and README.                                                                                                                                                                                                                                                   |
| T5  | Cheapest layer          | A behaviour is tested at the cheapest level that can show it. The code tests (level 1) check each script or function, including every edge case. The action tests (level 2 and 3) check the contract and the wiring (T16).                                                                                                                                                                                                                      |
| T6  | Same cases, one source  | The local and the released action run the same cases, defined once. Drift between the two is impossible by construction, or detected by a check.                                                                                                                                                                                                                                                                                                |
| T7  | One file for both       | `ci-action.yaml` is one reusable workflow with a boolean input `use-released`. `nightly.yaml` calls it with `true`; `ci.yaml` calls it with `false`. There is no `nightly-test-released.yaml`.                                                                                                                                                                                                                                                  |
| T8  | Cases are data          | Case tables live in one JSON file; a case has `released: true/false` for features the last release lacks. A new case is a row, not a job. Verification code is shared (`test-helper.sh`).                                                                                                                                                                                                                                                       |
| T9  | Shipped = tested        | What consumers get (`git archive`) is what is tested: the exported set is checked, or the local action runs from the exported archive. A file the action needs is never `export-ignore`d.                                                                                                                                                                                                                                                       |
| T10 | Bounded cost            | Every job has `timeout-minutes`, matrices use `fail-fast: false` and `max-parallel`. The cells per run are counted and documented. The matrix is the same on PRs, pushes and the schedule; the cost is bounded by what crosses it (T16).                                                                                                                                                                                                        |
| T11 | No side effects         | Tests change nothing outside the runner: `dry_run`, fakes, throwaway artifacts and releases. What cannot be tested in CI is written down with the check that covers it (bot, manual run).                                                                                                                                                                                                                                                       |
| T12 | Tests that can fail     | Failure paths are asserted (`continue-on-error` plus an outcome check), with the `failed-check` id or the exact output, not the message. A negative test has a positive control on the same runner. Where cheap, a mutation check proves it.                                                                                                                                                                                                    |
| T13 | Local equals CI         | Every command run by CI is a `make` target. The unit tier runs on a laptop. Checks that need GitHub say so in the PR.                                                                                                                                                                                                                                                                                                                           |
| T14 | Docs match code         | A test compares the README inputs and outputs to `action.yaml`, and the README examples to fixtures. Release notes carry history, the README tells the current behaviour.                                                                                                                                                                                                                                                                       |
| T15 | Safe                    | `permissions: {}` at workflow level, least privilege per job, actions pinned to a SHA with a `ratchet` comment, inputs through `env:`, no `concurrency`.                                                                                                                                                                                                                                                                                        |
| T16 | General vs edge cases   | The action tests are split in two. **General behaviour**: the default and the main documented usage, run on the full matrix (`os_matrix`, and `python_versions` where it applies), to show that the action works on every supported OS. **Edge cases** (one input, one invalid value, one unusual file): run on one runner, or on `os_latest` when the case is OS-sensitive. The action tests check the contract and the wiring, not the logic. |

## 4. The three levels

### 4.1 Level 1: the code (`ci-shell*.yaml`, `ci-python.yaml`)

| Code           | Tool                      | Workflow                              | Matrix                           |
| -------------- | ------------------------- | ------------------------------------- | -------------------------------- |
| Shell scripts  | bats                      | `ci-shell.yaml`                       | `os_matrix`                      |
| Shell scripts  | bats, system bash 3.2     | `ci-shell-bash32.yaml` (macOS)        | `os_macos`                       |
| Python package | pytest                    | `ci-python.yaml`                      | `os_matrix` x Python (section 6) |
| Inline steps   | the real steps, extracted | `ci-shell.yaml` (sign's `test-local`) | `os_matrix`                      |

Rules:

- Logic goes in functions or scripts that a test can call. Inline steps with
  branching logic are the main obstacle to T5: `setup-venv-uv-action` (431
  lines), `build-pypi-package-action` and `verify-github-workflow-action` have
  all their logic in `action.yaml` and so test it only on GitHub. The
  alternative used by `sign-pypi-package-action` (run the steps extracted from
  `action.yml` with mocks) works without moving code; moving the logic to
  scripts (as `uv-install-package-action` and `verify-uv-build-action` did) is
  the better target.
- Each script has its own test file; one behaviour per test; external commands
  (`gh`, `uv`, `date`) are mocked on `PATH`; success, failure and edge cases.
- bash 3.2 and GNU/BSD portability are tested for shell code that runs on macOS.
- A mutation check (cancel) is optional. It is worth it for a script of more
  than a few hundred lines with many tests.

### 4.2 Level 2: the local action (`ci-action.yaml`, `use-released: false`)

Level 2 tests the contract and the wiring: `action.yaml` inputs, defaults and
outputs, `shell: bash`, step order, the real runner, the real tools, the
packaging. It does not re-test the logic of the scripts: each script and
function is tested by level 1 (T5), so a failure at level 2 means that the
wiring is broken.

The tests are split in two groups (T16).

**General behaviour: the full matrix.** It shows that the action works on every
supported OS (and Python version, where the action depends on it). It holds few
jobs, each with a real assertion on the outputs.

| Job            | What it checks                                                                                                             | Runs on                                            |
| -------------- | -------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------- |
| `test`         | The default usage succeeds and the outputs have the expected value                                                         | `os_matrix` (x `python_versions` where it applies) |
| `test-<usage>` | A main documented usage (for example the README example, or the inputs most callers set), when it differs from the default | `os_matrix` (x `python_versions` where it applies) |

**Edge cases: one runner.** One job or one case row per input, per invalid
value and per unusual situation. They run on `ubuntu-latest`, or on `os_latest`
(Linux and macOS) when the case is OS-sensitive (paths, `sed`, `date`, file
system). They do not cross the Python matrix.

| Job                    | What it checks                                                                                           | Runs on                              |
| ---------------------- | -------------------------------------------------------------------------------------------------------- | ------------------------------------ |
| `test-<input>`         | One job (or one case row) per input that changes behaviour, with an assertion of the effect              | one runner                           |
| `test-invalid-<input>` | An invalid input fails (`continue-on-error`, outcome and `failed-check` assertion), and nothing was done | one runner                           |
| `cases`                | The table of `cases.json`: one matrix cell per row                                                       | one runner, or `os_latest` if needed |
| `test-export`          | The action runs from the exported archive (T9)                                                           | one runner                           |

A case that is general behaviour in one repo can be an edge case in another:
the rule is that the full matrix proves "it works everywhere" and the other
jobs prove "this input does this". If an edge case turns out to depend on the OS,
it is moved to `os_latest` or to the full matrix.

Rules:

- Every input has a case that sets it and asserts its effect, not only that the
  action succeeds. A case that only needs the contract (the input reaches the
  script, the output is set) is enough: the values are tested at level 1.
  Every validated input has a case that passes an invalid value and asserts
  that it failed in the validation.
- Outputs are asserted by value or format, not printed.
- Dependent matrices (package x Python) come from a generated file (as
  `uv-install-package-action`, `bot-generate-package-versions.yaml`).
- Cases that depend on the trigger (`workflow_dispatch`, tag ref) run in their
  own job with an `if`, and the header says how to run them by hand.

### 4.3 Level 3: the released action (`ci-action.yaml`, `use-released: true`)

Same file, same cases, `uses: durandtibo/<repo>@<sha> # ratchet:...@vX.Y.Z`
instead of `uses: ./`.

- `nightly.yaml` (schedule and `workflow_dispatch`) calls `ci-action.yaml`
  with `use-released: true`. `ci.yaml` calls it with `false` (T7).
- A case with `released: false` is skipped. After a release, the maintainer
  flips the flags for the features of that release and updates the pin
  (`bot-pin-action.yaml`).
- A failure that does not reproduce at level 2 means an upstream change
  (runner, tool, dependency). A failure at both means a regression in the code.

Shape of one job in the single file, as in `read-json-action`:

```yaml
- name: Run the action (local)
  id: local
  if: ${{ !inputs.use-released }}
  continue-on-error: true
  uses: ./
  with: ...
- name: Run the action (released)
  id: released
  if: ${{ inputs.use-released }}
  continue-on-error: true
  uses: durandtibo/<repo>@<sha> # ratchet:durandtibo/<repo>@vX.Y.Z
  with: ...
- name: Verify
  env:
    OUTCOME: ${{ inputs.use-released && steps.released.outcome || steps.local.outcome }}
    RESULT: ${{ steps.local.outputs.result || steps.released.outputs.result }}
  run: scripts/test-helper.sh ...
```

The cost is the duplicated `with:` block per job, which is why the inputs
should come from the case row (`matrix.case`) and be passed to both steps.

### 4.4 Cross-cutting checks

- **Exported set (T9).** `make check-export`: `git archive --worktree-attributes
HEAD | tar t` equals the expected list. Required for every repo with a
  `.gitattributes`. Optional: a job that extracts the archive and runs the
  action from it (`uses: ./exported`); to confirm that `uses:` accepts it.
- **Docs match code (T14).** One test per repo comparing README tables to
  `action.yaml` (the four existing implementations differ: bats, pytest,
  Python script; pick one per language).
- **Contract between actions.** Where one action consumes the output of another
  (`sign` x `build-pypi`), a nightly job chains the two, pinned to SHAs, and the
  failure message says to read the changelog of the sibling.
- **Workflow lint (`ci-verify-workflows.yaml`)** is standalone, as in `CLAUDE.md`
  of every repo, so it can be a required check. It lints the test workflows too.

## 5. Workflow layout (the same in all repos)

```text
ci.yaml                     entry point; no steps; calls the files below
  lib-get-test-matrix.yaml  loads the matrix once
  ci-format.yaml            lint and format (not a test)
  ci-shell.yaml             level 1, shell      (when there is shell code)
  ci-shell-bash32.yaml      level 1, bash 3.2   (when it runs on macOS)
  ci-python.yaml            level 1, Python     (when there is Python code)
  ci-export.yaml            T9
  ci-action.yaml            level 2 and 3, input use-released (default false)
ci-verify-workflows.yaml    own triggers, not called from ci.yaml
nightly.yaml                schedule; calls ci-action.yaml with use-released: true
                            and, when it applies, ci-contract.yaml
```

- `nightly-test-released.yaml` and `ci-action-<x>.yaml` variants are removed;
  extra jobs of `uv-install-package-action` become jobs of `ci-action.yaml`
  or reusable workflows called by it with the same `use-released` input.
- The test files are in `tests/` (code) and `tests/cases.json` plus
  `tests/fixtures/` (cases). `test/` and `test-data/` are renamed when the repo
  is touched for another reason.
- `scripts/test-helper.sh` holds shared assertions and no fixture knowledge.

## 6. Matrices (T3, T4, T10)

Single source: `durandtibo/workflow-config-action`, read by
`lib-get-test-matrix.yaml`. The file is the same in every repo and exposes the
same keys: `os_matrix`, `os_macos`, `os_latest`, `python_versions`,
`python_versions_standard`. `os_latest` is for some edge cases only (T16).
There is no reduced matrix for pull requests and pushes (decision of the
maintainer): the schedule and the PRs use the same matrix.

| Dimension | Applies to                                                                                                      | General behaviour (PR, push, schedule) | Edge cases                                   |
| --------- | --------------------------------------------------------------------------------------------------------------- | -------------------------------------- | -------------------------------------------- |
| OS        | Every action                                                                                                    | `os_matrix`                            | one runner, or `os_latest`                   |
| Python    | Actions that run in the user's Python (`setup-venv`, `uv-install`, `verify-uv-build`, `build-pypi`, `extract`)  | `python_versions`                      | none (the latest, or the one the case needs) |
| None      | `format-files`, `verify-github-workflow`, `workflow-config`, `sign` and `read-json` (Python only for `python3`) | no Python dimension                    | no Python dimension                          |

The cost of the full matrix (F2: up to 104 cells for a job that crosses OS and
Python) is controlled by T16: only the few general-behaviour jobs cross it. The
level 1 tests use the same matrix as the general-behaviour jobs. Rules:

- The OS and Python choice of a repo is written in its `CLAUDE.md` (T4) and
  matches its README. Windows is added only with a README claim, as in
  `build-pypi-package-action`.
- Level 1 uses the same matrix rule as level 2.
- A job that is not OS-specific (a pure option check) runs on one runner.

## 7. Plan per repository

Items are in the order in which they should be done. "Single file" is the T7
change. Nothing here is implemented.

| Repo                                | Do                                                                                                                                                                                                                                                                                                                                                                    |
| ----------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `cancel-queued-runs-action`         | Single file (3 jobs: easy). Add `ci-export` (it has the `.gitattributes` rule). Its layout already follows T16: `test` on `os_matrix` is the general behaviour (each cell runs a real cancel, so the 13 cells are API-bound: accepted), and `test-48h` and `test-outputs` (dry run, invalid input) are edge cases on one runner. Keep bats, bash 3.2, mutation check. |
| `extract-pyproject-metadata-action` | Single file. Keep the golden approach (3 cases for wiring, the rest in `test_golden.py`). Keep `test` on `os_matrix` x `python_versions` (general behaviour); `test-warning`, `test-default-path`, `test-path-with-spaces`, `test-strict`, `test-invalid-inputs` are edge cases and run on one runner. Keep `test-old-python`.                                        |
| `uv-install-package-action`         | Already has `action-ref`; rename it `use-released` and move `ci-action-deps` and `ci-action-edge-cases` under one `ci-action.yaml` input. Keep `ci-export`. Rename `ci-test` to `ci-python`.                                                                                                                                                                          |
| `verify-uv-build-action`            | Single file: `test_workflow_mirror.bats`, `load-cases.sh` and the `released` filter of the loader go away (their target state proposes it for the whole nightly, this review keeps the nightly). Keep the `released` flag in `cases.json`.                                                                                                                            |
| `sign-pypi-package-action`          | Already single file (`released`); rename to `use-released`. Keep the unit tier with the fake `gh`, the real-release job, and `ci-contract`. This is the reference for T5 and T11.                                                                                                                                                                                     |
| `read-json-action`                  | Already single file (`use-released`). Reference for T7 and T8. Add `ci-export` (has a `.gitattributes`). Add level 1 tests for `validate-json.py` (pytest or a case table: a Python script with many cases).                                                                                                                                                          |
| `build-pypi-package-action`         | Single file (stage 2 of its F8). Keep `released` flags, `failed-check` assertions, Windows. Document the trigger-dependent cases (F7). Move inline logic to scripts or extract the steps (as `sign`), for T5.                                                                                                                                                         |
| `format-files-action`               | Single file; the released file lacks 3 of the 9 jobs today. Add the "consumer-like directory" run of its review (B2). Document that PR creation is covered by the bot (F7), not by the matrix.                                                                                                                                                                        |
| `setup-venv-uv-action`              | Single file: removes the 874 vs 852 lines. Turn the 27 jobs into case rows where only the inputs differ (`test-invalid-inputs` already is one). Add `ci-export`. Keep the `check_readme_inputs.py` check in CI.                                                                                                                                                       |
| `verify-github-workflow-action`     | Single file: this closes the 15 vs 2 gap in one change. Keep the positive-control rule and the `ran-<tool>` markers. Document that the tools are downloaded, so a nightly failure can be upstream.                                                                                                                                                                    |
| `workflow-config-action`            | Single file. It is the matrix source for the 10 others: assert the content of outputs (valid JSON, keys, sorted, non-empty). Add the `downloaded-files` job to level 2. Add `ci-export` (has a `.gitattributes`).                                                                                                                                                     |

Order across repos:

1. `workflow-config-action`: fix the shape of the matrix keys (F3), release, so
   the 10 others can copy one `lib-get-test-matrix.yaml`.
2. Prove the single-file pattern on two repos: `cancel-queued-runs-action`
   (this repo, 3 jobs, simplest) and `verify-github-workflow-action` (largest
   drift, 15 jobs vs 2).
3. The other two-file repos with drift: `format-files-action`,
   `setup-venv-uv-action`.
4. `extract-pyproject-metadata-action`, `verify-uv-build-action`,
   `build-pypi-package-action`.
5. Renames and `ci-export` for the repos that already have the single file or
   `action-ref`.

One pull request per repo and per change.

## 8. Open points to verify

1. **Cost of the full matrix.** Decided: the nightly of the released action is
   kept, and there is no reduced matrix on PRs and pushes. The cost is bounded
   by T16 (few general-behaviour jobs on the matrix). Measure the real number of
   cells and the minutes (macOS is the main cost) per repo once T16 is applied,
   and report it, before deciding anything else.
2. **Which jobs are general behaviour.** T16 needs a decision per repo: which
   jobs cross the matrix and which run on one runner. The plan of section 7
   gives the first answer for `cancel-queued-runs-action` and
   `extract-pyproject-metadata-action`; the other repos need the same list
   written in their `CLAUDE.md`. A job such as `test-package` of
   `setup-venv-uv-action` can be argued either way.
3. **Single file versus two files.** `setup-venv-uv-action`'s review (6.2)
   chose to keep two files and to release often instead of a generator, and
   `format-files-action`'s review (4.5) leaves the choice open. This review
   proposes the single file for all, because the existing drift (F1) happened in
   spite of the rule. To confirm in a prototype: `if` on every `uses:` step, and
   that `steps.local.outputs.x || steps.released.outputs.x` works when the
   skipped step has no outputs.
4. **`uses: ./exported` (section 4.4)** is not tested here: confirm that GitHub
   accepts a local action path that is a directory extracted at run time, and
   that the extracted archive keeps the files `uses:` needs.
5. **Windows.** Only `build-pypi-package-action` claims it. Four repos do not
   state their position in the files read (F9); confirm and write it in their
   `CLAUDE.md`.
6. **Job counts.** The 13 runners and 104 cells of F2 come from
   `configs/versions.json` and the matrix expressions. Check one real run per
   repo before relying on the saving.
7. **Level 1 for inline actions.** Moving the inline logic of `setup-venv`,
   `build-pypi`, `verify-github-workflow` and `format-files` to scripts is the
   biggest change to enable T5. It is a code change, not a test change; each
   repo's `target_state.md` may already cover it, and was not checked for that.
8. **Mutation check** exists only in `cancel-queued-runs-action`. Decide whether
   to extend it to the repos with a large bats suite (`uv-install`,
   `verify-uv-build`).
