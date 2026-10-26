import Foundation

/// A separate set of notes ("Personal", "Acme Corp"…) with its own folder and theme.
public struct Profile: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var theme: ProfileTheme
    /// Position in the profile list.
    public var order: Int
    public var created: Date
    /// The profile's folder in the notes container. Normally its name; not saved in the file.
    public var folderName: String

    public init(id: UUID = UUID(), name: String, theme: ProfileTheme, order: Int, created: Date = Date(), folderName: String) {
        self.id = id
        self.name = name
        self.theme = theme
        self.order = order
        self.created = created
        self.folderName = folderName
    }

    /// The first letter, for the profile's badge.
    public var initial: String {
        name.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() } ?? "?"
    }
}

extension Profile {
    /// What `.inkwell-profile.json` holds.
    struct Metadata: Codable {
        var id: UUID
        var name: String
        var theme: ProfileTheme
        var order: Int
        var created: Date
    }

    var metadata: Metadata {
        Metadata(id: id, name: name, theme: theme, order: order, created: created)
    }

    init(metadata: Metadata, folderName: String) {
        self.init(id: metadata.id, name: metadata.name, theme: metadata.theme, order: metadata.order,
                  created: metadata.created, folderName: folderName)
    }
}

/// A profile's colours: an accent, and whether it also tints the backgrounds.
public struct ProfileTheme: Codable, Hashable, Sendable {
    /// 0xRRGGBB.
    public var accent: UInt32
    /// Mix a little of the accent into the background, sidebar and cards, so the whole window
    /// takes on the profile's colour.
    public var tintsBackground: Bool

    public init(accent: UInt32, tintsBackground: Bool = true) {
        self.accent = accent & 0xFFFFFF
        self.tintsBackground = tintsBackground
    }

    /// Claude Code's coral on its warm neutrals: the original Inkwell look.
    public static let claude = ProfileTheme(accent: 0xD97757, tintsBackground: false)

    public struct Preset: Identifiable, Sendable {
        public var name: String
        public var theme: ProfileTheme
        public var id: String { name }
    }

    public static let presets: [Preset] = [
        Preset(name: "Claude", theme: .claude),
        Preset(name: "Ocean", theme: ProfileTheme(accent: 0x3B7FC4)),
        Preset(name: "Teal", theme: ProfileTheme(accent: 0x23968A)),
        Preset(name: "Forest", theme: ProfileTheme(accent: 0x4F8A4B)),
        Preset(name: "Amber", theme: ProfileTheme(accent: 0xD9931E)),
        Preset(name: "Rose", theme: ProfileTheme(accent: 0xD0507A)),
        Preset(name: "Plum", theme: ProfileTheme(accent: 0x8E5BB5)),
        Preset(name: "Graphite", theme: ProfileTheme(accent: 0x6E7480)),
    ]

    /// The preset this theme matches, if any.
    public var presetName: String? {
        Self.presets.first { $0.theme == self }?.name
    }

    // Saved as "#RRGGBB" so the file is easy to read and edit by hand.
    enum CodingKeys: String, CodingKey {
        case accent, tintsBackground
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let hex = try container.decode(String.self, forKey: .accent)
        guard let value = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) else {
            throw DecodingError.dataCorruptedError(forKey: .accent, in: container, debugDescription: "Not a colour: \(hex)")
        }
        self.init(accent: value, tintsBackground: try container.decodeIfPresent(Bool.self, forKey: .tintsBackground) ?? true)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(String(format: "#%06X", accent), forKey: .accent)
        try container.encode(tintsBackground, forKey: .tintsBackground)
    }
}

/// Every colour the UI uses, worked out from a `ProfileTheme` for light and dark mode.
/// Text colours stay neutral; the accent and (optionally) the surfaces follow the profile.
public struct ThemeColors: Equatable, Sendable {
    public struct Pair: Equatable, Sendable {
        public var light: UInt32
        public var dark: UInt32

        public init(light: UInt32, dark: UInt32) {
            self.light = light
            self.dark = dark
        }
    }

