# Makefile — single entry point for routine project actions.
# Run `make` or `make help` to list targets.

APP := Docmost

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

.PHONY: build
build: ## Build a release Docmost.app via build-app.sh
	./build-app.sh

.PHONY: debug
debug: ## SwiftPM debug build (no .app bundle)
	swift build

.PHONY: run
run: build ## Build and launch Docmost.app
	open $(APP).app

.PHONY: test
test: ## Run the unit tests
	swift test

.PHONY: icon
icon: ## Regenerate the app icon (Resources/AppIcon.icns)
	swift scripts/make-icon.swift

.PHONY: clean
clean: ## Remove build artifacts
	swift package clean
	rm -rf .build $(APP).app
