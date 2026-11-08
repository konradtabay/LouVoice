import AppKit
import SwiftUI

/// App shell styled like the landing page header: wordmark left, four tabs centred with an ink
/// underline on the active one, Settings on the right.
struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.devMode { DevModeView() } else { simple }
        }
        .onAppear(perform: applyAppearance)
        .onChange(of: model.devMode) { applyAppearance() }
    }

    /// The simple UI is light-only like the website; dev mode follows the system (light or dark),
    /// exactly as the original app did. Set on NSApp because `.preferredColorScheme` sticks on
    /// macOS after the view that set it goes away.
    private func applyAppearance() {
        NSApp?.appearance = model.devMode ? nil : NSAppearance(named: .aqua)
    }

    private var simple: some View {
        VStack(spacing: 0) {
            Header()
            if model.isSimulated { SimulatorBanner() }
            Group {
                switch model.screen {
                case .signals: SignalsView()
                case .train: TrainView()
                case .speak: SpeakView()
                case .history: HistoryView()
                case .settings: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(PaperBackground())
        .overlay { if model.showOnboarding { OnboardingView() } }
        .foregroundStyle(LV.ink)
        .tint(LV.heart)
    }
}

private struct Header: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 16) {
            // Clicking the logo switches to dev mode (the original UI). TODO(team): hidden on purpose so the patient doesn't hit it.
            Button { model.devMode = true } label: { Wordmark() }
                .buttonStyle(.plain)
                .help("Dev mode")
            // Tabs share the row with the sides (equal flexible space either side), so with four
            // tabs plus Help and Settings they can't run into the AirPods dot.
            Spacer(minLength: 24)
            HStack(spacing: 36) {
                ForEach(AppModel.Screen.tabs) { tab in TabLink(tab: tab) }
            }
            .fixedSize()
            Spacer(minLength: 24)
            LiveIndicator().fixedSize()
            Button { model.showOnboarding = true } label: {
                Label("Help", systemImage: "questionmark.circle").labelStyle(.titleAndIcon)
            }
            .lvButton(.outline)
            .fixedSize()
            .help("Show how LouVoice works")
            Button { open(.settings) } label: {
                Label("Settings", systemImage: "gearshape").labelStyle(.titleAndIcon)
            }
            .lvButton(model.screen == .settings ? .primary : .outline)
            .fixedSize()
            .keyboardShortcut(",", modifiers: .command)
        }
        .padding(.horizontal, 32)
        .frame(height: 84)
        .overlay(alignment: .bottom) { Rectangle().fill(LV.ink).frame(height: 1) }
    }

    private func open(_ screen: AppModel.Screen) {
        model.advancedPage = nil
        model.screen = screen
    }
}

private struct TabLink: View {
    @Environment(AppModel.self) private var model
    var tab: AppModel.Screen

    var body: some View {
        let active = model.screen == tab
        Button {
            model.advancedPage = nil
            model.screen = tab
        } label: {
            Text(tab.rawValue)
                .font(LV.sans(22, active ? .semibold : .regular))
                .foregroundStyle(active ? LV.ink : LV.ink.opacity(0.6))
                .padding(.vertical, 12).padding(.horizontal, 6)
                .frame(height: 84)
                .overlay(alignment: .bottom) { if active { Rectangle().fill(LV.ink).frame(height: 3) } }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// Small, always-visible AirPods status: a pulsing dot while motion is streaming.
/// While connected, clicking it switches what one press says (D49): green = one word,
/// purple = a whole sentence. While not connected, clicking it opens Signals.
struct LiveIndicator: View {
    @Environment(AppModel.self) private var model
    @State private var pulse = false

    var body: some View {
        let live = model.hub.status == .streaming
        let d = model.decoder
        let sentence = d.sentenceMode
        let busy = d.phase == .recording || d.phase == .thinking
        let dot = !live ? LV.warn : sentence ? LV.heart : LV.good
        let mode = sentence ? "Sentence" : "Word"
        Button {
            if live {
                if !busy { d.sentenceMode.toggle() }
            } else {
                model.advancedPage = nil; model.screen = .signals
            }
        } label: {
            HStack(spacing: 8) {
                ZStack {
                    if live {
                        Circle().fill(dot.opacity(0.35)).frame(width: 20, height: 20)
                            .scaleEffect(pulse ? 1 : 0.5).opacity(pulse ? 0 : 1)
                    }
                    Circle().fill(dot).frame(width: 11, height: 11)
                }
                .frame(width: 20, height: 20)
                .animation(.easeOut(duration: 0.2), value: sentence)
                // The dot's colour alone shows the mode: no Word / Sentence text (user request).
                Text(live ? "AirPods on" : "AirPods off").font(LV.sans(16, .semibold))
            }
            .foregroundStyle(LV.ink)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(live ? "Click to switch mode." : "AirPods not connected. Click to check.")
        .accessibilityLabel(live ? "AirPods connected, \(mode.lowercased()) mode" : "AirPods not connected")
        .accessibilityHint(live ? "Switches between word and sentence mode" : "Opens Signals")
        .onAppear {
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true }
        }
    }
}

/// Page heading in the site's display face.
struct PageTitle: View {
    var title: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(LV.display(54)).foregroundStyle(LV.ink)
            if let subtitle {
                Text(subtitle).font(LV.sans(20)).foregroundStyle(LV.ink.opacity(0.8)).frame(maxWidth: 640, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
