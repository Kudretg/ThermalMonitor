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

    var fraction: Double {
        guard max > min, current >= 10 else { return 0 }
        return Swift.min(Swift.max((current - min) / (max - min), 0), 1)
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

    func installFanHelper(completion: @escaping (Bool, String?) -> Void) {
        SMCReader.installHelper { [weak self] success, error in
            self?.fanControlAvailable = SMCReader.helperAvailable
            completion(success, error)
        }
    }

    private let smc = SMCReader()
    private var pollingSource: DispatchSourceTimer?

    init() {
        smc.open()
        sensors = sensorCatalogue.map { TemperatureSensor(name: $0.0, key: $0.1, category: $0.2) }
        loadFans()
        startPolling()
    }

    deinit {
        pollingSource?.cancel()
        NotificationCenter.default.removeObserver(self)
        smc.close()
    }

    private func loadFans() {
        let count = smc.fanCount()
        fans = (0..<count).map { i in
            var f = FanData(index: i)
            f.min = smc.fanMinSpeed(index: i) ?? 1200
            f.max = smc.fanMaxSpeed(index: i) ?? 6800
            return f
        }
    }

    private func startPolling() {
        refresh()

        // DispatchSourceTimer on the main queue: fires in the main-actor context
        // so reading @MainActor properties is safe. SMC reads are dispatched out
        // to a background queue inside refresh().
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + 1, repeating: 1.0, leeway: .milliseconds(100))
        source.setEventHandler { [weak self] in self?.refresh() }
        source.resume()
        pollingSource = source

        // Immediate refresh on wake from sleep
        NotificationCenter.default.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }
    }

    func refresh() {
        // Capture snapshots on the main actor, then hand off to a background queue
        // for the actual IOKit SMC reads. Only dispatch a UI update when something changed.
        let sensorSnapshot = sensors
        let fanSnapshot    = fans
        let smcRef         = smc

        DispatchQueue.global(qos: .utility).async { [weak self] in
            var newSensors = sensorSnapshot
            var newFans    = fanSnapshot
            var anyChanged = false

            for i in newSensors.indices {
                let v = smcRef.temperature(key: newSensors[i].key)
                if abs((v ?? 0) - (newSensors[i].value ?? -999)) > 0.4 { anyChanged = true }
                newSensors[i].value = v
            }
            for i in newFans.indices {
                let spd = smcRef.fanCurrentSpeed(index: newFans[i].index) ?? 0
                if abs(spd - newFans[i].current) > 50 { anyChanged = true }
                newFans[i].current = spd
            }

            guard anyChanged else { return }

            let primary = newSensors.first(where: { $0.key == "Tp01" })?.value
                ?? newSensors.first(where: { $0.category == .cpu && $0.value != nil })?.value

            DispatchQueue.main.async { [weak self] in
                self?.sensors     = newSensors
                self?.fans        = newFans
                self?.primaryTemp = primary
                self?.lastUpdated = Date()
            }
        }
    }

    func setFanManual(index: Int, speed: Double) {
        smc.setFanManual(index: index, speed: speed)
        if let i = fans.firstIndex(where: { $0.index == index }) {
            fans[i].isManual = true
            fans[i].target = speed
        }
    }

    // MARK: - Launch at Login

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() }
                else        { try SMAppService.mainApp.unregister() }
            } catch {
                print("Login item: \(error.localizedDescription)")
            }
        }
    }

    func setFanAuto(index: Int) {
        smc.setFanAuto(index: index)
        if let i = fans.firstIndex(where: { $0.index == index }) {
            fans[i].isManual = false
            fans[i].target = nil
        }
    }

    func maxAllFans() {
        for fan in fans { setFanManual(index: fan.index, speed: fan.max) }
    }

    func resetAllFans() {
        for fan in fans { setFanAuto(index: fan.index) }
    }
}
