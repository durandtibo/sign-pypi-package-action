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
