import SwiftUI

/// Colours and small building blocks shared by every screen.
enum Theme {
    /// The page background that hero artwork fades into.
    static let base = Color(red: 0.055, green: 0.065, blue: 0.09)
    static let glass = Color.white.opacity(0.12)
    static let glassStrong = Color.white.opacity(0.2)
    static let ink = Color(red: 0.08, green: 0.08, blue: 0.1)
    static let live = Color(red: 1, green: 0.3, blue: 0.3)
    /// Text of rows that delete something, on glass.
    static let danger = Color(red: 1, green: 0.54, blue: 0.54)
    /// The same rows while focused (white background).
    static let dangerInk = Color(red: 0.75, green: 0.1, blue: 0.1)
    /// Status dots.
    static let good = Color(red: 0.29, green: 0.87, blue: 0.5)
    static let warning = Color(red: 1, green: 0.75, blue: 0.3)
}

extension Color {
    /// A colour from a hex string such as "da020e" or "#DA020E".
    init?(hex: String?) {
        guard var text = hex?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }
}

/// The soft, frosted backdrop behind Live TV, Sports, Calendar, Search and Settings.
struct AppBackground: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        ZStack {
            switch settings.prefs.backgroundStyle {
            case .frosted:
                Color(red: 0.2, green: 0.24, blue: 0.31)
                RadialGradient(colors: [Color(red: 0.62, green: 0.5, blue: 0.45).opacity(0.55), .clear],
                               center: UnitPoint(x: 0.72, y: 0.3), startRadius: 0, endRadius: 900)
                RadialGradient(colors: [Color(red: 0.35, green: 0.5, blue: 0.7).opacity(0.6), .clear],
                               center: UnitPoint(x: 0.1, y: 0.15), startRadius: 0, endRadius: 800)
                RadialGradient(colors: [Color(red: 0.55, green: 0.4, blue: 0.55).opacity(0.4), .clear],
                               center: UnitPoint(x: 0.45, y: 0.95), startRadius: 0, endRadius: 800)
                LinearGradient(colors: [.clear, Theme.base.opacity(0.5)], startPoint: .top, endPoint: .bottom)
            case .dark:
                Theme.base
            case .black:
                Color.black
            case .ocean:
                Glows(base: (18, 40, 58), glows: [((40, 170, 180), 0.45, 0.75, 0.25), ((40, 90, 200), 0.55, 0.1, 0.2),
                                                  ((60, 140, 160), 0.35, 0.5, 0.95)])
            case .sunset:
                Glows(base: (46, 31, 42), glows: [((230, 120, 70), 0.45, 0.75, 0.25), ((200, 70, 120), 0.45, 0.1, 0.2),
                                                  ((110, 60, 140), 0.4, 0.5, 0.95)])
            case .forest:
                Glows(base: (24, 38, 31), glows: [((90, 140, 80), 0.45, 0.75, 0.25), ((40, 110, 100), 0.5, 0.1, 0.2),
                                                  ((120, 120, 60), 0.3, 0.5, 0.95)])
            case .aurora:
                Glows(base: (16, 24, 40), glows: [((60, 200, 150), 0.35, 0.7, 0.2), ((130, 80, 200), 0.45, 0.15, 0.3),
                                                  ((40, 90, 180), 0.4, 0.5, 0.95)])
            case .rose:
                Glows(base: (43, 32, 38), glows: [((220, 150, 160), 0.4, 0.72, 0.28), ((170, 120, 170), 0.4, 0.12, 0.18),
                                                  ((230, 180, 150), 0.3, 0.48, 0.95)])
            }
        }
        .ignoresSafeArea()
    }
}

/// A soft background like Frosted: coloured glows over a dark base, darker towards the bottom.
private struct Glows: View {
    typealias RGB = (Double, Double, Double)
    let base: RGB
    /// Colour, strength and centre (x, y from 0 to 1).
    let glows: [(RGB, Double, Double, Double)]

    private static func color(_ rgb: RGB) -> Color {
        Color(red: rgb.0 / 255, green: rgb.1 / 255, blue: rgb.2 / 255)
    }

