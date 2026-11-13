#!/usr/bin/env bash
# The unit tier: runs every row of test/cases.json that does not need a real GitHub service through
# the whole action, on this machine. The real steps of action.yml are extracted and run in order by
# scripts/fake-runner.sh; only the infrastructure is faked (artifact download, Sigstore, gh over a
# store directory, the OIDC token). Each row asserts the failed-check id and the state of the fake
# releases afterwards: assets byte-identical to the dist, nothing attached by a rejected run, drafts
# kept, no tag created or removed, and no gh call at all when a check before the release fails.
# It needs no GitHub runner, so it runs in seconds on any OS and makes no API call. Rows with
# "integration": true (the real artifact service) are for ci-action.yaml only. Signing itself is
# only tested there, never here.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/test-helper.sh
source "${root}/scripts/test-helper.sh"
# shellcheck source=scripts/fake-runner.sh
source "${root}/scripts/fake-runner.sh"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
fake_runner_init "${root}/action.yml" "${work}"

# The ids of the checks that run before any release call: a run rejected by one of them must not
# have called gh at all.
before_release="tag checksums-file file-set checksum permissions bundle"

# make_base <dir>: a good distribution set with its SHA256SUMS.
make_base() {
	mkdir -p "$1"
	(
		cd "$1"
		printf 'sdist' >pkg-1.0.0.tar.gz
		printf 'wheel' >pkg-1.0.0-py3-none-any.whl
		sha256sum -- *.tar.gz *.whl >SHA256SUMS
	)
}

