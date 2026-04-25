import AppKit
import Combine
import Foundation
import ServiceManagement
import SwiftUI

/// The top-level, main-actor-bound state holder. Owns:
///   - storage (EventLog, StateFile)
///   - the EventCoordinator actor (single disk writer)
///   - all watchers (window / afk / browser / system)
///   - periodic timers (heartbeat, rotation, summary refresh,
///     permission polling)
///
/// The SwiftUI menu bar views subscribe to its `@Published` properties
/// and call its action methods directly (pause, open settings, etc.).
@MainActor
final class AppState: ObservableObject {
    // ─── Observable state ────────────────────────────────────────────
    @Published var paused = false
    @Published var isAccessibilityGranted = AccessibilityPermission.isGranted
    @Published var summary: DailySummary = .empty
    @Published var loginItemStatus: SMAppService.Status = .notRegistered

    // v2.0 — Categorization state.
    // `dayCategorization` is the PRIMARY view (cumulative day totals).
    // `rollup` is the LATEST 20-min window (secondary / detail).
    // UI falls back to v1 raw-app view when both are nil.
    @Published var dayCategorization: DayCategorization?
    @Published var rollup: CachedRollup?
    @Published var rollupError: String?
    @Published var showRawApps = false

    // v2.0 — Pairing flow state.
    @Published var isPairing = false
    @Published var pairingState: PairingState?
    @Published var pairingError: String?
    /// True from the moment the user clicks "Connect account…" until the
    /// /pair/start response comes back (or errors). Lets the menu button
    /// show a spinner + disable itself so rapid clicks can't fire multiple
    /// pair/start calls.
    @Published var isConnecting = false
    /// Brief (~250 ms) disabled window after clicking Sign out so the row
    /// can't be re-clicked while Keychain delete is in flight.
    @Published var isSigningOut = false

    // ─── Backing ─────────────────────────────────────────────────────
    let dataDir: URL
    let coordinator: EventCoordinator
    private let browserWatcher: BrowserWatcher
    private let windowWatcher: WindowWatcher
    private let afkWatcher: AFKWatcher
    private let systemWatcher: SystemWatcher

    private var heartbeatTimer: DispatchSourceTimer?
    private var rotationTimer: DispatchSourceTimer?
    private var permissionTimer: Timer?
    private var summaryTimer: Timer?
    private var categorizeTimer: DispatchSourceTimer?
    private var categorizeInflight = false

    /// Context file helper — used by the "Edit context" menu action.
    /// Context is resolved per-request by the client, not cached.
    let contextStore: ContextStore

    /// Device token store for Keychain-backed token (RFC 8628 pairing flow).
    let deviceTokenStore = DeviceTokenStore()

    /// Device authorization flow coordinator.
    let pairingFlow = PairingFlow()

    /// Persistent categorization log — mirrors EventLog's JSONL-per-day
    /// pattern. Rehydrates `rollup` on startup so the menu isn't empty
    /// after a relaunch.
    let categorizationLog: CategorizationLog

    /// Cadence for the categorization API call. 20 minutes is the default
    /// per the product spec; can be overridden via env for development.
    private let categorizeInterval: TimeInterval = {
        if let s = ProcessInfo.processInfo.environment["MINIOWL_CATEGORIZE_INTERVAL_S"],
           let v = TimeInterval(s), v >= 30 {
            return v
        }
        return 20 * 60
    }()

