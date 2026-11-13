#!/usr/bin/env bash
# Shared assertions for ci-action.yaml, which tests both the current checkout
# and the last released tag, so verification logic is written once, and the fakes of the
# unit tests (scripts/test-local.sh, scripts/test-steps.sh): a fake `gh` store and a fake signer.
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

# fake_gh_seed <store> <kind> <tag>: prepare the store of test/fake-gh/gh for a "tag" kind of
# test/cases.json, so that the action finds what a real repository would hold before the run:
#   new, same, draft  the tag was pushed and a draft release exists
#   published         the tag was pushed and a published release exists
#   tagged            the tag was pushed, there is no release
#   missing           neither the tag nor a release exists (also none, dash, space: no tag is used)
fake_gh_seed() {
	local store="$1" kind="$2" tag="$3"
	mkdir -p "${store}"
	touch "${store}/tags"
	case "${kind}" in
	new | same | draft | published | tagged) echo "${tag}" >>"${store}/tags" ;;
	missing | none | dash | space) return 0 ;;
	*)
		echo "::error::unknown tag kind '${kind}'"
		return 1
		;;
	esac
	case "${kind}" in
	new | same | draft)
		mkdir -p "${store}/${tag}/assets"
		echo draft >"${store}/${tag}/state"
		;;
	published)
		mkdir -p "${store}/${tag}/assets"
		echo published >"${store}/${tag}/state"
		;;
	esac
}

# fake_sigstore_sign <mode> <file>...: stands in for step 2.2 (Sigstore), which cannot run without
# an OIDC token. It writes <file>.sigstore.json for each file, so that what is tested is the logic
# around signing (step 2.3), never Sigstore itself. Modes:
#   all             a bundle for every file
#   skip:<name>     a bundle for every file except <name>
#   empty:<name>    an empty bundle for <name>
#   none            no bundle at all
fake_sigstore_sign() {
	local mode="$1" f
	shift
	for f in "$@"; do
		case "${mode}" in
		all) echo '{}' >"${f}.sigstore.json" ;;
		skip:*) [ "$(basename "${f}")" = "${mode#skip:}" ] || echo '{}' >"${f}.sigstore.json" ;;
		empty:*) if [ "$(basename "${f}")" = "${mode#empty:}" ]; then : >"${f}.sigstore.json"; else echo '{}' >"${f}.sigstore.json"; fi ;;
		none) ;;
		*)
			echo "::error::unknown fake signer mode '${mode}'"
			return 1
			;;
		esac
	done
}

# fake_release_state <store> <tag>: "draft", "published" or "absent" in the store of test/fake-gh.
fake_release_state() {
	if [ -f "$1/$2/state" ]; then cat "$1/$2/state"; else echo absent; fi
}

# fake_release_assets <store> <tag>: the sorted asset names of the release, one per line.
fake_release_assets() {
	if [ -d "$1/$2/assets" ]; then (cd "$1/$2/assets" && find . -type f | sed 's|^\./||' | LC_ALL=C sort); fi
}

# assert_fake_release_matches_dist <store> <tag> <dist-dir>
# The fake release holds exactly the assets expected for the dist (see release_asset_names, with
# the bundle of SHA256SUMS), every distribution and SHA256SUMS is byte-identical to its source,
# and every bundle is non-empty. Prints the problem and returns 1 instead of exiting.
assert_fake_release_matches_dist() {
	local store="$1" tag="$2" dist="$3" expected actual f
	expected="$(release_asset_names "${dist}" true | LC_ALL=C sort)"
	actual="$(fake_release_assets "${store}" "${tag}")"
	[ "${expected}" = "${actual}" ] || {
		echo "release ${tag} assets differ from the dist ('<' missing, '>' unexpected):"
		diff <(echo "${expected}") <(echo "${actual}") || true
		return 1
	}
	for f in SHA256SUMS $(sed -E 's/^.{64} .//' "${dist}/SHA256SUMS"); do
		cmp -s "${dist}/${f}" "${store}/${tag}/assets/${f}" || {
			echo "release asset ${f} of ${tag} is not identical to the file that was checksummed"
			return 1
		}
	done
	for f in $(echo "${actual}" | grep '\.sigstore\.json$'); do
		[ -s "${store}/${tag}/assets/${f}" ] || {
			echo "bundle ${f} of ${tag} is empty"
			return 1
		}
	done
}

