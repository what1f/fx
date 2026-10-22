import Foundation
import Testing
@testable import LibFx

@Test func nativeOutputWaitsForItsReaderWithoutDroppingResponses() async throws {
    let transport = try NativeTransport(options: .object([
        "apiKey": .string("test-key"), "model": .string("swift/backpressure"),
        "home": .string("/tmp"), "workspaceRoot": .string("/tmp"),
    ]))
    try await transport.start()
    do {
        let encoder = JSONEncoder()
        for id in 0...384 {
            let request = JSONValue.object([
                "jsonrpc": .string("2.0"), "id": .number(Double(id)),
                "method": .string(id == 0 ? "initialize" : "unknown-backpressure-method"),
                "params": id == 0 ? .object(["protocolVersion": .number(1), "clientCapabilities": .object([:])]) : .object([:]),
            ])
            var bytes = try encoder.encode(request)
            bytes.append(10)
            try await transport.write(bytes)
            // Keep the consumer paused while independent readiness wakes arrive.
            try await Task.sleep(for: .milliseconds(1))
        }
        var buffered = Data(), replies: [Int] = []
        for try await chunk in transport.output {
            buffered.append(chunk)
            while let end = buffered.firstIndex(of: 10) {
                let reply = try JSONDecoder().decode(JSONValue.self, from: buffered[..<end])
                buffered.removeSubrange(...end)
                let id = try #require(reply["id"]?.integer)
                replies.append(id)
                if id == 0 { #expect(reply["result"] != nil) }
                else { #expect(reply["error"]?["code"] == .number(-32601)) }
            }
            if replies.count == 385 { break }
        }
        #expect(replies == Array(0...384))
        #expect(buffered.isEmpty)
        await transport.close()
    } catch {
        await transport.close()
        throw error
    }
}

@Test func closingNativeTransportReleasesAnIdleOutputReader() async throws {
    let transport = try NativeTransport(options: .object([
        "apiKey": .string("test-key"), "home": .string("/tmp"), "workspaceRoot": .string("/tmp"),
    ]))
    try await transport.start()
    let reading = Task {
        var iterator = transport.output.makeAsyncIterator()
        return try await iterator.next()
    }
    await Task.yield()
    await transport.close()
    #expect(try await reading.value == nil)
}
