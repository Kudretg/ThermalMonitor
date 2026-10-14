import Foundation
import SwiftUI
import ServiceManagement
import AppKit

// MARK: - Data models

struct TemperatureSensor: Identifiable {
    let id = UUID()
    let name: String
    let key: String
    let category: SensorCategory
    var value: Double?

    enum SensorCategory: String {
        case cpu     = "CPU"
        case gpu     = "GPU"
        case storage = "Storage"
        case battery = "Battery"
        case thermal = "Thermal"
        case other   = "Other"
    }

    var display: String {
        guard let v = value else { return "--" }
        return String(format: "%.1f°C", v)
    }

    var color: Color {
        guard let v = value else { return .secondary }
        switch v {
        case ..<60:   return .green
        case 60..<80: return .yellow
        case 80..<95: return .orange
        default:      return .red
        }
    }

    var fraction: Double {
        guard let v = value else { return 0 }
        return Swift.min(Swift.max((v - 30) / 90, 0), 1)
    }
}

struct FanData: Identifiable {
    let id = UUID()
    let index: Int
    var current: Double = 0
    var min: Double = 1200
    var max: Double = 6800
    var target: Double? = nil
    var isManual = false

    var name: String { "Fan \(index + 1)" }
    var rpm: String { String(format: "%.0f RPM", current) }

    // Manual control (and the slider's min...max range) needs a sane range from the SMC.
    var hasValidRange: Bool { min >= 0 && max > min }

    func clamped(_ rpm: Double) -> Double { Swift.min(Swift.max(rpm, min), max) }

    var fraction: Double {
        guard max > min, current >= 10 else { return 0 }
        return Swift.min(Swift.max((current - min) / (max - min), 0), 1)
    }
}

// nil → value and value → nil count as changes; nil → nil does not.
private func readingChanged(_ new: Double?, _ old: Double?, threshold: Double) -> Bool {
    switch (new, old) {
    case (nil, nil):            return false
    case let (n?, o?):          return abs(n - o) > threshold
    default:                    return true
    }
}

// MARK: - Sensor catalogue
// Covers Apple Silicon (M1 → M4 all variants) and Intel Macs.
// Non-existent keys return nil and are filtered out, so listing extras is safe.

private let sensorCatalogue: [(String, String, TemperatureSensor.SensorCategory)] = [
    // ── Apple Silicon: CPU Performance cores ──────────────────────────────────
    // M1: 4P  M1 Pro: 8P  M1 Max/Ultra: 10-20P  M2: 4P  M2 Pro: 6-8P  M2 Max: 12P
    // M3: 4-8P  M3 Pro: 6P  M3 Max: 14P  M4: 4-10P  (keys reuse same pattern)
    ("P-Core 1",  "Tp01", .cpu), ("P-Core 2",  "Tp05", .cpu),
    ("P-Core 3",  "Tp0D", .cpu), ("P-Core 4",  "Tp0L", .cpu),
    ("P-Core 5",  "Tp0P", .cpu), ("P-Core 6",  "Tp0X", .cpu),
    ("P-Core 7",  "Tp0b", .cpu), ("P-Core 8",  "Tp0n", .cpu),
    ("P-Core 9",  "Tp0t", .cpu), ("P-Core 10", "Tp0x", .cpu),
    ("P-Core 11", "Tp11", .cpu), ("P-Core 12", "Tp15", .cpu),
    ("P-Core 13", "Tp1D", .cpu), ("P-Core 14", "Tp1L", .cpu),
    ("P-Core 15", "Tp1P", .cpu), ("P-Core 16", "Tp1X", .cpu),
    ("P-Core 17", "Tp1b", .cpu), ("P-Core 18", "Tp1n", .cpu),
    ("P-Core 19", "Tp1t", .cpu), ("P-Core 20", "Tp1x", .cpu),

    // ── Apple Silicon: CPU Efficiency cores ───────────────────────────────────
    ("E-Core 1",  "Tp09", .cpu), ("E-Core 2",  "Tp0h", .cpu),
    ("E-Core 3",  "Tp0j", .cpu), ("E-Core 4",  "Tp0r", .cpu),
    ("E-Core 5",  "Tp0f", .cpu), ("E-Core 6",  "Tp0p", .cpu),
    ("E-Core 7",  "Tp19", .cpu), ("E-Core 8",  "Tp1h", .cpu),

    // ── Apple Silicon: GPU ────────────────────────────────────────────────────
    ("GPU Core 1",  "Tg05", .gpu), ("GPU Core 2",  "Tg0D", .gpu),
    ("GPU Core 3",  "Tg0L", .gpu), ("GPU Core 4",  "Tg0T", .gpu),
    ("GPU Core 5",  "Tg0b", .gpu), ("GPU Core 6",  "Tg0f", .gpu),
    ("GPU Core 7",  "Tg0j", .gpu), ("GPU Core 8",  "Tg0n", .gpu),
    ("GPU Core 9",  "Tg15", .gpu), ("GPU Core 10", "Tg1D", .gpu),
    ("GPU Core 11", "Tg1L", .gpu), ("GPU Core 12", "Tg1T", .gpu),

    // ── Intel: CPU ───────────────────────────────────────────────────────────
    ("CPU Proximity", "TC0P", .cpu), ("CPU Die",      "TC0D", .cpu),
    ("CPU PECI",      "TC0E", .cpu), ("CPU Package",  "TC0F", .cpu),
    ("CPU Core 1",    "TC1C", .cpu), ("CPU Core 2",   "TC2C", .cpu),
    ("CPU Core 3",    "TC3C", .cpu), ("CPU Core 4",   "TC4C", .cpu),
    ("CPU Core 5",    "TC5C", .cpu), ("CPU Core 6",   "TC6C", .cpu),
    ("CPU Core 7",    "TC7C", .cpu), ("CPU Core 8",   "TC8C", .cpu),
    ("CPU iGPU",      "TCGC", .gpu),

    // ── Intel: GPU ───────────────────────────────────────────────────────────
    ("GPU Proximity", "TG0P", .gpu), ("GPU Die",      "TG0D", .gpu),
    ("GPU Heatsink",  "TG0H", .gpu), ("GPU 2 Die",    "TG1D", .gpu),

    // ── Intel: Memory ─────────────────────────────────────────────────────────
    ("Memory A1", "TM0P", .thermal), ("Memory B1", "TM1P", .thermal),
    ("PCH Die",   "TPCD", .thermal),

    // ── Storage (all Macs) ────────────────────────────────────────────────────
    ("NVMe",        "Th1H", .storage), ("NVMe 2",  "Th2H", .storage),
    ("HDD Bay 1",   "TH0P", .storage), ("HDD Bay 2","TH1P", .storage),

    // ── Battery (all Macs) ───────────────────────────────────────────────────
    ("Battery 1", "TB1T", .battery), ("Battery 2", "TB2T", .battery),
    ("Battery 3", "TB3T", .battery),

    // ── Thermal / Ambient ─────────────────────────────────────────────────────
    ("Ambient",     "Ta0L", .thermal), ("Palm Left",  "TaLP", .thermal),
    ("Palm Right",  "TaRP", .thermal), ("Charger",    "TCHP", .thermal),
    ("WiFi",        "TW0P", .thermal),
]

