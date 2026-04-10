// ─────────────────────────────────────────────────────────────────────
//  Privacy Manifest — the list of macOS APIs miniowl must NEVER use.
// ─────────────────────────────────────────────────────────────────────
//
//  This file is non-executable documentation. Its sole purpose is to be
//  grepped by `scripts/check-privacy.sh`, which enforces that none of
//  these symbols appear anywhere else in the source tree.
//
//  If you find yourself wanting to import one of these, stop. miniowl's
//  privacy contract is the whole reason it exists. The contract:
//
//     "miniowl reads only what you voluntarily put in a window title,
//      plus a count of seconds since your last input. Nothing else."
//
//  Any API that lets us read keystrokes, clipboard contents, screen
//  pixels, or that sends data off the machine is forbidden.
//
//  Banned symbols (the grep script greps for each of these literally):
//
//    - NSPasteboard                  // clipboard access
//    - CGEventTap                    // keystroke/mouse interception
//    - addGlobalMonitorForEvents     // system-wide input monitoring
//    - CGWindowListCreateImage       // window screenshots
//    - CGDisplayStream               // display pixel stream
//    - ScreenCaptureKit              // screen recording framework
//    - URLSession                    // network client (Phase 1 is air-gapped)
//    - URLSessionDataTask            // network client
//    - Network.framework             // low-level networking
//
//  The grep script excludes THIS file (ForbiddenImports.swift) so the
//  manifest can name what's banned without tripping itself.
//
//  Audit surface: total Swift source under Sources/ is small enough that
//  a skeptic can read it end-to-end in under an hour and verify that
//  nothing here lies.
