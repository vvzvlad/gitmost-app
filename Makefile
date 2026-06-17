# Makefile — single entry point for all routine project actions.
# Run `make` or `make help` to list targets.

APP_NAME  := gitmost
# SPM executable product name (internal; not renamed).
BIN_NAME  := Docmost
BUNDLE_ID := xyz.vvzvlad.gitmost
APP       := $(APP_NAME).app

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

.PHONY: debug
debug: ## SwiftPM debug build (no .app bundle)
	swift build

.PHONY: test
test: ## Run the unit tests
	swift test

.PHONY: icon
icon: ## (Re)generate the app icon (Resources/AppIcon.icns)
	swift scripts/make-icon.swift

.PHONY: build
build: ## Build a release gitmost.app bundle (compile + assemble + ad-hoc sign)
	@echo "==> Building release binary..."
	swift build -c release
	@test -f Resources/AppIcon.icns || swift scripts/make-icon.swift
	@echo "==> Assembling $(APP)..."
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	cp ".build/release/$(BIN_NAME)" "$(APP)/Contents/MacOS/$(APP_NAME)"
	cp Resources/AppIcon.icns "$(APP)/Contents/Resources/AppIcon.icns"
	@printf '%s\n' \
		'<?xml version="1.0" encoding="UTF-8"?>' \
		'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
		'<plist version="1.0">' \
		'<dict>' \
		'    <key>CFBundleName</key>' \
		'    <string>$(APP_NAME)</string>' \
		'    <key>CFBundleDisplayName</key>' \
		'    <string>$(APP_NAME)</string>' \
		'    <key>CFBundleExecutable</key>' \
		'    <string>$(APP_NAME)</string>' \
		'    <key>CFBundleIdentifier</key>' \
		'    <string>$(BUNDLE_ID)</string>' \
		'    <key>CFBundleIconFile</key>' \
		'    <string>AppIcon</string>' \
		'    <key>CFBundleIconName</key>' \
		'    <string>AppIcon</string>' \
		'    <key>CFBundlePackageType</key>' \
		'    <string>APPL</string>' \
		'    <key>CFBundleShortVersionString</key>' \
		'    <string>1.0</string>' \
		'    <key>CFBundleVersion</key>' \
		'    <string>1</string>' \
		'    <key>LSMinimumSystemVersion</key>' \
		'    <string>14.0</string>' \
		'    <key>NSPrincipalClass</key>' \
		'    <string>NSApplication</string>' \
		'    <key>NSHighResolutionCapable</key>' \
		'    <true/>' \
		'    <key>NSAppTransportSecurity</key>' \
		'    <dict>' \
		'        <key>NSAllowsArbitraryLoads</key>' \
		'        <true/>' \
		'    </dict>' \
		'</dict>' \
		'</plist>' \
		> "$(APP)/Contents/Info.plist"
	@echo "==> Ad-hoc signing..."
	codesign --force --deep --sign - "$(APP)" || true
	@echo "==> Done. Created $(APP) (run: open $(APP))"

.PHONY: run
run: build ## Build and launch gitmost.app
	open "$(APP)"

.PHONY: clean
clean: ## Remove build artifacts
	swift package clean
	rm -rf .build "$(APP)"