// MARK: - Observable model

@MainActor
class ThermalModel: ObservableObject {
    @Published var sensors: [TemperatureSensor] = []
    @Published var fans: [FanData] = []
    @Published var primaryTemp: Double? = nil
    @Published var lastUpdated = Date()
    @Published var fanControlAvailable: Bool = SMCReader.helperAvailable
    @Published var fanControlError: String? = nil
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled

    func installFanHelper(completion: @escaping (Bool, String?) -> Void) {
        SMCReader.installHelper { [weak self] success, error in
            self?.fanControlAvailable = SMCReader.helperAvailable
            completion(success, error)
        }
    }

    private let smc = SMCReader()
    // Every SMC access — IOKit reads and helper writes — runs on this serial queue.
    // SMCReader's key cache isn't thread-safe, and ordering writes before later reads
    // keeps the polled fan mode consistent with what we just set.
    private let smcQueue = DispatchQueue(label: "ThermalMonitor.smc", qos: .utility)
    private var pollingSource: DispatchSourceTimer?
    private var wakeObserver: NSObjectProtocol?
    private var refreshInFlight = false
    // Fans we've asked to go manual this session, including writes still queued, so
    // restoreAutomaticFans() covers them even before the UI state catches up.
    private var manualRequested = Set<Int>()

    init() {
        sensors = sensorCatalogue.map { TemperatureSensor(name: $0.0, key: $0.1, category: $0.2) }
        let smcRef = smc
        smcQueue.async { smcRef.open() }
        loadFans()
        startPolling()
    }

    deinit {
        pollingSource?.cancel()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        let smcRef = smc
        smcQueue.async { smcRef.close() }
    }

    private func loadFans() {
        let smcRef = smc
        smcQueue.async { [weak self] in
            let count = smcRef.fanCount()
            let loaded: [FanData] = (0..<count).map { i in
                var f = FanData(index: i)
                f.min = smcRef.fanMinSpeed(index: i) ?? 1200
                f.max = smcRef.fanMaxSpeed(index: i) ?? 6800
                f.current = smcRef.fanCurrentSpeed(index: i) ?? 0
                // Pick up a manual mode left behind by a previous run or crash.
                f.isManual = smcRef.fanIsManual(index: i) ?? false
                return f
            }
            DispatchQueue.main.async { [weak self] in
                self?.fans = loaded
            }
        }
    }

