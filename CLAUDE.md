# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build commands

```bash
make              # build everything (helper + app bundle)
make build-helper # build only the smc_write helper
make run          # build and launch the app (kills previous instance first)
make install      # build and copy to /Applications
make release      # build + install + create DMG → ~/Downloads/
make dmg          # create DMG from current build/
make clean        # remove build/
```

The build uses a hand-written Makefile with `xcrun swiftc` directly — not Xcode and not `swift build`. The Swift Package Manager `Package.swift` exists but is not used for the production build.

**Fan control helper install** (one-time, requires sudo):
```bash
make install-helper   # sudo cp + chown root:wheel + chmod 4755
```

There are no tests.

## Architecture

This is a macOS menu bar app (SwiftUI, macOS 13+, arm64) that reads hardware sensor data from the SMC (System Management Controller) via IOKit.

### Two compiled artifacts

1. **`ThermalMonitor`** — the main app (`Sources/ThermalMonitor/`)
2. **`smc_write`** — a privileged CLI helper (`helpers/smc_write.swift`) compiled separately and installed setuid-root. Fan RPM writes require root; the main app cannot write SMC keys itself, so it shells out to this helper.

The built app bundle at `build/ThermalMonitor.app` embeds `smc_write` at `Contents/MacOS/smc_write`. At runtime, `SMCReader` finds it via `Bundle.main.url(forAuxiliaryExecutable:)` or as a sibling of the running binary.

### Source files (`Sources/ThermalMonitor/`)

- **`ThermalMonitorApp.swift`** — `@main` entry point. Creates the `MenuBarExtra` scene with a `MenuBarLabel` (icon + temperature) and a `PopoverContentView` window. Temperature color thresholds: <70°C primary, <85°C orange, ≥85°C red.

- **`ThermalModel.swift`** — `@MainActor ObservableObject`. Owns all state: `sensors`, `fans`, `primaryTemp`, `lastUpdated`, `fanControlAvailable`. Polls SMC every 1 second via `DispatchSourceTimer` on the main queue. SMC reads are dispatched to a `.utility` background queue; results are published back to the main actor only when a reading changes by >0.4°C or >50 RPM. Also handles launch-at-login via `SMAppService`.

- **`SMCReader.swift`** — Low-level IOKit wrapper. Opens/closes `AppleSMC` service. Reads temperature (supports both Apple Silicon `flt ` little-endian IEEE 754 and Intel `sp78` fixed-point) and fan speed (`flt ` or `fpe2`). Writes are delegated to `smc_write` helper. `SMCParamStruct` has explicit padding fields (`_kp0/1/2`, `_dp`) to exactly match the C kernel layout (80 bytes total) — do not remove this padding.

- **`PopoverContentView.swift`** — Entire popover UI: `HeaderBar` (refresh + quit), `FanSection` (per-fan rows with slider for manual RPM control and `FanControlSetupBanner` when helper isn't installed), `TemperatureSection` (sensors grouped by category: CPU → GPU → Storage → Battery → Thermal → Other, only showing sensors with non-nil readings).

### Sensor catalogue

`ThermalModel.swift` contains a static `sensorCatalogue` array covering Apple Silicon M1–M4 (all variants) and Intel SMC keys. Non-existent keys return `nil` from SMC and are filtered from the UI — it is safe to list extra keys.

`primaryTemp` is the first reading from key `Tp01` (Apple Silicon P-Core 1) or, if absent, the first available CPU sensor.

### Fan control flow

1. User toggles "Manual control" in `FanRow` → calls `ThermalModel.setFanManual(index:speed:)`
2. `ThermalModel` calls `SMCReader.setFanManual` → `writeViaHelper("F{i}Md", type: "ui8", value: "1")` then `writeViaHelper("F{i}Tg", type: "flt", value: "<rpm>")`
3. `SMCReader.writeViaHelper` runs `/usr/local/bin/smc_write <key> <type> <value>` as a subprocess
4. First-run install: `FanControlSetupBanner` triggers `SMCReader.installHelper` which runs an NSAppleScript `do shell script … with administrator privileges`
