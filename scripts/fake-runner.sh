#!/usr/bin/env bash
# A fake runner for the unit tests: runs the real steps of action.yml, in order, on this machine.
# Only the infrastructure is replaced:
#   1.1 download-artifact  -> a copy of a staged directory into ${RUNNER_TEMP}/sign-pypi-package
#   2.2 Sigstore           -> fake_sigstore_sign (scripts/test-helper.sh)
#   gh                     -> test/fake-gh (a store directory instead of GitHub)
#   OIDC                   -> ACTIONS_ID_TOKEN_REQUEST_URL is set or unset
# The run stops at the first failing step, like a job does, and step 4.2 (`if: failure()`) then
# reports the failed-check id. Source it after scripts/test-helper.sh.

# fake_runner_init <action.yml> <dir>: extracts every step to <dir>/steps. Call it once.
fake_runner_init() {
	local s
	FR_STEPS="$2/steps"
	FR_FAKE_BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/../test/fake-gh" && pwd)"
	mkdir -p "${FR_STEPS}"
	for s in 0.1 0.2 1.2 1.3 1.4 2.1 2.3 3.1 4.1 4.2; do extract_step "$1" "${s}" >"${FR_STEPS}/step-${s}.sh"; done
}

# fake_run_action <run-dir> <runner-temp> <staged-dist>: one run of the action. Prints nothing; the
# result is in <run-dir>: `failed-check` (the id, empty on success), `status` (0 or 1), `log-<step>`.
# Configuration, from the environment of the caller (unset = default):
#   FR_STORE        the store of the fake gh (required)
#   FR_TAG_INPUT    the tag-name input (default empty)
#   FR_REF_TYPE, FR_REF_NAME  the ref of the run (default: branch main)
#   FR_OIDC         0 = the job has no id-token permission (default 1)
#   FR_SIGN         the mode of fake_sigstore_sign (default all)
#   FR_GH_FAIL      FAKE_GH_FAIL of the fake gh
# <runner-temp> is shared by the runs of one job, so a second run sees what the first one left.
# A <staged-dist> that is not a directory is an artifact that does not exist (step 1.1 fails).
fake_run_action() {
	local rd="$1" rt="$2" src="$3" dist="$2/sign-pypi-package" failed=0 files inputs tag
	mkdir -p "${rd}" "${rt}"
	: >"${rd}/summary"
	# s <step> [VAR=value...]: runs a step; once a step failed, the rest of the run is skipped.
	s() {
		local n="$1"
		shift
		[ "${failed}" = 0 ] || return 0
		: >"${rd}/out-${n}"
		env RUNNER_TEMP="${rt}" GITHUB_OUTPUT="${rd}/out-${n}" GITHUB_STEP_SUMMARY="${rd}/summary" \
			GITHUB_REPOSITORY=o/r GITHUB_SERVER_URL=https://github.com \
			PATH="${FR_FAKE_BIN}:${PATH}" FAKE_GH_ROOT="${FR_STORE}" FAKE_GH_FAIL="${FR_GH_FAIL:-}" \
			"$@" bash "${FR_STEPS}/step-${n}.sh" >"${rd}/log-${n}" 2>&1 || failed=1
	}
	out() { if [ -f "${rd}/out-$1" ]; then sed -n "s/^$2=//p" "${rd}/out-$1"; fi; }

	s 0.1
	s 0.2 INPUT_TAG="${FR_TAG_INPUT:-}" REF_TYPE="${FR_REF_TYPE:-branch}" REF_NAME="${FR_REF_NAME:-main}"
	# 1.1: what download-artifact does, or its failure.
	if [ "${failed}" = 0 ]; then
		if [ -d "${src}" ]; then
			mkdir -p "${dist}" && cp -R "${src}/." "${dist}/"
		else
			echo "Unable to download artifact (fake): ${src} does not exist" >"${rd}/log-1.1"
			failed=1
		fi
	fi
	s 1.2 DIST="${dist}" ARTIFACT=dist
	files="$(out 1.2 files)" inputs="$(out 1.2 inputs)" tag="$(out 0.2 tag)"
	s 1.3 DIST="${dist}" FILES="${files}"
	s 1.4 DIST="${dist}"
	if [ "${FR_OIDC:-1}" = 0 ]; then
		s 2.1 ACTIONS_ID_TOKEN_REQUEST_URL=
	else
		s 2.1 ACTIONS_ID_TOKEN_REQUEST_URL=https://token.example/fake
	fi
	if [ "${failed}" = 0 ]; then
		# Word splitting is intended: names are plain file names (step 1.2).
		# shellcheck disable=SC2086
		fake_sigstore_sign "${FR_SIGN:-all}" ${inputs} || failed=1
	fi
	s 2.3 DIST="${dist}" FILES="${files}"
	s 3.1 GH_TOKEN=fake DIST="${dist}" TAG="${tag}" FILES="${files}"
	s 4.1 DIST="${dist}" TAG="${tag}" FILES="${files}"
	echo "${failed}" >"${rd}/status"
	: >"${rd}/failed-check"
	if [ "${failed}" = 1 ]; then
		# Step 4.2 is `if: failure()`; an id that was never recorded is "unexpected".
		failed=0
		s 4.2
		sed -n 's/^failed-check=//p' "${rd}/out-4.2" >"${rd}/failed-check"
	fi
}
