#!/usr/bin/env bash
# Runs the local checks of action.yml (steps 0.2, 1.2, 1.3, 1.4) on every row of
# test/cases.json that needs no GitHub release, against a fake distribution set.
# The step scripts are extracted from action.yml, so this tests the real code on
# the developer's machine (and on any OS) in seconds. It cannot replace
# ci-action.yaml: signing, releasing and permissions need a runner.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
action="${root}/action.yml"
# shellcheck source=scripts/test-helper.sh
source "${root}/scripts/test-helper.sh"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

for s in 0.1 0.2 1.2 1.3 1.4; do extract_step "${action}" "${s}" >"${work}/step-${s}.sh"; done
# Step 0.1 writes fail.sh through a heredoc: run it to get the helper.
RUNNER_TEMP="${work}" bash "${work}/step-0.1.sh"

# run_case <name> <stage> <tag-kind>: prints the failed-check id ("" = accepted).
run_case() {
	local name="$1" stage="$2" kind="$3" dir="${work}/${1}" id=""
	mkdir -p "${dir}/rt/sign-pypi-package"
	(
		cd "${dir}/rt/sign-pypi-package"
		printf 'sdist' >pkg-1.0.0.tar.gz
		printf 'wheel' >pkg-1.0.0-py3-none-any.whl
		sha256sum -- *.tar.gz *.whl >SHA256SUMS
		bash -euo pipefail -c "${stage}"
	)
	export RUNNER_TEMP="${dir}/rt" GITHUB_STEP_SUMMARY="${dir}/summary" GITHUB_OUTPUT="${dir}/out"
	export DIST="${dir}/rt/sign-pypi-package" ARTIFACT=dist
	: >"${GITHUB_STEP_SUMMARY}" && : >"${GITHUB_OUTPUT}"
	cp "${work}/fail.sh" "${RUNNER_TEMP}/fail.sh"
	run() { bash "${work}/step-$1.sh" >"${dir}/log-$1" 2>&1; }
	case "${kind}" in
	none) INPUT_TAG="" REF_TYPE=branch REF_NAME=main run 0.2 || true ;;
	dash) INPUT_TAG="-bad" REF_TYPE=branch REF_NAME=main run 0.2 || true ;;
	space) INPUT_TAG="bad tag" REF_TYPE=branch REF_NAME=main run 0.2 || true ;;
	esac
	if [ ! -s "${RUNNER_TEMP}/failed-check" ]; then
		run 1.2 || true
		if [ ! -s "${RUNNER_TEMP}/failed-check" ]; then
			FILES="$(sed -n 's/^files=//p' "${GITHUB_OUTPUT}")" run 1.3 || true
		fi
		if [ ! -s "${RUNNER_TEMP}/failed-check" ]; then run 1.4 || true; fi
	fi
	if [ -s "${RUNNER_TEMP}/failed-check" ]; then id="$(cat "${RUNNER_TEMP}/failed-check")"; fi
	echo "${id}"
}

failures=0 ran=0
while IFS='|' read -r name expected kind runs stage; do
	# Rows that need a release, a second run or signing are for ci-action.yaml.
	case "${kind}" in none | dash | space | new) ;; *) continue ;; esac
	[ "${runs}" = 1 ] || continue
	stage="$(printf '%s' "${stage}" | base64 --decode)"
	actual="$(run_case "${name}" "${stage}" "${kind}")"
	ran=$((ran + 1))
	if [ "${actual}" = "${expected}" ]; then
		echo "ok   ${name}"
	else
		echo "FAIL ${name}: expected '${expected}', got '${actual}'"
		failures=$((failures + 1))
	fi
done < <(jq -r '.[] | select(.artifact == null) | [.name, .expected, (.tag // "new"), (.runs // 1 | tostring), (.stage | @base64)] | join("|")' "${root}/test/cases.json")

echo "${ran} local cases, ${failures} failed"
[ "${failures}" = 0 ]
