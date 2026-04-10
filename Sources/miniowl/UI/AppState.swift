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

        // SMAppService.register() is synchronous and very fast once the
        // binary is installed; slow only in the "never run before" case
        // which we tolerate.
        registerLoginItem()

        // Debug breadcrumb so we can verify start() actually ran even
        // when the binary's stdout isn't visible (e.g. when launched
        // via `open`).
        let breadcrumb = "miniowl start() at \(Date())\n"
        try? breadcrumb.write(
            toFile: "/tmp/miniowl-debug.log",
            atomically: true,
            encoding: .utf8
        )

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
