import SwiftUI
import AppKit

/// The palette, the type scale and the shapes — Material 3, generated rather than chosen.
///
/// Every colour below comes out of Google's material-color-utilities (`SchemeTonalSpot`) for the
/// seed #6750A4, dark and light. They are not hand-tuned on purpose: the previous palette was, and
/// it drifted into a Claude orange 11° from the "needs you" amber, a Codex teal identical to the
/// shell status in light mode, and an accent used for a dozen unrelated things. Regenerate the whole
/// scheme from a new seed rather than nudging one value. DESIGN.md (kept with the redesign mockups)
/// is the reference for which role is used where.
///
/// Every colour is a dynamic `NSColor`, so the system resolves it per appearance: nothing observes
/// the appearance and no view can be left holding a stale colour. The web dashboard's CSS variables
/// carry the same values (see `:root` in WebDashboardPage) so the two can be compared by eye.
enum Theme {

    /// A colour with a value per appearance, each `0xRRGGBB`.
    private static func dual(_ dark: UInt32, _ light: UInt32,
                             darkAlpha: Double = 1, lightAlpha: Double = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(srgbRed: Double((hex >> 16) & 0xFF) / 255,
                           green: Double((hex >> 8) & 0xFF) / 255,
                           blue: Double(hex & 0xFF) / 255,
                           alpha: isDark ? darkAlpha : lightAlpha)
        })
    }

    /// True when the app is currently drawing dark. Also what the web dashboard is told so it can
    /// match the desktop rather than the phone (see `WebSnapshot.dark`).
    @MainActor static var isDark: Bool {
        NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    // MARK: Material 3 roles (SchemeTonalSpot, seed #6750A4)

    static let primary                 = dual(0xCFBDFE, 0x65558F)
    static let onPrimary               = dual(0x36275D, 0xFFFFFF)
    static let primaryContainer        = dual(0x4D3D75, 0xE9DDFF)
    static let onPrimaryContainer      = dual(0xE9DDFF, 0x4D3D75)
    static let secondaryContainer      = dual(0x4A4458, 0xE8DEF8)
    static let onSecondaryContainer    = dual(0xE8DEF8, 0x4A4458)
    static let tertiary                = dual(0xEFB8C8, 0x7E5260)
    static let tertiaryContainer       = dual(0x633B48, 0xFFD9E3)
    static let onTertiaryContainer     = dual(0xFFD9E3, 0x633B48)
    static let surface                 = dual(0x141218, 0xFDF7FF)
    static let surfaceContainerLow     = dual(0x1D1B20, 0xF8F2FA)
    static let surfaceContainer        = dual(0x211F24, 0xF2ECF4)
    static let surfaceContainerHigh    = dual(0x2B292F, 0xECE6EE)
    static let surfaceContainerHighest = dual(0x36343A, 0xE6E0E9)
    static let onSurface               = dual(0xE6E0E9, 0x1D1B20)
    static let onSurfaceVariant        = dual(0xCAC4CF, 0x49454E)
    static let outline                 = dual(0x948F99, 0x7A757F)
    static let outlineVariant          = dual(0x49454E, 0xCAC4CF)
    static let inverseSurface          = dual(0xE6E0E9, 0x322F35)
    static let inverseOnSurface        = dual(0x322F35, 0xF5EFF7)
    static let error                   = dual(0xFFB4AB, 0xBA1A1A)
    static let errorContainer          = dual(0x93000A, 0xFFDAD6)
    static let onErrorContainer        = dual(0xFFDAD6, 0x93000A)

    // "Needs you". Material has no warning role, so this is what M3 does with a custom colour:
    // #E0A100 harmonised toward the seed, then taken at tones 80/40 (colour) and 30/90 (container).
    static let warn                    = dual(0xFFB86A, 0x895200)
    static let warnContainer           = dual(0x683D00, 0xFFDCBC)
    static let onWarnContainer         = dual(0xFFDCBC, 0x2C1700)

    /// Content that is shown but not live — an exited or closed terminal. M3's disabled opacity.
    static let endedOpacity: Double = 0.38

    // MARK: The names the views use

    // Surfaces, darkest to lightest in dark mode: the board, the panels on it, the cards on those.
    static let bg        = surface
    static let panel     = surfaceContainerLow
    static let card      = surfaceContainerHigh
    static let cardHover = surfaceContainerHighest
    /// Hairlines and dividers.
    static let stroke    = outlineVariant
    static let text      = onSurface
    static let subtext   = onSurfaceVariant
    /// Selection, focus, the path you are on, a running agent. Nothing decorative.
    static let accent    = primary
    /// Foreground for content sitting ON `accent`.
    static let onAccent  = onPrimary
    /// A marked (bookmarked) card. Identity, not state: a glyph only, never the card's fill.
    static let markTint  = tertiary
    static let markCard  = surfaceContainerHigh
    /// Positive feedback ("copied", tokens still flowing). The scheme has no green and does not need
    /// one: the accent already means "live".
    static let green     = primary
    static let amber     = warn
    static let red       = error

    // Agent identity: a small mark at the foot of a card, never a border or a fill. Codex is
    // monochrome, like its own mark — which also keeps it clear of every status colour.
    static let claudeTint = dual(0xD97757, 0xB4552F)
    static let codexTint  = onSurface

    static func agentColor(_ k: AgentKind) -> Color {
        switch k {
        case .claude:  return claudeTint
        case .codex:   return codexTint
        case .unknown: return subtext
        }
    }

    /// Session-tree lanes. The path you are on is the accent; every abandoned branch is the same
    /// neutral grey. They used to take a palette colour each — teal, orange, violet, green, amber —
    /// which put the status colours on lines that have no status, and made a tree with three
    /// branches the loudest thing in the window.
    static func laneColor(_ index: Int) -> Color { index < 0 ? accent : outline }

    static func statusColor(_ s: TermStatus) -> Color {
        switch s {
        case .working:  return primary
        case .needsYou: return warn
        case .idle:     return outline
        case .shell:    return outline
        case .exited:   return onSurface.opacity(endedOpacity)
        case .closed:   return onSurface.opacity(endedOpacity)
        }
    }

    // MARK: Shapes and sizes

    enum Radius {
        static let chip: CGFloat = 8
        static let card: CGFloat = 12
        static let sheet: CGFloat = 16
        static let dialog: CGFloat = 28
    }

    /// Every control that sits in a bar is this tall, and either all of a bar's controls have a
    /// container or none do.
    static let controlHeight: CGFloat = 36
}

/// The Material 3 type scale, set in the system font. Six sizes and three weights; anything that
/// is not one of these is a mistake, not a style.
extension Font {
    /// 16/24 medium — project names, panel titles.
    static let fvTitleMedium = Font.system(size: 16, weight: .medium)
    /// 14/20 medium — card names, section titles.
    static let fvTitleSmall  = Font.system(size: 14, weight: .medium)
    /// 14/20 — sidebar rows, tree prompts, fields.
    static let fvBody        = Font.system(size: 14)
    /// 12/16 — a card's last prompt, reply previews, secondary text.
    static let fvBodySmall   = Font.system(size: 12)
    /// 12/16 medium — timers, badges, buttons, chips.
    static let fvLabel       = Font.system(size: 12, weight: .medium)
    /// 11/16 medium — group names, token counts, metadata.
    static let fvLabelSmall  = Font.system(size: 11, weight: .medium)
    /// Ids, paths, commands.
    static let fvMono        = Font.system(size: 11, design: .monospaced)
    static let fvMonoBody    = Font.system(size: 12, design: .monospaced)
}
