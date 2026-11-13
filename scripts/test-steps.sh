#!/usr/bin/env bash
# Step-level tests of action.yml that need no GitHub runner. The run: block of each bash step is
# extracted from action.yml and executed on a fake runner directory, so the real code is tested:
#   - 0.1 cleanup of a previous run, 0.2 tag resolution (and output injection)
#   - 1.2 outputs, 1.4 with the `shasum -a 256` fallback
#   - 2.1 permission check, 2.3 bundle check
#   - 3.1 release logic against the fake `gh` of test/fake-gh (draft handling, cleanup, no overwrite,
#     no --cleanup-tag), and the fake itself and the `gh` flags it models
#   - 4.1 success summary, 4.2 failed-check output
#   - consistency of action.yml, README.md, test/cases.json and the workflows
# The table of test/cases.json is run by test-local.sh; signing and real releases by ci-action.yaml.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
action="${root}/action.yml"
# shellcheck source=scripts/test-helper.sh
source "${root}/scripts/test-helper.sh"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

for s in 0.1 0.2 1.2 1.4 2.1 2.3 3.1 4.1 4.2; do extract_step "${action}" "${s}" >"${work}/step-${s}.sh"; done
RUNNER_TEMP="${work}" bash "${work}/step-0.1.sh" # writes fail.sh

total=0 failed=0
# check <label> <expected> <actual>
check() {
	total=$((total + 1))
	if [ "$2" = "$3" ]; then
		echo "ok   $1"
	else
		echo "FAIL $1: expected '$2', got '$3'"
		failed=$((failed + 1))
	fi
}
# check_has <label> <file> <fixed string>, check_lacks: the same, for absence.
check_has() {
	total=$((total + 1))
	if grep -qF -- "$3" "$2"; then
		echo "ok   $1"
	else
		echo "FAIL $1: '$3' not found in $2"
		failed=$((failed + 1))
	fi
}
check_lacks() {
	total=$((total + 1))
	if grep -qF -- "$3" "$2"; then
		echo "FAIL $1: '$3' found in $2"
		failed=$((failed + 1))
	else
		echo "ok   $1"
	fi
}

# new_dir <name>: a fake runner directory with the failure helper; prints its path.
new_dir() {
	local d="${work}/$1"
	rm -rf "${d}"
	mkdir -p "${d}/rt/sign-pypi-package"
	: >"${d}/summary"
	: >"${d}/out"
	cp "${work}/fail.sh" "${d}/rt/fail.sh"
	echo "${d}"
}

# run_step <dir> <step> [VAR=value...]: runs the step; the log is <dir>/log-<step>.
STEP_BASH=bash
run_step() {
	local d="$1" s="$2"
	shift 2
	env -u ACTIONS_ID_TOKEN_REQUEST_URL RUNNER_TEMP="${d}/rt" GITHUB_STEP_SUMMARY="${d}/summary" \
		GITHUB_OUTPUT="${d}/out" DIST="${d}/rt/sign-pypi-package" ARTIFACT=dist \
		GITHUB_REPOSITORY=o/r GITHUB_SERVER_URL=https://github.com "$@" \
		"${STEP_BASH}" "${work}/step-${s}.sh" >"${d}/log-${s}" 2>&1
}

# failed_id <dir>: the recorded failed-check id, "" if none.
failed_id() { if [ -s "$1/rt/failed-check" ]; then cat "$1/rt/failed-check"; fi; }

# make_dist <dir> <file>...: the files with their content and a SHA256SUMS.
make_dist() {
	local dir="$1" f
	shift
	for f in "$@"; do printf 'content of %s' "${f}" >"${dir}/${f}"; done
	(cd "${dir}" && if command -v sha256sum >/dev/null 2>&1; then sha256sum -- "$@"; else shasum -a 256 -- "$@"; fi >SHA256SUMS)
}

echo "== step 0.1: a run starts clean"
d="$(new_dir clean)"
mkdir -p "${d}/rt/sign-pypi-package"
echo stale >"${d}/rt/sign-pypi-package/stale.whl"
echo checksum >"${d}/rt/failed-check"
run_step "${d}" 0.1
check "stale failed-check removed" "" "$(failed_id "${d}")"
check "stale work directory removed" "no" "$([ -e "${d}/rt/sign-pypi-package/stale.whl" ] && echo yes || echo no)"
check "helper written" "yes" "$([ -s "${d}/rt/fail.sh" ] && echo yes || echo no)"