# use_fake_gh <store> <seed kind> <tag>: for a workflow job. Seeds the store of test/fake-gh for the
# tag (see fake_gh_seed) and puts the fake gh first on the PATH of the later steps of the job, the
# steps of composite actions included, and tells it where its store is.
use_fake_gh() {
	local store="$1" root
	root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
	fake_gh_seed "$@"
	echo "${root}/test/fake-gh" >>"${GITHUB_PATH}"
	echo "FAKE_GH_ROOT=${store}" >>"${GITHUB_ENV}"
}

# assert_fake_gh_used <store>: the action called the fake gh to attach assets. Without it a PATH
# that did not apply would let the action call the real gh and the test could pass by accident.
assert_fake_gh_used() {
	grep -q '^release upload ' "$1/calls.log" 2>/dev/null || {
		echo "::error::the fake gh was not called to upload assets: the PATH did not apply to the action"
		exit 1
	}
}

# assert_fake_release_verifies <store> <tag> <repository>
# What a consumer does with the assets of the release: verify each one with its bundle.
assert_fake_release_verifies() {
	local store="$1" tag="$2" repository="$3" tmp f files=()
	tmp="$(mktemp -d)"
	cp "${store}/${tag}/assets/"* "${tmp}/"
	for f in "${tmp}"/*.tar.gz "${tmp}"/*.whl "${tmp}/SHA256SUMS"; do
		[ -e "${f}" ] && files+=("${f}")
	done
	assert_sigstore_valid "${repository}" "${files[@]}"
	rm -rf "${tmp}"
}

# assert_wheel_and_sdist_only <dir>
# The directory holds exactly one wheel and one sdist and nothing else: what the build action
# produces and what the checksums are generated from.
assert_wheel_and_sdist_only() {
	local dir="$1" files wheels sdists
	files="$(find "${dir}" -mindepth 1 | wc -l | tr -d ' ')"
	wheels="$(find "${dir}" -mindepth 1 -maxdepth 1 -name '*.whl' | wc -l | tr -d ' ')"
	sdists="$(find "${dir}" -mindepth 1 -maxdepth 1 -name '*.tar.gz' | wc -l | tr -d ' ')"
	if [ "${files}" != 2 ] || [ "${wheels}" != 1 ] || [ "${sdists}" != 1 ]; then
		echo "::error::${dir} must hold exactly one wheel and one sdist, found ${wheels} wheel(s), ${sdists} sdist(s) among ${files} file(s):"
		find "${dir}" -mindepth 1
		exit 1
	fi
}

# create_draft_release <tag>: a draft release for the tag, as a user could create beforehand.
# Drafts are visible only to people with write access and create no tag (the tag would be
# created when publishing), so the tests leave nothing on the public releases or tags pages.
create_draft_release() {
	local tag="$1"
	gh release create "${tag}" \
		--repo "${GITHUB_REPOSITORY}" \
		--draft \
		--title "Test run ${tag} (throwaway, will be deleted)" \
		--notes "Draft created by the CI workflow, deleted at the end of the run." \
		--target "${GITHUB_SHA}"
}

# delete_release <tag>: remove a draft made by create_draft_release; never fails.
# The title marker "(throwaway, will be deleted)" is what `make clean-throwaway-releases` matches.
delete_release() {
	local tag="$1"
	gh release delete "${tag}" --repo "${GITHUB_REPOSITORY}" --yes >/dev/null 2>&1 || true
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
