import LouVoiceCore
import SwiftUI

struct SensorsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let hub = model.hub
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    MetricTile(title: "Status", value: hub.status == .streaming ? "Streaming" : "Not streaming",
                               detail: hub.status == .streaming ? nil : hub.status.label)
                    MetricTile(title: "Sample rate", value: String(format: "%.1f Hz", hub.sampleRate),
                               detail: "AirPods deliver roughly 25 Hz")
                    MetricTile(title: "Largest recent gap", value: String(format: "%.0f ms", hub.maxRecentGap * 1000),
                               detail: "Takes with gaps over 150 ms are rejected")
                }
                if let s = hub.latest {
                    SectionCard(title: "Rotation rate (rad/s)") {
                        LivePlot(samples: hub.history, channels: [
                            ("x", .red, { $0.rotation.x }), ("y", .green, { $0.rotation.y }), ("z", .blue, { $0.rotation.z }),
                        ], range: 1.0)
                    }
                    SectionCard(title: "User acceleration (g)") {
                        LivePlot(samples: hub.history, channels: [
                            ("x", .red, { $0.accel.x }), ("y", .green, { $0.accel.y }), ("z", .blue, { $0.accel.z }),
                        ], range: 0.1)
                    }
                    SectionCard(title: "Attitude (rad) — nod is pitch, shake is yaw") {
                        LivePlot(samples: hub.history, channels: [
                            ("pitch", .orange, { $0.pitch }), ("yaw", .purple, { $0.yaw }), ("roll", .teal, { $0.roll }),
                        ], range: 0.6)
                    }
                    SectionCard(title: "Earbud orientation") {
                        Text(String(format: "Gravity in sensor frame: (%.2f, %.2f, %.2f). Every capture is rotated so this points straight down, which cancels re-seating (D7).",
                                    s.gravity.x, s.gravity.y, s.gravity.z))
                            .font(.callout)
                        Text("macOS doesn't report which earbud is sending data (that API is iOS-only).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    ContentUnavailableView("No motion yet", systemImage: "airpodspro",
                                           description: Text(hub.status.label))
                }
            }
            .padding(20)
        }
        .navigationTitle("Sensors")
    }
}