echo "== step 0.2: tag resolution"
# tag_case <label> <tag-name input> <ref type> <ref name> <expected: tag=<tag> or the failed id>
tag_case() {
	local d got
	d="$(new_dir "tag-$1")"
	run_step "${d}" 0.2 INPUT_TAG="$2" REF_TYPE="$3" REF_NAME="$4" || true
	got="$(failed_id "${d}")"
	if [ -z "${got}" ]; then got="$(cat "${d}/out")"; fi
	check "tag $1" "$5" "${got}"
}
tag_case input-only v1 branch main tag=v1
tag_case ref-tag "" tag v2 tag=v2
tag_case input-wins v1 tag v2 tag=v1
tag_case plus-and-underscore v1.0.0+build_2 branch main tag=v1.0.0+build_2
tag_case slash release/1.0 branch main tag=release/1.0
tag_case branch-no-input "" branch main tag
tag_case pull-request-no-input "" branch 12/merge tag
tag_case dash -x branch main tag
tag_case space "a b" branch main tag
tag_case tab $'a\tb' branch main tag
tag_case ref-tag-dash "" tag -v tag
tag_case newline-injection $'v1\nfoo=bar' branch main tag
tag_case newline-ref-injection "" tag $'v1\nfoo=bar' tag
# A tag that looks like a workflow command is data: it is written once, unchanged.
tag_case hostile-tag '%0A::error::x' branch main 'tag=%0A::error::x'

echo "== step 1.2: outputs"
for set in "pkg-1.0.0.tar.gz pkg-1.0.0-py3-none-any.whl" "pkg-1.0.0-py3-none-any.whl" "b-1.whl a-1.whl c-1.tar.gz"; do
	d="$(new_dir "sums-${set// /_}")"
	read -r -a names <<<"${set}"
	make_dist "${d}/rt/sign-pypi-package" "${names[@]}"
	run_step "${d}" 1.2
	exp_files="$(printf '%s\n' "${names[@]}" | sort | tr '\n' ' ')"
	exp_inputs="${d}/rt/sign-pypi-package/SHA256SUMS $(printf '%s\n' "${names[@]}" | sort | sed "s|^|${d}/rt/sign-pypi-package/|" | tr '\n' ' ')"
	check "files output of '${set}'" "files=${exp_files}" "$(grep '^files=' "${d}/out")"
	check "inputs output of '${set}'" "inputs=${exp_inputs}" "$(grep '^inputs=' "${d}/out")"
	check "only two outputs of '${set}'" 2 "$(wc -l <"${d}/out" | tr -d ' ')"
done

echo "== step 1.4: the shasum fallback (sha256sum hidden)"
shim="${work}/shim"
mkdir -p "${shim}"
for t in bash env cat grep sed sort uniq tr awk shasum perl ls diff dirname rm head cut; do
	p="$(command -v "${t}" || true)"
	if [ -n "${p}" ]; then ln -s "${p}" "${shim}/${t}"; fi
done
if [ -x "${shim}/shasum" ] && [ -x "${shim}/bash" ] &&
	! PATH="${shim}" "${shim}/bash" -c 'command -v sha256sum' >/dev/null 2>&1 &&
	PATH="${shim}" "${shim}/bash" -c 'shasum -a 256 </dev/null' >/dev/null 2>&1; then
	STEP_BASH="${shim}/bash"
	d="$(new_dir fallback-good)"
	make_dist "${d}/rt/sign-pypi-package" pkg-1.whl pkg-1.tar.gz
	run_step "${d}" 1.4 PATH="${shim}" || true
	check "fallback accepts good files" "" "$(failed_id "${d}")"
	d="$(new_dir fallback-tampered)"
	make_dist "${d}/rt/sign-pypi-package" pkg-1.whl pkg-1.tar.gz
	echo corrupted >>"${d}/rt/sign-pypi-package/pkg-1.whl"
	run_step "${d}" 1.4 PATH="${shim}" || true
	check "fallback rejects a tampered file" "checksum" "$(failed_id "${d}")"
	STEP_BASH=bash
else
	echo "skip the shasum fallback test (needs a POSIX system with shasum and perl)"
fi

echo "== step 2.1: signing permission"
d="$(new_dir perm-yes)"
run_step "${d}" 2.1 ACTIONS_ID_TOKEN_REQUEST_URL=https://token.example/x || true
check "token URL set" "" "$(failed_id "${d}")"
d="$(new_dir perm-unset)"
run_step "${d}" 2.1 || true
check "token URL unset" "permissions" "$(failed_id "${d}")"
d="$(new_dir perm-empty)"
run_step "${d}" 2.1 ACTIONS_ID_TOKEN_REQUEST_URL= || true
check "token URL empty" "permissions" "$(failed_id "${d}")"

echo "== step 2.3: signature bundles"
# bundle_case <label> <expected> <bundles to remove...>; "EMPTY:<name>" empties a bundle instead.
bundle_case() {
	local label="$1" expected="$2" d dist f
	shift 2
	d="$(new_dir "bundle-${label}")"
	dist="${d}/rt/sign-pypi-package"
	make_dist "${dist}" pkg-1.whl pkg-1.tar.gz
	for f in SHA256SUMS pkg-1.whl pkg-1.tar.gz; do echo '{}' >"${dist}/${f}.sigstore.json"; done
	for f in "$@"; do
		case "${f}" in
		EMPTY:*) : >"${dist}/${f#EMPTY:}.sigstore.json" ;;
		*) rm "${dist}/${f}.sigstore.json" ;;
		esac
	done
	run_step "${d}" 2.3 FILES="pkg-1.tar.gz pkg-1.whl " || true
	check "bundles ${label}" "${expected}" "$(failed_id "${d}")"
}
bundle_case all-present ""
bundle_case wheel-missing bundle pkg-1.whl
bundle_case sdist-missing bundle pkg-1.tar.gz
bundle_case sums-missing bundle SHA256SUMS
bundle_case wheel-empty bundle EMPTY:pkg-1.whl
bundle_case sums-empty bundle EMPTY:SHA256SUMS

