import Foundation
import CFx
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// The actor serializes C access and destruction. A cancelled source retains the box until its handler runs.
private final class CoreHandle: @unchecked Sendable {
    private(set) var pointer: OpaquePointer?
    init(_ pointer: OpaquePointer) { self.pointer = pointer }
    func destroy() {
        if let pointer { fx_core_destroy(pointer); self.pointer = nil }
    }
    deinit { destroy() }
}

actor NativeTransport: CoreTransport {
    nonisolated let output: AsyncThrowingStream<Data, any Error>
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
    private let handle: CoreHandle
    private let httpClient: any FxHTTPClient
    private var source: (any DispatchSourceRead)?
    private var fetchTasks: [Int32: Task<Void, Never>] = [:]
    private var closed = false
    private let sourceClosed: AsyncStream<Void>
    private let sourceClosedContinuation: AsyncStream<Void>.Continuation

    init(options: JSONValue, httpClient: any FxHTTPClient = FxURLSessionHTTPClient()) throws {
        guard fx_core_abi_version() == 1 else { throw FxError.protocolViolation("Unsupported core ABI version") }
        self.httpClient = httpClient
        let data = try JSONEncoder().encode(options)
        var failure = FxBuffer()
        let pointer = data.withUnsafeBytes {
            fx_core_create($0.bindMemory(to: UInt8.self).baseAddress, data.count, &failure)
        }
        defer { fx_buffer_free(failure) }
        guard let pointer else {
            let error = failure.data.map { String(decoding: UnsafeBufferPointer(start: $0, count: failure.len), as: UTF8.self) } ?? "Cannot create core"
            throw FxError.transport(error)
        }
        handle = CoreHandle(pointer)
        (sourceClosed, sourceClosedContinuation) = AsyncStream.makeStream()
        (output, continuation) = AsyncThrowingStream.makeStream(bufferingPolicy: .bufferingOldest(256))
    }

    func start() throws {
        guard source == nil, !closed else { return }
        let fd = fx_core_ready_fd(handle.pointer)
        guard fd >= 0 else { throw FxError.transport("Core has no readiness descriptor") }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .userInitiated))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.pump() }
        }
        source.setCancelHandler { [handle, sourceClosedContinuation] in
            withExtendedLifetime(handle) { sourceClosedContinuation.finish() }
        }
        self.source = source
        source.resume()
        pump()
    }

    func write(_ data: Data) throws {
        guard !closed else { throw FxError.closed }
        let status = data.withUnsafeBytes {
            fx_core_write(handle.pointer, $0.bindMemory(to: UInt8.self).baseAddress, data.count)
        }
        guard status == 0 else { throw FxError.transport("Core input rejected") }
    }

    private func pump() {
        guard !closed else { return }
        let fd = fx_core_ready_fd(handle.pointer)
        var wake = [UInt8](repeating: 0, count: 256)
        while read(fd, &wake, wake.count) > 0 {}
        do {
            while true {
                var buffer = FxBuffer()
                let status = fx_core_drain(handle.pointer, &buffer)
                let data = consume(buffer)
                guard status >= 0 else { throw FxError.transport("Cannot drain core") }
                if data.isEmpty { break }
                if case .dropped = continuation.yield(data) { throw FxError.outputOverflow }
            }
            for (id, task) in fetchTasks where fx_core_fetch_disposition(handle.pointer, id) != 1 {
                task.cancel()
                fetchTasks.removeValue(forKey: id)
            }
            while true {
                var metadata = FxBuffer(), body = FxBuffer()
                let status = fx_core_take_fetch(handle.pointer, &metadata, &body)
                let metadataData = consume(metadata), bodyData = consume(body)
                guard status >= 0 else { throw FxError.transport("Cannot read model request") }
                if status == 0 { break }
                let value = try JSONDecoder().decode(JSONValue.self, from: metadataData)
                guard let id = value["handle"]?.integer, let urlText = value["url"]?.string,
                      let url = URL(string: urlText), let method = value["method"]?.string else {
                    throw FxError.protocolViolation("Invalid model request")
                }
                var request = URLRequest(url: url)
                request.httpMethod = method
                if !bodyData.isEmpty { request.httpBody = bodyData }
                if let text = value["headers"]?.string,
                   case .array(let headers) = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) {
                    for header in headers {
                        if let name = header["name"]?.string { request.setValue(header["value"]?.string, forHTTPHeaderField: name) }
                    }
                }
                let fetchID = Int32(id)
                fetchTasks[fetchID] = Task { [weak self, request] in
                    await self?.fetch(request, id: fetchID)
                }
            }
            if fx_core_exited(handle.pointer) != 0 {
                let code = fx_core_exit_code(handle.pointer)
                shutdown(code == 0 ? nil : FxError.transport("Core exited with code \(code)"))
            }
        } catch { shutdown(error) }
    }

    private func consume(_ buffer: FxBuffer) -> Data {
        defer { fx_buffer_free(buffer) }
        guard let pointer = buffer.data, buffer.len > 0 else { return Data() }
        return Data(bytes: pointer, count: buffer.len)
    }

    private func fetch(_ request: URLRequest, id: Int32) async {
        defer { fetchTasks.removeValue(forKey: id) }
        do {
            let response = try await sendWithRetry(request)
            defer { response.cancel() }
            guard !closed, !Task.isCancelled else { return }
            guard let status = UInt16(exactly: response.statusCode) else {
                throw FxError.transport("Invalid HTTP response status")
            }
            guard fx_core_start_fetch(handle.pointer, id, status) == 1 else { return }
            for try await data in response.body {
                try Task.checkCancellation()
                guard !closed else { return }
                // Host clients may provide a larger chunk than the bounded C queue.
                var offset = 0
                while offset < data.count {
                    let length = min(16 * 1024, data.count - offset)
                    try await push(data.subdata(in: offset..<(offset + length)), id: id)
                    offset += length
                }
            }
            if !closed { _ = fx_core_finish_fetch(handle.pointer, id) }
        } catch {
            if !closed { _ = fx_core_fail_fetch(handle.pointer, id) }
        }
    }

    private func sendWithRetry(_ request: URLRequest) async throws -> FxHTTPResponse {
        try Task.checkCancellation()
        do { return try await httpClient.send(request) }
        catch {
            try Task.checkCancellation()
            guard !closed else { throw FxError.closed }
            if error is CancellationError || error as? FxError == .cancelled { throw error }
            if case FxError.invalidInput = error { throw error }
            if error is FxSubscriptionError { throw error }
            if let error = error as? URLError, error.code == .cancelled { throw error }
            // Retry only before response headers. Never replay a partial response.
            return try await httpClient.send(request)
        }
    }

    private func push(_ data: Data, id: Int32) async throws {
        while !closed {
            try Task.checkCancellation()
            let status = data.withUnsafeBytes {
                fx_core_push_fetch(handle.pointer, id, $0.bindMemory(to: UInt8.self).baseAddress, data.count)
            }
            if status == 1 { return }
            if status == 0 { throw FxError.cancelled }
            guard status == 2 else { throw FxError.transport("Cannot deliver model response") }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw FxError.closed
    }

    func putAttachment(_ data: Data, id: UInt32) throws {
        guard !closed else { throw FxError.closed }
        let status = data.withUnsafeBytes {
            fx_core_write_attachment(handle.pointer, id, $0.bindMemory(to: UInt8.self).baseAddress, data.count)
        }
        guard status == 0 else { throw FxError.transport("Cannot stage attachment") }
    }

    func takeAttachment(id: UInt32) throws -> Data {
        guard !closed else { throw FxError.closed }
        var buffer = FxBuffer()
        let status = fx_core_take_attachment(handle.pointer, id, &buffer)
        let data = consume(buffer)
        guard status == 1 else { throw FxError.transport("Attachment unavailable") }
        return data
    }

    func discardAttachments() {
        if !closed { fx_core_discard_attachments(handle.pointer) }
    }

    func abortEffects() {
        for task in fetchTasks.values { task.cancel() }
        fetchTasks.removeAll()
        if !closed { fx_core_abort_fetch(handle.pointer) }
    }

    private func shutdown(_ error: (any Error)?) {
        guard !closed else { return }
        abortEffects()
        closed = true
        fx_core_close(handle.pointer)
        if let source { source.cancel() }
        else { handle.destroy(); sourceClosedContinuation.finish() }
        source = nil
        if let error { continuation.finish(throwing: error) }
        else { continuation.finish() }
    }

    func close() async {
        shutdown(nil)
        for await _ in sourceClosed {}
        handle.destroy()
    }
}
