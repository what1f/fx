import Foundation
import CoreServices
import os

/// A live catalog refreshed by filesystem events, independent of request rendering.
public actor FxSkillCatalog {
    public nonisolated let updates: AsyncStream<FxSkillDiscovery.Catalog>
    private let output: AsyncStream<FxSkillDiscovery.Catalog>.Continuation
    private let discovery: FxSkillDiscovery
    private var snapshot: FxSkillDiscovery.Catalog
    private var watcher: SkillDirectoryWatcher?
    private var eventsTask: Task<Void, Never>?
    private var paths: [String] = []
    private var closed = false

    private init(roots: [URL]) {
        discovery = FxSkillDiscovery(roots: roots)
        snapshot = discovery.discover()
        let pair = AsyncStream<FxSkillDiscovery.Catalog>.makeStream(bufferingPolicy: .bufferingNewest(1))
        updates = pair.stream; output = pair.continuation
    }
    public static func open(roots: [URL]) async throws -> FxSkillCatalog {
        let catalog = FxSkillCatalog(roots: roots)
        try await catalog.start()
        return catalog
    }
    public func current() -> FxSkillDiscovery.Catalog { snapshot }
    public func close() {
        closed = true
        eventsTask?.cancel(); eventsTask = nil
        watcher?.close(); watcher = nil
        output.finish()
    }
    deinit { eventsTask?.cancel(); watcher?.close(); output.finish() }
    private func start() throws {
        let events = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        try watch(continuation: events.continuation)
        // Cover writes between initial discovery and watcher installation.
        snapshot = discovery.discover()
        try watch(continuation: events.continuation)
        output.yield(snapshot)
        eventsTask = Task { [weak self] in
            for await _ in events.stream {
                guard !Task.isCancelled else { break }
                do { try await self?.refresh(continuation: events.continuation) }
                catch { await self?.close() }
            }
        }
    }
    private func refresh(continuation: AsyncStream<Void>.Continuation) throws {
        guard !closed else { return }
        let next = discovery.discover()
        let changed = next.skills != snapshot.skills || next.diagnostics != snapshot.diagnostics
        snapshot = next
        try watch(continuation: continuation)
        if changed { output.yield(next) }
    }
    private func watch(continuation: AsyncStream<Void>.Continuation) throws {
        // Parents detect removal/recreation of roots. Resolved directories cover
        // symlink targets outside the root, including target-side edits.
        var wanted = Set<String>()
        for root in discovery.roots + snapshot.watchedDirectories {
            var directory = root.deletingLastPathComponent()
            var isDirectory: ObjCBool = false
            while !FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) || !isDirectory.boolValue {
                let parent = directory.deletingLastPathComponent()
                if parent == directory { break }
                directory = parent
            }
            wanted.insert(directory.path)
        }
        let nextPaths = wanted.sorted()
        guard paths != nextPaths else { return }
        let next = try SkillDirectoryWatcher(paths: nextPaths, continuation: continuation)
        watcher?.close(); watcher = next; paths = nextPaths
    }
}

/// The lock guards the native stream lifetime; callback data is immutable and retained
/// by FSEvents itself until all queued callbacks have finished.
private final class SkillDirectoryWatcher: Sendable {
    private struct State { var stream: FSEventStreamRef? }
    private let state: OSAllocatedUnfairLock<State>
    private final class Sink: Sendable {
        let continuation: AsyncStream<Void>.Continuation
        init(_ continuation: AsyncStream<Void>.Continuation) { self.continuation = continuation }
    }
    init(paths: [String], continuation: AsyncStream<Void>.Continuation) throws {
        let sink = Sink(continuation)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(sink).toOpaque(),
            retain: { raw in
                guard let raw else { return nil }
                _ = Unmanaged<Sink>.fromOpaque(raw).retain()
                return UnsafeRawPointer(raw)
            }, release: { raw in
                if let raw { Unmanaged<Sink>.fromOpaque(raw).release() }
            }, copyDescription: nil)
        let stream = FSEventStreamCreate(nil, { _, info, _, _, _, _ in
            if let info { Unmanaged<Sink>.fromOpaque(info).takeUnretainedValue().continuation.yield(()) }
        }, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.15,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot))
        guard let stream else { throw CocoaError(.fileReadUnknown) }
        // The non-Sendable C pointer stays under this lock and never escapes.
        state = OSAllocatedUnfairLock(uncheckedState: State(stream: stream))
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
        guard FSEventStreamStart(stream) else { close(); throw CocoaError(.fileReadUnknown) }
    }
    func close() {
        state.withLockUnchecked { value in
            if let stream = value.stream {
                FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
                value.stream = nil
            }
        }
    }
    deinit { close() }
}
