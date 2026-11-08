import AppKit
import CoreText
import SwiftUI

/// The landing page's design language (website/src/index.css + fonts.css) as SwiftUI.
/// Pearl paper, ink hairlines, square corners, ink buttons with a heart-purple offset shadow,
/// Geist Serif Square for display type, Geist Sans for everything else.
/// Component shapes follow the Radix/shadcn primitives the site uses (Button, Card, Tabs, Switch).
enum LV {
    // Palette (index.css @theme).
    static let ink = Color(hex: 0x010101)
    static let pearl = Color(hex: 0xE6DDD6)
    static let schooner = Color(hex: 0x918983)
    static let quincy = Color(hex: 0x5B3629)
    static let heart = Color(hex: 0x682BD7)
    static let heartDark = Color(hex: 0x3D1689)
    static let portage = Color(hex: 0xA37CF0)
    static let violet = Color(hex: 0xBD2E95)
    static let muted = Color(hex: 0x5D5753)
    static let card = Color.white.opacity(0.55)
    // Status colours, kept earthy so they sit on pearl. TODO(team): not on the site; picked to match.
    static let good = Color(hex: 0x2F7A3E)
    static let warn = Color(hex: 0xB0611A)
    static let bad = Color(hex: 0xB3261E)

    // Type. Sizes are larger than the site's: the app is for an older user, read at arm's length.
    static func display(_ size: CGFloat) -> Font { .custom("GeistSerif-Square", size: size) }
    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom("Geist", size: size).weight(weight)
    }
    static let body = sans(19)
    static let small = sans(16)

    /// Registers the bundled Geist fonts. Looks in the .app's Resources, then ./Resources/Fonts for `swift run`.
    static func registerFonts() {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("Fonts"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/Fonts"),
        ].compactMap { $0 }
        guard let dir = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for url in files where ["ttf", "otf", "woff2"].contains(url.pathExtension.lowercased()) {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}

// MARK: Paper

/// The site's `.paper` background: pearl with a faint fractal grain.
struct PaperBackground: View {
    private static let grain: NSImage = {
        let size = 220
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        var rng = SystemRandomNumberGenerator()
        for y in 0..<size { for x in 0..<size {
            let a = Double.random(in: 0...1, using: &rng)
            rep.setColor(NSColor(srgbRed: 0.25, green: 0.22, blue: 0.2, alpha: a > 0.82 ? (a - 0.82) * 0.5 : 0), atX: x, y: y)
        } }
        let img = NSImage(size: NSSize(width: size, height: size))
        img.addRepresentation(rep)
        return img
    }()

    var body: some View {
        LV.pearl.overlay(Image(nsImage: Self.grain).resizable(resizingMode: .tile)).ignoresSafeArea()
    }
}

/// The site's `.hatch`: diagonal ink stripes.
struct Hatch: View {
    var spacing: CGFloat = 8
    var line: CGFloat = 2.5
    var body: some View {
        Canvas { ctx, size in
            var p = Path()
            var x = -size.height
            while x < size.width + size.height {
                p.move(to: CGPoint(x: x, y: size.height)); p.addLine(to: CGPoint(x: x + size.height * 0.62, y: 0))
                x += spacing
            }
            ctx.stroke(p, with: .color(LV.ink), lineWidth: line)
        }
        .clipped()
    }
}

/// LouVoice mark from LogoMark.tsx: the jawline turning into a sound wave.
struct LogoMark: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 62, sy = rect.height / 45
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + (x - 1.5) * sx, y: rect.minY + (y - 9.5) * sy) }
        var path = Path()
        path.move(to: p(6, 14))
        path.addCurve(to: p(26, 50), control1: p(6, 40), control2: p(14, 50))
        path.addCurve(to: p(42, 32), control1: p(34, 50), control2: p(36, 32))
        path.addCurve(to: p(52, 44), control1: p(48, 32), control2: p(48, 44))
        path.addCurve(to: p(59, 36), control1: p(56, 44), control2: p(57, 36))
        return path
    }
}

struct Wordmark: View {
    var body: some View {
        HStack(spacing: 10) {
            LogoMark().stroke(LV.heartDark, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                .frame(width: 40, height: 29)
            Text("LouVoice").font(LV.display(28)).foregroundStyle(LV.ink)
        }
        .accessibilityElement(children: .ignore).accessibilityLabel("LouVoice")
    }
}

// MARK: Button (shadcn Button: default / outline / ghost / destructive)

struct LVButtonStyle: ButtonStyle {
    enum Kind { case primary, outline, ghost, danger }
    enum Size { case regular, large, huge }
    var kind: Kind = .primary
    var size: Size = .regular
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let (height, font, pad): (CGFloat, Font, CGFloat) = switch size {
        case .regular: (48, LV.sans(18, .semibold), 20)
        case .large: (64, LV.sans(21, .semibold), 30)
        case .huge: (88, LV.sans(28, .semibold), 44)
        }
        let pressed = configuration.isPressed
        let shadow: CGFloat = kind == .primary ? (size == .regular ? 4 : 6) : 0
        return configuration.label
            .font(font)
            .lineLimit(1)
            .padding(.horizontal, pad)
            .frame(minHeight: height)
            .foregroundStyle(fg)
            .background(bg(pressed))
            .overlay(Rectangle().strokeBorder(border, lineWidth: kind == .ghost ? 0 : 1.5))
            .background { if kind == .primary { LV.heart.offset(x: pressed ? 1 : shadow, y: pressed ? 1 : shadow) } }
            .offset(x: pressed ? shadow - 1 : 0, y: pressed ? shadow - 1 : 0)
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.08), value: pressed)
    }

    private var fg: Color {
        switch kind { case .primary: LV.pearl; case .outline, .ghost: LV.ink; case .danger: LV.bad }
    }
    private func bg(_ pressed: Bool) -> Color {
        switch kind {
        case .primary: pressed ? LV.heartDark : LV.ink
        case .outline: pressed ? LV.ink.opacity(0.08) : LV.pearl
        case .ghost: pressed ? LV.ink.opacity(0.08) : .clear
        case .danger: pressed ? LV.bad.opacity(0.18) : LV.bad.opacity(0.08)
        }
    }
    private var border: Color {
        switch kind { case .primary, .outline: LV.ink; case .ghost: .clear; case .danger: LV.bad }
    }
}

