import SwiftUI
import NozzleCore

/// Heater control: live readouts, a target for each heater, the preheat presets, and
/// the history graph.
struct TemperaturesView: View {
    @Environment(PrinterController.self) private var controller

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                if !controller.state.activity.isConnected {
                    InfoCard(
                        symbol: "thermometer.medium.slash",
                        title: "No readings",
                        message: "Connect to the printer to see live temperatures and set the heaters."
                    )
                }

                preheatCard

                if !controller.temperatureHistory.isEmpty {
                    Card {
                        SectionHeading("History", detail: "The last ten minutes. Solid lines are what the "
                                                       + "printer reports, dashed lines what it was asked for.")
                        TemperatureGraph(samples: controller.temperatureHistory)
                    }
                }

                HeaterCard(
                    heater: .hotend,
                    symbol: "flame",
                    reading: controller.state.hotend,
                    limit: controller.profile.maxHotendTemperature,
                    detail: "Melts the filament. Nothing can be extruded below "
                          + "\(MovePlanner.format(controller.profile.minimumExtrusionTemperature)) °C."
                )

                HeaterCard(
                    heater: .bed,
                    symbol: "square.3.layers.3d.bottom.filled",
                    reading: controller.state.bed,
                    limit: controller.profile.maxBedTemperature,
                    detail: "Keeps the first layer stuck down. PLA needs far less heat here than the nozzle."
                )

                if controller.state.activity.isConnected {
                    Text(freshness)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                footnote
            }
            .padding(28)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Presets

    private var preheatCard: some View {
        Card {
            SectionHeading("Preheat", detail: "Sets both heaters at once and lets them warm up in the "
                                            + "background — you can carry on using the other controls.")

            HStack(spacing: 10) {
                ForEach(PreheatPreset.standard(for: controller.profile)) { preset in
                    Button {
                        Task { await controller.preheat(preset) }
                    } label: {
                        VStack(spacing: 2) {
                            Text(preset.name).font(.system(size: 13, weight: .semibold))
                            Text("\(MovePlanner.format(preset.hotend)) / \(MovePlanner.format(preset.bed)) °C")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    }
                    .help(preset.note)
                }

                Button {
                    Task { await controller.turnHeatersOff() }
                } label: {
                    VStack(spacing: 2) {
                        Text("Cool down").font(.system(size: 13, weight: .semibold))
                        Text("both off")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .help("Turns both heaters off. The fan keeps running until the hotend is cool.")
            }
            .disabled(!controller.state.activity.isConnected || controller.isBusyWithOperation)

            if let operation = controller.operation {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text(operation).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// How old the numbers on screen are. A frozen readout is worth spotting.
    private var freshness: String {
        guard let updated = controller.state.lastTemperatureUpdate else {
            return "Waiting for the first reading…"
        }
        let age = Int(Date().timeIntervalSince(updated))
        return age < 5 ? "Last reading just now." : "Last reading \(age)s ago."
    }

    private var footnote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Why nothing freezes while it heats").font(.headline)
            Text("There are two ways to ask a printer to heat up. One tells it to sit and wait until the "
               + "temperature is reached, which also stops it answering anything else for the several "
               + "minutes that takes. Nozzle uses the other: it sets the target and keeps talking, so the "
               + "readout stays live and you can still move the printer or turn the heater back off.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - One heater

private struct HeaterCard: View {
    @Environment(PrinterController.self) private var controller

    let heater: Heater
    let symbol: String
    let reading: HeaterTemperature?
    let limit: Double
    let detail: String

    @State private var entered: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        Card {
            HStack(alignment: .firstTextBaseline) {
                SectionHeading(heater.displayName, detail: detail)
                Spacer(minLength: 16)
                readout
            }

            HStack(spacing: 8) {
                TextField("Target", text: $entered, prompt: Text("°C"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 82)
                    .focused($focused)
                    .onSubmit { apply() }
                    .help("A target between 0 and \(MovePlanner.format(limit)) °C. 0 turns the heater off.")

                Button("Set") { apply() }
                    .disabled(parsed == nil)

                Button("Off") {
                    entered = ""
                    focused = false
                    Task { await controller.setTemperature(heater, celsius: 0) }
                }

                Spacer()

                if let reading, reading.isHeating {
                    Label(status(reading), systemImage: statusSymbol(reading))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!controller.state.activity.isConnected || controller.isBusyWithOperation)
        }
    }

    private var readout: some View {
        Text(reading?.formatted() ?? "—")
            .font(.system(size: 26, weight: .medium, design: .rounded))
            .monospacedDigit()
            .contentTransition(.numericText())
            .foregroundStyle(reading?.isHeating == true ? Color.orange : .primary)
            .accessibilityLabel("\(heater.displayName): \(reading?.formatted() ?? "no reading")")
    }

    /// The typed target, or nil when it is not a number this heater will accept.
    private var parsed: Double? {
        let text = entered.trimmingCharacters(in: .whitespaces)
        guard let value = Double(text.replacingOccurrences(of: ",", with: ".")) else { return nil }
        guard value >= 0, value <= limit else { return nil }
        return value
    }

    private func apply() {
        guard let value = parsed else { return }
        focused = false
        Task { await controller.setTemperature(heater, celsius: value) }
    }

    private func status(_ reading: HeaterTemperature) -> String {
        guard let target = reading.target, target > 0 else { return "Off" }
        let difference = target - reading.current
        if abs(difference) <= 2 { return "At temperature" }
        return difference > 0 ? "Heating" : "Cooling"
    }

    private func statusSymbol(_ reading: HeaterTemperature) -> String {
        guard let target = reading.target, target > 0 else { return "power" }
        return abs(target - reading.current) <= 2 ? "checkmark.circle" : "arrow.up.circle"
    }
}
