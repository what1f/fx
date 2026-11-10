import Foundation
import LibFx

// The test transport copies identity, not observer behavior. Spans and their
// terminal states are produced by the real Swift SDK in the receiving process.
func relayedMCPObservation(_ value: JSONValue?, token: String) throws -> FxToolObservation? {
    guard let value, value != .null else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    let scope = try decoder.decode(FxObservation.self, from: JSONEncoder().encode(value["scope"] ?? .null))
    guard let callID = scope.data["call"]?["callId"]?.string else { throw FxError.invalidInput("Missing MCP tool scope") }
    let options = FxObservationOptions(captureContent: value["captureContent"] == .bool(true)) { event in
        DriverOutput.emit(.object(["mcpObservation": .object(["token": .string(token), "event": try encodeObservation(event)])]))
    } onError: { error in
        DriverOutput.emit(.object(["mcpObservationError": .object(["token": .string(token), "error": .string(String(describing: error))])]))
    }
    let observation = try FxToolObservation(scope: scope, callID: callID, options: options)
    if value["active"] == .bool(false) { observation.invalidate() }
    return observation
}

func encodeObservation(_ event: FxObservation) throws -> JSONValue {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    var value = try JSONDecoder().decode(JSONValue.self, from: encoder.encode(event))
    if case .object(var fields) = value {
        fields["timestamp"] = .number((event.timestamp.timeIntervalSince1970 * 1000).rounded())
        for key in ["parentSessionId", "parentTurnId", "parentCallId", "sourceSessionId", "workId", "turnId", "executionId"] where fields[key] == nil {
            fields[key] = .null
        }
        value = .object(fields)
    }
    return value
}
