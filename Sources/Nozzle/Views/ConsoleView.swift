import SwiftUI
import NozzleCore

/// Advanced → Console. Everything technical lives here so the other screens don't have to.
struct ConsoleView: View {
    @Environment(PrinterController.self) private var controller

    @State private var commandText = ""
    @State private var commandHistory: [String] = []
    @State private var historyCursor: Int?
    @State private var autoScroll = true
    @State private var hiddenDirections: Set<TrafficEntry.Direction> = []
    @State private var pendingDangerousCommand: DangerousCommand?

    private struct DangerousCommand: Identifiable {
        let id = UUID()
        let command: String
        let reason: String
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            transcript
            Divider()
            commandField
        }
        .alert(item: $pendingDangerousCommand) { pending in
            Alert(
                title: Text("Send \(pending.command)?"),
                message: Text(pending.reason),
                primaryButton: .destructive(Text("Send \(pending.command)")) {
                    dispatch(pending.command)
                },
                secondaryButton: .cancel()
            )
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            ForEach(TrafficEntry.Direction.allCases, id: \.self) { direction in
                Toggle(isOn: Binding(
                    get: { !hiddenDirections.contains(direction) },
                    set: { shown in
                        if shown { hiddenDirections.remove(direction) } else { hiddenDirections.insert(direction) }
                    }
                )) {
                    Text(label(for: direction)).font(.caption)
                }
                .toggleStyle(.button)
                .controlSize(.small)
            }

            Divider().frame(height: 16)

            Toggle(isOn: $autoScroll) {
                Label("Follow", systemImage: "arrow.down.to.line")
                    .font(.caption)
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .help("Keep scrolling to the newest line")

            Spacer()

            Text("\(visibleEntries.count) lines")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Button {
                let text = controller.log.exportText()
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .controlSize(.small)
            .help("Copy the whole log to the clipboard")

            Button(role: .destructive) {
                controller.clearLog()
            } label: {
                Label("Clear", systemImage: "trash")
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func label(for direction: TrafficEntry.Direction) -> String {
        switch direction {
        case .tx: return "TX"
        case .rx: return "RX"
        case .info: return "Notes"
        case .warning: return "Warnings"
        }
    }

    // MARK: Transcript

    private var visibleEntries: [TrafficEntry] {
        controller.log.entries.filter { !hiddenDirections.contains($0.direction) }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if controller.log.droppedCount > 0 {
                        Text("… \(controller.log.droppedCount) earlier line(s) dropped from the buffer …")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 4)
                    }
                    ForEach(visibleEntries) { entry in
                        row(entry).id(entry.id)
                    }
                    // Anchor so "follow" has something stable to scroll to.
                    Color.clear.frame(height: 1).id(bottomAnchor)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .textSelection(.enabled)
            .onChange(of: controller.log.entries.count) {
                guard autoScroll else { return }
                withAnimation(.linear(duration: 0.1)) {
                    proxy.scrollTo(bottomAnchor, anchor: .bottom)
                }
            }
        }
    }

    private let bottomAnchor = "console-bottom"

    private func row(_ entry: TrafficEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(Self.timeFormatter.string(from: entry.timestamp))
                .foregroundStyle(.tertiary)
            Text(entry.direction.rawValue)
                .foregroundStyle(color(for: entry.direction))
                .frame(width: 22, alignment: .leading)
            Text(entry.text)
                .foregroundStyle(entry.direction == .warning ? Color.orange : Color.primary)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11.5, design: .monospaced))
    }

    private func color(for direction: TrafficEntry.Direction) -> Color {
        switch direction {
        case .tx: return .blue
        case .rx: return .green
        case .info: return .secondary
        case .warning: return .orange
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    // MARK: Command entry

    private var commandField: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)

            TextField("Type a G-code command, e.g. M105", text: $commandText)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .autocorrectionDisabled()
                .onSubmit(submit)
                .onKeyPress(.upArrow) { recallHistory(offset: -1); return .handled }
                .onKeyPress(.downArrow) { recallHistory(offset: 1); return .handled }
                .disabled(!controller.state.activity.isConnected)

            Button("Send", action: submit)
                .keyboardShortcut(.return, modifiers: [])
                .disabled(commandText.trimmingCharacters(in: .whitespaces).isEmpty
                          || !controller.state.activity.isConnected)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) {
            if !controller.state.activity.isConnected {
                Text("Connect to a printer to send commands.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, -18)
            }
        }
    }

    private func submit() {
        let command = commandText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }

        commandHistory.append(command)
        historyCursor = nil

        // A typo like M502 instead of M503 wipes the printer's calibration, so risky
        // commands get an explanation and a second, deliberate click.
        if case .dangerous(let reason) = CommandSafety.assess(command) {
            pendingDangerousCommand = DangerousCommand(command: command, reason: reason)
            commandText = ""
            return
        }
        dispatch(command)
        commandText = ""
    }

    private func dispatch(_ command: String) {
        Task { await controller.sendConsoleCommand(command) }
    }

    private func recallHistory(offset: Int) {
        guard !commandHistory.isEmpty else { return }
        let current = historyCursor ?? commandHistory.count
        let next = min(max(current + offset, 0), commandHistory.count)
        historyCursor = next
        commandText = next < commandHistory.count ? commandHistory[next] : ""
    }
}
