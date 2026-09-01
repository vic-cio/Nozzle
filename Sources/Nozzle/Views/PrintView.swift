import SwiftUI
import UniformTypeIdentifiers
import NozzleCore

/// The main screen: choose a file, look at what it will do, press Print.
struct PrintView: View {
    @Environment(PrinterController.self) private var controller
    @State private var isChoosingFile = false
    @State private var isConfirmingStop = false

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                if controller.state.activity.isJobActive {
                    progressCard
                } else if let file = controller.loadedFile {
                    fileCard(file)
                    warningsSection
                    startSection
                } else {
                    chooser
                    if !controller.state.activity.isConnected { gettingStarted }
                }
            }
            .padding(28)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
        }
        .fileImporter(
            isPresented: $isChoosingFile,
            allowedContentTypes: GCodeDocument.readableTypes,
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                controller.loadFile(at: url)
            }
        }
        // Dragging a file from Finder is how most people will do this.
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, !controller.state.activity.isJobActive else { return false }
            controller.loadFile(at: url)
            return true
        }
    }

    // MARK: - Choosing a file

    private var chooser: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.badge.plus")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Color.accentColor)
            Text("Choose a G-code file").font(.title3.weight(.semibold))
            Text("Slice your model in Cura, save the .gcode file, then drop it here or use the button. "
               + "Nozzle checks it against your printer before anything is sent.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)

            Button("Choose file…") { isChoosingFile = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut("o", modifiers: .command)
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - The loaded file

    private func fileCard(_ file: GCodeFile) -> some View {
        Card {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name).font(.headline).lineLimit(1).truncationMode(.middle)
                    if let generator = file.metadata.generator {
                        Text(generator).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 12)
                Button("Choose another…") { isChoosingFile = true }
                    .controlSize(.small)
            }

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 7) {
                detail("Size", file.metadata.bounds.sizeDescription)
                detail("Layers", "\(file.layerCount)"
                       + (file.metadata.layerHeight.map { " at \(MovePlanner.format($0)) mm" } ?? ""))
                detail("Estimated time", file.metadata.estimatedDuration.map(formatDuration))
                detail("Filament", file.metadata.filamentUsedMetres.map { "\(MovePlanner.format($0)) m" })
                detail("Temperatures", temperatureSummary(file))
                detail("Commands", "\(file.commandCount)")
            }
            .font(.system(size: 12))
        }
    }

    private func temperatureSummary(_ file: GCodeFile) -> String? {
        let nozzle = file.metadata.maxHotendTarget.map { "\(MovePlanner.format($0)) °C nozzle" }
        let bed = file.metadata.maxBedTarget.map { "\(MovePlanner.format($0)) °C bed" }
        let parts = [nozzle, bed].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    @ViewBuilder
    private func detail(_ label: String, _ value: String?) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value ?? "Not stated in the file").textSelection(.enabled)
        }
    }

    private var warningsSection: some View {
        VStack(spacing: 10) {
            ForEach(controller.fileWarnings) { warning in
                WarningCard(warning: warning)
            }
        }
    }

    // MARK: - Starting

    private var startSection: some View {
        Card {
            HStack(spacing: 14) {
                Button {
                    Task { await controller.startPrint() }
                } label: {
                    Label("Print", systemImage: "printer.fill")
                        .frame(minWidth: 120)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(controller.printBlockedReason != nil)

                if let reason = controller.printBlockedReason {
                    Text(reason)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("The file heats the printer and homes it itself. Make sure the bed is clear and "
                       + "levelled, and that filament is loaded.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - While printing

    private var progressCard: some View {
        let progress = controller.progress ?? PrintProgress()

        return VStack(spacing: 20) {
            Card {
                HStack(alignment: .firstTextBaseline) {
                    Text(controller.loadedFile?.name ?? "Printing")
                        .font(.headline).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 12)
                    Text("\(Int(progress.fraction * 100))%")
                        .font(.system(size: 22, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }

                ProgressView(value: progress.fraction)

                phaseBanner

                HStack(spacing: 26) {
                    stat("Layer", progress.layerIndex.map { "\($0 + 1) of \(progress.layerCount)" } ?? "—")
                    stat("Time left", progress.estimatedRemaining.map(formatDuration) ?? "Unknown")
                    stat("Printing for", progress.printingTime.map(formatDuration) ?? "—")
                    if progress.pausedDuration >= 1 {
                        stat("Paused for", formatDuration(progress.pausedDuration))
                    }
                    stat("Commands", "\(progress.commandsSent) of \(progress.commandCount)")
                }
            }

            Card {
                HStack(spacing: 40) {
                    TemperatureReadout(title: "NOZZLE", symbol: "flame", heater: controller.state.hotend)
                    TemperatureReadout(title: "BED", symbol: "square.3.layers.3d.bottom.filled", heater: controller.state.bed)
                }
                TemperatureGraph(samples: controller.temperatureHistory, height: 140)
            }

            controlsCard
        }
        .confirmationDialog("Stop the print?", isPresented: $isConfirmingStop) {
            Button("Stop the print", role: .destructive) {
                Task { await controller.stopPrint() }
            }
            Button("Keep printing", role: .cancel) {}
        } message: {
            Text("The part on the bed will be unfinished and cannot be finished later — stopping is not "
               + "pausing. You would need to start the file again from the beginning. If you only need "
               + "the printer for a moment, pause instead.")
        }
    }

    /// What the printer is doing when it is doing something other than printing.
    @ViewBuilder
    private var phaseBanner: some View {
        switch controller.jobPhase {
        case .pausing:
            banner("Pausing", "Finishing the command the printer is already on, then parking the nozzle.",
                   symbol: "pause.circle", tint: .orange, spinning: true)
        case .paused:
            banner("Paused", "The nozzle is parked clear of the print and both heaters are still on. "
                           + "Filament sitting in a hot nozzle degrades, so try not to leave it too long.",
                   symbol: "pause.circle.fill", tint: .orange, spinning: false)
        case .resuming:
            banner("Resuming", "Moving back to where the print left off before carrying on.",
                   symbol: "play.circle", tint: .orange, spinning: true)
        default:
            EmptyView()
        }
    }

    private func banner(_ title: String, _ detail: String, symbol: String, tint: Color, spinning: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if spinning {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: symbol).foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private var controlsCard: some View {
        Card {
            HStack(spacing: 12) {
                if controller.jobPhase == .paused {
                    Button {
                        Task { await controller.resumePrint() }
                    } label: {
                        Label("Resume", systemImage: "play.fill").frame(minWidth: 90)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                } else {
                    Button {
                        Task { await controller.pausePrint() }
                    } label: {
                        Label("Pause", systemImage: "pause.fill").frame(minWidth: 90)
                    }
                    .controlSize(.large)
                    .disabled(controller.pauseBlockedReason != nil)
                }

                Button(role: .destructive) {
                    isConfirmingStop = true
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .controlSize(.large)

                Spacer(minLength: 0)
            }

            Text(controlsExplanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if controller.isPreventingSleep {
                Label("This Mac is being kept awake until the print finishes. Closing a laptop's lid "
                    + "still sleeps it, which would stop the print.",
                      systemImage: "bolt.badge.clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var controlsExplanation: String {
        if controller.jobPhase == .paused {
            return "Resuming moves the nozzle back over the print, lowers it to the layer it was on, "
                 + "pushes the retracted filament back and carries on from the next command."
        }
        return "Pausing waits for the command the printer is on, then pulls the filament back a little, "
             + "lifts the nozzle off the part and parks it out of the way — the heaters stay on so the "
             + "print can carry on. Stopping does the same but turns everything off, and cannot be undone."
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 14, weight: .medium)).monospacedDigit()
        }
    }

    /// "1h 04m" / "31 min" / "45s"
    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total >= 3600 {
            return "\(total / 3600)h \(String(format: "%02d", (total % 3600) / 60))m"
        }
        if total >= 60 { return "\(total / 60) min" }
        return "\(total)s"
    }

    // MARK: - Not connected yet

    private var gettingStarted: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Before you print").font(.headline)
            step(1, "Connect the printer.",
                 "Plug it into this Mac over USB, switch it on and press Connect at the top right.")
            step(2, "Level the bed.",
                 "This printer has no automatic levelling, so it is done by hand with a sheet of paper "
                 + "under the nozzle. A print will not stick without it.")
            step(3, "Load filament.",
                 "Heat the nozzle on the Temperatures screen, then push filament through on Prepare.")
            step(4, "Choose your file and press Print.",
                 "Nozzle checks the file fits the bed and stays within the printer's temperature limits "
                 + "before sending anything.")
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private func step(_ number: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .frame(width: 20, height: 20)
                .background(Color.accentColor.opacity(0.18), in: Circle())
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Supporting pieces

/// The file types the picker will offer. `.gcode` has no registered UTI on macOS, so it
/// is declared here by filename extension rather than being silently unselectable.
enum GCodeDocument {
    static let readableTypes: [UTType] = {
        var types: [UTType] = []
        if let gcode = UTType(filenameExtension: "gcode") { types.append(gcode) }
        if let gco = UTType(filenameExtension: "gco") { types.append(gco) }
        types.append(.plainText)
        return types
    }()
}

private struct WarningCard: View {
    let warning: GCodeWarning

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: warning.severity == .blocking ? "exclamationmark.octagon.fill" : "info.circle")
                .foregroundStyle(warning.severity == .blocking ? Color.red : Color.orange)
                .font(.system(size: 16))
            VStack(alignment: .leading, spacing: 4) {
                Text(warning.title).font(.system(size: 13, weight: .semibold))
                Text(warning.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            (warning.severity == .blocking ? Color.red : Color.orange).opacity(0.12),
            in: RoundedRectangle(cornerRadius: 10)
        )
    }
}
