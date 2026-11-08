import SwiftUI

/// "Speak aloud" as a dropdown (D58): Off, the system default, or any output device on this Mac.
/// Off sets `Decoder.speakResult` to false (the AirPods stem still toggles it, D51); choosing a
/// device turns it back on and sets `VoiceService.outputDeviceUID`.
///
/// Drawn by hand rather than with a system `Menu`, so the open list matches the site: pearl
/// paper, ink hairline, heart-purple offset shadow, square corners (D59). The parent should give
/// the row a `zIndex` so the open list draws over what's below it.
struct SpeakAloudMenu: View {
    @Environment(AppModel.self) private var model
    /// false in Settings, where the row already says "Speak aloud".
    var showsTitle = true
    @State private var open = false
    @State private var devices: [AudioOutputs.Device] = []
    @State private var systemDefault: AudioOutputs.Device?

    static let listWidth: CGFloat = 320

    var body: some View {
        let d = model.decoder
        Button {
            if !open { refresh() }
            open.toggle()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: d.speakResult ? "speaker.wave.2.fill" : "speaker.slash.fill")
                if showsTitle { Text("Speak aloud:").font(LV.sans(18, .semibold)) }
                Text(currentName).font(LV.sans(18)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 12, weight: .semibold))
                    .rotationEffect(.degrees(open ? 180 : 0))
            }
            .foregroundStyle(open ? LV.pearl : LV.ink)
            .padding(.horizontal, 16)
            .frame(height: 48)
            .background(open ? LV.ink : LV.card)
            .overlay(Rectangle().strokeBorder(LV.ink, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Where your words are spoken. Off: shown on screen only. The AirPod stem also turns it on and off.")
        .overlay {
            // Click anywhere else to close: a large invisible layer behind the list.
            if open {
                Color.clear
                    .frame(width: 5000, height: 5000)
                    .contentShape(Rectangle())
                    .onTapGesture { open = false }
            }
        }
        .overlay(alignment: .topTrailing) {
            if open {
                list
                    .offset(y: 48 + 8)
                    .transition(.opacity.combined(with: .offset(y: -4)))
            }
        }
        .animation(.easeOut(duration: 0.12), value: open)
        .onExitCommand { open = false }
        .onAppear(perform: refresh)
    }

    private var list: some View {
        let d = model.decoder, v = model.voice
        return VStack(alignment: .leading, spacing: 0) {
            Eyebrow(text: "Speak my words on").padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 6)
            Row(title: "Off", detail: "Show on screen only", icon: "speaker.slash", selected: !d.speakResult) {
                d.speakResult = false; open = false
            }
            Rule()
            Row(title: "System default", detail: systemDefault?.name, icon: "macbook",
                selected: d.speakResult && v.outputDeviceUID == nil) { select(nil) }
            ForEach(devices) { dev in
                Row(title: dev.name, detail: nil, icon: Self.icon(for: dev.name),
                    selected: d.speakResult && v.outputDeviceUID == dev.uid) { select(dev.uid) }
            }
            Rule()
            Row(title: "Refresh list", detail: nil, icon: "arrow.clockwise", selected: false, muted: true) { refresh() }
                .padding(.bottom, 6)
        }
        .frame(width: Self.listWidth, alignment: .leading)
        .background(LV.pearl)
        .overlay(Rectangle().strokeBorder(LV.ink, lineWidth: 1))
        .background(Rectangle().fill(LV.heart).offset(x: 5, y: 5))   // the site's offset shadow
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
        open = false
    }

    private func refresh() {
        devices = AudioOutputs.list()
        systemDefault = AudioOutputs.systemDefault()
    }

    static func icon(for name: String) -> String {
        let n = name.lowercased()
        if n.contains("airpods") { return "airpodspro" }
        if n.contains("headphone") || n.contains("beats") { return "headphones" }
        if n.contains("display") || n.contains("monitor") || n.contains("tv") { return "display" }
        if n.contains("macbook") || n.contains("speaker") { return "speaker.wave.2" }
        return "hifispeaker"
    }
}

/// One choice in the list: icon, name, optional detail, a heart-purple tick when selected,
/// and a faint ink wash on hover.
private struct Row: View {
    var title: String
    var detail: String?
    var icon: String
    var selected: Bool
    var muted = false
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).frame(width: 22).foregroundStyle(muted ? LV.muted : LV.ink)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(LV.sans(17, selected ? .semibold : .regular))
                        .foregroundStyle(muted ? LV.muted : LV.ink).lineLimit(1)
                    if let detail { Text(detail).font(LV.sans(14)).foregroundStyle(LV.muted).lineLimit(1) }
                }
                Spacer(minLength: 8)
                if selected {
                    Image(systemName: "checkmark").font(.system(size: 14, weight: .bold)).foregroundStyle(LV.heart)
                }
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .background(hover ? LV.ink.opacity(0.06) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

private struct Rule: View {
    var body: some View { Rectangle().fill(LV.ink.opacity(0.15)).frame(height: 1).padding(.vertical, 4) }
}
