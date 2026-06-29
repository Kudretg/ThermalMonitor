import SwiftUI

// MARK: - Root popover view

struct PopoverContentView: View {
    @EnvironmentObject var model: ThermalModel

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar()
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !model.fans.isEmpty {
                        FanSection()
                    }
                    TemperatureSection()
                }
                .padding(.vertical, 12)
            }
            .frame(maxHeight: 480)
            FooterBar()
        }
        .frame(width: 340)
        .background(.regularMaterial)
        .environmentObject(model)
    }
}

// MARK: - Header

private struct HeaderBar: View {
    @EnvironmentObject var model: ThermalModel
    @State private var isHoveringQuit = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "thermometer.medium")
                .foregroundStyle(.secondary)
                .font(.system(size: 14, weight: .medium))
            Text("Thermal Monitor")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Button {
                model.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .help("Refresh now")

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .help("Quit")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - Footer

private struct FooterBar: View {
    @EnvironmentObject var model: ThermalModel

    private var timeString: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: model.lastUpdated)
    }

    var body: some View {
        Divider()
        HStack {
            Text("Updated \(timeString)")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Spacer()
            Toggle("Launch at Login", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.launchAtLogin = $0 }
            ))
            .toggleStyle(.checkbox)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}

// MARK: - Temperature section

private struct TemperatureSection: View {
    @EnvironmentObject var model: ThermalModel

    private var grouped: [(String, [TemperatureSensor])] {
        let active = model.sensors.filter { $0.value != nil }
        let order: [TemperatureSensor.SensorCategory] = [.cpu, .gpu, .storage, .battery, .thermal, .other]
        return order.compactMap { cat in
            let items = active.filter { $0.category == cat }
            return items.isEmpty ? nil : (cat.rawValue, items)
        }
    }

    var body: some View {
        if grouped.isEmpty {
            HStack {
                Spacer()
                Label("No sensors found", systemImage: "sensor.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 24)
                Spacer()
            }
        } else {
            ForEach(grouped, id: \.0) { (title, items) in
                SectionGroup(title: title) {
                    ForEach(items) { sensor in
                        SensorRow(sensor: sensor)
                    }
                }
            }
        }
    }
}

// MARK: - Fan section

private struct FanSection: View {
    @EnvironmentObject var model: ThermalModel
    @State private var installing = false
    @State private var installError: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header: "FANS" label + Max / Auto buttons
            HStack(spacing: 8) {
                Text("FANS")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if model.fanControlAvailable {
                    Button {
                        model.maxAllFans()
                    } label: {
                        Label("Max", systemImage: "arrow.up.circle.fill")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.orange)

                    Button {
                        model.resetAllFans()
                    } label: {
                        Label("Auto", systemImage: "arrow.clockwise.circle.fill")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 4)

            GroupBox {
                VStack(spacing: 0) {
                    ForEach($model.fans) { $fan in
                        FanRow(fan: $fan)
                    }
                    if !model.fanControlAvailable {
                        FanControlSetupBanner(installing: $installing, installError: $installError)
                    }
                }
            }
            .padding(.horizontal, 10)
        }
    }
}

private struct FanControlSetupBanner: View {
    @EnvironmentObject var model: ThermalModel
    @Binding var installing: Bool
    @Binding var installError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text("Fan control needs a one-time permission setup.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            if let err = installError {
                Text(err)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            HStack {
                if installing {
                    ProgressView()
                        .controlSize(.small)
                    Text("Installing…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    Button {
                        installing = true
                        installError = nil
                        model.installFanHelper { success, error in
                            installing = false
                            if !success {
                                installError = error ?? "Installation failed."
                            }
                        }
                    } label: {
                        Label("Enable Fan Control", systemImage: "lock.open.fill")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

// MARK: - Section group

private struct SectionGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
            GroupBox {
                VStack(spacing: 0) {
                    content
                }
            }
            .padding(.horizontal, 10)
        }
    }
}

// MARK: - Sensor row

private struct SensorRow: View {
    let sensor: TemperatureSensor

    var body: some View {
        HStack(spacing: 10) {
            Text(sensor.name)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .frame(width: 110, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.quaternary)
                        .frame(height: 5)
                    Capsule()
                        .fill(sensor.color.gradient)
                        .frame(width: geo.size.width * sensor.fraction, height: 5)
                        .animation(.easeInOut(duration: 0.4), value: sensor.fraction)
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 18)

            Text(sensor.display)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(sensor.color)
                .frame(width: 60, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        Divider().padding(.leading, 130)
    }
}

// MARK: - Fan row

private struct FanRow: View {
    @EnvironmentObject var model: ThermalModel
    @Binding var fan: FanData
    @State private var sliderValue: Double = 1200

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: fan.current < 10 ? "fan" : "fan.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(fan.current < 10 ? .secondary : .primary)
                Text(fan.name)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                if fan.current < 10 {
                    Text("Idle")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    Text(fan.rpm)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.primary)
                }
            }

            // Speed bar — show relative between min and max when running
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary).frame(height: 5)
                    if fan.current >= 10 {
                        Capsule()
                            .fill(fanColor(fan.current, max: fan.max).gradient)
                            .frame(width: geo.size.width * fan.fraction, height: 5)
                            .animation(.easeInOut(duration: 0.4), value: fan.fraction)
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 10)

            // Manual control (disabled if helper not installed)
            HStack {
                Toggle("Manual control", isOn: Binding(
                    get: { fan.isManual },
                    set: { manual in
                        if manual {
                            sliderValue = fan.current > 100 ? fan.current : fan.min
                            model.setFanManual(index: fan.index, speed: sliderValue)
                        } else {
                            model.setFanAuto(index: fan.index)
                        }
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.system(size: 11))
                .disabled(!model.fanControlAvailable)
                Spacer()
                if fan.isManual {
                    Text(String(format: "%.0f RPM", sliderValue))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(Int(fan.min))–\(Int(fan.max)) RPM")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }

            if fan.isManual {
                HStack(spacing: 6) {
                    Text(String(format: "%.0f", fan.min))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    Slider(value: $sliderValue, in: fan.min...fan.max, step: 50) { editing in
                        if !editing {
                            model.setFanManual(index: fan.index, speed: sliderValue)
                        }
                    }
                    Text(String(format: "%.0f", fan.max))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                .onAppear {
                    sliderValue = fan.target ?? max(fan.current, fan.min)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        Divider().padding(.leading, 10)
    }

    private func fanColor(_ speed: Double, max: Double) -> Color {
        let f = max > 0 ? speed / max : 0
        if f < 0.5 { return .green }
        if f < 0.75 { return .yellow }
        return .orange
    }
}
