# Changelog

All notable changes to miniowl are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [2.0.0] — 2026-04-28

Miniowl 2.0 — strategic categorization & opt-in cloud sync. The product
goes from "raw app names in a JSONL file" to "your day, sorted into the
four 3-circles zones, visible at a glance in the menu bar and on the
web." Cloud sync is **off by default** — nothing about your day leaves
your Mac unless you explicitly turn it on from the dashboard.

### Added

#### Strategic categorization (LLM)
- **CategorizationClient** — the *only* `URLSession` site in the codebase
  (privacy-check enforced). HTTPS POST every 20 minutes with a compact
  summary of the window: bundle id, app name, window title (truncated to
  120 chars), URL host (truncated, browsers only), duration. No
  keystrokes, clipboard, screen pixels, or page content. URL baked at
  build time via `#if MINIOWL_DEV` — no runtime override.
- **Server-side LLM** classifies each window into one of seven strategic
  buckets — *Product · GTM · Strategy · Learning · Admin · Operations ·
  Personal* — and returns a one-line founder-honest summary.
- **CategoryRollup + DayCategorization** — cumulative whole-day picture,
  rebuilt fresh on every categorize call. The menu bar shows this as the
  primary view; the v1 raw-app list is now a "Show raw apps" fallback.
- **CategoryBarsView** — colored progress bars per bucket, mapped onto
  the **3-circles palette** (Sweet Spot · Joy+Skill trap · Need-only ·
  Personal). Same colors carry through to the dashboard.
- **CategorizationLog** — per-day `.cats.jsonl` files mirror the v1
  EventLog rotation pattern. The last entry rehydrates the menu after a
  relaunch so users don't see an empty popover for 20 minutes.
- **ContextStore** — an editable `~/Library/Application
  Support/miniowl/context.md` that gets shipped to the LLM with every
  categorize call. Lets users teach miniowl about their company, their
  side projects, their non-obvious tool choices. Size-capped at 2 KB.

#### Cloud sync (opt-in)
- **Default OFF.** A brand-new user has zero server-side persistence
  until they flip the toggle. The menu bar still shows category bars in
  real time when off — the gate is on *server storage*, not on the
  categorize call itself.
- **Hard-delete on disable.** Toggling cloud sync off purges every saved
  `day_rollups` row for that user *in the same call*. Privacy promise
  surfaced verbatim in the dashboard confirmation dialog.
- **Web dashboard** at `miniowl.me/dashboard` — today's bars, last-7-day
  3-circles stacked chart, last-30-day category split. The cloud-sync
  toggle lives at the top of the page.

#### Account pairing (RFC 8628 device-code flow)
- **PairingFlow** — Mac asks server for a `device_code` + `user_code`,
  opens the default browser to the dashboard's pair page, polls every 5
  seconds, and receives a long-lived **device token** when the user
  confirms.
- **DeviceTokenStore** — token persisted in the **macOS Keychain**
  (`kSecClassGenericPassword`, account `device_token`). Never on disk in
  plaintext, never in source.
- **Connect account… / Sign out** menu rows wired to the flow. Sign out
  removes the keychain entry — server-side revocation lives in the
  dashboard's Devices panel.
- **Token format** — `miniowl_sk_<base64url>`. Server validates against a
  hashed copy in `miniowl.devices.token_hash`; we never store the
  plaintext server-side either.

#### Resilient sync (outbox pattern)
- **SyncCoordinator** — categorize calls go through an outbox. Failed
  calls (network down, server 5xx) persist to `sync_state.json` and
  replay on the next 20-minute tick. Batch size capped at 5 per tick to
  bound recovery cost after a long outage.
- **Idempotency anchor** — server is keyed on `last_window_end` so the
  same window can be sent twice without producing a duplicate row.

#### "Open dashboard" menu row
- New menu item between "Connect account…" and "Edit context…" that
  opens the web dashboard in the default browser. Compile-time URL —
  dev → `localhost:3003`, prod → `miniowl.me/dashboard` — so a shipped
  binary cannot be redirected.

### Changed

- **README** rewritten for v2 — updated privacy contract, project
  layout, beta-status section, and v2 architecture summary.
- **Hero subtitle** drops the "no network" claim (false now that v2 has
  opt-in cloud sync) — replaced with "private by default, optional cloud
  sync."
- **MenuContent** — reordered so account-related rows ("Connect
  account…", "Open dashboard") sit AFTER local utilities ("Pause", "Open
  data folder") for natural left-to-right flow on first use.
- **MenuBarLabel** extracted into its own `ObservableObject`-bound
  SwiftUI view so the menu icon swaps between active and paused glyphs
  the moment the user toggles pause (the previous closure captured the
  initial value once).
- **Info.plist** version bumped to 2.0.0.

### Privacy notes

- The `URLSession` allowlist still applies: only
  `Sources/miniowl/Categorization/CategorizationClient.swift` may import
  it. The privacy-check script enforces this at CI time.
- Local raw events (the v1 `*.mow` JSONL files) are untouched by v2 —
  cloud sync only ever sees the per-window summary that's already on its
  way to the LLM, never the raw event stream.
- Toggling cloud sync OFF deletes server-side rows but leaves your local
  Mac data alone. v1 keeps working with no network.

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
