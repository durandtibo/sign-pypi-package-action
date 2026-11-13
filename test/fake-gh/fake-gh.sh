#!/usr/bin/env bash
# A fake `gh` for the tests that must not touch GitHub: the "releases" are directories under
# $FAKE_GH_ROOT. It implements exactly the `gh release` calls that action.yml makes. Anything else
# exits 99, so a new call in the action cannot go unnoticed. Put test/fake-gh first on PATH (the
# symlink `gh` points here); the real behaviour of each call is described in its comment, and the
# real-release job of ci-action.yaml is what checks that the fake does not drift from it.
#
# Store layout:
#   $FAKE_GH_ROOT/tags                 one existing tag per line (what pushing a tag makes)
#   $FAKE_GH_ROOT/<tag>/state          "draft" or "published"
#   $FAKE_GH_ROOT/<tag>/assets/<name>  the uploaded files
#   $FAKE_GH_ROOT/calls.log            one line per call, the arguments as given
#
# Failure injection: FAKE_GH_FAIL is a comma-separated list of verbs (view, create, upload, edit,
# delete) that fail with exit 1 before changing anything, like a network or permission error.
set -euo pipefail

root="${FAKE_GH_ROOT:?FAKE_GH_ROOT must name the directory of the fake releases}"
mkdir -p "${root}"
touch "${root}/tags"
echo "$*" >>"${root}/calls.log"

die() {
	echo "gh (fake): $*" >&2
	exit 1
}

[ "${1:-}" = release ] || {
	echo "unexpected gh call: $*" >&2
	exit 99
}
verb="${2:-}"
case "${verb}" in
view | create | upload | edit | delete) ;;
*)
	echo "unexpected gh call: $*" >&2
	exit 99
	;;
esac
case ",${FAKE_GH_FAIL:-}," in
*",${verb},"*) die "release ${verb} failed (injected by FAKE_GH_FAIL)" ;;
esac

tag="${3:-}"
[ -n "${tag}" ] || die "release ${verb}: a tag is required"
shift 3
dir="${root}/${tag}"

# Split the remaining arguments into flags and positional arguments (files). --repo, --title,
# --notes and --target take a value; the other flags are booleans or --flag=value.
draft="" verify_tag=0 clobber=0 cleanup_tag=0 yes=0 positional=()
while [ "$#" -gt 0 ]; do
	case "$1" in
	--repo | --title | --notes | --target) shift 2 ;;
	--draft) draft=true && shift ;;
	--draft=*) draft="${1#--draft=}" && shift ;;
	--verify-tag) verify_tag=1 && shift ;;
	--clobber) clobber=1 && shift ;;
	--cleanup-tag) cleanup_tag=1 && shift ;;
	--yes) yes=1 && shift ;;
	-*) die "release ${verb}: unknown flag $1" ;;
	*) positional+=("$1") && shift ;;
	esac
done

exists() { [ -d "${dir}" ]; }
tag_exists() { grep -qxF -- "${tag}" "${root}/tags"; }

case "${verb}" in
view)
	# Exit 0 if the release exists (a draft too), 1 otherwise.
	exists || die "release not found"
	;;
create)
	# A release is unique per tag. With --verify-tag the tag must already exist, otherwise gh
	# creates it. Without --draft the release is published at once.
	exists && die "HTTP 422: a release for ${tag} already exists"
	if [ "${verify_tag}" = 1 ] && ! tag_exists; then die "tag ${tag} does not exist in the repository"; fi
	tag_exists || echo "${tag}" >>"${root}/tags"
	mkdir -p "${dir}/assets"
	if [ "${draft}" = true ]; then echo draft >"${dir}/state"; else echo published >"${dir}/state"; fi
	;;
upload)
	# The release must exist. An asset that already exists is an error unless --clobber is given.
	# Assets are sent in order, so a failure leaves the assets before it uploaded, like the real
	# command can.
	exists || die "release not found"
	[ "${#positional[@]}" -gt 0 ] || die "release upload: at least one file is required"
	for f in "${positional[@]}"; do [ -f "${f}" ] || die "open ${f}: no such file"; done
	for f in "${positional[@]}"; do
		name="$(basename "${f}")"
		if [ -e "${dir}/assets/${name}" ] && [ "${clobber}" = 0 ]; then die "HTTP 422: asset ${name} already exists"; fi
		cp "${f}" "${dir}/assets/${name}"
	done
	;;
edit)
	# Only --draft[=bool] is supported: it is the one edit the action makes.
	exists || die "release not found"
	[ -n "${draft}" ] || die "release edit: only --draft is supported by the fake"
	if [ "${draft}" = true ]; then echo draft >"${dir}/state"; else echo published >"${dir}/state"; fi
	;;
delete)
	# Removes the release and its assets, and the tag only with --cleanup-tag.
	[ "${yes}" = 1 ] || die "release delete: --yes is required (no prompt in the fake)"
	exists || die "release not found"
	rm -rf "${dir}"
	if [ "${cleanup_tag}" = 1 ]; then
		grep -vxF -- "${tag}" "${root}/tags" >"${root}/tags.tmp" || true
		mv "${root}/tags.tmp" "${root}/tags"
	fi
	;;
esac
