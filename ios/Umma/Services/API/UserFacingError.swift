import Foundation

extension Error {
    /// Copy that is safe to show for any failure (brief 010): the server's or the adapter's own
    /// sentence when there is one, otherwise a plain line. Never a type name or an error number,
    /// which is what `localizedDescription` gives for a Swift error without a description.
    var userFacingMessage: String {
        if let api = self as? APIError { return api.userMessage }
        if self is URLError { return APIError.connectionMessage }
        if let described = (self as? LocalizedError)?.errorDescription, !described.isEmpty { return described }
        let bridged = self as NSError
        if bridged.userInfo[NSLocalizedDescriptionKey] != nil { return bridged.localizedDescription }
        return APIError.genericMessage
    }

    /// The person said no to the camera, microphone or speech recognition (or it is restricted).
    /// Only Settings can change that, so screens offer "Open Settings" next to the explanation.
    var isPermissionDenied: Bool {
        if case .permissionDenied? = self as? CaptureError { return true }
        return false
    }
}
