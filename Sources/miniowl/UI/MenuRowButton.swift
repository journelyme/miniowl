// ─────────────────────────────────────────────────────────────────────
//  MenuRowButton.swift
//
//  Shared row-style button for the menu-bar popover.
//
//  Monochrome on purpose: the real content above (category bars + day
//  summary) already carries color. Action rows should recede, not
//  compete. Icons are secondary-gray, labels primary, hover = subtle
//  system fill. No destructive red, no accent — chrome disappears.
// ─────────────────────────────────────────────────────────────────────

import SwiftUI

struct MenuRowButton: View {
    let systemImage: String
    let title: String
    var isLoading: Bool = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                iconView
                    .frame(width: 16, alignment: .center)
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovering && !isLoading ? hoverFill : .clear)
            )
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .opacity(isLoading ? 0.7 : 1.0)
        .onHover { hovering in
            isHovering = hovering
        }
    }

    @ViewBuilder
    private var iconView: some View {
        if isLoading {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.7)
                .frame(width: 14, height: 14)
        } else {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    /// macOS's standard menu-row hover fill. Uses the system's control
    /// background so it tracks light/dark mode automatically.
    private var hoverFill: Color {
        Color(NSColor.controlBackgroundColor).opacity(0.6)
    }
}