echo "== step 3.1: release logic with the fake gh (test/fake-gh)"
fakebin="${root}/test/fake-gh"
# release_case <label> <expected id> <expected calls: space-separated verbs> <seed kind> [FAKE_GH_FAIL=verb]
# The verbs are the gh subcommands (view, create, upload, edit, delete) in the order of the calls.
# The seed kind is the state of the repository before the run (see fake_gh_seed). Afterwards
# $store holds the releases, for the checks of the caller.
release_case() {
	local label="$1" expected="$2" calls="$3" kind="$4" d dist got log
	shift 4
	d="$(new_dir "release-${label}")"
	dist="${d}/rt/sign-pypi-package"
	store="${d}/store"
	make_dist "${dist}" pkg-1.whl pkg-1.tar.gz
	(cd "${dist}" && fake_sigstore_sign all SHA256SUMS pkg-1.whl pkg-1.tar.gz)
	fake_gh_seed "${store}" "${kind}" v1
	cp "${store}/tags" "${d}/tags.before"
	run_step "${d}" 3.1 PATH="${fakebin}:${PATH}" FAKE_GH_ROOT="${store}" GH_TOKEN=x TAG=v1 \
		FILES="pkg-1.tar.gz pkg-1.whl " "$@" || true
	log="${store}/calls.log"
	check "release ${label}: failed-check" "${expected}" "$(failed_id "${d}")"
	got="$(awk '{print $2}' "${log}" | tr '\n' ' ')"
	check "release ${label}: gh calls" "${calls}" "${got% }"
	check_lacks "release ${label}: never --cleanup-tag" "${log}" "--cleanup-tag"
	check_lacks "release ${label}: never --clobber" "${log}" "--clobber"
	check "release ${label}: the tag list is unchanged" "$(cat "${d}/tags.before")" "$(cat "${store}/tags")"
	if grep -q '^release upload' "${log}"; then
		check_has "release ${label}: uploads every file and bundle" "${log}" \
			"release upload v1 --repo o/r SHA256SUMS SHA256SUMS.sigstore.json pkg-1.tar.gz pkg-1.whl pkg-1.tar.gz.sigstore.json pkg-1.whl.sigstore.json"
	fi
	if grep -q '^release create' "${log}"; then
		check_has "release ${label}: create is a draft" "${log}" "--draft"
		check_has "release ${label}: create never makes the tag" "${log}" "--verify-tag"
	fi
	if grep -q '^release delete' "${log}"; then
		check_has "release ${label}: deletes only the release" "${log}" "release delete v1 --repo o/r --yes"
	fi
	if grep -q '^release edit' "${log}"; then
		check_has "release ${label}: publishes" "${log}" "release edit v1 --repo o/r --draft=false"
	fi
}
# state <store>: the release state of v1 ("absent" when there is no release).
state() { if [ -f "$1/v1/state" ]; then cat "$1/v1/state"; else echo absent; fi; }
# assets <store>: the sorted asset names of v1, space-separated.
assets() { if [ -d "$1/v1/assets" ]; then (cd "$1/v1/assets" && find . -type f | sed 's|^\./||' | LC_ALL=C sort | tr '\n' ' '); fi; }
all_assets="SHA256SUMS SHA256SUMS.sigstore.json pkg-1.tar.gz pkg-1.tar.gz.sigstore.json pkg-1.whl pkg-1.whl.sigstore.json "

