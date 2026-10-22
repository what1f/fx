import Foundation
import LibFx
import MCP

public enum FxMCPError: Error, Sendable, Equatable {
    case invalidServerName
    case invalidPrefix
    case invalidCatalog
    case invalidPagination
    case instructionsTooLarge
    case invalidArguments
    case invalidImage
    case closed
}

/// Tools and text context from one MCP server. Closing disconnects its client.
public struct FxMCPAdapter: Sendable {
    public struct Prompt: Sendable {
        public let name: String
        public let arguments: [String: String]?
        public init(name: String, arguments: [String: String]? = nil) {
            self.name = name
            self.arguments = arguments
        }
    }

    public let tools: [FxTool]
    public let instructions: String
    private let connection: MCPConnection

    /// Connect using an official MCP transport configured by the host.
    public static func connect(transport: any Transport, client: Client? = nil, prefix: String = "", resources: [String] = [],
                               prompts: [Prompt] = [], propagateCorrelation: Bool = false, serverName: String? = nil) async throws -> FxMCPAdapter {
        if let serverName, serverName.isEmpty || serverName.utf8.count > 1024 { throw FxMCPError.invalidServerName }
        guard prefix.utf8.allSatisfy(isNameByte) else { throw FxMCPError.invalidPrefix }
        let wrapped = CancellableTransport(transport, logger: await transport.logger)
        let client = client ?? Client(name: "libfx-swift", version: "1")
        let connection = MCPConnection(client: client, transport: wrapped)
        return try await withTaskCancellationHandler { do {
            try Task.checkCancellation()
            let initialized = try await client.connect(transport: wrapped)
            let adapter = try await build(connection: connection, prefix: prefix, resources: resources,
                                          prompts: prompts, propagateCorrelation: propagateCorrelation,
                                          serverName: serverName ?? initialized.serverInfo.name)
            try Task.checkCancellation()
            return adapter
        } catch {
            await wrapped.disconnect()
            await connection.close()
            if Task.isCancelled { throw CancellationError() }
            throw error
        } } onCancel: {
            Task { await wrapped.disconnect(); await client.disconnect() }
        }
    }

    public func close() async { await connection.close() }

    private static func build(connection: MCPConnection, prefix: String, resources: [String],
                              prompts: [Prompt], propagateCorrelation: Bool, serverName: String) async throws -> FxMCPAdapter {
        var catalog: [Tool] = []
        var cursors: Set<String> = []
        var cursor: String?
        for page in 0...64 {
            guard page < 64 else { throw FxMCPError.invalidPagination }
            let result = try await connection.request(ListTools.request(cursor.map { .init(cursor: $0) } ?? .init()))
            guard catalog.count + result.tools.count <= 64 else { throw FxMCPError.invalidCatalog }
            catalog.append(contentsOf: result.tools)
            guard let next = result.nextCursor else { break }
            guard next.utf8.count <= 4096, cursors.insert(next).inserted else { throw FxMCPError.invalidPagination }
            cursor = next
        }
        var remoteNames: Set<String> = []
        var localNames: Set<String> = []
        let tools = try catalog.map { tool in
            guard !tool.name.isEmpty, tool.name.count <= 256, remoteNames.insert(tool.name).inserted else {
                throw FxMCPError.invalidCatalog
            }
            let base = prefix + String(tool.name.unicodeScalars.map { scalar in
                scalar.isASCII && isNameByte(UInt8(scalar.value)) ? Character(String(scalar)) : "_"
            })
            var name = String(base.prefix(64))
            var suffix = 2
            while !localNames.insert(name).inserted {
                let tail = "_\(suffix)"
                name = String(base.prefix(64 - tail.count)) + tail
                suffix += 1
            }
            return FxTool(name: name, description: tool.description.flatMap { $0.isEmpty ? nil : $0 } ?? "MCP tool",
                          inputSchema: try convert(tool.inputSchema, to: JSONValue.self), isIdempotent: false) { input, context in
                guard case .object = input else { throw FxMCPError.invalidArguments }
                let arguments = try convert(input, to: [String: Value].self)
                let correlationID = propagateCorrelation ? UUID().uuidString.lowercased() : nil
                let meta: Metadata? = try correlationID.map { id in
                    try convert(JSONValue.object(["libfx/correlationId": .string(id)]), to: Metadata.self)
                }
                let request = CallTool.request(.init(name: tool.name, arguments: arguments, meta: meta))
                let result: CallTool.Result
                if let observation = context.observation {
                    let server = !serverName.isEmpty && serverName.utf8.count <= 1024 ? serverName : nil
                    result = try await observation.mcp(server: server, tool: tool.name, correlationID: correlationID,
                                                       isError: { $0.isError == true }) {
                        try await connection.request(request)
                    }
                } else {
                    result = try await connection.request(request)
                }
                return try toolResult(result)
            }
        }
        var sections: [String] = []
        var bytes = 0
        func append(_ label: String, _ text: String) throws {
            guard !text.isEmpty else { return }
            let section = "<\(label)>\n\(text)\n</\(label)>"
            bytes += section.utf8.count + (sections.isEmpty ? 0 : 2)
            guard bytes <= 64 * 1024 else { throw FxMCPError.instructionsTooLarge }
            sections.append(section)
        }
        for uri in resources {
            let result = try await connection.request(ReadResource.request(.init(uri: uri)))
            try append("mcp_resource", result.contents.compactMap { $0.text ?? ($0.blob == nil ? nil : omittedContext) }.filter { !$0.isEmpty }.joined(separator: "\n"))
        }
        for prompt in prompts {
            let result = try await connection.request(GetPrompt.request(.init(name: prompt.name, arguments: prompt.arguments)))
            let text = result.messages.map { message -> String in
                switch message.content {
                case .text(let text): return text
                case .resource(let resource, _, _): return resource.text ?? (resource.blob == nil ? "" : omittedContext)
                case .resourceLink(let uri, let name, _, _, _, _): return "\(name): \(uri)"
                case .image, .audio: return omittedContext
                }
            }.filter { !$0.isEmpty }.joined(separator: "\n")
            try append("mcp_prompt", text)
        }
        return FxMCPAdapter(tools: tools, instructions: sections.joined(separator: "\n\n"), connection: connection)
    }

