import AppKit
import SwiftUI

/// `LouVoice --snapshot <dir>`: renders each tab to <dir>/<screen>.png and quits.
/// For checking the UI without Screen Recording permission. Use with LOUVOICE_SOURCE=simulator.
@MainActor
enum Snapshot {
    static var directory: URL? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[i + 1])
    }

    static func render(_ model: AppModel, name: String, to dir: URL) {
        let view = ContentView().environment(model).frame(width: 1280, height: 1240)  // tall: scroll areas render flat here
        let r = ImageRenderer(content: view)
        r.scale = 1
        if let img = r.nsImage, let tiff = img.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: dir.appendingPathComponent("\(name).png"))
        }
    }

    static func run(model: AppModel, to dir: URL) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            for screen in AppModel.Screen.allCases {
                model.screen = screen
                render(model, name: screen.rawValue.lowercased(), to: dir)
            }
            model.showOnboarding = true
            render(model, name: "onboarding", to: dir)
            NSApp.terminate(nil)
        }
    }
}
