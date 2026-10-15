import SwiftUI
import AppKit

@main
struct ThermalMonitorApp: App {
    // The delegate owns the model so it can restore fans at quit.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            PopoverContentView()
                .environmentObject(appDelegate.model)
        } label: {
            MenuBarLabel()
                .environmentObject(appDelegate.model)
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - App delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // Lazy so it's created on first use from the main actor, not in NSObject's init.
    private(set) lazy var model = ThermalModel()
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // SIGTERM/SIGINT (`kill`, `pkill`, `make run`) would otherwise exit without
        // applicationWillTerminate and leave fans in manual mode. Route them through
        // a normal quit instead.
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { NSApplication.shared.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.restoreAutomaticFans()
    }
}

// MARK: - Menu bar label

struct MenuBarLabel: View {
    @EnvironmentObject var model: ThermalModel

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: iconName)
                .font(.system(size: 12, weight: .medium))
            if let t = model.primaryTemp {
                Text(String(format: "%.0f°", t))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
            }
        }
        .foregroundStyle(labelColor)
    }

    private var labelColor: Color {
        guard let t = model.primaryTemp else { return .primary }
        if t < 70 { return .primary }
        if t < 85 { return .orange }
        return .red
    }

    private var iconName: String {
        guard let t = model.primaryTemp else { return "thermometer.medium" }
        if t < 50 { return "thermometer.low" }
        if t < 80 { return "thermometer.medium" }
        return "thermometer.high"
    }
}