release_case creates-publishes "" "view create upload edit" tagged
check "release creates-publishes: published" published "$(state "${store}")"
check "release creates-publishes: every asset" "${all_assets}" "$(assets "${store}")"
release_case existing-draft-only-added "" "view upload" new
check "release existing-draft-only-added: still a draft" draft "$(state "${store}")"
check "release existing-draft-only-added: every asset" "${all_assets}" "$(assets "${store}")"
release_case existing-published-only-added "" "view upload" published
check "release existing-published-only-added: still published" published "$(state "${store}")"
release_case missing-tag-not-created release "view create" missing
check "release missing-tag-not-created: no release" absent "$(state "${store}")"
check "release missing-tag-not-created: no tag created" "" "$(cat "${store}/tags")"
release_case create-fails release "view create" tagged FAKE_GH_FAIL=create
check "release create-fails: no release" absent "$(state "${store}")"
release_case upload-fails-created-deleted release "view create upload delete" tagged FAKE_GH_FAIL=upload
check "release upload-fails-created-deleted: no release left" absent "$(state "${store}")"
check "release upload-fails-created-deleted: the tag is kept" v1 "$(cat "${store}/tags")"
release_case publish-fails-created-deleted release "view create upload edit delete" tagged FAKE_GH_FAIL=edit
check "release publish-fails-created-deleted: no release left" absent "$(state "${store}")"
release_case upload-fails-existing-kept release "view upload" new FAKE_GH_FAIL=upload
check "release upload-fails-existing-kept: the draft is kept" draft "$(state "${store}")"
check "release upload-fails-existing-kept: no asset" "" "$(assets "${store}")"

echo "== the fake gh (test/fake-gh) behaves like the real one where the action depends on it"
# fgh <args...>: runs the fake on the store $fs and prints its exit code.
fgh() {
	local rc=0
	FAKE_GH_ROOT="${fs}" "${fakebin}/gh" "$@" >/dev/null 2>&1 || rc=$?
	echo "${rc}"
}
fs="${work}/fake-store"
rm -rf "${fs}"
mkdir -p "${work}/fake-files"
echo one >"${work}/fake-files/a.txt"
echo two >"${work}/fake-files/b.txt"
echo changed >"${work}/fake-files/c.txt"
check "fake: view of an unknown release fails" 1 "$(fgh release view v1 --repo o/r)"
check "fake: create --verify-tag needs the tag" 1 "$(fgh release create v1 --repo o/r --draft --verify-tag)"
check "fake: that failure created nothing" absent "$(state "${fs}")"
check "fake: create without --verify-tag creates the tag" 0 "$(fgh release create v1 --repo o/r --draft)"
check "fake: the tag was created" v1 "$(cat "${fs}/tags")"
check "fake: --draft creates a draft" draft "$(state "${fs}")"
check "fake: a second create fails (HTTP 422)" 1 "$(fgh release create v1 --repo o/r --draft)"
check "fake: view finds the draft" 0 "$(fgh release view v1 --repo o/r)"
check "fake: upload to an unknown release fails" 1 "$(fgh release upload v2 --repo o/r "${work}/fake-files/a.txt")"
check "fake: upload of a missing file fails" 1 "$(fgh release upload v1 --repo o/r "${work}/fake-files/a.txt" "${work}/fake-files/nope.txt")"
check "fake: ... and uploads nothing" "" "$(assets "${fs}")"
check "fake: upload works" 0 "$(fgh release upload v1 --repo o/r "${work}/fake-files/a.txt" "${work}/fake-files/b.txt")"
check "fake: the assets are there" "a.txt b.txt " "$(assets "${fs}")"
cp "${work}/fake-files/c.txt" "${work}/fake-files/a.txt.new"
mv "${work}/fake-files/a.txt.new" "${work}/fake-files/a.txt"
check "fake: an existing asset is not overwritten" 1 "$(fgh release upload v1 --repo o/r "${work}/fake-files/a.txt")"
check "fake: ... and keeps its content" one "$(cat "${fs}/v1/assets/a.txt")"
check "fake: upload stops at the first existing asset, keeping the earlier ones" 1 \
	"$(echo new >"${work}/fake-files/z.txt" && fgh release upload v1 --repo o/r "${work}/fake-files/z.txt" "${work}/fake-files/b.txt")"
