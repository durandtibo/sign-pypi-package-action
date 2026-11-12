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
test-local: ## Run the table cases that need no GitHub runner (steps 0.2 and 1.2 to 1.4)
	bash scripts/test-local.sh