extension View {
    func lvButton(_ kind: LVButtonStyle.Kind = .primary, _ size: LVButtonStyle.Size = .regular) -> some View {
        buttonStyle(LVButtonStyle(kind: kind, size: size))
    }
}

// MARK: Scroll

/// ScrollView, except in `--snapshot` mode, where ImageRenderer can't draw scroll contents.
struct LVScroll<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        if Snapshot.directory != nil { VStack(spacing: 0) { content; Spacer(minLength: 0) } } else { ScrollView { content } }
    }
}

// MARK: Card

/// Square card with an ink hairline, like the site's step panels.
struct LVCard<Content: View>: View {
    var title: String? = nil
    var subtitle: String? = nil
    var padding: CGFloat = 24
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let title {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(LV.display(30)).foregroundStyle(LV.ink)
                    if let subtitle { Text(subtitle).font(LV.small).foregroundStyle(LV.muted) }
                }
            }
            content
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LV.card)
        .overlay(Rectangle().strokeBorder(LV.ink, lineWidth: 1))
    }
}

// MARK: Switch (Radix Switch, square)

struct LVToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(alignment: .center, spacing: 16) {
                configuration.label.font(LV.body).foregroundStyle(LV.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Rectangle().fill(configuration.isOn ? LV.heart : LV.pearl)
                        .overlay(Rectangle().strokeBorder(LV.ink, lineWidth: 1.5))
                    Rectangle().fill(configuration.isOn ? LV.pearl : LV.ink)
                        .frame(width: 22, height: 22).padding(5)
                }
                .frame(width: 64, height: 32)
                .animation(.easeOut(duration: 0.12), value: configuration.isOn)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}

// MARK: Segmented choice (Radix ToggleGroup)

struct LVChoice<T: Hashable>: View {
    var options: [(T, String)]
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options.indices, id: \.self) { i in
                let (value, label) = options[i]
                let on = selection == value
                Button { selection = value } label: {
                    Text(label).font(LV.sans(18, on ? .semibold : .regular))
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .foregroundStyle(on ? LV.pearl : LV.ink)
                        .background(on ? LV.ink : Color.clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if i < options.count - 1 { Rectangle().fill(LV.ink).frame(width: 1) }
            }
        }
        .overlay(Rectangle().strokeBorder(LV.ink, lineWidth: 1.5))
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: Stepper row

struct LVStepper: View {
    var label: String
    @Binding var value: Int
    var range: ClosedRange<Int>

    var body: some View {
        HStack(spacing: 16) {
            Text(label).font(LV.body).foregroundStyle(LV.ink).frame(maxWidth: .infinity, alignment: .leading)
            Button { value = max(range.lowerBound, value - 1) } label: { Image(systemName: "minus").frame(width: 20) }
                .lvButton(.outline).disabled(value <= range.lowerBound).accessibilityLabel("Less")
            Text("\(value)").font(LV.display(32)).monospacedDigit().frame(minWidth: 40)
            Button { value = min(range.upperBound, value + 1) } label: { Image(systemName: "plus").frame(width: 20) }
                .lvButton(.outline).disabled(value >= range.upperBound).accessibilityLabel("More")
        }
    }
}

// MARK: Text field

struct LVTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .font(LV.body)
            .padding(.horizontal, 14)
            .frame(minHeight: 48)
            .background(Color.white.opacity(0.7))
            .overlay(Rectangle().strokeBorder(LV.ink, lineWidth: 1.5))
    }
}

// MARK: Status

struct StatusBadge: View {
    enum Tone { case good, warn, bad, neutral }
    var tone: Tone
    var text: String

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(color).frame(width: 12, height: 12)
            Text(text).font(LV.sans(17, .semibold)).foregroundStyle(LV.ink)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .overlay(Rectangle().strokeBorder(LV.ink, lineWidth: 1))
    }

    private var color: Color {
        switch tone { case .good: LV.good; case .warn: LV.warn; case .bad: LV.bad; case .neutral: LV.schooner }
    }
}

/// Section label like the site's "01 / Train" eyebrow.
struct Eyebrow: View {
    var text: String
    var body: some View {
        Text(text.uppercased()).font(LV.sans(14, .semibold)).tracking(1.4).foregroundStyle(LV.muted)
    }
}