check "fake: ... as the real command can leave a partial upload" "a.txt b.txt z.txt " "$(assets "${fs}")"
check "fake: --clobber overwrites" 0 "$(fgh release upload v1 --repo o/r --clobber "${work}/fake-files/a.txt")"
check "fake: ... with the new content" changed "$(cat "${fs}/v1/assets/a.txt")"
check "fake: publishing" 0 "$(fgh release edit v1 --repo o/r --draft=false)"
check "fake: state is published" published "$(state "${fs}")"
check "fake: back to draft" 0 "$(fgh release edit v1 --repo o/r --draft=true)"
check "fake: state is draft again" draft "$(state "${fs}")"
check "fake: edit of anything else is refused" 1 "$(fgh release edit v1 --repo o/r --title x)"
check "fake: delete needs --yes" 1 "$(fgh release delete v1 --repo o/r)"
check "fake: delete removes the release but keeps the tag" 0 "$(fgh release delete v1 --repo o/r --yes)"
check "fake: ... the release is gone" absent "$(state "${fs}")"
check "fake: ... the tag stays" v1 "$(cat "${fs}/tags")"
check "fake: create without --draft publishes" 0 "$(fgh release create v1 --repo o/r --verify-tag)"
check "fake: ... so the state is published" published "$(state "${fs}")"
check "fake: delete --cleanup-tag removes the tag too" 0 "$(fgh release delete v1 --repo o/r --yes --cleanup-tag)"
check "fake: ... the tag is gone" "" "$(cat "${fs}/tags")"
for verb in view create upload edit delete; do
	check "fake: FAKE_GH_FAIL=${verb} fails ${verb}" 1 "$(FAKE_GH_FAIL="${verb}" fgh release "${verb}" v9 --repo o/r --draft --yes)"
done
check "fake: FAKE_GH_FAIL fails before changing anything" "" "$(find "${fs}" -mindepth 1 -maxdepth 1 ! -name tags ! -name calls.log)"
check "fake: FAKE_GH_FAIL takes a list" 1 "$(FAKE_GH_FAIL=edit,upload fgh release upload v9 --repo o/r "${work}/fake-files/a.txt")"
check "fake: other gh calls exit 99" 99 "$(fgh pr list)"
check "fake: other release calls exit 99" 99 "$(fgh release list)"
check "fake: calls are logged" "release view v1 --repo o/r" "$(head -1 "${fs}/calls.log")"
rc=0
env -u FAKE_GH_ROOT "${fakebin}/gh" release view v1 >/dev/null 2>&1 || rc=$?
check "fake: needs FAKE_GH_ROOT" 1 "${rc}"