    // ─── Init ────────────────────────────────────────────────────────
    init() {
        // Resolve and ensure the data directory exists.
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        self.dataDir = base.appendingPathComponent("miniowl")
        try? FileManager.default.createDirectory(
            at: dataDir, withIntermediateDirectories: true
        )

        // Storage layer.
        let log: EventLog
        do {
            log = try EventLog(directory: dataDir)
        } catch {
            fputs("miniowl: failed to open event log: \(error)\n", stderr)
            fatalError("miniowl: cannot continue without a writable log")
        }
        let stateFile = StateFile(directory: dataDir)
        self.coordinator = EventCoordinator(log: log, stateFile: stateFile)

        // Watchers.
        self.browserWatcher = BrowserWatcher()
        self.windowWatcher = WindowWatcher(
            coordinator: coordinator,
            browserWatcher: browserWatcher
        )
        self.afkWatcher = AFKWatcher(coordinator: coordinator)
        self.systemWatcher = SystemWatcher(coordinator: coordinator)

        // Context file — ensure placeholder exists so the user can find
        // it via "Edit context…". Not cached — client reads fresh on
        // every categorize call.
        self.contextStore = ContextStore(dataDir: dataDir)
        contextStore.initializeIfMissing()

        // v2.0 — persistent categorization log. Prime `rollup` from the
        // last entry so the menu isn't empty after a restart. Silent
        // on missing file (first run).
        self.categorizationLog = CategorizationLog(dataDir: dataDir)
        self.rollup = categorizationLog.readLatest()
        self.dayCategorization = categorizationLog.readToday()
    }

    // ─── Lifecycle ───────────────────────────────────────────────────

    /// Called by AppDelegate.applicationDidFinishLaunching.
    func start() {
        // Fire-and-forget the launch marker off-main so any XPC delays
        // in start() itself (e.g. SMAppService) can't stall it.
        Task.detached { [coordinator] in
            await coordinator.systemEvent(kind: "launch")
        }

        windowWatcher.start()
        afkWatcher.start()
        systemWatcher.start()

        startHeartbeatTimer()
        startRotationTimer()
        startPermissionPolling()
        startSummaryRefresh()
        refreshSummaryNow()

        // v2.0 — always start the categorize timer. Token is resolved per-
        // request by the client. If the user has no token configured, each
        // call fails cleanly and the UI shows "set token" guidance.
        startCategorizeTimer()
        print("miniowl: categorization timer armed (every \(Int(categorizeInterval))s)")

        // SMAppService.register() is synchronous and very fast once the
        // binary is installed; slow only in the "never run before" case
        // which we tolerate.
        registerLoginItem()

        // Debug breadcrumb so we can verify start() actually ran even
        // when the binary's stdout isn't visible (e.g. when launched
        // via `open`).
        // Debug breadcrumb removed for production. Was writing to
        // /tmp/miniowl-debug.log — unnecessary and leaks launch time.

        print("miniowl: tracking started")
        print("miniowl: data dir → \(dataDir.path)")
    }

    /// Called by AppDelegate.applicationWillTerminate. Synchronously
    /// drains the coordinator so we don't lose the last event on quit.
    func shutdown() {
        let sem = DispatchSemaphore(value: 0)
        Task.detached { [coordinator] in
            await coordinator.systemEvent(kind: "quit")
            await coordinator.flush()
            sem.signal()
        }
        sem.wait()
    }

    // ─── User actions ────────────────────────────────────────────────

    func togglePause() {
        paused.toggle()
        let p = paused
        Task { await coordinator.setPaused(p) }
    }

    func openDataFolder() {
        NSWorkspace.shared.open(dataDir)
    }

    func openAccessibilitySettings() {
        AccessibilityPermission.openSystemSettings()
    }

    func openLoginItemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Human-readable label of the environment this build targets
    /// ("dev (localhost)" or "production"). Shown in the menu for
    /// transparency — the user should never be surprised about which
    /// backend their data goes to.
    var environmentLabel: String { CategorizationSettings.environmentLabel }

    /// Open the context file in the user's default text editor. Changes
    /// take effect on the next categorize call — no reload needed.
    func editContext() {
        contextStore.openInEditor()
    }

    // ─── Pairing flow management ─────────────────────────────────────

    /// True if the Mac is paired (device token present in Keychain).
    /// Reads fresh each call — cheap Keychain lookup, ~1ms.
    var hasDeviceToken: Bool {
        deviceTokenStore.read() != nil
    }

    /// Human-readable connection status for the menu
    var connectionStatus: String {
        hasDeviceToken ? "Signed in" : "Not connected"
    }