    public var accent: Pair
    /// The accent where it colours text (links, tags, code), with enough contrast to read.
    public var accentText: Pair
    public var background: Pair
    public var sidebar: Pair
    public var card: Pair
    public var codeBackground: Pair
    /// A selected list row on iPhone and iPad, under white text.
    public var selectedRow: Pair

    public init(_ theme: ProfileTheme) {
        if theme == .claude {
            self = .claude
            return
        }
        let accent = theme.accent
        // On dark backgrounds a deep accent needs lifting to stay visible.
        let darkAccent = Self.adjusted(accent, toward: 0xFFFFFF, against: 0x262624, ratio: 3)
        self.accent = Pair(light: accent, dark: darkAccent)
        accentText = Pair(light: Self.adjusted(accent, toward: 0x000000, against: 0xFAF9F5, ratio: 4.5),
                          dark: Self.adjusted(darkAccent, toward: 0xFFFFFF, against: 0x262624, ratio: 4.5))
        let tint = theme.tintsBackground
        func surface(_ light: UInt32, _ lightAmount: Double, _ dark: UInt32, _ darkAmount: Double) -> Pair {
            Pair(light: tint ? Self.mix(light, accent, lightAmount) : light,
                 dark: tint ? Self.mix(dark, darkAccent, darkAmount) : dark)
        }
        background = surface(0xFAF9F5, 0.035, 0x262624, 0.06)
        sidebar = surface(0xF0EEE6, 0.08, 0x1F1E1D, 0.08)
        card = surface(0xFFFFFF, 0.02, 0x2E2E2B, 0.06)
        codeBackground = surface(0xF0EEE6, 0.05, 0x30302E, 0.06)
        selectedRow = Pair(light: Self.adjusted(Self.mix(accent, 0x000000, 0.06), toward: 0x000000, against: 0xFFFFFF, ratio: 3),
                           dark: Self.adjusted(Self.mix(darkAccent, 0x000000, 0.18), toward: 0x000000, against: 0xFFFFFF, ratio: 3))
    }

    /// The hand-tuned original palette.
    static let claude = ThemeColors(
        accent: Pair(light: 0xD97757, dark: 0xD97757),
        accentText: Pair(light: 0xB9552F, dark: 0xE89276),
        background: Pair(light: 0xFAF9F5, dark: 0x262624),
        sidebar: Pair(light: 0xF0EEE6, dark: 0x1F1E1D),
        card: Pair(light: 0xFFFFFF, dark: 0x2E2E2B),
        codeBackground: Pair(light: 0xF0EEE6, dark: 0x30302E),
        selectedRow: Pair(light: 0xC96442, dark: 0xB85A3C)
    )

    private init(accent: Pair, accentText: Pair, background: Pair, sidebar: Pair, card: Pair, codeBackground: Pair, selectedRow: Pair) {
        self.accent = accent
        self.accentText = accentText
        self.background = background
        self.sidebar = sidebar
        self.card = card
        self.codeBackground = codeBackground
        self.selectedRow = selectedRow
    }

    // MARK: Colour maths (sRGB)

    /// `a` moved `amount` (0…1) of the way to `b`.
    public static func mix(_ a: UInt32, _ b: UInt32, _ amount: Double) -> UInt32 {
        func channel(_ shift: UInt32) -> UInt32 {
            let x = Double((a >> shift) & 0xFF)
            let y = Double((b >> shift) & 0xFF)
            return UInt32((x + (y - x) * amount).rounded()) << shift
        }
        return channel(16) | channel(8) | channel(0)
    }

    /// WCAG contrast ratio between two colours (1…21).
    public static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    static func luminance(_ color: UInt32) -> Double {
        func linear(_ shift: UInt32) -> Double {
            let value = Double((color >> shift) & 0xFF) / 255
            return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(16) + 0.7152 * linear(8) + 0.0722 * linear(0)
    }

    /// `color`, mixed toward `target` in small steps until it has `ratio` contrast with `background`.
    static func adjusted(_ color: UInt32, toward target: UInt32, against background: UInt32, ratio: Double) -> UInt32 {
        var result = color
        var step = 0.0
        while contrast(result, background) < ratio, step < 1 {
            step += 0.05
            result = mix(color, target, step)
        }
        return result
    }
}