echo "== the fake signer and the seeds of the fake store"
sd="$(new_dir signer)"
sign_case() {
	local label="$1" expected="$2" mode="$3"
	(cd "${sd}/rt/sign-pypi-package" && rm -f ./*.sigstore.json && fake_sigstore_sign "${mode}" SHA256SUMS pkg-1.whl pkg-1.tar.gz)
	check "signer ${label}" "${expected}" "$(cd "${sd}/rt/sign-pypi-package" && for f in $(find . -maxdepth 1 -name '*.sigstore.json' | sed 's|^\./||' | LC_ALL=C sort); do if [ -s "${f}" ]; then echo "${f}"; else echo "${f}(empty)"; fi; done | tr '\n' ' ')"
}
make_dist "${sd}/rt/sign-pypi-package" pkg-1.whl pkg-1.tar.gz
sign_case all "SHA256SUMS.sigstore.json pkg-1.tar.gz.sigstore.json pkg-1.whl.sigstore.json " all
sign_case skip "SHA256SUMS.sigstore.json pkg-1.tar.gz.sigstore.json " skip:pkg-1.whl
sign_case empty "SHA256SUMS.sigstore.json(empty) pkg-1.tar.gz.sigstore.json pkg-1.whl.sigstore.json " empty:SHA256SUMS
sign_case none "" none
for kind in new same draft published tagged missing none dash space; do
	rm -rf "${sd}/store"
	fake_gh_seed "${sd}/store" "${kind}" v1
	case "${kind}" in
	new | same | draft) exp="v1 draft" ;;
	published) exp="v1 published" ;;
	tagged) exp="v1 absent" ;;
	*) exp=" absent" ;;
	esac
	check "seed ${kind}" "${exp}" "$(cat "${sd}/store/tags" | tr -d '\n') $(state "${sd}/store")"
done
rm -rf "${sd}/store"
check "an unknown seed kind is refused" 1 "$(fake_gh_seed "${sd}/store" bogus v1 >/dev/null 2>&1 && echo 0 || echo 1)"

echo "== gh flags that the action relies on exist in the installed gh"
# The fake only proves that the action matches the fake. This catches a renamed flag in the real
# gh, offline; the real-release job of ci-action.yaml checks the semantics. Skipped without gh.
if command -v gh >/dev/null 2>&1; then
	gh_flag() { # gh_flag <subcommand> <flag>
		local h
		h="$(gh release "$1" --help 2>&1 || true)"
		check "gh release $1 has $2" yes "$(grep -qF -- "$2" <<<"${h}" && echo yes || echo no)"
	}
	gh_flag create --draft
	gh_flag create --verify-tag
	gh_flag create --title
	gh_flag create --notes
	gh_flag upload --clobber
	gh_flag edit --draft
	gh_flag delete --yes
	gh_flag delete --cleanup-tag
else
	echo "skip the gh flag check (gh is not installed)"
fi

echo "== step 4.1: success summary"
d="$(new_dir summary)"
make_dist "${d}/rt/sign-pypi-package" pkg-1.whl pkg-1.tar.gz
run_step "${d}" 4.1 TAG=v1 FILES="pkg-1.tar.gz pkg-1.whl " || true
for expected in "Signed and released v1" "https://github.com/o/r/releases/tag/v1" "- \`SHA256SUMS\`" \
	"- \`SHA256SUMS.sigstore.json\`" "- \`pkg-1.whl\`" "- \`pkg-1.tar.gz.sigstore.json\`" \
	"sigstore verify github --repository o/r" "$(cat "${d}/rt/sign-pypi-package/SHA256SUMS")"; do
	check_has "summary has '${expected%%$'\n'*}'" "${d}/summary" "${expected%%$'\n'*}"
done

echo "== step 4.2: failed-check output"
d="$(new_dir report-id)"
echo checksum >"${d}/rt/failed-check"
run_step "${d}" 4.2
check "a recorded id is reported" "failed-check=checksum" "$(cat "${d}/out")"
d="$(new_dir report-none)"
run_step "${d}" 4.2
check "no recorded id is unexpected" "failed-check=unexpected" "$(cat "${d}/out")"
d="$(new_dir report-empty)"
: >"${d}/rt/failed-check"
run_step "${d}" 4.2
check "an empty id is unexpected" "failed-check=unexpected" "$(cat "${d}/out")"

echo "== consistency of action.yml, README.md, test/cases.json and the workflows"
workflows="${root}/.github/workflows"
action_ids="$(grep -oE '(^|[^a-z])fail [a-z][a-z-]* "' "${action}" | sed -E 's/.*fail ([a-z-]+) "/\1/' | sort -u | tr '\n' ' ')"
readme_ids="$(grep -E '^\| [0-9]\.[0-9]' "${root}/README.md" | awk -F'|' '{gsub(/[` ]/, "", $(NF-1)); print $(NF-1)}' | grep -vx unexpected | sort -u | tr '\n' ' ')"
check "fail ids of action.yml are the ids of the README table" "${readme_ids}" "${action_ids}"
output_ids="$(sed -n '/^outputs:/,/^runs:/p' "${action}" | grep -oE '\(tag, [a-z, -]*\)' | tr -d '(),' | tr ' ' '\n' | grep -v '^$' | sort | tr '\n' ' ')"
check "ids listed in the output description are the fail ids" "${action_ids}" "${output_ids}"

# Every id has a row in the table of test/cases.json, except the ones tested elsewhere:
# permissions (own job of ci-action.yaml) and bundle (step 2.3 above, Sigstore cannot omit it).
for id in ${action_ids} unexpected; do
	case "${id}" in permissions | bundle) continue ;; esac
	n="$(jq --arg id "${id}" '[.[] | select(.expected == $id)] | length' "${root}/test/cases.json")"
	check "cases.json has a row expecting '${id}'" "yes" "$([ "${n}" -ge 1 ] && echo yes || echo no)"
done
check "case names are unique" "" "$(jq -r '[.[].name] | group_by(.)[] | select(length > 1) | .[0]' "${root}/test/cases.json")"
check "case names are kebab-case" "" "$(jq -r '.[].name | select(test("^[a-z0-9]+(-[a-z0-9]+)*$") | not)' "${root}/test/cases.json")"
check "case fields are known" "" "$(jq -r '.[] | .name as $n | keys[] | select(IN("name","stage","expected","released","runs","tag","artifact") | not) | "\($n): \(.)"' "${root}/test/cases.json")"
check "case tags are known" "" "$(jq -r '.[] | select(.tag != null and (.tag | IN("new","same","missing","none","dash","space","draft") | not)) | .name' "${root}/test/cases.json")"
check "case expected ids are known" "" "$(jq -r --arg ids "${action_ids}unexpected " '.[] | select(.expected != "") | .expected as $e | select(($ids | split(" ")) | index($e) | not) | .name' "${root}/test/cases.json")"
check "case runs are 1 or 2" "" "$(jq -r '.[] | select(.runs != null and (.runs | IN(1,2) | not)) | .name' "${root}/test/cases.json")"
check "every case has a stage" "" "$(jq -r '.[] | select((.stage // "") == "") | .name' "${root}/test/cases.json")"

inputs_action="$(sed -n '/^inputs:/,/^outputs:/p' "${action}" | grep -oE '^  [a-z-]+:' | tr -d ' :' | sort | tr '\n' ' ')"
inputs_readme="$(sed -n '/^## Inputs/,/^## Outputs/p' "${root}/README.md" | grep -oE "^\\| \`[a-z-]+\`" | tr -d '|` ' | sort | tr '\n' ' ')"
check "inputs of action.yml are the inputs of the README" "${inputs_readme}" "${inputs_action}"

# Every run: step sets shell: bash.
check "every run: step sets shell: bash" "" "$(awk '
	function flush() { if (run && !sh) print name; run = 0; sh = 0 }
	/^    - name:/ { flush(); name = $0 }
	/^      run:/ { run = 1 }
	/^      shell: bash/ { sh = 1 }
	END { flush() }' "${action}")"
# Inputs reach the scripts through env:, never by interpolation in run:.
check "no \${{ }} expression inside a run: block" "" "$(awk '
	/^      run:/ { r = 1; next }
	r && /^      [a-z-]+:/ { r = 0 }
	r && /^    - / { r = 0 }
	r && /\$\{\{/ { print NR ": " $0 }' "${action}")"
# Third-party actions are pinned to a commit SHA with a ratchet comment.
check "every uses: is a local path or pinned with a ratchet comment" "" "$(grep -HnE '^\s*(- )?uses:' "${action}" "${workflows}"/*.yaml |
	grep -vE 'uses: \./' | grep -vE '@[0-9a-f]{40} # ratchet:[^ ]+@[^ ]+$' || true)"
# Workflows: least privilege and a timeout on every job.
for f in "${workflows}"/*.yaml; do
	check "$(basename "${f}") has permissions: {} at the workflow level" "yes" "$(grep -qE '^permissions: \{\}' "${f}" && echo yes || echo no)"
done

echo
echo "${total} checks, ${failed} failed"
[ "${failed}" = 0 ]
