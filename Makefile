SHELL = /bin/bash

include .make/actions.mk
include .make/help.mk
include .make/makefile.mk
include .make/markdown.mk
include .make/self.mk
include .make/shell.mk
include .make/uv.mk
include .make/yaml.mk

.DEFAULT_GOAL := help

.PHONY: format
format: format-yaml format-makefile format-shell format-markdown ## Format all files

.PHONY: lint
lint: lint-yaml lint-makefile lint-shell lint-markdown lint-actions ## Lint all files

.PHONY: clean-throwaway-releases
clean-throwaway-releases: ## Delete the releases (and their tags) titled "(throwaway, will be deleted)"
	gh release list --limit 1000 --json name,tagName \
		--jq '.[] | select(.name | contains("(throwaway, will be deleted)")) | .tagName' \
		| while read -r tag; do \
			echo "Deleting release $$tag"; \
			gh release delete "$$tag" --yes --cleanup-tag; \
		done

.PHONY: test-local
test-local: ## Run the tests that need no GitHub runner (table cases, step tests, consistency checks)
	bash scripts/test-local.sh
	bash scripts/test-steps.sh
