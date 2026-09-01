import SwiftUI
import NozzleCore

/// Homing, jogging, motors off and the extruder controls.
///
/// The rule this screen follows: a control that cannot be used still says why. Marlin
/// refuses a cold extrusion or an unhomed move with a one-line error buried in the
/// serial log — this screen explains the same thing before the button is pressed.
struct PrepareView: View {
    @Environment(PrinterController.self) private var controller

    /// How far one press of a jog button moves, in millimetres.
    @State private var step: Double = 1
    /// How much filament one press of Extrude or Retract moves.
    @State private var filamentStep: Double = 5

    private let stepChoices: [Double] = [0.1, 1, 10, 100]
    private let filamentChoices: [Double] = [1, 5, 10, 50]

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                positionCard

                if let note = controller.lastNote {
                    NoticeBanner(text: note) { controller.lastNote = nil }
                }

                homingCard
                movementCard
                extruderCard
            }
            .padding(28)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Position

    private var positionCard: some View {
        Card {
            HStack(alignment: .center) {
                ForEach(PrinterAxis.allCases) { axis in
                    axisReadout(axis)
                    if axis != .z { Spacer(minLength: 0) }
                }

                Spacer(minLength: 16)

                Button("Read position") {
                    Task { await controller.readPosition() }
                }
                .disabled(!controller.state.activity.isConnected || controller.isBusyWithOperation)
                .help("Asks the printer where it thinks it is (M114).")
            }

            if let operation = controller.operation {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text(operation).font(.callout).foregroundStyle(.secondary)
                }
            } else if !controller.state.hasHomedAllAxes, controller.state.position != nil {
                Text("These numbers are the printer's guess. Until an axis is homed they mean nothing — "
                   + "the firmware starts from wherever the nozzle happened to be switched on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func axisReadout(_ axis: PrinterAxis) -> some View {
        let homed = controller.state.homedAxes.contains(axis)
        let value = controller.state.position?.value(for: axis)

        return VStack(spacing: 3) {
            HStack(spacing: 4) {
                Text(axis.rawValue)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Image(systemName: homed ? "house.fill" : "questionmark")
                    .font(.system(size: 8))
                    .foregroundStyle(homed ? Color.green : Color.orange)
            }
            Text(value.map { String(format: "%.2f", $0) } ?? "—")
                .font(.system(size: 20, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(homed ? .primary : .secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(axis.rawValue) axis, \(value.map { String(format: "%.2f millimetres", $0) } ?? "unknown"), "
                          + "\(homed ? "homed" : "not homed")")
    }

    // MARK: - Homing

    private var homingCard: some View {
        Card {
            SectionHeading("Homing", detail: "Drives each axis to its endstop so the printer learns where it is. "
                                           + "Everything else on this screen needs this done first.")

            HStack(spacing: 10) {
                Button {
                    Task { await controller.home() }
                } label: {
                    Label("Home all", systemImage: "house")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                ForEach(PrinterAxis.allCases) { axis in
                    Button(axis.rawValue) {
                        Task { await controller.home([axis]) }
                    }
                    .controlSize(.large)
                    .frame(width: 46)
                    .help("Home only the \(axis.rawValue) axis (G28 \(axis.rawValue)).")
                }
            }
            .disabled(homingBlocked != nil || controller.isBusyWithOperation)

            if let reason = homingBlocked {
                BlockedNote(reason)
            }
        }
    }

    private var homingBlocked: String? { controller.state.homingBlockedReason() }

    // MARK: - Movement

    private var movementCard: some View {
        Card {
            SectionHeading("Movement", detail: "Use the arrows for relative moves, or a corner button to move "
                                             + "30 mm inside that bed corner for levelling.")

            Picker("Step", selection: $step) {
                ForEach(stepChoices, id: \.self) { choice in
                    Text("\(MovePlanner.format(choice)) mm").tag(choice)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(alignment: .top, spacing: 34) {
                jogPad
                zColumn
            }
            .frame(maxWidth: .infinity)
            .disabled(movementBlocked != nil || controller.isBusyWithOperation)

            if let reason = movementBlocked {
                BlockedNote(reason)
            } else {
                Text("Corner buttons move X first to clear the side clips, then Y, and never change Z. "
                   + "The axis arrows are labelled by coordinates: the gantry travels in X and Y while "
                   + "the bed travels in Z.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack {
                Button {
                    Task { await controller.disableMotors() }
                } label: {
                    Label("Turn the motors off", systemImage: "poweroff")
                }
                .disabled(!controller.state.activity.isConnected
                          || controller.state.activity.isJobActive
                          || controller.isBusyWithOperation)
                .help("Releases the steppers (M84) so the axes can be pushed by hand.")

                Spacer()
            }

            Text("With the motors off you can move the gantry and bed by hand — useful for levelling. "
               + "The printer then no longer knows where anything is, so you will need to home again.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var movementBlocked: String? { controller.state.movementBlockedReason() }

    /// The X/Y cross. Up is Y+, right is X+, matching the coordinates in the G-code.
    private var jogPad: some View {
        Grid(horizontalSpacing: 6, verticalSpacing: 6) {
            GridRow {
                bedLevelCornerButton(.rearLeft, symbol: "arrow.up.left")
                jogButton(axis: .y, sign: 1, symbol: "arrow.up")
                bedLevelCornerButton(.rearRight, symbol: "arrow.up.right")
            }
            GridRow {
                jogButton(axis: .x, sign: -1, symbol: "arrow.left")
                Button {
                    Task { await controller.home([.x, .y]) }
                } label: {
                    Image(systemName: "house")
                        .frame(width: 46, height: 46)
                }
                .buttonStyle(.bordered)
                .help("Home X and Y")
                jogButton(axis: .x, sign: 1, symbol: "arrow.right")
            }
            GridRow {
                bedLevelCornerButton(.frontLeft, symbol: "arrow.down.left")
                jogButton(axis: .y, sign: -1, symbol: "arrow.down")
                bedLevelCornerButton(.frontRight, symbol: "arrow.down.right")
            }
        }
    }

    private func bedLevelCornerButton(_ corner: BedLevelCorner, symbol: String) -> some View {
        Button {
            Task { await controller.moveToBedLevelCorner(corner) }
        } label: {
            VStack(spacing: 1) {
                Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
                Text("30").font(.system(size: 9, weight: .medium))
            }
            .frame(width: 46, height: 46)
        }
        .buttonStyle(.bordered)
        .help("Move to the \(corner.displayName) levelling point (X first, then Y; Z unchanged)")
        .accessibilityLabel("Move to \(corner.displayName) levelling point, 30 millimetres inside the corner; Z unchanged")
    }

    private var zColumn: some View {
        VStack(spacing: 6) {
            jogButton(axis: .z, sign: 1, symbol: "arrow.up")
            Text("Z")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(height: 46)
            jogButton(axis: .z, sign: -1, symbol: "arrow.down")
        }
    }

    private func jogButton(axis: PrinterAxis, sign: Double, symbol: String) -> some View {
        let distance = step * sign
        let label = "\(axis.rawValue)\(sign > 0 ? "+" : "−")"

        return Button {
            Task { await controller.jog(axis: axis, millimetres: distance) }
        } label: {
            VStack(spacing: 1) {
                Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
                Text(label).font(.system(size: 9, weight: .medium))
            }
            .frame(width: 46, height: 46)
        }
        .buttonStyle(.bordered)
        .help("Move \(axis.rawValue) by \(MovePlanner.format(distance)) mm")
        .accessibilityLabel("Move \(axis.rawValue) by \(MovePlanner.format(distance)) millimetres")
    }

    // MARK: - Extruder

    private var extruderCard: some View {
        Card {
            SectionHeading("Filament", detail: "Pushes filament through the nozzle, or pulls it back. Use this "
                                             + "to load a new spool or to clear the nozzle before a print.")

            Picker("Amount", selection: $filamentStep) {
                ForEach(filamentChoices, id: \.self) { choice in
                    Text("\(MovePlanner.format(choice)) mm").tag(choice)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(spacing: 10) {
                Button {
                    Task { await controller.extrude(millimetres: -filamentStep) }
                } label: {
                    Label("Retract", systemImage: "arrow.up.to.line")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)

                Button {
                    Task { await controller.extrude(millimetres: filamentStep) }
                } label: {
                    Label("Extrude", systemImage: "arrow.down.to.line")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
            }
            .disabled(extrusionBlocked != nil || controller.isBusyWithOperation)

            if let reason = extrusionBlocked {
                BlockedNote(reason)
            }
        }
    }

    private var extrusionBlocked: String? {
        controller.state.extrusionBlockedReason(profile: controller.profile)
    }
}

// MARK: - Shared pieces for the control screens

/// A titled group of controls.
struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct SectionHeading: View {
    let title: String
    let detail: String

    init(_ title: String, detail: String) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.headline)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Why a control cannot be used. Shown next to the control rather than instead of it,
/// so the user can see what they are missing and what to do about it.
struct BlockedNote: View {
    let reason: String

    init(_ reason: String) { self.reason = reason }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.orange)
            Text(reason)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 2)
    }
}

/// Something Nozzle did differently from what was asked, or a change of circumstance
/// worth noticing. Dismissible, and never an alert — nothing here needs interrupting for.
struct NoticeBanner: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(.orange)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}
