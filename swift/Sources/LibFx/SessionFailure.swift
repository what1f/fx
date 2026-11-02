import Foundation

/// The durable description of an executor failure. Hosts may throw this value
/// directly when an upstream service provides its own error name or code.
public struct FxSessionFailure: Error, Sendable, Codable, Equatable, LocalizedError {
    public let message: String
    public let name: String
    public let code: JSONValue?
    public let rpcCode: Int?

    public init(message: String, name: String = "Error", code: JSONValue? = nil, rpcCode: Int? = nil) {
        self.message = message; self.name = name; self.code = code; self.rpcCode = rpcCode
    }

    public init(_ error: any Error) {
        if let failure = error as? FxSessionFailure { self = failure; return }
        if case FxError.rpc(let code, let message, let data) = error {
            self.init(message: message, name: data?["name"]?.string ?? "FxError",
                      code: data?["code"] ?? .number(Double(code)), rpcCode: code)
            return
        }
        if case FxError.invalidInput(let message) = error {
            self.init(message: message, name: "FxError", code: .string("invalidInput"))
            return
        }
        if case FxHarnessError.stopped(let message) = error {
            self.init(message: message, name: "FxHarnessError", code: .string("FX_HARNESS_STOPPED"))
            return
        }
        if let error = error as? any CustomNSError {
            let type = type(of: error)
            let message = (error as? any LocalizedError)?.errorDescription
                ?? error.errorUserInfo[NSLocalizedDescriptionKey] as? String ?? String(describing: error)
            self.init(message: message, name: type.errorDomain, code: .number(Double(error.errorCode)))
            return
        }
        if type(of: error) is NSError.Type {
            let error = error as NSError
            self.init(message: error.localizedDescription, name: error.userInfo["name"] as? String ?? error.domain,
                      code: .number(Double(error.code)))
            return
        }
        self.init(message: (error as? any LocalizedError)?.errorDescription ?? String(describing: error),
                  name: String(describing: type(of: error)))
    }

    public var errorDescription: String? { message }
}
