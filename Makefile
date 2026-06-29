APP       := ThermalMonitor
BUNDLE    := build/$(APP).app
BIN       := $(BUNDLE)/Contents/MacOS/$(APP)
SOURCES   := $(wildcard Sources/$(APP)/*.swift)
PLIST     := Resources/Info.plist
TARGET    := arm64-apple-macos13.0
ICON_SRC  := $(HOME)/Downloads/app icon.png
ICON_ICNS := Resources/AppIcon.icns

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

.PHONY: all build run release install dmg build-helper install-helper icon clean

all: build

# ── Icon (separate phony target — avoids Make choking on spaces in filename) ──
icon:
	@bash scripts/make_icon.sh "$(ICON_SRC)" "$(ICON_ICNS)"

# ── Helper binary ─────────────────────────────────────────────────────────────
build-helper:
	@echo "Building smc_write..."
	@mkdir -p build
	xcrun swiftc helpers/smc_write.swift $(HELPER_FLAGS) -o build/smc_write

# ── App bundle ────────────────────────────────────────────────────────────────
$(BIN): $(SOURCES) $(PLIST) build/smc_write
	@echo "Building $(APP)..."
	@mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	xcrun swiftc $(SOURCES) $(SWIFTFLAGS) -o $(BIN)
	@cp $(PLIST) $(BUNDLE)/Contents/Info.plist
	@cp build/smc_write $(BUNDLE)/Contents/MacOS/smc_write
	@[ -f $(ICON_ICNS) ] && cp $(ICON_ICNS) $(BUNDLE)/Contents/Resources/AppIcon.icns || true
	@codesign --deep --force --sign - $(BUNDLE)
	@echo "✅ Build complete → $(BUNDLE)"

build: build-helper $(BIN)

# ── One-command release: build → install → DMG ───────────────────────────────
release: build
	@echo "Installing to /Applications..."
	@rm -rf /Applications/$(APP).app
	@cp -r $(BUNDLE) /Applications/$(APP).app
	@echo "Building DMG..."
	@bash scripts/make_dmg.sh
	@open ~/Downloads/$(APP)-1.0.dmg
	@echo "✅ Done — DMG at ~/Downloads/$(APP)-1.0.dmg"

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

install-helper: build-helper
	sudo cp build/smc_write /usr/local/bin/smc_write
	sudo chown root:wheel /usr/local/bin/smc_write
	sudo chmod 4755 /usr/local/bin/smc_write
	@echo "✅ Helper installed"

clean:
	rm -rf build/
