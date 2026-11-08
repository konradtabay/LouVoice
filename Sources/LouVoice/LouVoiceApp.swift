import AppKit
import SwiftUI

@main
struct LouVoiceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    init() { LV.registerFonts() }

    var body: some Scene {
        WindowGroup("LouVoice") {
            ContentView()
                .environment(model)
                .frame(minWidth: 1240, minHeight: 760)  // header: centred tabs + AirPods dot, Help, Settings
                .onAppear { model.start() }
        }
        .windowToolbarStyle(.unified)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare SwiftPM binary; harmless inside the .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
