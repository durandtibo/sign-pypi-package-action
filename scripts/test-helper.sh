#!/usr/bin/env bash
# Shared assertions for the CI workflows, so test-local.yaml (and a future
# test-stable.yaml once a release is tagged) only differ in which sign
# action ref they exercise (local checkout vs. a released tag), not in
# verification logic.
set -euo pipefail

# assert_sigstore_valid <repository> <file>...
assert_sigstore_valid() {
	local repository="$1"
	shift
	uvx sigstore verify github --repository "${repository}" "$@"
}

# assert_signatures_artifact_uploaded <run-id>
assert_signatures_artifact_uploaded() {
	local run_id="$1"
	gh api "repos/${GITHUB_REPOSITORY}/actions/runs/${run_id}/artifacts" \
		--jq '.artifacts[].name' | grep -qx 'signatures'
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

# delete_dist_artifacts <repository> <run-id>
# Deletes every "dist"-named artifact already uploaded in this run. Needed
# because test-stable.yaml's checksum-rejection jobs run the pinned stable
# action, which always downloads an artifact literally named "dist" (it
# predates the dist-artifact-name input); those jobs are serialized with
# "needs" and each must clear out the previous job's "dist" artifact before
# uploading its own, since artifacts are scoped to the whole run rather
# than the job and a stale one would make the by-name download ambiguous.
delete_dist_artifacts() {
	local repository="$1" run_id="$2"
	local id
	gh api "repos/${repository}/actions/runs/${run_id}/artifacts" --paginate \
		--jq '.artifacts[] | select(.name == "dist") | .id' |
		while read -r id; do
			gh api -X DELETE "repos/${repository}/actions/artifacts/${id}"
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