    private func startPolling() {
        refresh()

        // DispatchSourceTimer on the main queue: fires in the main-actor context
        // so reading @MainActor properties is safe. SMC reads are dispatched out
        // to smcQueue inside refresh().
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + 1, repeating: 1.0, leeway: .milliseconds(100))
        source.setEventHandler { [weak self] in self?.refresh() }
        source.resume()
        pollingSource = source

        // Immediate refresh on wake from sleep. NSWorkspace posts this on its own
        // notification center, not NotificationCenter.default.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }
    }

    func refresh() {
        // One read at a time: overlapping reads (timer + button + wake) could finish
        // out of order and publish stale values over newer ones.
        guard !refreshInFlight else { return }
        refreshInFlight = true

        // Capture snapshots on the main actor, then hand off to smcQueue for the
        // actual IOKit SMC reads. Only publish when something changed.
        let sensorSnapshot = sensors
        let fanSnapshot    = fans
        let smcRef         = smc

        smcQueue.async { [weak self] in
            var newSensors = sensorSnapshot
            var anyChanged = false

            for i in newSensors.indices {
                let v = smcRef.temperature(key: newSensors[i].key)
                if readingChanged(v, newSensors[i].value, threshold: 0.4) { anyChanged = true }
                newSensors[i].value = v
            }

            var fanReadings: [(index: Int, current: Double, isManual: Bool?)] = []
            for fan in fanSnapshot {
                let spd = smcRef.fanCurrentSpeed(index: fan.index) ?? 0
                let manual = smcRef.fanIsManual(index: fan.index)
                if abs(spd - fan.current) > 50 { anyChanged = true }
                if let manual, manual != fan.isManual { anyChanged = true }
                fanReadings.append((fan.index, spd, manual))
            }

            let primary = newSensors.first(where: { $0.key == "Tp01" })?.value
                ?? newSensors.first(where: { $0.category == .cpu && $0.value != nil })?.value

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.refreshInFlight = false
                guard anyChanged else { return }

                self.sensors = newSensors
                // Merge only the polled fields: target may have changed on the main
                // actor while this read was running.
                for r in fanReadings {
                    guard let i = self.fans.firstIndex(where: { $0.index == r.index }) else { continue }
                    self.fans[i].current = r.current
                    if let manual = r.isManual {
                        self.fans[i].isManual = manual
                        if !manual { self.fans[i].target = nil }
                    }
                }
                self.primaryTemp = primary
                self.lastUpdated = Date()
            }
        }
    }

    // MARK: - Fan control

    func setFanManual(index: Int, speed: Double) {
        guard let fan = fans.first(where: { $0.index == index }), fan.hasValidRange else { return }
        let rpm = fan.clamped(speed)
        manualRequested.insert(index)
        let smcRef = smc
        // The helper is a separate process; never wait on it from the main thread.
        smcQueue.async(qos: .userInitiated) { [weak self] in
            let ok = smcRef.setFanManual(index: index, speed: rpm)
            DispatchQueue.main.async { [weak self] in
                self?.applyFanWrite(index: index, ok: ok, manual: true, target: rpm)
            }
        }
    }

    func setFanAuto(index: Int) {
        manualRequested.remove(index)
        let smcRef = smc
        smcQueue.async(qos: .userInitiated) { [weak self] in
            let ok = smcRef.setFanAuto(index: index)
            DispatchQueue.main.async { [weak self] in
                self?.applyFanWrite(index: index, ok: ok, manual: false, target: nil)
            }
        }
    }

    private func applyFanWrite(index: Int, ok: Bool, manual: Bool, target: Double?) {
        guard ok else {
            fanControlAvailable = SMCReader.helperAvailable
            fanControlError = "Couldn't change Fan \(index + 1)."
                + (fanControlAvailable ? "" : " Fan control needs to be reinstalled.")
            return
        }
        fanControlError = nil
        if let i = fans.firstIndex(where: { $0.index == index }) {
            fans[i].isManual = manual
            fans[i].target = target
        }
    }

    func maxAllFans() {
        for fan in fans where fan.hasValidRange { setFanManual(index: fan.index, speed: fan.max) }
    }

    func resetAllFans() {
        for fan in fans { setFanAuto(index: fan.index) }
    }

    // Called at quit: hand every fan we (or a previous run) left in manual mode back
    // to the SMC. Synchronous so the writes finish before the process exits; queued
    // writes ahead of it on smcQueue run first.
    func restoreAutomaticFans() {
        let indices = manualRequested.union(fans.filter(\.isManual).map(\.index))
        guard !indices.isEmpty else { return }
        let smcRef = smc
        smcQueue.sync {
            for i in indices.sorted() { smcRef.setFanAuto(index: i) }
        }
    }

    // MARK: - Launch at Login

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else       { try SMAppService.mainApp.unregister() }
        } catch {
            print("Login item: \(error.localizedDescription)")
        }
        // Re-read so the toggle reflects what actually happened.
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
