import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Nötig, wenn die Binary ohne .app-Bundle (swift run) gestartet wird.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct ClearHubApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("ClearHub", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 860, minHeight: 500)
        }
        .defaultSize(width: 1040, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Scan") {
                Button(model.isScanning ? "Scan abbrechen" : (model.hasScanned ? "Erneut scannen" : "Scannen")) {
                    model.isScanning ? model.cancelScan() : model.startScan()
                }
                .keyboardShortcut("r")
                .disabled(!model.canScan && !model.isScanning)

                Button("Ordner hinzufügen …") { model.addRoots() }
                    .keyboardShortcut("o")
            }
        }
    }
}
