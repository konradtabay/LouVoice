import Foundation
import LouVoiceCore

/// JSON in ~/Library/Application Support/LouVoice/. Separate files per source so simulated
/// takes can never pollute real AirPods data.
enum DatasetStore {
    static var directory: URL {
        // LOUVOICE_DATA_DIR overrides the location (used by the --smoke run).
        let dir = ProcessInfo.processInfo.environment["LOUVOICE_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL.applicationSupportDirectory.appending(path: "LouVoice", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func url(simulated: Bool) -> URL {
        directory.appending(path: simulated ? "dataset-simulated.json" : "dataset.json")
    }

    static func load(simulated: Bool) -> Dataset {
        guard let data = try? Data(contentsOf: url(simulated: simulated)),
              let dataset = try? JSONDecoder().decode(Dataset.self, from: data) else { return .empty }
        return dataset
    }

    static func save(_ dataset: Dataset, simulated: Bool) {
        let url = url(simulated: simulated)
        Task.detached(priority: .utility) {
            do {
                try JSONEncoder().encode(dataset).write(to: url, options: .atomic)
            } catch {
                print("LouVoice: failed to save dataset: \(error)")
            }
        }
    }
}
