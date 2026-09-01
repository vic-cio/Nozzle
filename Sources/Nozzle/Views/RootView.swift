import SwiftUI
import NozzleCore

enum MainSection: String, CaseIterable, Identifiable {
    case print = "Print"
    case prepare = "Prepare"
    case temperatures = "Temperatures"
    case console = "Console"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .print:        return "printer"
        case .prepare:      return "move.3d"
        case .temperatures: return "thermometer.medium"
        case .console:      return "terminal"
        }
    }

    /// The digit this section answers to in the View menu, pressed with ⌘. Never bare:
    /// an unmodified digit shortcut steals typing from every text field in the window.
    var shortcut: KeyEquivalent {
        switch self {
        case .print:        return "1"
        case .prepare:      return "2"
        case .temperatures: return "3"
        case .console:      return "4"
        }
    }
}

struct RootView: View {
    @Environment(PrinterController.self) private var controller

    var body: some View {
        @Bindable var controller = controller

        VStack(spacing: 0) {
            ConnectionBar()
            Divider()

            Picker("", selection: $controller.section) {
                ForEach(MainSection.allCases) { item in
                    Label(item.rawValue, systemImage: item.symbol).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            Group {
                switch controller.section {
                case .print:        PrintView()
                case .prepare:      PrepareView()
                case .temperatures: TemperaturesView()
                case .console:      ConsoleView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.background)
        .alert(
            "Printer problem",
            isPresented: Binding(
                get: { controller.lastError != nil },
                set: { if !$0 { controller.lastError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { controller.lastError = nil }
        } message: {
            Text(controller.lastError ?? "")
        }
        // Switching sections from the keyboard lives in the View menu as ⌘1–⌘4.
        // It used to be here as bare 1/2/3/4, which swallowed those digits before any
        // text field could see them — typing a 210 °C target produced "0".
    }
}

// MARK: - Shared building blocks

/// The coloured status pill. Deliberately the loudest thing in the window: the user
/// should never have to work out whether the printer is actually connected.
struct StatusPill: View {
    let activity: PrinterActivity

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(activity.label)
                .font(.system(size: 12, weight: .semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.15), in: Capsule())
        .foregroundStyle(color)
        .accessibilityLabel("Printer status: \(activity.label)")
    }

    private var color: Color {
        switch activity {
        case .disconnected: return .secondary
        case .connecting:   return .orange
        case .connected:    return .green
        case .printing:     return .blue
        case .paused:       return .orange
        case .error:        return .red
        }
    }
}

/// A large temperature readout: "Nozzle  198 / 200 °C".
struct TemperatureReadout: View {
    let title: String
    let symbol: String
    let heater: HeaterTemperature?
    var compact = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(heater?.isHeating == true ? .orange : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(heater?.formatted() ?? "—")
                    .font(.system(size: compact ? 13 : 20, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Empty-state / explanation card used across the placeholder screens.
struct InfoCard: View {
    let symbol: String
    let title: String
    let message: String
    var tint: Color = .accentColor

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(tint)
            Text(title)
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
        }
        .padding(28)
    }
}
