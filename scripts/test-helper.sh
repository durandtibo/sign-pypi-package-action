#!/usr/bin/env bash
# Shared assertions for ci-action.yaml, which tests both the current checkout
# and the last released tag, so verification logic is written once.
set -euo pipefail

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
