import Foundation
import LibFx

extension Driver {
    func signInOperation(_ value: JSONValue) async throws -> JSONValue {
        guard let raw = value["provider"]?.string, let provider = FxSubscriptionProvider(rawValue: raw) else {
            throw FxSignInError.invalidAuthorization
        }
        let signIn = FxSignIn(provider: provider, httpClient: self)
        let args = value["args"] ?? .null
        switch value["action"]?.string {
        case "start":
            let state = try signIn.startAuthorization()
            return .object(["url": .string(state.url.absoluteString), "state": .string(state.state),
                            "verifier": .string(state.verifier), "redirectUri": .string(state.redirectURL.absoluteString)])
        case "finish":
            guard let state = args["authorization"]?["state"]?.string,
                  let verifier = args["authorization"]?["verifier"]?.string,
                  let redirect = args["authorization"]?["redirectUri"]?.string ?? (provider == .codex ? "http://localhost:1455/auth/callback" : nil),
                  let redirectURL = URL(string: redirect), let address = args["address"]?.string else { throw FxSignInError.invalidAuthorization }
            let authorization = FxSignIn.Authorization(provider: provider, url: redirectURL, state: state, verifier: verifier, redirectURL: redirectURL)
            return signInCredentials(try await signIn.completeAuthorization(authorization, callback: address))
        case "startDevice":
            let device = try await signIn.startDeviceAuthorization()
            return .object(["verificationUrl": .string(device.verificationURL.absoluteString), "userCode": .string(device.userCode),
                            provider == .codex ? "deviceAuthId" : "deviceCode": .string(device.deviceCode),
                            "intervalMs": .number(device.pollInterval * 1000), "expiresAt": .number(device.expiresAt.timeIntervalSince1970 * 1000)])
        case "pollDevice", "completeDevice":
            guard let code = args["device"]?[provider == .codex ? "deviceAuthId" : "deviceCode"]?.string,
                  let user = args["device"]?["userCode"]?.string,
                  case .number(let interval) = args["device"]?["intervalMs"],
                  case .number(let expiry) = args["device"]?["expiresAt"] else { throw FxSignInError.invalidAuthorization }
            let device = FxSignIn.DeviceAuthorization(provider: provider, verificationURL: URL(string: "https://example.com/device")!,
                userCode: user, pollInterval: interval / 1000, expiresAt: Date(timeIntervalSince1970: expiry / 1000), deviceCode: code)
            if value["action"] == .string("completeDevice") { return signInCredentials(try await signIn.completeDeviceAuthorization(device)) }
            return try await signIn.pollDeviceAuthorization(device).map(signInCredentials) ?? .null
        case "refresh", "normalize":
            guard let access = args["credentials"]?["accessToken"]?.string else { throw FxSubscriptionError.invalidCredentials }
            let expiry: Date?
            if case .number(let seconds) = args["credentials"]?["expiresAt"] { expiry = Date(timeIntervalSince1970: seconds / 1000) }
            else { expiry = nil }
            let credentials = try FxSubscriptionCredentials(accessToken: access,
                refreshToken: args["credentials"]?["refreshToken"]?.string, accountID: args["credentials"]?["accountId"]?.string,
                expiresAt: expiry).normalized(for: provider)
            if value["action"] == .string("normalize") { return signInCredentials(credentials) }
            return signInCredentials(try await signIn.refreshCredentials(credentials))
        default: throw FxSignInError.invalidAuthorization
        }
    }

    private func signInCredentials(_ value: FxSubscriptionCredentials) -> JSONValue {
        var fields: [String: JSONValue] = ["accessToken": .string(value.accessToken)]
        if let token = value.refreshToken { fields["refreshToken"] = .string(token) }
        if let account = value.accountID { fields["accountId"] = .string(account) }
        if let expiry = value.expiresAt { fields["expiresAt"] = .number(expiry.timeIntervalSince1970 * 1000) }
        return .object(fields)
    }

    func signInErrorFields(_ error: any Error, provider: String?) -> [String: JSONValue] {
        guard let provider, ["codex", "grok"].contains(provider) else { return [:] }
        let prefix = provider == "codex" ? "LIBFX_CHATGPT" : "LIBFX_GROK"
        var fields: [String: JSONValue] = [:]
        var suffix: String?
        var status: Int?
        if let error = error as? FxSignInError {
            switch error {
            case .invalidAuthorization: fields["category"] = .string("type")
            case .invalidAddress: suffix = "SIGN_IN_INVALID_ADDRESS"
            case .stateMismatch: suffix = "SIGN_IN_STATE_MISMATCH"
            case .denied(let reason): suffix = "SIGN_IN_DENIED"; fields["reason"] = .string(reason)
            case .expired(let code): suffix = "SIGN_IN_EXPIRED"; status = code
            case .deviceUnavailable(let code): suffix = "DEVICE_CODE_UNAVAILABLE"; status = code
            case .deviceExpired:
                suffix = "DEVICE_CODE_EXPIRED"
                fields["message"] = .string(provider == "codex" ? "The code expired. Check ChatGPT security settings or ask your workspace admin." : "The code expired. Start again.")
            case .accountUnavailable(let code): suffix = "ACCOUNT_UNAVAILABLE"; status = code
            case .failed(let code): suffix = "SIGN_IN_FAILED"; status = code
            }
        } else if let error = error as? FxSubscriptionError {
            switch error {
            case .invalidCredentials:
                fields["category"] = .string("type")
                fields["message"] = .string(provider == "grok" ? "Grok credentials need an accountId" : "Invalid ChatGPT credentials")
            case .refreshFailed(let code): suffix = "REFRESH_FAILED"; status = code
            case .accountChanged: suffix = "ACCOUNT_CHANGED"
            case .credentialSaveFailed: break
            }
        }
        if let suffix { fields["code"] = .string(prefix + "_" + suffix) }
        if let status { fields["status"] = .number(Double(status)) }
        return fields
    }
}
