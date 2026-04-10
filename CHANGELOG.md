# Changelog

All notable changes to miniowl are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.0] — 2026-04-10

First public release. End-to-end Phase 1 functionality: a tiny, privacy-first
macOS activity tracker that lives in the menu bar and writes plain JSONL
files locally. ~1,500 lines of Swift, zero third-party dependencies, no
network code.

### Added

#### Tracking
- **WindowWatcher** — captures the frontmost app's bundle ID, name, and
  window title via `NSWorkspace.didActivateApplicationNotification` plus a
  5-second polling fallback for same-app title changes. Uses the
  Accessibility API (`kAXFocusedWindowAttribute` → `kAXTitleAttribute`)
  with a 0.5-second messaging timeout so an unresponsive app can never
  hang miniowl.
- **BrowserWatcher** — pre-compiled `NSAppleScript` snippets for Chrome,
  Safari, Arc, and Brave that read the active tab's URL once per
  app-switch. Lazy per-browser Automation prompts; graceful degradation
  to title-only on TCC denial.
- **AFKWatcher** — idle detection via `CGEventSource.secondsSinceLastEventType`
  (a single integer; no `CGEventTap`, no global event monitors). 180-second
  threshold, retroactive `start_ts` so the AFK interval reflects when you
  actually walked away.
- **SystemWatcher** — sleep / wake / lock / unlock events via `NSWorkspace`
  notifications. Flushes the in-memory pending event before sleep so no
  interval straddles the boundary.

#### Storage
- **EventCoordinator** — single-writer `actor` that buffers a `PendingEvent`
  in memory and merges consecutive identical observations. Closes events
  to disk only when the state changes, so a 1-hour focus session writes
  one row, not 720.
- **EventLog** — append-only JSONL writer with daily rotation. At local
  midnight, today's `.mow` is closed, gzipped via `/usr/bin/gzip`, and a
  fresh file opens with a versioned header line.
- **StateFile** — 10-second heartbeat that mirrors the in-memory pending
  event to `state.json` via atomic write-then-rename. On the next launch
  the coordinator recovers any stale pending into the log, so a `kill -9`
  loses at most 10 seconds of in-flight work.
- **LogReader** — streaming JSONL reader for the menu bar's "Today"
  view; aggregates per-app totals + AFK in a single pass.

#### UI
- **SwiftUI `MenuBarExtra`** menu bar app — eye icon, popover with
  status header, accessibility-permission banner, live "Today" totals
  (top 6 apps + AFK), pause/resume button, open data folder button,
  quit button.
- **`AppState`** central `@MainActor` orchestrator owning the coordinator,
  watchers, heartbeat timer, rotation timer, summary refresh timer, and
  permission polling.
- Permission polling timer registered in `.common` RunLoop mode so it
  fires while the popover is open.
- "Restart miniowl" escape hatch in the permission banner for the rare
  case macOS caches a stale `AXIsProcessTrusted()` denial.

#### Permissions and lifecycle
- `SMAppService.mainApp.register()` for auto-launch at login
- `AccessibilityPermission` helper that opens System Settings to the
  Accessibility pane in one click
- Pause / resume emits explicit `paused` / `resumed` markers in the log
  so gaps are honest

#### Privacy enforcement
- `Sources/miniowl/Privacy/ForbiddenImports.swift` — non-executable
  manifest naming the banned macOS API surfaces
- `scripts/check-privacy.sh` — grep gate that fails the build if any
  banned symbol appears in the source tree
- Banned: `NSPasteboard`, `CGEventTap`, `addGlobalMonitorForEvents`,
  `CGWindowListCreateImage`, `CGDisplayStream`, `ScreenCaptureKit`,
  `URLSession`, `URLSessionDataTask`, `Network.framework`
- Entitlements file requests **only** `com.apple.security.automation.apple-events`
  — no network client, no file access outside container, no sandbox

#### Build pipeline
- `scripts/build-app.sh` — auto-detects signing identity in this
  preference order: `$MINIOWL_SIGNING_IDENTITY` env → `Developer ID
  Application` → `Apple Development` → ad-hoc fallback. Locks bundle
  ID at signing time via `--identifier`. Verifies the result with
  `codesign --verify --strict`.
- `tools/make-icon.sh` + `tools/make-icon.swift` — generates the app
  icon programmatically via Core Graphics (no external image editor),
  packs all macOS icon sizes into `miniowl-bundle/AppIcon.icns`.
- `tools/setup-notary.sh` — one-time setup for `xcrun notarytool`
  credentials, stored in the macOS keychain.
- `tools/make-dmg.sh` — builds, signs, packages, notarizes, and
  staples a distributable `.dmg`. Requires the Developer ID
  Application cert and notarization credentials.
- GitHub Actions CI workflow (`.github/workflows/ci.yml`) running on
  `macos-14`: privacy check + `swift build -c release` + binary
  verification on every push and PR.

#### Tooling and docs
- `scripts/query-today.sh` — canned `jq` report (top apps by time +
  AFK total + system markers) for today's `.mow` file
- README: privacy contract table, install + permissions guide, full
  data format spec, `jq` query recipes, architecture diagram, project
  layout, contributing notes
- LICENSE: MIT
- App icon: stylized owl face on a night-sky gradient

### Privacy contract

miniowl can only read:

- Frontmost app name + bundle ID (via `NSWorkspace`)
- Focused window title (via Accessibility API; `null` for secure-input
  fields, 1Password, Terminal sudo)
- Seconds since last input (a single integer from `CGEventSource`)
- Browser tab URL via AppleScript (whitelisted browsers only)
- macOS sleep / wake / lock notifications

miniowl **cannot** read keystrokes, clipboard, screen pixels, page
content, file contents, or anything over the network. These are
mechanically enforced by the privacy check at build time.

[unreleased]: https://github.com/journelyme/miniowl/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/journelyme/miniowl/releases/tag/v0.1.0
