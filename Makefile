SHELL = /bin/bash

include .make/all.mk

.PHONY: clean-throwaway-releases
clean-throwaway-releases: ## Delete the throwaway releases (drafts included) titled "(throwaway, will be deleted)" and the CI test tags (ci-<name>-<run id>-<attempt>)
	GH_PAGER=cat gh release list --limit 1000 --json name,tagName \
		--jq '.[] | select(.name | contains("(throwaway, will be deleted)")) | .tagName' \
		| while read -r tag; do \
			echo "Deleting release $$tag"; \
			GH_PAGER=cat gh release delete "$$tag" --yes; \
		done
	GH_PAGER=cat gh api --paginate "repos/{owner}/{repo}/git/matching-refs/tags/ci-" --jq '.[].ref | ltrimstr("refs/tags/")' \
		| grep -E '^ci-.+-[0-9]+-[0-9]+(-2)?$$' \
		| while read -r tag; do \
			echo "Deleting tag $$tag"; \
			GH_PAGER=cat gh api -X DELETE "repos/{owner}/{repo}/git/refs/tags/$$tag"; \
		done || true

.PHONY: test-local
test-local: ## Run the tests that need no GitHub runner (table cases, step tests, consistency checks)
	bash scripts/test-local.sh
	bash scripts/test-steps.sh

.PHONY: check-export
check-export: ## Check that the exported files are the files the action needs
	./dev/check_export.sh
