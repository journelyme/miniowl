<div align="center">
  <img src="assets/icon-256.png" width="140" alt="Miniowl app icon" />
  <h1>Miniowl</h1>
  <p><strong>A menu-bar honesty meter for solo founders. Are you shipping, or just coding?</strong></p>
  <p>~4,000 lines of Swift · zero dependencies · plain JSONL files · private by default, optional cloud sync</p>
  <br/>
  <img src="assets/screenshot-popover.png" width="320" alt="miniowl menu bar popover" />
  <p>
    <a href="https://github.com/journelyme/miniowl/actions/workflows/ci.yml"><img alt="ci" src="https://github.com/journelyme/miniowl/actions/workflows/ci.yml/badge.svg" /></a>
    <a href="https://github.com/journelyme/miniowl/releases/latest"><img alt="latest release" src="https://img.shields.io/github/v/release/journelyme/miniowl?label=release" /></a>
    <img alt="Platform" src="https://img.shields.io/badge/platform-macOS%2014%2B-blue" />
    <img alt="Language" src="https://img.shields.io/badge/swift-5.9%2B-orange" />
    <img alt="License" src="https://img.shields.io/badge/license-MIT-green" />
    <img alt="Dependencies" src="https://img.shields.io/badge/dependencies-0-brightgreen" />
  </p>
</div>

---

## What it is

miniowl is a small macOS app that quietly records which application has focus, what its window title is, when you're at the keyboard versus away, and (for whitelisted browsers) the URL of your current tab. It writes everything to a plain JSON-Lines file under `~/Library/Application Support/miniowl/`. By default, **nothing leaves your Mac**.