    /// Start the device pairing flow. The PairingFlow polls in the
    /// background and calls `onCompletion` exactly once when it terminates
    /// (success OR failure), so we always unstick the "Waiting to pair…" UI.
    ///
    /// `isConnecting` is flipped true immediately and cleared only after
    /// the /pair/start response (success or error) lands. The menu button
    /// disables itself during that window so rapid clicks can't fire
    /// duplicate pair_code rows at the server.
    func connectAccount() {
        guard !isConnecting && !isPairing else { return }
        isConnecting = true
        pairingError = nil

        Task {
            do {
                let state = try await pairingFlow.startPairing { @MainActor failureMessage in
                    self.isPairing = false
                    self.pairingState = nil
                    // nil = success → no banner. Non-nil = surface to user.
                    self.pairingError = failureMessage
                }

                await MainActor.run {
                    self.isConnecting = false
                    self.isPairing = true
                    self.pairingState = state
                }
            } catch {
                await MainActor.run {
                    self.isConnecting = false
                    self.pairingError = error.localizedDescription
                    self.isPairing = false
                    self.pairingState = nil
                }
                print("miniowl: pairing failed: \(error)")
            }
        }
    }

    /// Cancel the current pairing flow
    func cancelPairing() {
        Task {
            await pairingFlow.cancelPairing()
            await MainActor.run {
                self.isPairing = false
                self.pairingState = nil
                self.pairingError = nil
            }
        }
    }

    /// Sign out - remove device token from Keychain.
    /// Brief disabled window so rapid re-click can't race.
    func signOut() {
        guard !isSigningOut else { return }
        isSigningOut = true
        Task {
            do {
                try deviceTokenStore.delete()
                print("miniowl: signed out successfully")
            } catch {
                print("miniowl: sign out failed: \(error)")
            }
            // Small UX beat — user sees "yes, you did that" instead of a
            // jarringly-instant state flip.
            try? await Task.sleep(for: .milliseconds(250))
            await MainActor.run {
                self.isSigningOut = false
            }
        }
    }

    // ─── Timers ──────────────────────────────────────────────────────

