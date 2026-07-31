import Foundation

public enum JSONRPCError: Error, Equatable, Sendable {
    case executableNotFound(String)
    case processLaunchFailed(String)
    case processExited(status: Int32)
    case processTerminationFailed
    case processTerminationTimedOut
    case processInputBufferOverflow(limit: Int)
    case requestTooLarge(limit: Int)
    case invalidPendingRequestLimit
    case pendingRequestLimitExceeded(limit: Int)
    case invalidRequestTimeout
    case notificationSendLimitExceeded(limit: Int)
    case notificationTimedOut
    case notInitialized
    case alreadyInitialized
    case startupCancelled
    case requestTimedOut(JSONRPCRequestID)
    case requestCancelled(JSONRPCRequestID)
    case malformedJSON
    case missingResponsePayload
    case invalidInitializeResponse
    case responseTooLarge(limit: Int)
    case transportBufferOverflow(limit: Int)
    case notificationBufferOverflow(limit: Int)
    case unknownResponseID(JSONRPCRequestID)
    case remoteError(code: Int)
    case transportClosed
}

extension JSONRPCError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .executableNotFound(let name):
            "Executable not found: \(Self.sanitizedExecutableName(name))."
        case .processLaunchFailed(let name):
            "Could not launch executable: \(Self.sanitizedExecutableName(name))."
        case .processExited(let status):
            "The child process exited unexpectedly with status \(status)."
        case .processTerminationFailed:
            "The child process could not be forcefully terminated."
        case .processTerminationTimedOut:
            "The child process did not confirm termination before the deadline."
        case .processInputBufferOverflow(let limit):
            "The process input buffer exceeded its safe limit of \(limit)."
        case .requestTooLarge(let limit):
            "The JSON-RPC request exceeded the safe limit of \(limit) bytes."
        case .invalidPendingRequestLimit:
            "The JSON-RPC request and notification send limit must be greater than zero."
        case .pendingRequestLimitExceeded(let limit):
            "The JSON-RPC client reached its limit of \(limit) pending requests."
        case .invalidRequestTimeout:
            "The JSON-RPC request timeout must be greater than zero."
        case .notificationSendLimitExceeded(let limit):
            "The JSON-RPC client reached its limit of \(limit) active notification sends."
        case .notificationTimedOut:
            "The JSON-RPC notification send timed out."
        case .notInitialized:
            "The client has not completed initialization."
        case .alreadyInitialized:
            "The client has already started initialization."
        case .startupCancelled:
            "Client startup was cancelled."
        case .requestTimedOut(let id):
            "JSON-RPC request \(id.diagnosticDescription) timed out."
        case .requestCancelled(let id):
            "JSON-RPC request \(id.diagnosticDescription) was cancelled."
        case .malformedJSON:
            "The transport received malformed JSON."
        case .missingResponsePayload:
            "The JSON-RPC response has neither a result nor an error."
        case .invalidInitializeResponse:
            "The Codex server returned an invalid initialize response."
        case .responseTooLarge(let limit):
            "The transport received a response larger than \(limit) bytes."
        case .transportBufferOverflow(let limit):
            "The transport exceeded its output buffer of \(limit) chunks."
        case .notificationBufferOverflow(let limit):
            "The JSON-RPC notification buffer exceeded \(limit) messages."
        case .unknownResponseID(let id):
            "The transport received an unknown response ID \(id.diagnosticDescription)."
        case .remoteError(let code):
            "The remote endpoint returned JSON-RPC error code \(code)."
        case .transportClosed:
            "The JSON-RPC transport is closed."
        }
    }

    static func sanitizedExecutableName(_ value: String) -> String {
        let candidate = URL(fileURLWithPath: value).lastPathComponent
        let allowed = candidate.unicodeScalars.filter {
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-")).contains($0)
        }
        let sanitized = String(String.UnicodeScalarView(allowed))
        return sanitized.isEmpty ? "unknown" : String(sanitized.prefix(80))
    }
}
