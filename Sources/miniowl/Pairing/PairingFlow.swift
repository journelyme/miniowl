import Foundation
import AppKit

/// RFC 8628 Device Authorization Grant flow coordinator.
///
/// This actor manages the complete pairing process:
/// 1. Generate device_code and POST to /pair/start
/// 2. Open verification URL in browser
/// 3. Poll /pair/poll until approved/expired/denied
/// 4. On success: store device_token in Keychain and notify UI
///
/// Thread-safe via actor isolation. Only one pairing flow can be active at a time.
actor PairingFlow {

    // MARK: - State

    private var currentTask: Task<Void, Never>?
    private var currentState: PairingState?
    private let deviceTokenStore = DeviceTokenStore()

    /// Callback fired on any termination — success, expiry, or give-up.
    /// The `result` passes `nil` on success, a localized error string on
    /// failure so the UI can decide whether to show an error banner.
    private var onCompletion: (@MainActor @Sendable (_ failureMessage: String?) -> Void)?

    /// Safety caps so a crashed server doesn't get hammered for 15 minutes.
    /// Interval is taken from the server's `poll_interval` (usually 5s) and
    /// backs off exponentially on failure up to `maxBackoffSeconds`.
    private let maxConsecutiveErrors = 5
    private let maxBackoffSeconds: TimeInterval = 60

    // MARK: - Public Interface

    var isPairing: Bool {
        currentTask != nil && !(currentTask?.isCancelled ?? true)
    }

    /// Start the pairing flow. Returns the pairing state for UI display.
    /// Throws if already pairing or if the initial setup fails.
    ///
    /// `onCompletion` is called exactly once when polling ends — success
    /// (failureMessage == nil), expiry, give-up, or cancel. The UI uses
    /// it to clear "Waiting to pair…" state, either to "Signed in" or
    /// an error banner.
    func startPairing(onCompletion: (@MainActor @Sendable (_ failureMessage: String?) -> Void)? = nil) async throws -> PairingState {
        // Cancel any existing flow
        cancelPairing()

        self.onCompletion = onCompletion

        // Generate device code (32 random bytes -> base64url, 43 chars)
        let deviceCode = try generateDeviceCode()
        let deviceName = Host.current().localizedName ?? "Mac"
        let platform = "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"

        let request = PairStartRequest(
            device_name: deviceName,
            platform: platform,
            device_code: deviceCode
        )

        // Use the same client as categorization to keep network in one place.
        let response = try await CategorizationClient.pairStart(request)

        let state = PairingState(
            userCode: response.user_code,
            verificationURL: response.verification_url,
            expiresAt: Date().addingTimeInterval(TimeInterval(response.expires_in)),
            pollInterval: TimeInterval(response.poll_interval)
        )
        currentState = state

        // Open verification URL in browser.
        if let url = URL(string: response.verification_url) {
            _ = await MainActor.run {
                NSWorkspace.shared.open(url)
            }
        }

        // Start polling in background.
        currentTask = Task { [weak self] in
            guard let self = self else { return }
            await self.pollForApproval(deviceCode: deviceCode, state: state)
        }

        return state
    }

    /// Cancel the current pairing flow
    func cancelPairing() {
        currentTask?.cancel()
        currentTask = nil
        currentState = nil
        onCompletion = nil
    }

    /// Called from the polling loop when it terminates for any reason.
    /// Clears actor state so `isPairing` goes false and fires the callback
    /// so the UI can transition out of "Waiting to pair…".
    private func finishPairing(failureMessage: String?) async {
        let cb = onCompletion
        currentTask = nil
        currentState = nil
        onCompletion = nil
        if let cb = cb {
            await cb(failureMessage)
        }
    }

    // MARK: - Private Implementation

    /// Generate a cryptographically secure device code
    private func generateDeviceCode() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let result = SecRandomCopyBytes(kSecRandomDefault, 32, &bytes)

        guard result == errSecSuccess else {
            throw PairingError.deviceCodeGeneration
        }

        return Data(bytes).base64URLEncodedString()
    }

    /// Poll the server until approval, expiration, max errors, or cancel.
    ///
    /// Safety guarantees:
    ///   - Respects `state.pollInterval` (server decides cadence, usually 5s).
    ///   - Hard stop at `state.expiresAt` (~15 min from start).
    ///   - Exponential backoff on network errors, capped at maxBackoffSeconds.
    ///   - Gives up after maxConsecutiveErrors so a crashed server doesn't
    ///     get hammered for the full 15 min.
    ///   - Always calls finishPairing() on exit so the UI unsticks.
    private func pollForApproval(deviceCode: String, state: PairingState) async {
        var consecutiveErrors = 0
        var failureMessage: String? = nil

        defer {
            // `defer` can't await — schedule the finish on a detached Task.
            // Captures the final failureMessage and the actor.
            let msg = failureMessage
            Task { [weak self] in
                await self?.finishPairing(failureMessage: msg)
            }
        }

        while !Task.isCancelled && !state.isExpired {
            // Compute the wait — base interval, or exponential backoff after errors.
            let wait: TimeInterval = {
                if consecutiveErrors == 0 { return state.pollInterval }
                let backoff = state.pollInterval * pow(2, Double(consecutiveErrors - 1))
                return min(backoff, maxBackoffSeconds)
            }()

            do {
                try await Task.sleep(for: .seconds(wait))
            } catch {
                // Task cancelled during sleep.
                return
            }

            if Task.isCancelled { return }
            if state.isExpired {
                failureMessage = "Pairing request expired. Please try again."
                return
            }

            do {
                let response = try await CategorizationClient.pairPoll(deviceCode: deviceCode)
                consecutiveErrors = 0  // any response resets the error counter

                switch response.status {
                case "pending":
                    continue

                case "approved":
                    guard let deviceToken = response.device_token else {
                        failureMessage = "Server approved pairing but did not return a token."
                        return
                    }
                    do {
                        try deviceTokenStore.save(token: deviceToken)
                        print("miniowl: device token saved to Keychain")
                        // success — failureMessage stays nil
                    } catch {
                        failureMessage = "Could not save device token: \(error.localizedDescription)"
                    }
                    return

                case "expired":
                    failureMessage = "Pairing request expired. Please try again."
                    return

                case "denied":
                    failureMessage = "Pairing was denied."
                    return

                default:
                    failureMessage = "Unexpected server response: \(response.status)"
                    return
                }

            } catch {
                consecutiveErrors += 1
                print("miniowl: polling error \(consecutiveErrors)/\(maxConsecutiveErrors): \(error)")
                if consecutiveErrors >= maxConsecutiveErrors {
                    failureMessage = "Can't reach the server. Check your connection and try again."
                    return
                }
                continue
            }
        }

        if state.isExpired {
            failureMessage = "Pairing request expired. Please try again."
        }
    }
}

// MARK: - Data Extensions

extension Data {
    /// Convert to base64url encoding (RFC 4648 Section 5)
    /// Replace + with -, / with _, remove padding =
    func base64URLEncodedString() -> String {
        return self.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}