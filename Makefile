APP       := ThermalMonitor
BUNDLE    := build/$(APP).app
BIN       := $(BUNDLE)/Contents/MacOS/$(APP)
SOURCES   := $(wildcard Sources/$(APP)/*.swift)
PLIST     := Resources/Info.plist
ENTITLEMENTS := Resources/$(APP).entitlements
TARGET    := arm64-apple-macos13.0
ICON_SRC  := $(HOME)/Downloads/app icon.png
ICON_ICNS := Resources/AppIcon.icns
DMG       := $(HOME)/Downloads/$(APP)-1.0.dmg
HELPER_DEST := /Library/PrivilegedHelperTools/com.github.Kudretg.ThermalMonitor.smc_write

# Code signing. Ad-hoc ("-") by default; for a release others can open, pass your
# Developer ID, e.g. make notarize SIGN_ID="Developer ID Application: Name (TEAMID)" NOTARY_PROFILE=notary
SIGN_ID        ?= -
NOTARY_PROFILE ?=
SIGN_FLAGS     := --force --options runtime $(if $(filter -,$(SIGN_ID)),,--timestamp) --sign "$(SIGN_ID)"

# CLT SwiftBridging bug fixed (sudo mv module.modulemap → .bak) — no VFS overlay needed
SWIFTFLAGS := \
	-target $(TARGET) \
	-framework AppKit \
	-framework SwiftUI \
	-framework IOKit \
	-framework ServiceManagement \
	-parse-as-library

HELPER_FLAGS := \
	-target $(TARGET) \
	-framework IOKit

.PHONY: all build run release install dmg notarize build-helper install-helper icon clean

all: build

# ── Icon (separate phony target — avoids Make choking on spaces in filename) ──
icon:
	@bash scripts/make_icon.sh "$(ICON_SRC)" "$(ICON_ICNS)"

# ── Helper binary ─────────────────────────────────────────────────────────────
build/smc_write: helpers/smc_write.swift
	@echo "Building smc_write..."
	@mkdir -p build
	xcrun swiftc helpers/smc_write.swift $(HELPER_FLAGS) -o build/smc_write
	@codesign $(SIGN_FLAGS) build/smc_write

build-helper: build/smc_write

# ── App bundle ────────────────────────────────────────────────────────────────
$(BIN): $(SOURCES) $(PLIST) $(ENTITLEMENTS) build/smc_write
	@echo "Building $(APP)..."
	@mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	xcrun swiftc $(SOURCES) $(SWIFTFLAGS) -o $(BIN)
	@cp $(PLIST) $(BUNDLE)/Contents/Info.plist
	@cp build/smc_write $(BUNDLE)/Contents/MacOS/smc_write
	@[ -f $(ICON_ICNS) ] && cp $(ICON_ICNS) $(BUNDLE)/Contents/Resources/AppIcon.icns || true
	@# The helper is already signed; sign the bundle itself (no --deep).
	@codesign $(SIGN_FLAGS) --entitlements $(ENTITLEMENTS) $(BUNDLE)
	@echo "✅ Build complete → $(BUNDLE)"

build: $(BIN)

# ── One-command release: build → install → DMG ───────────────────────────────
release: build
	@echo "Installing to /Applications..."
	@rm -rf /Applications/$(APP).app
	@cp -r $(BUNDLE) /Applications/$(APP).app
	@echo "Building DMG..."
	@bash scripts/make_dmg.sh
	@open $(DMG)
	@echo "✅ Done — DMG at $(DMG)"

# Sign, notarize and staple the DMG so Gatekeeper accepts it on other Macs.
# Requires a Developer ID (SIGN_ID) and a notarytool keychain profile (NOTARY_PROFILE).
notarize: dmg
	@if [ "$(SIGN_ID)" = "-" ] || [ -z "$(NOTARY_PROFILE)" ]; then \
		echo "Set SIGN_ID=\"Developer ID Application: …\" and NOTARY_PROFILE=<notarytool profile>"; exit 1; fi
	codesign --force --timestamp --sign "$(SIGN_ID)" $(DMG)
	xcrun notarytool submit $(DMG) --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple $(DMG)

# ── Dev helpers ───────────────────────────────────────────────────────────────
run: build
	@pkill $(APP) 2>/dev/null || true
	open $(BUNDLE)

install: build
	@rm -rf /Applications/$(APP).app
	@cp -r $(BUNDLE) /Applications/$(APP).app
	@echo "✅ Installed"

dmg: build
	@bash scripts/make_dmg.sh

# Root-owned directory; setuid root but executable only by the admin group.
install-helper: build/smc_write
	sudo mkdir -p /Library/PrivilegedHelperTools
	sudo install -o root -g admin -m 4750 build/smc_write "$(HELPER_DEST)"
	@# Remove the unrestricted helper older versions installed.
	@if [ -u /usr/local/bin/smc_write ]; then sudo rm -f /usr/local/bin/smc_write && echo "Removed legacy /usr/local/bin/smc_write"; fi
	@echo "✅ Helper installed"

clean:
	rm -rf build/
