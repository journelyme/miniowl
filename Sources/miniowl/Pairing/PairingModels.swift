import Foundation

// MARK: - Wire models for RFC 8628 Device Authorization Grant flow

struct PairStartRequest: Codable {
    let device_name: String
    let platform: String
    let device_code: String
}

/// Server-side validation / business errors come back wrapped as
/// `{success: false, error: "..."}`. We surface the message to the UI
/// instead of generic keyNotFound decode errors.
struct PairServerError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct PairStartResponse: Codable {
    let user_code: String
    let verification_url: String
    let expires_in: Int
    let poll_interval: Int

    /// Decode the Go `{success, data, error}` envelope, falling back to raw.
    /// If the envelope carries `success:false`, throw `PairServerError` so
    /// the real message reaches the menu bar instead of a keyNotFound.
    static func decode(_ data: Data) throws -> PairStartResponse {
        let decoder = JSONDecoder()
        if let wrapped = try? decoder.decode(GoEnvelope.self, from: data) {
            if let inner = wrapped.data { return inner }
            if wrapped.success == false, let msg = wrapped.error {
                throw PairServerError(message: msg)
            }
        }
        return try decoder.decode(PairStartResponse.self, from: data)
    }

    private struct GoEnvelope: Codable {
        let success: Bool
        let data: PairStartResponse?
        let error: String?
    }
}

struct PairPollResponse: Codable {
    let status: String
    let device_token: String?  // Only present when status = "approved"

    /// Same envelope-tolerant decode as PairStartResponse.
    static func decode(_ data: Data) throws -> PairPollResponse {
        let decoder = JSONDecoder()
        if let wrapped = try? decoder.decode(GoEnvelope.self, from: data) {
            if let inner = wrapped.data { return inner }
            if wrapped.success == false, let msg = wrapped.error {
                throw PairServerError(message: msg)
            }
        }
        return try decoder.decode(PairPollResponse.self, from: data)
    }

    private struct GoEnvelope: Codable {
        let success: Bool
        let data: PairPollResponse?
        let error: String?
    }
}

// MARK: - UI State model

/// Current state of the pairing flow for UI display
struct PairingState: Equatable {
    /// Raw 8-char code (no dash). This is the canonical on-wire / DB form.
    let userCode: String
    let verificationURL: String
    let expiresAt: Date
    let pollInterval: TimeInterval

    var isExpired: Bool {
        Date() >= expiresAt
    }

    /// Display variant — inserts a dash at position 4 purely for
    /// readability ("WDJB-MJHT"). Never sent to the server.
    var displayUserCode: String {
        guard userCode.count == 8 else { return userCode }
        let mid = userCode.index(userCode.startIndex, offsetBy: 4)
        return "\(userCode[..<mid])-\(userCode[mid...])"
    }
}

// MARK: - Errors

enum PairingError: Error, LocalizedError {
    case deviceCodeGeneration
    case expired
    case denied
    case unknown
    case networkError(String)
    case serverError(Int, String)

    var errorDescription: String? {
        switch self {
        case .deviceCodeGeneration:
            return "Failed to generate device code"
        case .expired:
            return "Pairing request expired. Please try again."
        case .denied:
            return "Pairing request was denied"
        case .unknown:
            return "Unknown error occurred"
        case .networkError(let message):
            return "Network error: \(message)"
        case .serverError(let status, let message):
            return "Server error \(status): \(message)"
        }
    }
}