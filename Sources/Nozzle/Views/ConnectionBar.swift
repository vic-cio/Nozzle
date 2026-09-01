import SwiftUI
import NozzleCore

/// The persistent header: who we are talking to, over what, and whether it is working.
struct ConnectionBar: View {
    @Environment(PrinterController.self) private var controller
    @State private var isWorking = false

    var body: some View {
        @Bindable var controller = controller

        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(controller.headerTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                if let detail = subtitle {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            StatusPill(activity: controller.state.activity)

            if controller.state.isBusy {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.small)
                    Text("Busy").font(.caption).foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 12)

            if controller.state.activity.isConnected {
                HStack(spacing: 18) {
                    TemperatureReadout(title: "NOZZLE", symbol: "flame", heater: controller.state.hotend, compact: true)
                    TemperatureReadout(title: "BED", symbol: "square.3.layers.3d.bottom.filled", heater: controller.state.bed, compact: true)
                }
                .padding(.trailing, 4)
            } else {
                portControls
            }

            connectButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var subtitle: String? {
        if controller.state.activity.isConnected {
            var parts: [String] = []
            if let port = controller.state.portPath {
                parts.append((port as NSString).lastPathComponent)
            }
            parts.append("\(controller.state.baudRate) baud")
            if let firmware = controller.firmwareSummary { parts.append(firmware) }
            return parts.joined(separator: "  •  ")
        }
        if case .error(let reason) = controller.state.activity { return reason }
        return "Not connected"
    }

    // MARK: Port + baud pickers

    @ViewBuilder
    private var portControls: some View {
        @Bindable var controller = controller

        Picker("Port", selection: $controller.selectedPortPath) {
            Text(autoLabel).tag(String?.none)
            ForEach(controller.ports) { port in
                Text(port.displayName).tag(String?.some(port.path))
            }
        }
        .labelsHidden()
        .frame(maxWidth: 260)
        .disabled(controller.useDemoPrinter)
        .help("Which USB serial device your printer is on. macOS names these /dev/cu.usbserial-… — "
            + "Nozzle picks the most likely one for you.")

        Picker("Baud", selection: $controller.profile.baudRate) {
            ForEach(BaudRate.common, id: \.self) { rate in
                // String(rate), not "\(rate)": the latter picks up locale digit
                // grouping and renders 115200 as "115,200", which is not a baud rate.
                Text(String(rate)).tag(rate)
            }
        }
        .labelsHidden()
        .frame(width: 96)
        .disabled(controller.useDemoPrinter)
        .help("Serial speed. Marlin on an Ender-5 Pro is normally 115200. This must match "
            + "the printer exactly or you will see nothing but garbled text.")

        Button {
            controller.refreshPorts()
        } label: {
            Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.borderless)
        .help("Look for serial ports again (⇧⌘R)")

        Toggle("Demo", isOn: $controller.useDemoPrinter)
            .toggleStyle(.switch)
            .controlSize(.mini)
            .help("Connect to a built-in simulated printer instead of real hardware. "
                + "Useful for trying Nozzle out with nothing plugged in.")
    }

    private var autoLabel: String {
        guard !controller.useDemoPrinter else { return "Demo Printer" }
        if let best = SerialPortDiscovery.bestGuess(from: controller.ports) {
            return "Automatic — \(best.displayName)"
        }
        return controller.ports.isEmpty ? "No serial ports found" : "Automatic"
    }

    // MARK: Connect

    private var connectButton: some View {
        Button {
            isWorking = true
            Task {
                if controller.state.activity.isConnected {
                    await controller.disconnect()
                } else {
                    await controller.connect()
                }
                isWorking = false
            }
        } label: {
            HStack(spacing: 6) {
                if isWorking { ProgressView().controlSize(.small) }
                Text(controller.state.activity.isConnected ? "Disconnect" : "Connect")
                    .frame(minWidth: 68)
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .keyboardShortcut("k", modifiers: .command)
        .disabled(isWorking || (!controller.canConnect && !controller.state.activity.isConnected))
    }
}