v2 adds an **opt-in** cloud-sync mode. When you turn it on, miniowl sends a compact summary of each 20-minute window to a categorization service that returns strategic buckets — *Product, GTM, Strategy, Learning, Admin, Operations, Personal* — and persists one daily-rollup row per user so you can review your week from a web dashboard. Cloud sync is **off until you flip it on**, and toggling it off purges every saved row from the server in the same call. See [Privacy contract → v2 cloud sync](#v2-cloud-sync-opt-in) for the exact wire shape.

It exists because **the only honest way to know where your time goes is to measure it**. Self-reports are flattering and inaccurate. Calendars are aspirational. Miniowl just records what actually happened — and v2 helps you see it as the categories that decide whether you ship or stall.

## Why you might want it

- You want to answer "where did the week go?" with data instead of memory.
- You're a solo founder trying to escape the **Joy+Skill trap** (coding when you should be talking to users) and need to see your time honestly grouped by strategic category.
- You don't want a SaaS time tracker reading your screen, screenshotting your work, or showing you a dashboard designed to keep you engaged.
- You want a small, source-visible tool you can audit and trust on a privacy-sensitive product.

If those don't resonate, you probably want something else — RescueTime, Toggl, Timing, or ActivityWatch are all good. Miniowl is deliberately narrow: built for one persona, on one platform, with one opinion about what time data is for.

## Privacy contract

These are **code-enforced** invariants. The build fails if any banned API appears in the source tree (see [`scripts/check-privacy.sh`](scripts/check-privacy.sh) and [`Sources/miniowl/Privacy/ForbiddenImports.swift`](Sources/miniowl/Privacy/ForbiddenImports.swift)).

| miniowl can read | miniowl cannot read |
|---|---|
| Frontmost app name + bundle ID | Keystrokes (no `CGEventTap`, no global event monitors) |
| Title of the focused window (via the Accessibility API) | Clipboard contents (no `NSPasteboard`) |
| One number: seconds since last input | Screen pixels (no `CGWindowListCreateImage`, no `ScreenCaptureKit`) |
| Browser current-tab URL via AppleScript (whitelisted browsers only) | Page content, form data, browsing history |
| `NSWorkspace` notifications: sleep / wake / lock / unlock | — |

The audit surface is small enough that a skeptic can read every line of Swift in under an hour and verify these claims.

### v2 cloud sync (opt-in)

v2 adds **two** opt-in network paths, both off by default and both gated by an explicit user action.

**1. Pairing (one-time, RFC 8628 device-code flow).** Click *Connect account…* in the menu bar. miniowl asks the server for a short-lived `device_code` and `user_code`, opens your default browser to the dashboard, and you log in with your Supabase account and confirm. The server issues a long-lived **device token** (`miniowl_sk_…`) which is stored in the **macOS Keychain** — never on disk in plaintext, never in source. You can revoke any device from the dashboard at any time.

**2. Categorization (every 20 minutes, only when cloud sync is on).** Once paired AND the per-user `cloud_sync_enabled` flag is `true` (the dashboard toggle), miniowl POSTs a compact summary of the last window to the categorization API. The response is a list of strategic buckets — *Product, GTM, Strategy, Learning, Admin, Operations, Personal* — plus one short founder-honest summary line. The server stores **one row per user per day** in a `day_rollups` table; raw window/event data never leaves your Mac.

**Cloud sync OFF (default):** the categorize call still works locally so the menu bar can show category bars in real time, but the server **does not persist anything**. Your `day_rollups` row is never created. Toggling OFF after it was on triggers a **hard-delete** of every saved row for your user, in the same call. The dashboard goes empty.

**What miniowl sends** (per call, batched, only when cloud sync is on):

```jsonc
{
  "tz": "Asia/Tokyo",
  "window_start": 1712739600000,
  "window_end": 1712740800000,
  "events": [
    {
      "b":  "com.jetbrains.intellij",     // bundle id
      "n":  "IntelliJ IDEA",              // app display name
      "ti": "miniowl – CategorizationClient.swift",  // window title (truncated to 120 chars)
      "u":  null,                          // URL host+first-path (truncated to 120 chars), null unless browser
      "ms": 480000                         // duration in ms within this window
    }
    // ... up to 400 deduped events per call
  ]
}
```

**What miniowl does NOT send, ever:** keystrokes, clipboard, screen pixels, page content / HTML / text, form data, full URLs (only host + first path segment), file contents, audio, network packets from other apps, anything from outside the existing v1 watchers.

**Auth seam:** the device token rides in `Authorization: Bearer miniowl_sk_<…>` over HTTPS. The server validates it against a hashed copy in `miniowl.devices.token_hash` (we never store the plaintext) and binds the call to your `user_id` before any business logic runs. The token is the only credential miniowl carries — there is no shared client secret in the source tree.

**Allowlisted file:** `URLSession` is allowed in **exactly one file** (`Sources/miniowl/Categorization/CategorizationClient.swift`). The privacy-check script enforces this — any other file that imports `URLSession` fails the build. The whole network surface is auditable in <100 lines.

**Outbox + idempotency:** when a categorize call fails (network, server down), the payload is appended to a local outbox in `~/Library/Application Support/miniowl/sync_state.json`. The next successful call replays it. The server is keyed on `last_window_end` so the same window can be sent twice without producing a duplicate row.

## Features

- **App + window title** capture via `NSWorkspace` activation events and the Accessibility API
- **Browser URL** capture for Chrome, Safari, Arc, and Brave via pre-compiled AppleScript
- **AFK detection** via `CGEventSource.secondsSinceLastEventType` (one integer, no event taps)
- **Sleep / wake / lock** events via `NSWorkspace` notifications
- **Live menu bar popover** with today's top apps + AFK total, refreshed every 30 s
- **Pause / resume** with honest `paused` / `resumed` markers in the data
- **Auto-launch at login** via `SMAppService.mainApp`
- **Daily rotation + gzip**: today's file is plain JSONL, older days get compressed at midnight
- **Crash recovery** via a 10 s heartbeat to `state.json` — at most 10 seconds of pending work is lost on `kill -9`
- **Compact storage**: ~5–8 KB per day gzipped, ~10–15 MB for five years
- **Zero third-party dependencies** — only Foundation, AppKit, ApplicationServices, ServiceManagement, SwiftUI
- **v2 strategic categorization (opt-in)** — every 20 minutes the window summary is sent to a categorization API which returns founder-strategic bucket totals (*Product / GTM / Strategy / Learning / Admin / Operations / Personal*) plus a one-line founder-honest summary, mapped onto the **3-circles palette** (Sweet Spot · Joy+Skill trap · Need-only · Personal). Disabled by default.
- **v2 device pairing (RFC 8628)** — one-time browser-based pairing flow, device tokens stored in the macOS Keychain, revocable from the dashboard at any time. No password ever lives in the app.
- **v2 cloud-sync toggle** — single dashboard toggle. ON = daily summaries persist on the server. OFF = nothing is stored, and flipping from ON→OFF hard-deletes every saved row for your user immediately.
- **v2 web dashboard** — see [miniowl.me/dashboard](https://miniowl.me/dashboard) for today's bars, last-7-days 3-circles stacked chart, and 30-day category split.
- **Resilient sync** — failed categorize calls go to a local outbox and replay on the next successful call. Server-side idempotency keyed on `last_window_end` means duplicate sends never create duplicate rows.

## Pricing & beta status

Miniowl is in **private beta**. While we make sure the category view actually changes how founders work — not just how their menu bar looks — the whole product is **free, no card required**.

| | Today (private beta) | At public launch |
|---|---|---|
| **Local tracking + menu bar** | Free | Free, forever |
| **Cloud sync + web dashboard** | Free | $5/mo |

**Founding-user perk:** if you join during the beta and give feedback, your first 3 months of cloud sync stay free after we open to the public. Our way of saying thanks for the brutally honest feedback.

We are deliberately not building Stripe or a billing flow yet — we want to validate that the dashboard changes behavior before charging. If that bet is wrong, the price was always going to be wrong too.

## Screenshot

<div align="center">
  <img src="assets/screenshot-popover.png" width="320" alt="miniowl menu bar popover showing today's top apps" />
  <p><em>Click the owl icon in your menu bar to see today's totals live.</em></p>
</div>

## Install

### Requirements

- macOS 14 (Sonoma) or later

### Option A — download the signed `.dmg` (recommended)

Grab the latest release from the [Releases page](https://github.com/journelyme/miniowl/releases/latest):

1. Download `miniowl-<version>.dmg`
2. Open the `.dmg`
3. Drag `miniowl.app` to **Applications**
4. Open **Applications** → **miniowl**

The `.dmg` is **signed by JOURNELY LLC and notarized by Apple**, so Gatekeeper will not show "unidentified developer" warnings.

### Option B — build from source

Requires Swift 5.9+ (ships with Xcode 15+, or via Command Line Tools — `xcode-select --install`).

```bash
git clone https://github.com/journelyme/miniowl.git
cd miniowl
./scripts/build-app.sh
cp -R build/miniowl.app /Applications/
open /Applications/miniowl.app
```

`./scripts/build-app.sh` auto-detects a signing identity from your keychain (`Developer ID Application` → `Apple Development` → ad-hoc fallback). For day-to-day local use, ad-hoc is fine — it just means you'll need to re-grant Accessibility after every rebuild because macOS tracks ad-hoc-signed apps by code hash.

### After install

`miniowl` appears as an eye icon in your menu bar (top-right of the screen).

## First-run permissions

macOS will ask for two permissions on the first launch. Both are required for the features to work but **neither lets miniowl read content** — see the [privacy contract](#privacy-contract) above for what each one actually allows.

### 1. Accessibility (required for window titles)

1. Click the eye icon in the menu bar — the popover will say "Accessibility permission required"
2. Click **Open Settings**
3. In **System Settings → Privacy & Security → Accessibility**, click the **+** button, navigate to `/Applications/miniowl.app`, and add it
4. Toggle the new `miniowl` entry **on**
5. Click the menu bar icon again — the banner should clear within ~1 second

If the banner stays after granting, click **Restart miniowl** in the same banner. This is a known macOS quirk with newly signed binaries — see [Limitations](#limitations--known-issues) below.

### 2. Automation (per browser, required for URL tracking)

The first time you focus Chrome, Safari, Arc, or Brave after granting Accessibility, macOS will show:

> "miniowl" wants to control "Google Chrome". Allowing control will provide access to documents and data in "Google Chrome", and to perform actions within that app.

Click **OK**. miniowl uses this only to read the URL of the active tab via AppleScript — it never reads page content, form data, or other tabs. Each browser prompts independently the first time it gains focus.

### 3. Login items (so miniowl auto-starts at login)

Miniowl calls `SMAppService.mainApp.register()` on first launch. macOS may show a prompt; you can also verify (or toggle) it manually under **System Settings → General → Login Items & Extensions → Open at Login**.

## Querying your data

There is no dashboard, by design. Today's data lives at `~/Library/Application Support/miniowl/YYYY-MM-DD.mow` and older days at `YYYY-MM-DD.mow.gz`. Use the canned report script or your own `jq` recipes.

```bash
# Top apps by active time today
./scripts/query-today.sh
```

Sample output:

```
Miniowl — 2026-04-10
─────────────────────────────────────

Top apps by active time

  142.3m  IntelliJ IDEA
   63.1m  Google Chrome
   45.0m  Preview
   28.4m  Slack
    9.2m  Terminal

AFK:           37.2 min

System markers
  09:02:11  launch
  10:14:33  sleep
  10:38:02  wake
  ...
```

### Custom queries

The data is plain JSON-Lines. Anything that reads text can query it. The schema lives in [the Data format section](#data-format) below.

```bash
DATA="$HOME/Library/Application Support/miniowl"
TODAY=$(date +%F)

# Total time in IntelliJ today
jq -r 'select(.t=="w" and .b=="com.jetbrains.intellij") | .e - .s' "$DATA/$TODAY.mow" \
  | awk '{s+=$1} END {printf "%.1fh\n", s/3600000}'

# Top URLs visited in Chrome today
jq -r 'select(.t=="w" and .b=="com.google.Chrome" and .u != null) | "\(.e-.s)\t\(.u)"' "$DATA/$TODAY.mow" \
  | awk -F'\t' '{sum[$2]+=$1} END {for(k in sum) printf "%4.0fs  %s\n", sum[k]/1000, k}' \
  | sort -rn | head -10

# How much "coding time" (your favorite IDEs/terminals) vs "talking time"
# (Slack/Zoom/Meet) so far this month
for f in "$DATA"/$(date +%Y-%m)-*.mow*; do
  case "$f" in *.gz) gunzip -c "$f" ;; *) cat "$f" ;; esac
done | jq -r 'select(.t=="w") | "\(.e-.s)\t\(.b)"' \
  | awk -F'\t' '
      /jetbrains|iTerm|Terminal|VSCode/ {code += $1}
      /slack|zoom|Meet|Messages|Discord/ {talk += $1}
      END {printf "code: %5.1fh\ntalk: %5.1fh\n", code/3600000, talk/3600000}'
```

## Data format

Each day gets one file: `YYYY-MM-DD.mow`. It's plain JSON-Lines — you can `cat`, `tail -f`, `jq`, or `grep` it. At local midnight the file is gzipped (`.mow.gz`) and a new one is opened.

### Header (line 1)

```json
{"d":"2026-04-10","start":1712707200000,"tz":"Asia/Tokyo","v":1}
```

| Key | Meaning |
|---|---|
| `v` | Format version. Bumped on breaking changes. |
| `d` | Local calendar date for this file. |
| `tz` | IANA time zone at rotation time. |
| `start` | Unix milliseconds at which this file was opened. |

### Event lines

Single-character keys to keep the uncompressed file small (gzip mostly erases the difference, but the raw file is also useful in flight).

#### Window event — `t: "w"`

```json
{"t":"w","s":1712739600000,"e":1712739720000,"b":"com.jetbrains.intellij","n":"IntelliJ IDEA","ti":"workspace – main.go","u":null}
```

| Key | Meaning |
|---|---|
| `s` | start_ts — Unix ms UTC |
| `e` | end_ts — Unix ms UTC |
| `b` | bundle identifier |
| `n` | app display name |
| `ti` | window title (may be null for secure-input fields) |
| `u` | active tab URL (only set for whitelisted browsers; null otherwise) |

Consecutive observations with the same `(b, ti, u)` triple are merged in memory by the coordinator and written as a single row when the state changes.

#### AFK event — `t: "a"`

```json
{"t":"a","s":1712739900000,"e":1712740080000,"k":1}
```

| Key | Meaning |
|---|---|
| `s`, `e` | Unix ms UTC start / end of the AFK interval |
| `k` | `1` = away. Only `away` intervals are written; "active" is implied as the complement. |

The threshold for "AFK" is 180 seconds of no input. Start timestamps are back-dated: if you walk away at 10:00:00 and the threshold trips at 10:03:00, the row's `s` is 10:00:00.

#### System event — `t: "s"`

```json
{"t":"s","s":1712740100000,"k":"sleep"}
```

| `k` value | Meaning |
|---|---|
| `launch` | miniowl process started |
| `quit` | miniowl process exited cleanly |
| `sleep` | system going to sleep |
| `wake` | system woke from sleep |
| `lock` | screens locked |
| `unlock` | screens unlocked |
| `paused` | tracking paused by user |
| `resumed` | tracking resumed |

### Expected disk footprint

| Period | Size (rotated + gzipped) |
|---|---|
| 1 day | 5–8 KB |
| 1 month | 150–250 KB |
| 1 year | 2–3 MB |
| 5 years | 10–15 MB |

## Architecture

```
┌────────────── miniowl (single process) ──────────────┐
│                                                       │
│  ┌─ MenuBarExtra (SwiftUI, main thread) ──────┐      │
│  │  Status · Pause/Resume · Open data folder  │      │
│  │  Today's totals · Permission state · Quit  │      │
│  └────────────────┬────────────────────────────┘      │
│                   │                                   │
│  ┌─ EventCoordinator (actor, single writer) ─┐       │
│  │  Buffers a PendingEvent in memory.         │       │
│  │  Decides when to extend / close / persist. │       │
│  │  Writes to EventLog on close or heartbeat. │       │
│  └──┬─────┬─────┬─────┬─────┬─────────────────┘      │
│     │     │     │     │     │                        │
│  ┌──▼──┐ ┌▼──┐ ┌▼───┐ ┌▼────┐                       │
│  │Win  │ │AFK│ │Sys │ │Brwsr│                       │
│  │Watch│ │   │ │Watc│ │     │                       │
│  └─────┘ └───┘ └────┘ └─────┘                        │
│                                                       │
│  ┌─ EventLog (serial JSONL writer + rotation) ─┐    │
│  │  ~/Library/Application Support/miniowl/      │    │
│  │    YYYY-MM-DD.mow      (today, plain)        │    │
│  │    YYYY-MM-DD.mow.gz   (yesterday, gzipped)  │    │
│  │    state.json          (10 s pending snap)   │    │
│  └───────────────────────────────────────────────┘    │
└───────────────────────────────────────────────────────┘
```

**One writer.** Every disk write funnels through the `EventCoordinator` actor — no races on the file handle.

**Watchers are dumb producers.** They emit raw observations; the coordinator decides whether the new observation extends the pending event in memory or closes it and opens a new one.

**Merging happens before disk.** Staying in IntelliJ on the same file for an hour writes one row, not 720.

**Crash safety.** A 10-second heartbeat mirrors the in-memory pending event to `state.json` via atomic write-then-rename. On the next launch, the coordinator recovers any stale pending into the log.

## Project layout

```
miniowl/
├── Package.swift                           # SPM manifest (Swift 5.9, macOS 14+)
├── miniowl-bundle/
│   ├── Info.plist                          # bundle metadata, LSUIElement
│   ├── miniowl.entitlements                # only automation.apple-events
│   └── AppIcon.icns                        # generated by tools/make-icon.sh
├── Sources/miniowl/
│   ├── miniowlApp.swift                    # @main + AppDelegate + signal handlers
│   ├── Coordinator/
│   │   ├── EventCoordinator.swift          # single-writer actor + merging logic
│   │   ├── SyncCoordinator.swift           # outbox-pattern actor for v2 sync lifecycle
│   │   └── PendingEvent.swift              # in-memory value type
│   ├── Storage/
│   │   ├── EventLog.swift                  # JSONL append + daily gzip rotation
│   │   ├── StateFile.swift                 # atomic state.json for crash recovery
│   │   ├── LogReader.swift                 # streaming JSONL → daily totals
│   │   ├── CategorizationLog.swift         # v2 cumulative day-level rollup (local)
│   │   ├── ContextStore.swift              # user-supplied context.md → prompt context
│   │   └── SyncState.swift                 # outbox JSONL + last_window_end anchor
│   ├── Watchers/
│   │   ├── WindowWatcher.swift             # NSWorkspace + Accessibility API
│   │   ├── AFKWatcher.swift                # CGEventSource idle state machine
│   │   ├── BrowserWatcher.swift            # pre-compiled AppleScript per browser
│   │   └── SystemWatcher.swift             # sleep / wake / lock notifications
│   ├── Categorization/                     # v2 — opt-in network layer
│   │   ├── CategorizationClient.swift      # ONLY URLSession site (privacy-check enforced)
│   │   ├── CategoryRollup.swift            # v2 cumulative day rollup logic
│   │   ├── DayCategorization.swift         # in-memory day model
│   │   └── Models.swift                    # request/response wire shapes
│   ├── Pairing/                            # v2 — RFC 8628 device-code flow
│   │   ├── PairingFlow.swift               # state machine for /pair/start, /pair/poll
│   │   ├── DeviceTokenStore.swift          # macOS Keychain (kSecClassGenericPassword)
│   │   └── PairingModels.swift             # wire shapes
│   ├── Permissions/
│   │   └── AccessibilityPermission.swift   # AX trust check + open Settings helper
│   ├── UI/
│   │   ├── AppState.swift                  # @MainActor orchestrator + timers
│   │   ├── MenuContent.swift               # popover layout
│   │   ├── MenuRowButton.swift             # shared menu row component
│   │   ├── CategoryBarsView.swift          # v2 cumulative day bars + 3-circles colors
│   │   └── TodaySummary.swift              # v1 raw-app fallback view
│   └── Privacy/
│       └── ForbiddenImports.swift          # banned-symbol manifest (non-executable)
├── scripts/
│   ├── build-app.sh                        # build + bundle + ad-hoc sign
│   ├── check-privacy.sh                    # CI grep for banned APIs
│   └── query-today.sh                      # canned jq report
├── tools/
│   ├── make-icon.swift                     # render the master 1024 px PNG
│   └── make-icon.sh                        # PNG → iconset → .icns
└── assets/                                 # README icon previews
```

## Development

```bash
# Hot loop (run the binary directly, ctrl-C to stop)
swift run -c release

# Full bundled build
./scripts/build-app.sh

# Privacy check (also runs as the first step of build-app.sh)
./scripts/check-privacy.sh

# Regenerate the app icon from scratch
./tools/make-icon.sh
```

### Cutting a release

This is a one-time setup for whoever maintains miniowl. Once it's done, every release is a single command.

#### One-time setup (for the maintainer's machine)

1. Have a paid **Apple Developer Program** membership
2. In **Keychain Access**, generate a CSR via *Certificate Assistant → Request a Certificate From a Certificate Authority…* and save it to disk
3. At https://developer.apple.com/account/resources/certificates/list, click **+** → **Developer ID Application** → upload the CSR → download the resulting `.cer` → double-click to install in Keychain Access
4. At https://appleid.apple.com → **Sign-In and Security → App-Specific Passwords**, generate a new app-specific password (label it `miniowl notarization`) and copy the `xxxx-xxxx-xxxx-xxxx` string
5. Run `./tools/setup-notary.sh <your-apple-id-email>` and paste the app-specific password when prompted — it gets stored in the macOS keychain under the profile name `miniowl-notary`

#### Cutting a release (every time)

1. Bump `CFBundleShortVersionString` in `miniowl-bundle/Info.plist`
2. Add an entry under `[Unreleased]` in `CHANGELOG.md` and rename it to the new version
3. Commit, tag, push:
   ```bash
   git commit -am "release v0.1.0"
   git tag v0.1.0
   git push origin main --tags
   ```
4. Build the signed + notarized `.dmg`:
   ```bash
   ./tools/make-dmg.sh
   ```
   This runs the privacy check, builds the `.app`, signs it with your Developer ID, packages it into a `.dmg`, signs the `.dmg`, submits it to Apple's notary service, waits for the `Accepted` status, and staples the ticket. Output: `release/miniowl-<version>.dmg`.
5. Create the GitHub release with the `.dmg` attached:
   ```bash
   gh release create v0.1.0 release/miniowl-0.1.0.dmg \
     --title "miniowl 0.1.0" \
     --notes-file <(awk '/^## \[0.1.0\]/,/^## \[/ {if (!/^## \[/) print}' CHANGELOG.md)
   ```

The privacy check is just a `grep` for banned API names. Banned symbols live in [`Sources/miniowl/Privacy/ForbiddenImports.swift`](Sources/miniowl/Privacy/ForbiddenImports.swift) and the script greps the rest of the source tree for them. **If you need to add a new API surface, audit it against the privacy contract first** — and please don't bypass the check.

### Adding a new watcher

1. Create `Sources/miniowl/Watchers/MyWatcher.swift` with a class that takes an `EventCoordinator` and exposes `start()`. Use a dedicated `DispatchQueue` for sampling — never the main thread.
2. Add a new `EventKind` case in `Sources/miniowl/Coordinator/PendingEvent.swift` if your data shape doesn't fit the existing `.window` or `.afk` cases.
3. Teach `EventCoordinator.encodeInterval` how to serialize it.
4. Wire the watcher into `AppState.init` and `AppState.start`.
5. Document the new event type in this README's [Data format](#data-format) section.

## Limitations & known issues

- **Ad-hoc signing breaks TCC across rebuilds.** Every `swift build` produces a new code-signature hash, and macOS Accessibility/Automation grants are tied to that hash. After rebuilding, you may need to re-grant permission via System Settings → Privacy & Security → Accessibility (remove the old `miniowl` entry with `−`, add the freshly built `/Applications/miniowl.app` with `+`). The fix is to sign with a real Apple Developer ID; left as a future improvement.
- **Spotlight does not index ad-hoc-signed apps.** You won't find miniowl via Cmd+Space — that's expected. Use the menu bar icon, or use Raycast / Alfred which have their own indexers.
- **Watching a video reads as AFK.** No mouse or keyboard input → idle counter ticks → AFK threshold trips. We don't try to fix this; the honest signal is "no input at the keyboard."
- **Rotation polls every 60 seconds.** A new day's file opens within ~60 seconds of midnight, not exactly at midnight.
- **No exports / calendar overlay yet.** v2 ships LLM categorization, the web dashboard, and opt-in cloud sync. Calendar overlay, CSV export, and integrations with other trackers are deliberately deferred until we see whether the dashboard alone changes founder behavior.
- **Single-machine only.** No multi-device sync of raw events. If you use multiple Macs, you get one local log per machine. Cloud sync rolls them up by user, but the raw JSONL stays per-machine.

## Roadmap (maybe)

These are explicit *maybes* — they ship only if the private beta validates that the category view actually changes founder behavior.

- Per-user category taxonomy (let users edit the 7 buckets to fit their own work)
- Weekly Sunday-retro email summarizing the past week's 3-circles split
- Calendar.app overlay so meetings align with focus blocks
- Sparkle auto-update so beta users don't have to redownload `.dmg` for each version
- A "kill criteria" page in the dashboard that flags weeks ≥50% Joy+Skill

**Explicitly not on the roadmap, ever:** team plans, screenshots, keystroke logging, mobile app, Windows or Linux ports, social-sharing of categories, gamification / streaks. These are commitments, not omissions — listing them prevents drift.

If you'd find any of the *maybes* useful, open an issue and say so.

## Contributing

Issues and pull requests welcome. Please:

1. Run `./scripts/check-privacy.sh` before pushing — the build script does this, but it's faster to catch locally.
2. Don't add third-party dependencies. The project's whole shape is "auditable in one sitting." If you need a library, the bar is "I rewrote it twice and still got it wrong."
3. Don't add new `URLSession` sites. v2 has *exactly one* — `Sources/miniowl/Categorization/CategorizationClient.swift` — and the privacy script enforces that. New network paths must either route through that file or land in a new dedicated file with explicit privacy review.
4. Keep watchers off the main thread. AX and AppleScript calls can block for hundreds of milliseconds — main is reserved for SwiftUI.

## Acknowledgments

Inspired by [ActivityWatch](https://github.com/ActivityWatch/activitywatch). miniowl is a deliberately smaller, single-user reimagining in native Swift — none of ActivityWatch's source code is used.

## License

[MIT](LICENSE) — do what you want, no warranty, attribute if you fork for distribution.
