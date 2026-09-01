import SwiftUI
import NozzleCore

@main
struct NozzleApp: App {
    @State private var controller = PrinterController()

    var body: some Scene {
        WindowGroup("Nozzle") {
            RootView()
                .environment(controller)
                .frame(minWidth: 820, minHeight: 600)
                .task {
                    guard controller.autoConnectOnLaunch else { return }
                    await controller.connect()
                }
        }
        .defaultSize(width: 940, height: 700)
        .commands {
            // Nothing belongs in the "New Item" slot: Nozzle has no documents.
            CommandGroup(replacing: .newItem) {}

            // ⌘1–⌘4, the macOS convention for switching views. Modifier-free digits
            // would fight every text field in the window for the same keystrokes.
            CommandGroup(before: .toolbar) {
                ForEach(MainSection.allCases) { item in
                    Button(item.rawValue) { controller.section = item }
                        .keyboardShortcut(item.shortcut, modifiers: .command)
                }
                Divider()
            }

            CommandMenu("Printer") {
                Button(controller.state.activity.isConnected ? "Disconnect" : "Connect") {
                    Task {
                        if controller.state.activity.isConnected {
                            await controller.disconnect()
                        } else {
                            await controller.connect()
                        }
                    }
                }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(!controller.canConnect && !controller.state.activity.isConnected)

                Button("Refresh Ports") { controller.refreshPorts() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
    }
}
