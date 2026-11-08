import SwiftUI

/// "Speak aloud" as a dropdown (D58): Off, the system default, or any output device on this Mac.
/// Off sets `Decoder.speakResult` to false (the AirPods stem still toggles it, D51); choosing a
/// device turns it back on and sets `VoiceService.outputDeviceUID`.
struct SpeakAloudMenu: View {
    @Environment(AppModel.self) private var model
    /// false in Settings, where the row already says "Speak aloud".
    var showsTitle = true
    @State private var devices: [AudioOutputs.Device] = []
    @State private var systemDefault: AudioOutputs.Device?

    var body: some View {
        let d = model.decoder, v = model.voice
        Menu {
            choice("Off", selected: !d.speakResult) { d.speakResult = false }
            Divider()
            choice("System default" + (systemDefault.map { " (\($0.name))" } ?? ""),
                   selected: d.speakResult && v.outputDeviceUID == nil) { select(nil) }
            ForEach(devices) { dev in
                choice(dev.name, selected: d.speakResult && v.outputDeviceUID == dev.uid) { select(dev.uid) }
            }
            Divider()
            Button("Refresh list") { refresh() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: d.speakResult ? "speaker.wave.2.fill" : "speaker.slash.fill")
                if showsTitle { Text("Speak aloud:").font(LV.sans(18, .semibold)) }
                Text(currentName).font(LV.sans(18)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(LV.ink)
            .padding(.horizontal, 16)
            .frame(height: 48)
            .background(LV.card)
            .overlay(Rectangle().strokeBorder(LV.ink, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Where your words are spoken. Off: shown on screen only. The AirPod stem also turns it on and off.")
        .onAppear(perform: refresh)
    }

    private var currentName: String {
        let d = model.decoder, v = model.voice
        guard d.speakResult else { return "Off" }
        guard let uid = v.outputDeviceUID else { return "System default" }
        if let dev = devices.first(where: { $0.uid == uid }) { return dev.name }
        return "System default (device not connected)"
    }

    private func select(_ uid: String?) {
        model.voice.outputDeviceUID = uid
        model.decoder.speakResult = true
    }

    private func refresh() {
        devices = AudioOutputs.list()
        systemDefault = AudioOutputs.systemDefault()
    }

    @ViewBuilder private func choice(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if selected { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }
}
