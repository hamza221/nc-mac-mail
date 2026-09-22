# SPDX-FileCopyrightText: Hamza Mahjoubi
# SPDX-License-Identifier: AGPL-3.0-or-later

.DEFAULT_GOAL := help
SHELL := /bin/bash

PACKAGES := NCMailCore NCMailNet NCMailStore NCMailSync NCMailTestSupport

# Warnings are errors, and the flag lives here rather than in the manifests.
# SwiftPM applies -Xswiftc to the root package's own targets and not to its
# dependencies, so GRDB's warnings stay GRDB's problem. ADR-0016 has the rest.
SWIFTFLAGS := -Xswiftc -warnings-as-errors

# SUPPRESS_WARNINGS=NO is not optional: Xcode hands package targets
# -suppress-warnings, NextcloudUI's manifest asks for -warnings-as-errors, and
# swiftc refuses both at once. Without this the app does not build. ADR-0016.
XCODEFLAGS := -project NextcloudMail.xcodeproj -scheme NextcloudMail \
	-destination 'platform=macOS' SUPPRESS_WARNINGS=NO

# The toolchain ships swift-format as a subcommand of `swift`. There is no
# standalone `swift-format` binary to install, and invoking one is the most
# common way this Makefile gets broken by a well-meaning edit.
FORMAT_PATHS := Packages/*/Package.swift Packages/*/Sources Packages/*/Tests NextcloudMail NextcloudMailTests

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

.PHONY: setup
setup: ## Resolve dependencies and check the tools are installed
	@for tool in swiftlint xcodebuild; do \
		command -v $$tool >/dev/null || { echo "missing: $$tool"; exit 1; }; \
	done
	@swift format --version >/dev/null || { echo "missing: swift format"; exit 1; }
	@for p in $(PACKAGES); do echo "resolving $$p"; (cd Packages/$$p && swift package resolve); done
	@xcodebuild $(XCODEFLAGS) -resolvePackageDependencies >/dev/null
	@echo "ready. Xcode $$(cat .xcode-version) expected; $$(xcodebuild -version | head -1) installed."

.PHONY: build
build: ## Build every package, warnings as errors
	@for p in $(PACKAGES); do echo "== $$p"; (cd Packages/$$p && swift build $(SWIFTFLAGS)) || exit 1; done

.PHONY: test
test: ## Run every package's tests, warnings as errors
	@for p in $(PACKAGES); do echo "== $$p"; (cd Packages/$$p && swift test $(SWIFTFLAGS)) || exit 1; done

.PHONY: test-tsan
test-tsan: ## Run every package's tests under Thread Sanitizer
	@for p in $(PACKAGES); do echo "== $$p"; (cd Packages/$$p && swift test --sanitize=thread) || exit 1; done

.PHONY: build-app
build-app: ## Build the app target with xcodebuild
	xcodebuild $(XCODEFLAGS) build

.PHONY: test-app
test-app: ## Run the app target's unit tests with xcodebuild
	xcodebuild $(XCODEFLAGS) test

.PHONY: app
app: build-app ## Build the app and launch it
	open "$$(xcodebuild $(XCODEFLAGS) -showBuildSettings 2>/dev/null \
		| awk -F' = ' '/ BUILT_PRODUCTS_DIR =/ {print $$2}' | head -1)/NextcloudMail.app"

.PHONY: lint
lint: lint-format lint-swiftlint ## Run every lint check

.PHONY: lint-format
lint-format: ## Check formatting without writing
	swift format lint --strict --recursive --parallel $(FORMAT_PATHS)

.PHONY: lint-swiftlint
lint-swiftlint: ## Check the invariants in .swiftlint.yml
	swiftlint lint --strict

.PHONY: lint-reuse
lint-reuse: ## Check REUSE/SPDX compliance (needs `pipx install reuse`)
	reuse lint

.PHONY: format
format: ## Apply formatting in place
	swift format --in-place --recursive --parallel $(FORMAT_PATHS)

.PHONY: clean
clean: ## Remove build products
	rm -rf build
	@for p in $(PACKAGES); do rm -rf Packages/$$p/.build; done
