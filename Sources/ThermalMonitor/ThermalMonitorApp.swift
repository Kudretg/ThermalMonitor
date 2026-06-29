import SwiftUI

@main
struct ThermalMonitorApp: App {
    @StateObject private var model = ThermalModel()

    var body: some Scene {
        MenuBarExtra {
            PopoverContentView()
                .environmentObject(model)
        } label: {
            MenuBarLabel()
                .environmentObject(model)
        }
        .menuBarExtraStyle(.window)
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
