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

.PHONY: test-local
test-local: ## Run the tests that need no GitHub runner (table cases, step tests, consistency checks)
	bash scripts/test-local.sh
	bash scripts/test-steps.sh