    var body: some View {
        ZStack {
            Self.color(base)
            ForEach(glows.indices, id: \.self) { index in
                let glow = glows[index]
                RadialGradient(colors: [Self.color(glow.0).opacity(glow.1), .clear],
                               center: UnitPoint(x: glow.2, y: glow.3), startRadius: 0, endRadius: 850)
            }
            LinearGradient(colors: [.clear, Theme.base.opacity(0.5)], startPoint: .top, endPoint: .bottom)
        }
    }
}

/// A button style with no system chrome: the label draws its own focus state.
struct PlainPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.75 : 1)
    }
}

/// Wraps card artwork: white outline, lift and shadow while focused.
struct FocusFrame<Content: View>: View {
    let cornerRadius: CGFloat
    let content: Content
    @Environment(\.isFocused) private var isFocused

    init(cornerRadius: CGFloat = 18, @ViewBuilder content: () -> Content) {
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    var body: some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white, lineWidth: isFocused ? 5 : 0)
            )
            .scaleEffect(isFocused ? 1.06 : 1)
            .shadow(color: .black.opacity(isFocused ? 0.5 : 0), radius: 20, y: 12)
            .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}

/// A small rounded tag ("4K", "Drama", "★ 8.4").
struct Chip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 20, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Theme.glassStrong, in: Capsule())
    }
}

/// A rounded pill button label that turns white while focused.
struct PillLabel: View {
    let title: String
    var icon: String? = nil
    var selected = false
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        HStack(spacing: 12) {
            if let icon {
                Image(systemName: icon).font(.system(size: 24, weight: .semibold))
            }
            Text(title).font(.system(size: 24, weight: .semibold)).lineLimit(1)
        }
        .foregroundStyle(isFocused ? Theme.ink : Color.white)
        .padding(.horizontal, 26)
        .padding(.vertical, 14)
        .background(
            Capsule().fill(isFocused ? Color.white : (selected ? Theme.glassStrong : Theme.glass))
        )
        .scaleEffect(isFocused ? 1.04 : 1)
        .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}

/// A glass card that groups rows, with an optional small uppercase header.
struct GlassPanel<Content: View>: View {
    let title: String?
    let content: Content

    init(_ title: LocalizedStringResource, @ViewBuilder content: () -> Content) {
        self.init(String(localized: title), content: content)
    }

    @_disfavoredOverload
    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title {
                Text(title.uppercased())
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white.opacity(0.62))
                    .padding(.horizontal, 22)
                    .padding(.bottom, 6)
            }
            content
        }
        .padding(.horizontal, 12)
        .padding(.top, 18)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 34, style: .continuous).fill(Theme.glass))
        .overlay(RoundedRectangle(cornerRadius: 34, style: .continuous).stroke(.white.opacity(0.08), lineWidth: 1))
    }
}

/// A list row inside a glass panel: optional icon or logo, title, subtitle and
/// a trailing note. The whole row turns white while focused.
struct ListRowLabel: View {
    let title: String
    var subtitle: String? = nil
    var icon: String? = nil
    var logoURL: URL? = nil
    var showsLogo = false
    var trailing: String? = nil
    var trailingIcon: String? = nil
    var selected = false
    var dimmed = false
    /// Red text, for rows that delete something.
    var destructive = false
    /// Draws the focused look even when focus sits on something on top (a typing row's field).
    var highlighted = false
    @Environment(\.isFocused) private var environmentFocused
    private var isFocused: Bool { environmentFocused || highlighted }

    private var restingColor: Color {
        if destructive { return Theme.danger }
        return Color.white.opacity(dimmed ? 0.55 : 1)
    }

    var body: some View {
        HStack(spacing: 18) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 26, weight: .semibold))
                    .frame(width: 36)
            }
            if showsLogo {
                AsyncImage(url: logoURL) { image in
                    image.resizable().aspectRatio(contentMode: .fit)
                } placeholder: {
                    RoundedRectangle(cornerRadius: 6).fill(Theme.glassStrong)
                }
                .frame(width: 70, height: 42)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 26, weight: .semibold))
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 20, weight: .medium))
                        .opacity(0.7)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 22, weight: .medium))
                    .opacity(0.7)
                    .lineLimit(1)
            }
            if let trailingIcon {
                Image(systemName: trailingIcon).font(.system(size: 24, weight: .semibold))
            }
        }
        .foregroundStyle(isFocused ? (destructive ? Theme.dangerInk : Theme.ink) : restingColor)
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(isFocused ? Color.white : (selected ? Theme.glassStrong : Color.clear))
        )
        .animation(.easeOut(duration: 0.12), value: isFocused)
    }
}

