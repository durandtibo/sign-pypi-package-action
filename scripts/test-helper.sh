#!/usr/bin/env bash
# Shared assertions for ci-action.yaml, which tests both the current checkout
# and the last released tag, so verification logic is written once.
set -euo pipefail

# create_release <tag>: a throwaway release (and its tag) on the current commit.
create_release() {
	local tag="$1"
	gh release create "${tag}" \
		--repo "${GITHUB_REPOSITORY}" \
		--title "Test run ${tag} (throwaway, will be deleted)" \
		--notes "Created by the CI workflow, safe to ignore/delete." \
		--target "${GITHUB_SHA}"
}

# create_tag <tag>: a tag on the current commit, without a release.
create_tag() {
	local tag="$1"
	gh api "repos/${GITHUB_REPOSITORY}/git/refs" -f "ref=refs/tags/${tag}" -f "sha=${GITHUB_SHA}" >/dev/null
}

# delete_release_and_tag <tag>: remove what create_release or create_tag made.
# Also removes a tag created by the action itself; never fails.
delete_release_and_tag() {
	local tag="$1"
	gh release delete "${tag}" --repo "${GITHUB_REPOSITORY}" --yes --cleanup-tag >/dev/null 2>&1 || true
	gh api -X DELETE "repos/${GITHUB_REPOSITORY}/git/refs/tags/${tag}" >/dev/null 2>&1 || true
}

# assert_sigstore_valid <repository> <file>...
assert_sigstore_valid() {
	local repository="$1"
	shift
	uvx sigstore verify github --repository "${repository}" "$@"
}

# assert_release_assets <tag>
assert_release_assets() {
	local tag="$1"
	local assets
	assets="$(gh release view "${tag}" --repo "${GITHUB_REPOSITORY}" --json assets --jq '.assets[].name')"
	for pattern in '\.tar\.gz$' '\.whl$' '\.sigstore\.json$' '^SHA256SUMS$'; do
		echo "${assets}" | grep -qE "${pattern}" || {
			echo "::error::no release asset matching '${pattern}', got: ${assets}"
			exit 1
		}
	done
}

# assert_no_assets <tag>
# A rejected run must stop before signing and releasing: the release has no
# assets, or does not exist. An empty tag (no tag given) passes.
assert_no_assets() {
	local tag="$1" assets
	[ -n "${tag}" ] || return 0
	if ! assets="$(gh release view "${tag}" --repo "${GITHUB_REPOSITORY}" --json assets --jq '.assets[].name' 2>/dev/null)"; then
		return 0
	fi
	[ -z "${assets}" ] || {
		echo "::error::release ${tag} has assets after a rejected run: ${assets}"
		exit 1
	}
}

# assert_single_error <log-file>
# The log of a failing step holds exactly one "::error" command, and untrusted
# text could not add another or change it: '%' is escaped.
assert_single_error() {
	local log="$1" count
	count="$(grep -c '^::error' "${log}" || true)"
	[ "${count}" = 1 ] || {
		echo "::error::expected exactly one ::error line, got ${count}"
		exit 1
	}
	grep -qF '%250A::error::x' "${log}" || {
		echo "::error::'%' in the details was not escaped in the annotation"
		exit 1
	}
}

# assert_fail_helper_escapes <action.yml>
# Runs the failure helper of step 0.1 on hostile details (a fake workflow command,
# a CR, a fence) and checks the annotation and the summary. Needs no GitHub runner.
assert_fail_helper_escapes() {
	local action="$1" dir hostile
	dir="$(mktemp -d)"
	awk '/<<.EOF.$/ {f=1; next} /^ *EOF$/ {f=0} f' "${action}" >"${dir}/fail.sh"
	hostile=$'line %0A::error::x\r\n``` ~~~~~~ end'
	(RUNNER_TEMP="${dir}" GITHUB_STEP_SUMMARY="${dir}/summary" \
		bash -c 'source "${RUNNER_TEMP}/fail.sh"; fail test-id "A title" "$1" "A fix"' _ "${hostile}") >"${dir}/log" || true
	assert_single_error "${dir}/log"
	grep -qF '%0D' "${dir}/log" || {
		echo "::error::CR in the details was not escaped in the annotation"
		exit 1
	}
	[ "$(cat "${dir}/failed-check")" = test-id ] || {
		echo "::error::failed-check was not written"
		exit 1
	}
	grep -qx '~~~~~~~text' "${dir}/summary" || {
		echo "::error::the summary fence is not longer than the '~' run of the details"
		exit 1
	}
	rm -rf "${dir}"
}

# assert_failure <label> <actual-outcome>
assert_failure() {
	local label="$1" actual_outcome="$2"

	test "${actual_outcome}" = "failure" || {
		echo "::error::expected ${label} to fail, got outcome=${actual_outcome}"
		exit 1
	}
}

# assert_failed_check <label> <expected-id> <actual-id>
# The action's failed-check output is empty on success; tests assert the id,
# never the message text.
assert_failed_check() {
	local label="$1" expected="$2" actual="$3"

	test "${actual}" = "${expected}" || {
		echo "::error::${label}: expected failed-check '${expected}', got '${actual}'"
		exit 1
	}
}

# assert_success <label> <actual-outcome>
assert_success() {
	local label="$1" actual_outcome="$2"

	test "${actual_outcome}" = "success" || {
		echo "::error::expected ${label} to succeed, got outcome=${actual_outcome}"
		exit 1
	}
}