    private static let omittedContext = "[Non-text MCP context is not included in these text instructions.]"

    private static func isNameByte(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || byte == 95 || byte == 45
    }

    private static func convert<T: Encodable, U: Decodable>(_ value: T, to: U.Type) throws -> U {
        try JSONDecoder().decode(U.self, from: JSONEncoder().encode(value))
    }

    static func toolResult(_ result: CallTool.Result) throws -> FxToolResult {
        var texts: [String] = []
        var images: [FxImage] = []
        func image(_ data: String, _ mimeType: String) throws {
            guard let format = FxImageFormat(rawValue: mimeType), let bytes = Data(base64Encoded: data) else { throw FxMCPError.invalidImage }
            images.append(FxImage(data: bytes, format: format))
        }
        for content in result.content {
            switch content {
            case .text(let text, _, _): if !text.isEmpty { texts.append(text) }
            case .image(let data, let mimeType, _, _): try image(data, mimeType)
            case .resource(let resource, _, _):
                if let text = resource.text, !text.isEmpty { texts.append(text) }
                if let blob = resource.blob, let mimeType = resource.mimeType, mimeType.hasPrefix("image/") { try image(blob, mimeType) }
            case .resourceLink(let uri, let name, _, _, _, _): texts.append("\(name): \(uri)")
            case .audio: break
            }
        }
        var text = texts.joined(separator: "\n")
        if let structured = result.structuredContent {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let json = String(decoding: try encoder.encode(structured), as: UTF8.self)
            if text.isEmpty || text == json { text = json } else { text += "\n" + json }
        }
        return FxToolResult(text: text, images: images, isError: result.isError == true)
    }
}

private actor MCPConnection {
    let client: Client
    let transport: CancellableTransport
    private var closing: Task<Void, Never>?
    init(client: Client, transport: CancellableTransport) { self.client = client; self.transport = transport }

    func request<M: MCP.Method>(_ request: Request<M>) async throws -> M.Result {
        guard closing == nil else { throw FxMCPError.closed }
        try Task.checkCancellation()
        await transport.register(request.id)
        let context: RequestContext<M.Result>
        do { context = try await client.send(request) }
        catch {
            await transport.discard(request.id)
            if Task.isCancelled { throw CancellationError() }
            if closing != nil { throw FxMCPError.closed }
            throw error
        }
        return try await withTaskCancellationHandler {
            do {
                let result = try await context.value
                try Task.checkCancellation()
                guard closing == nil else { throw FxMCPError.closed }
                return result
            } catch {
                if Task.isCancelled { throw CancellationError() }
                if closing != nil { throw FxMCPError.closed }
                throw error
            }
        } onCancel: {
            Task {
                await self.transport.cancel(request.id)
                try? await self.client.cancelRequest(request.id)
            }
        }
    }

    func close() async {
        if let closing { await closing.value; return }
        let task = Task { await client.disconnect() }
        closing = task
        await task.value
    }
}