# run_row <name> <expected> <tag kind> <runs> <gh-fail> <sign mode> <oidc> <ref> <stage (base64)>
# Prints one line per problem; no output means the row passed.
run_row() {
	local name="$1" expected="$2" kind="$3" runs="$4" ghfail="$5" sign="$6" oidc="$7" ref="$8" stage="$9"
	local cdir="${work}/case-${name}" store tag1 tag2 src1 id last_run calls_before=0 state_before
	store="${cdir}/store"
	rm -rf "${cdir}"
	make_base "${cdir}/base"
	cp -R "${cdir}/base" "${cdir}/staged"
	(cd "${cdir}/staged" && bash -euo pipefail -c "$(printf '%s' "${stage}" | base64 --decode)")

	# The tag of each run, and the repository as it was before: what the kind of the row seeds.
	case "${kind}" in
	none) tag1="" ;;
	dash) tag1="-bad-v1" ;;
	space) tag1="bad tag v1" ;;
	*) tag1="v1" ;;
	esac
	tag2="${tag1}"
	if [ "${runs}" = 2 ] && [ "${kind}" = new ]; then tag2="v1-2"; fi
	fake_gh_seed "${store}" "${kind}" "${tag1}"
	if [ "${tag2}" != "${tag1}" ]; then fake_gh_seed "${store}" "${kind}" "${tag2}"; fi
	cp "${store}/tags" "${cdir}/tags.before"

	export FR_STORE="${store}" FR_TAG_INPUT="${tag1}" FR_REF_TYPE=branch FR_REF_NAME=main
	export FR_OIDC=1 FR_SIGN=all FR_GH_FAIL=
	if [ "${ref}" = tag ]; then
		FR_TAG_INPUT="" FR_REF_TYPE=tag FR_REF_NAME="${tag1}"
	fi
	# With two runs, the first one is a good run of the base dist on the first tag; the row then
	# applies to the second run only.
	src1="${cdir}/staged"
	if [ "${runs}" = 2 ]; then
		src1="${cdir}/base"
		fake_run_action "${cdir}/run1" "${cdir}/rt" "${src1}"
		id="$(cat "${cdir}/run1/failed-check")"
		[ -z "${id}" ] || echo "the first run failed with '${id}'"
		if [ -f "${store}/calls.log" ]; then calls_before="$(wc -l <"${store}/calls.log" | tr -d ' ')"; fi
		FR_TAG_INPUT="${tag2}"
		src1="${cdir}/staged"
	fi
	FR_OIDC="${oidc}" FR_SIGN="${sign}" FR_GH_FAIL="${ghfail}"
	last_run="${cdir}/run${runs}"
	fake_run_action "${last_run}" "${cdir}/rt" "${src1}"
	id="$(cat "${last_run}/failed-check")"
	[ "${id}" = "${expected}" ] || echo "expected failed-check '${expected}', got '${id}'"

	# A check before the release must stop the run before any gh call.
	case " ${before_release} " in
	*" ${expected} "*)
		if [ -f "${store}/calls.log" ] && [ "$(wc -l <"${store}/calls.log" | tr -d ' ')" != "${calls_before}" ]; then
			echo "a run rejected by '${expected}' called gh: $(tail -n +$((calls_before + 1)) "${store}/calls.log" | tr '\n' ';')"
		fi
		;;
	esac

	# No tag is ever created or removed by the action.
	cmp -s "${cdir}/tags.before" "${store}/tags" || echo "the tags changed: $(tr '\n' ' ' <"${cdir}/tags.before")-> $(tr '\n' ' ' <"${store}/tags")"

	# The state a release must be in afterwards: the action publishes only a release it created.
	case "${kind}" in
	tagged | published) state_before=published ;;
	*) state_before=draft ;;
	esac
	if [ -z "${expected}" ]; then
		assert_fake_release_matches_dist "${store}" "${tag2}" "${cdir}/staged" || true
		[ "$(fake_release_state "${store}" "${tag2}")" = "${state_before}" ] ||
			echo "release ${tag2} is '$(fake_release_state "${store}" "${tag2}")', expected '${state_before}'"
		if [ "${tag2}" != "${tag1}" ]; then
			assert_fake_release_matches_dist "${store}" "${tag1}" "${cdir}/base" || true
		fi
	elif [ "${runs}" = 1 ]; then
		# A rejected run attaches nothing, and leaves no release that it created.
		case "${kind}" in
		tagged | missing | none | dash | space)
			[ "$(fake_release_state "${store}" "${tag1}")" = absent ] ||
				echo "a rejected run left release ${tag1} behind"
			;;
		*)
			[ -z "$(fake_release_assets "${store}" "${tag1}")" ] ||
				echo "a rejected run attached: $(fake_release_assets "${store}" "${tag1}" | tr '\n' ' ')"
			[ "$(fake_release_state "${store}" "${tag1}")" = "${state_before}" ] ||
				echo "release ${tag1} is now '$(fake_release_state "${store}" "${tag1}")', expected '${state_before}'"
			;;
		esac
	else
		# After a rejected second run, the first run's release is intact (no asset overwritten).
		assert_fake_release_matches_dist "${store}" "${tag1}" "${cdir}/base" || true
	fi
}

failures=0 ran=0 skipped=0
while IFS='|' read -r name expected kind runs ghfail sign oidc ref stage; do
	ran=$((ran + 1))
	problems="$(run_row "${name}" "${expected}" "${kind}" "${runs}" "${ghfail}" "${sign}" "${oidc}" "${ref}" "${stage}" 2>&1)"
	if [ -z "${problems}" ]; then
		echo "ok   ${name}"
	else
		echo "FAIL ${name}"
		printf '       %s\n' "${problems}"
		failures=$((failures + 1))
	fi
done < <(jq -r '.[] | select(.integration != true) | [
	.name, .expected, (.tag // "new"), ((.runs // 1) | tostring), (.["gh-fail"] // ""), (.sign // "all"),
	(if .oidc == false then "0" else "1" end), (.ref // ""), (.stage | @base64)] | join("|")' "${root}/test/cases.json")
skipped="$(jq '[.[] | select(.integration == true)] | length' "${root}/test/cases.json")"

echo "${ran} local cases, ${failures} failed (${skipped} left to ci-action.yaml: they need the real artifact service)"
[ "${failures}" = 0 ]