    private func startHeartbeatTimer() {
        let t = DispatchSource.makeTimerSource(queue: .global())
        t.schedule(deadline: .now() + .seconds(10), repeating: .seconds(10))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.coordinator.heartbeat() }
        }
        t.resume()
        self.heartbeatTimer = t
    }

    /// Poll every minute for a date change. Simpler and more sleep/wake
    /// robust than a one-shot midnight timer — catches the rollover
    /// within 60 s of actual midnight, which is plenty precise.
    private func startRotationTimer() {
        let t = DispatchSource.makeTimerSource(queue: .global())
        t.schedule(deadline: .now() + .seconds(60), repeating: .seconds(60))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.coordinator.rotateIfNeeded() }
        }
        t.resume()
        self.rotationTimer = t
    }

    private func startPermissionPolling() {
        // CRITICAL: register the timer in `.common` modes so it keeps
        // firing while the menu bar popover is open. The default mode
        // (`.default`) is suspended whenever SwiftUI puts the runloop
        // into a tracking/event mode — which happens the moment the
        // user clicks the menu bar icon. Without `.common` the popover
        // would never see permission flips.
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.recheckAccessibilityPermission()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        permissionTimer = t
    }

    /// Force a synchronous re-check of the Accessibility permission and
    /// publish the result. Called from the polling timer AND from the
    /// menu popover's onAppear so the user's first click after granting
    /// permission picks up the change immediately.
    func recheckAccessibilityPermission() {
        let granted = AccessibilityPermission.isGranted
        if granted != isAccessibilityGranted {
            isAccessibilityGranted = granted
        }
    }

    private func startSummaryRefresh() {
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshSummaryNow()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        summaryTimer = t
    }

    /// v2.0 — fire the categorization API call on a schedule. First fire
    /// after 60s; then every `categorizeInterval` (default 20 min). All
    /// network work happens off-main; the @Published update bounces back
    /// to main via `await MainActor.run`.
    private func startCategorizeTimer() {
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(
            deadline: .now() + .seconds(60),
            repeating: .seconds(Int(categorizeInterval))
        )
        t.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.runCategorizeOnce() }
        }
        t.resume()
        self.categorizeTimer = t
    }

    /// One round-trip to the categorization API. No-op if v2 is disabled,
    /// paused, or another call is in-flight (single-flight semantics).
    /// Caller-safe to invoke from anywhere; runs on the global queue.
    func runCategorizeOnce() async {
        if paused { return }

        // Single-flight: bail if a call is already in progress.
        let alreadyRunning = await MainActor.run { () -> Bool in
            if categorizeInflight { return true }
            categorizeInflight = true
            return false
        }
        if alreadyRunning { return }
        defer {
            Task { @MainActor in self.categorizeInflight = false }
        }

        // Build the request from today's on-disk events. If the file is
        // empty (no activity), skip the call entirely.
        let today = DateUtils.localDateString(for: Date())
        let file = dataDir.appendingPathComponent("\(today).mow")
        // Pass current day totals so the LLM can write a natural day summary.
        let currentDayData = await MainActor.run { self.dayCategorization }
        guard let req = CategoryRollup.buildRequest(
            file: file,
            dayCategorization: currentDayData
        ) else {
            return
        }

        // Client reads token + user context fresh from disk per request.
        let client = CategorizationClient(dataDir: dataDir)
        do {
            let resp = try await client.categorize(req)
            let cached = CachedRollup(response: resp, computedAt: Date())

            // Persist BEFORE publishing to @Published so a crash between
            // the two doesn't lose the row. File I/O runs on the current
            // utility queue (outside the main actor).
            do {
                try categorizationLog.append(cached, request: req)
            } catch {
                fputs("miniowl: categorization log append failed: \(error)\n", stderr)
            }

            // Recompute cumulative day totals from ALL today's entries.
            let dayData = categorizationLog.readToday()

            await MainActor.run {
                self.rollup = cached
                self.dayCategorization = dayData
                self.rollupError = nil
            }
        } catch {
            // Fail-soft: keep showing the last good rollup if any, surface
            // a one-line error in the UI for transparency.
            await MainActor.run {
                self.rollupError = (error as? CategorizationError)?.errorDescription
                    ?? "\(error)"
            }
            fputs("miniowl: categorize failed: \(error)\n", stderr)
        }
    }

    /// Quit and immediately relaunch /Applications/miniowl.app. The
    /// fresh process gets a fresh `AXIsProcessTrusted()` answer — this
    /// is the bullet-proof escape hatch when macOS has cached a stale
    /// "permission denied" inside the running process.
    func restart() {
        let bundlePath = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", bundlePath]
        do {
            try task.run()
        } catch {
            fputs("miniowl: failed to relaunch: \(error)\n", stderr)
            return
        }
        // Give the new process a moment to come up before we die.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApp.terminate(nil)
        }
    }

    func refreshSummaryNow() {
        let today = DateUtils.localDateString(for: Date())
        let url = dataDir.appendingPathComponent("\(today).mow")
        self.summary = LogReader.summarize(file: url)
    }

    /// Re-read today's .cats.jsonl and update the day view. Clears stale
    /// yesterday data on day-change (file doesn't exist yet → nil).
    /// Cost: ~1ms for a 35KB daily file. Called on popover onAppear so
    /// the user never sees yesterday's bars on a new day.
    func refreshDayCategorization() {
        self.dayCategorization = categorizationLog.readToday()
    }

    // ─── Auto-launch ─────────────────────────────────────────────────

    /// Register miniowl as a login item via `SMAppService`. Silent
    /// failure is fine: it only works when the binary is an installed
    /// `.app` bundle (i.e. not during `swift run` development).
    private func registerLoginItem() {
        let service = SMAppService.mainApp
        switch service.status {
        case .enabled:
            loginItemStatus = .enabled
        case .notRegistered:
            do {
                try service.register()
                loginItemStatus = .enabled
                print("miniowl: registered as login item")
            } catch {
                loginItemStatus = .notRegistered
                print("miniowl: SMAppService.register() failed (expected during dev): \(error.localizedDescription)")
            }
        case .requiresApproval:
            loginItemStatus = .requiresApproval
            print("miniowl: login item requires approval in System Settings → General → Login Items")
        case .notFound:
            loginItemStatus = .notFound
        @unknown default:
            break
        }
    }
}

/// Shared local-date formatter helper used by AppState + EventLog so
/// the "today file" is resolved the same way everywhere.
enum DateUtils {
    static func localDateString(for date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }
}
