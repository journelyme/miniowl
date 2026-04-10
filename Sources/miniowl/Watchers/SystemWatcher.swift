import AppKit
import Foundation

/// Subscribes to macOS workspace notifications for sleep, wake, and
/// screen lock/unlock, and funnels each into a `system` event on the
/// coordinator. On `willSleep`, also asks the coordinator to `flush()`
/// the pending interval event so nothing ends up straddling sleep.
///
/// Privacy: these are ordinary public `NSWorkspace` notifications.
/// No identifying info is read — just the event type.
final class SystemWatcher {
    private let coordinator: EventCoordinator
    private var observers: [NSObjectProtocol] = []

    init(coordinator: EventCoordinator) {
        self.coordinator = coordinator
    }

    func start() {
        let nc = NSWorkspace.shared.notificationCenter

        observers.append(nc.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Flush *first*, then emit the sleep marker — this ordering
            // guarantees the pending event is closed with a timestamp
            // at or before the sleep marker.
            guard let self else { return }
            Task {
                await self.coordinator.flush()
                await self.coordinator.systemEvent(kind: "sleep")
            }
        })

        observers.append(nc.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.coordinator.systemEvent(kind: "wake") }
        })

        observers.append(nc.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.coordinator.systemEvent(kind: "lock") }
        })

        observers.append(nc.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.coordinator.systemEvent(kind: "unlock") }
        })
    }

    deinit {
        let nc = NSWorkspace.shared.notificationCenter
        for obs in observers {
            nc.removeObserver(obs)
        }
    }
}
