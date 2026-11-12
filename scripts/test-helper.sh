#!/usr/bin/env bash
# Shared assertions for ci-action.yaml, which tests both the current checkout
# and the last released tag, so verification logic is written once.
set -euo pipefail

# extract_step <action.yml> <step number>: the run: block of the step (for example "3.1"), de-indented.
extract_step() {
	awk -v p="- name: $2 " '
		index($0, p) { s = 1; next }
		s && /^    - name:/ { exit }
		s && /^      run: \|/ { r = 1; next }
		s && r { sub(/^        /, ""); print }
	' "$1"
}

# create_release <tag> [extra gh flag...]: a throwaway release (and its tag) on the current commit.
create_release() {
	local tag="$1"
	shift
	gh release create "${tag}" \
		--repo "${GITHUB_REPOSITORY}" \
		--title "Test run ${tag} (throwaway, will be deleted)" \
		--notes "Created by the CI workflow, safe to ignore/delete." \
		--target "${GITHUB_SHA}" \
		"$@"
}

# create_draft_release <tag>: a draft release on an existing tag, as a user could create beforehand.
create_draft_release() {
	local tag="$1"
	create_tag "${tag}"
	create_release "${tag}" --draft --verify-tag
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

# release_asset_names <dist-dir> <with-sums-bundle: true|false>
# The names the release must hold for a dist directory: SHA256SUMS, every file it lists, and a
# bundle for each (SHA256SUMS.sigstore.json only when the tested version signs the checksums file).
release_asset_names() {
	local dist="$1" sums_bundle="$2" names
	names="$(sed -E 's/^.{64} .//' "${dist}/SHA256SUMS")"
	{
		echo SHA256SUMS
		echo "${names}"
		echo "${names}" | awk '{ print $0 ".sigstore.json" }'
		if [ "${sums_bundle}" = "true" ]; then echo SHA256SUMS.sigstore.json; fi
	} | sort
}

# assert_release_matches_dist <tag> <dist-dir> <with-sums-bundle: true|false>
# The release holds exactly the assets expected for the dist the action was given (nothing missing,
# nothing extra), and every uploaded distribution and SHA256SUMS is byte-identical to its source.
assert_release_matches_dist() {
	local tag="$1" dist="$2" sums_bundle="$3" expected actual tmp f
	expected="$(release_asset_names "${dist}" "${sums_bundle}")"
	actual="$(gh release view "${tag}" --repo "${GITHUB_REPOSITORY}" --json assets --jq '.assets[].name' | sort)"
	[ "${expected}" = "${actual}" ] || {
		echo "::error::release ${tag} assets differ from the dist ('<' missing, '>' unexpected):"
		diff <(echo "${expected}") <(echo "${actual}") || true
		exit 1
	}
	tmp="$(mktemp -d)"
	gh release download "${tag}" --repo "${GITHUB_REPOSITORY}" --dir "${tmp}"
	for f in SHA256SUMS $(sed -E 's/^.{64} .//' "${dist}/SHA256SUMS"); do
		cmp -s "${dist}/${f}" "${tmp}/${f}" || {
			echo "::error::release asset ${f} of ${tag} is not identical to the file that was checksummed"
			exit 1
		}
	done
	rm -rf "${tmp}"
}

# assert_release_verifies <tag> <repository> <with-sums-bundle: true|false>
# What a consumer does: download the release assets and verify each one with its bundle.
assert_release_verifies() {
	local tag="$1" repository="$2" sums_bundle="$3" tmp f files=()
	tmp="$(mktemp -d)"
	gh release download "${tag}" --repo "${GITHUB_REPOSITORY}" --dir "${tmp}"
	for f in "${tmp}"/*.tar.gz "${tmp}"/*.whl; do
		[ -e "${f}" ] && files+=("${f}")
	done
	if [ "${sums_bundle}" = "true" ]; then files+=("${tmp}/SHA256SUMS"); fi
	assert_sigstore_valid "${repository}" "${files[@]}"
	rm -rf "${tmp}"
}

# assert_release_draft <tag>
# A release that existed as a draft before the run is only added to, never published by the action.
assert_release_draft() {
	local tag="$1" draft
	draft="$(gh release view "${tag}" --repo "${GITHUB_REPOSITORY}" --json isDraft --jq '.isDraft')"
	[ "${draft}" = "true" ] || {
		echo "::error::release ${tag} existed as a draft and must stay one (isDraft=${draft})"
		exit 1
	}
}

# assert_no_release <tag>
# A run rejected before releasing leaves no release (not even a draft) behind.
assert_no_release() {
	local tag="$1"
	if gh release view "${tag}" --repo "${GITHUB_REPOSITORY}" >/dev/null 2>&1; then
		echo "::error::release ${tag} exists after a run that must not create one"
		exit 1
	fi
}

# assert_release_published <tag>
# A release created by the action is public once it is done, not left as a draft.
assert_release_published() {
	local tag="$1" draft
	draft="$(gh release view "${tag}" --repo "${GITHUB_REPOSITORY}" --json isDraft --jq '.isDraft')"
	[ "${draft}" = "false" ] || {
		echo "::error::release ${tag} is not published (isDraft=${draft})"
		exit 1
	}
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