/// A thin progress bar.
struct ThinProgress: View {
    let fraction: Double
    var tint: Color = .white

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(tint.opacity(0.25))
                Capsule().fill(tint).frame(width: geo.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 8)
    }
}

/// A row you type into: selecting it opens the tvOS keyboard straight away (no pop-up first),
/// with the row's title at the top of the keyboard screen. Saved when you press Done.
struct TypingRow: View {
    let title: String
    var subtitle: String? = nil
    let icon: String
    /// What the row shows on the right (e.g. "Not set", a masked password).
    let value: String
    let initial: String
    var secure = false
    var autocapitalize = false
    var allowsEmpty = false
    let onSave: (String) -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    private var cleaned: String { secure ? text : text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        ListRowLabel(title: title, subtitle: subtitle, icon: icon, trailing: value, highlighted: focused)
            // The real field sits on top, almost invisible and exactly the row's size: selecting
            // the row selects it, which opens the keyboard. Its prompt is the keyboard's title.
            .overlay {
            Group {
                if secure {
                    SecureField(title, text: $text)
                } else {
                    TextField(title, text: $text)
                        .textInputAutocapitalization(autocapitalize ? .words : .never)
                }
            }
            .autocorrectionDisabled(!autocapitalize)
            .focused($focused)
            .opacity(0.02)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        .onAppear { text = initial }
        .onChange(of: initial) { _, value in
            if !focused { text = value }
        }
        .onSubmit {
            guard allowsEmpty || !cleaned.isEmpty else { text = initial; return }
            if cleaned != initial { onSave(cleaned) }
        }
    }
}

/// A sheet that asks for one line of text: a folder name, a server, a password…
struct NameSheet: View {
    let title: String
    let placeholder: String
    let secure: Bool
    let allowsEmpty: Bool
    let autocapitalize: Bool
    let onSave: (String) -> Void
    @State private var text: String
    @Environment(\.dismiss) private var dismiss

    init(title: String, initial: String = "", placeholder: String = String(localized: "Name"), secure: Bool = false,
         allowsEmpty: Bool = false, autocapitalize: Bool = true, onSave: @escaping (String) -> Void) {
        self.title = title
        self.placeholder = placeholder
        self.secure = secure
        self.allowsEmpty = allowsEmpty
        self.autocapitalize = autocapitalize
        self.onSave = onSave
        self._text = State(initialValue: initial)
    }

    /// Passwords are kept exactly as typed; everything else loses stray spaces.
    private var value: String { secure ? text : text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(spacing: 40) {
            Text(title).font(.title2).bold()
            Group {
                if secure {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                        .textInputAutocapitalization(autocapitalize ? .words : .never)
                }
            }
            .autocorrectionDisabled(!autocapitalize)
            .frame(maxWidth: 900)
            HStack(spacing: 40) {
                Button("Save") {
                    onSave(value)
                    dismiss()
                }
                .disabled(!allowsEmpty && value.isEmpty)
                Button("Cancel", role: .cancel) { dismiss() }
            }
        }
        .padding(80)
    }
}

/// Lays its children out in rows, wrapping to a new row when one is full
/// (filter buttons that don't fit on one line).
struct FlowLayout: Layout {
    var spacing: CGFloat = 12
    var rowSpacing: CGFloat = 12

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                y += rowHeight + rowSpacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                y += rowHeight + rowSpacing
                x = bounds.minX
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// The white tick on watched posters and episodes.
struct WatchedTick: View {
    var size: CGFloat = 40

    var body: some View {
        Image(systemName: "checkmark")
            .font(.system(size: size * 0.5, weight: .heavy))
            .foregroundStyle(Theme.ink)
            .frame(width: size, height: size)
            .background(Circle().fill(Color.white))
            .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
    }
}

/// How far into a movie or episode playback got, along the bottom of its artwork.
struct ProgressStrip: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.3))
                Capsule().fill(Color.white)
                    .frame(width: geo.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 7)
    }
}

extension View {
    /// Makes this row a full-width target for the remote: pressing up/down (or left/right)
    /// lands in it even when nothing sits directly in line with the focused item.
    func focusRow() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .focusSection()
    }
}
