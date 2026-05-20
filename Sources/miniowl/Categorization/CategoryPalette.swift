import SwiftUI

/// Deterministic color hashing for category names.
///
/// Same input → same color across Mac app, dashboard, and share card. Cross-
/// language port (TypeScript: apps/miniowl/src/lib/categoryPalette.ts).
///
/// The 36-color palette is organized into 6 hue families (6 shades each);
/// the index is the contract — if you reorder this list, reorder the TS one
/// too, or the share card will render different colors than the menu bar.
enum CategoryPalette {

    /// 36 colors organized into 6 hue families × 6 shades.
    /// Index 0..35 must match `PALETTE` in TypeScript.
    static let palette: [String] = [
        // Family 1 — Coral / Red
        "#DC2626", "#F87171", "#EA580C", "#FB923C", "#C2410C", "#FECDD3",
        // Family 2 — Yellow / Amber
        "#F59E0B", "#FBBF24", "#D97706", "#FCD34D", "#CA8A04", "#FDE047",
        // Family 3 — Green / Emerald
        "#10B981", "#34D399", "#059669", "#16A34A", "#4ADE80", "#15803D",
        // Family 4 — Blue / Cyan
        "#06B6D4", "#22D3EE", "#0891B2", "#3B82F6", "#60A5FA", "#1D4ED8",
        // Family 5 — Indigo / Purple / Pink
        "#8B5CF6", "#A78BFA", "#6D28D9", "#EC4899", "#F472B6", "#BE185D",
        // Family 6 — Neutral / Earth
        "#6B7280", "#9CA3AF", "#A8A29E", "#92400E", "#78716C", "#57534E",
    ]

    /// Locked colors override the hash — primarily for low-weight buckets
    /// (Personal, Other, Unsorted) that should always read as neutral grays.
    private static let locked: [String: String] = [
        "personal": "#78716C",
        "other": "#A8A29E",
        "unsorted": "#A8A29E",
    ]

    /// djb2 — non-cryptographic string hash by Daniel J. Bernstein.
    /// Returns an unsigned 32-bit integer.
    ///
    /// Iterates UTF-16 code units to match JavaScript's `charCodeAt(i)` —
    /// the TS port walks the same boundaries, so identical strings hash to
    /// identical indices across Swift, Go, and TypeScript.
    static func djb2(_ s: String) -> UInt32 {
        var h: UInt32 = 5381
        for unit in s.utf16 {
            // h * 33 + unit, with wrap-around (overflow is intentional)
            h = h &<< 5 &+ h &+ UInt32(unit)
        }
        return h
    }

    /// Hex string for the given category name.
    /// Case-insensitive; trimmed.
    static func hex(forCategory name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return locked["unsorted"]! }
        let lc = trimmed.lowercased()
        if let pinned = locked[lc] { return pinned }
        let index = Int(djb2(lc) % UInt32(palette.count))
        return palette[index]
    }

    /// SwiftUI Color for the given category name.
    static func color(forCategory name: String) -> Color {
        Color(hex: hex(forCategory: name))
    }
}

// MARK: - Color(hex:)

extension Color {
    /// Initialize from a "#RRGGBB" hex string. Falls back to gray on parse fail.
    init(hex: String) {
        let cleaned = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard cleaned.count == 6, let v = UInt32(cleaned, radix: 16) else {
            self = Color(red: 0.47, green: 0.44, blue: 0.42)
            return
        }
        let r = Double((v >> 16) & 0xFF) / 255.0
        let g = Double((v >> 8) & 0xFF) / 255.0
        let b = Double(v & 0xFF) / 255.0
        self = Color(red: r, green: g, blue: b)
    }
}
