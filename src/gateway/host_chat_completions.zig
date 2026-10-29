//! A configured OpenAI-compatible provider's requests sent through a host
//! transport, for runtimes such as libfx whose network access belongs to the
//! host. The request, the declared models and the reply parsing are the CLI's
//! own; only the HTTP client differs. The host adds the API key, if any.
const std = @import("std");
const stream_provider = @import("../core/agent/stream_provider.zig");
const provider_set = @import("../core/gateway/provider_set.zig");
const definitions = @import("../core/config/configured_provider.zig");
const chat_completions = @import("chat_completions.zig");
const host_stream = @import("host_stream_provider.zig");

const anthropic = @import("anthropic_protocol.zig");

const Allocator = std.mem.Allocator;

pub const Context = struct {
    transport: host_stream.Transport,
    /// The one provider this runtime may use. Owned; free with `deinit`.
    registry: definitions.Registry,

    /// Parses `json`, a settings-style providers object that must define
    /// exactly one provider and give it no credentials of its own.
    pub fn init(alloc: Allocator, transport: host_stream.Transport, json: []const u8) !Context {
        var registry = try definitions.Registry.parse_json(alloc, json);
        errdefer registry.deinit(alloc);
        if (registry.definitions.len != 1 or registry.definitions[0].auth != .none) {
            return error.InvalidConfiguredProvider;
        }
        return .{ .transport = transport, .registry = registry };
    }

    pub fn deinit(self: *Context, alloc: Allocator) void {
        self.registry.deinit(alloc);
    }

    pub fn definition(self: *const Context) *const definitions.Definition {
        return &self.registry.definitions[0];
    }
};

/// A `provider_set.Set.configured_fn` for a `*Context`. `definition` is the
/// engine's copy of a configured provider; a provider other than the context's
/// own gets an empty bundle, so its requests fail instead of reaching this host.
pub fn bundle(raw: ?*anyopaque, definition: *const definitions.Definition) provider_set.Bundle {
    const context: *Context = @ptrCast(@alignCast(raw orelse return .{}));
    const own = context.definition();
    if (!std.mem.eql(u8, &own.binding_identity(), &definition.binding_identity())) return .{};
    return .{
        .agent_stream = .{
            .context = context,
            .stream_fn = stream,
            .build_request_fn = buildRequest,
            .project_replay_fn = if (own.protocol == .@"openai-responses") @import("responses_protocol.zig").selectReplayParts else chat_completions.project_replay,
        },
        .model_catalog = chat_completions.model_catalog_provider(own),
        .fallback_model_capabilities_fn = chat_completions.fallbackCapabilities,
    };
}

fn buildRequest(raw: ?*anyopaque, alloc: Allocator, request: stream_provider.RequestData) anyerror![]u8 {
    const context: *Context = @ptrCast(@alignCast(raw.?));
    return chat_completions.build_for(context.definition(), alloc, request);
}

fn stream(raw: ?*anyopaque, alloc: Allocator, request: stream_provider.ModelRequest) anyerror!stream_provider.Result {
    const context: *Context = @ptrCast(@alignCast(raw.?));
    if (context.definition().protocol == .@"anthropic-messages") return anthropic.negotiate(raw, alloc, request, context.definition().id, buildRequest, streamOnce);
    return streamOnce(raw, alloc, request);
}

fn streamOnce(raw: ?*anyopaque, alloc: Allocator, request: stream_provider.ModelRequest) anyerror!stream_provider.Result {
    if (host_stream.deadlineExpired(request.deadline)) return error.Timeout;
    if (request.cancel_flag.load(.seq_cst)) return stream_provider.failResult(error.Cancelled);
    // The engine never holds this provider's key; the host adds it.
    if (request.credential.credentialSource() != .host_managed) {
        return stream_provider.failResult(error.ConfiguredProviderCredentialRequired);
    }
    const context: *Context = @ptrCast(@alignCast(raw.?));
    const transport = context.transport;
    const definition = context.definition();
    const payload = request.prepared_request_body orelse
        try chat_completions.build_for(definition, alloc, request.data());
    defer if (request.prepared_request_body == null) alloc.free(payload);
    const endpoint = try definition.chat_url(alloc);
    defer alloc.free(endpoint);
    const headers = [_]std.http.Header{
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "accept", .value = "text/event-stream" },
    };

    const opened = try host_stream.openPost(alloc, transport, request, endpoint, if (definition.protocol == .@"anthropic-messages") anthropic.headers[0..(if (request.deferred_tool_mode == .native) @as(usize, 4) else 3)] else &headers, payload);
    defer transport.close(opened.handle);
    if (opened.status != .ok) return .{ .failed = .{
        .http_status = @intCast(@backingInt(opened.status)),
        .kind = chat_completions.failure_kind(opened.status),
        .detail = try host_stream.readErrorBody(alloc, transport, opened.handle, request),
        .ownership = .owned,
    } };

    var reader: host_stream.HostStreamReader = undefined;
    reader.init(transport, opened.handle, request.cancel_flag, request.deadline, request.cooperative_pulse);
    const result = (if (definition.protocol == .@"anthropic-messages") anthropic.consume(alloc, &reader.interface, request, null) else if (definition.protocol == .@"openai-responses") @import("configured_responses.zig").consume(alloc, request, &reader.interface, null) else chat_completions.consume(alloc, &reader.interface, request, null)) catch |err| switch (err) {
        error.ReadFailed => return host_stream.readFailure(&reader, request.cancel_flag),
        else => return err,
    };
    switch (result) {
        .completed => |completed| host_stream.signalConsumed(transport, opened.handle, request, completed.completion),
        else => {},
    }
    return result;
}

const FakeTransport = @import("host_transport_testing.zig").FakeTransport;

const test_provider =
    \\{"local":{"protocol":"openai-chat-completions","base_url":"https://models.example/v1/","auth":{"type":"none"},
    \\"model_metadata":{"local-model":{"context_window":8192,"supports_tool_use":true}}}}
;

const reply_sse =
    "data: {\"id\":\"chat-1\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"libfx on a custom provider\"},\"finish_reason\":null}]}\n\n" ++
    "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
    "data: [DONE]\n\n";

test "host chat completions posts the CLI's request to the provider's base URL without credentials" {
    const alloc = std.testing.allocator;
    var fake = FakeTransport{ .model = "local-model", .responses = &.{.{ .status = 200, .body = reply_sse }} };
    defer fake.deinit();
    var context = try Context.init(alloc, fake.transport(), test_provider);
    defer context.deinit(alloc);
    const agent_stream = bundle(&context, context.definition()).agent_stream.?;
    var result = try agent_stream.stream(alloc, fake.request(.host_managed));
    defer result.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expectEqualStrings("POST", fake.methods[0]);
    try std.testing.expectEqualStrings("https://models.example/v1/chat/completions", fake.urls[0]);
    try std.testing.expectEqualStrings(
        "[{\"name\":\"content-type\",\"value\":\"application/json\"},{\"name\":\"accept\",\"value\":\"text/event-stream\"}]",
        fake.headers[0],
    );
    try std.testing.expectEqualStrings(fake.prepared_body, fake.bodies[0]);
    try std.testing.expectEqualStrings("libfx on a custom provider", result.completed.completion.content.?);
    try std.testing.expectEqual(@as(usize, 1), fake.consumed);
    try std.testing.expectEqual(fake.calls, fake.closed);
}

test "host chat completions returns the error status and body of a rejected request" {
    const alloc = std.testing.allocator;
    var fake = FakeTransport{ .model = "local-model", .responses = &.{.{ .status = 401, .body = "{\"error\":\"invalid key\"}" }} };
    defer fake.deinit();
    var context = try Context.init(alloc, fake.transport(), test_provider);
    defer context.deinit(alloc);
    var result = try bundle(&context, context.definition()).agent_stream.?.stream(alloc, fake.request(.host_managed));
    defer result.deinit(alloc);

    try std.testing.expectEqual(stream_provider.FailureKind.unauthorized, result.failed.kind);
    try std.testing.expectEqualStrings("{\"error\":\"invalid key\"}", result.failed.detail.?);
    try std.testing.expectEqual(@as(usize, 0), fake.consumed);
    try std.testing.expectEqual(fake.calls, fake.closed);
}

test "host chat completions refuses a credential held by the engine without sending" {
    const alloc = std.testing.allocator;
    var fake = FakeTransport{ .model = "local-model", .responses = &.{.{ .status = 200, .body = reply_sse }} };
    defer fake.deinit();
    var context = try Context.init(alloc, fake.transport(), test_provider);
    defer context.deinit(alloc);
    const lease: stream_provider.CredentialLease = .{ .direct = .{ .secret_bytes = "provider-key", .source = .configured } };
    try std.testing.expectError(
        error.ConfiguredProviderCredentialRequired,
        bundle(&context, context.definition()).agent_stream.?.stream(alloc, fake.request(lease)),
    );
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
}

test "host chat completions serves only its own provider and lists the declared models" {
    const alloc = std.testing.allocator;
    var fake = FakeTransport{ .responses = &.{} };
    defer fake.deinit();
    var context = try Context.init(alloc, fake.transport(), test_provider);
    defer context.deinit(alloc);

    // The engine parses its own copy of the same settings.
    var same = try definitions.Registry.parse_json(alloc, test_provider);
    defer same.deinit(alloc);
    const served = bundle(&context, &same.definitions[0]);
    try std.testing.expect(served.agent_stream != null);
    var listed = try served.model_catalog.?.fetch(alloc, .{ .endpoint = "unused" });
    defer @import("../core/gateway/model_catalog.zig").freeModelCatalog(alloc, &listed.catalog);
    try std.testing.expectEqual(@as(usize, 1), listed.catalog.items.len);
    try std.testing.expectEqualStrings("local-model", listed.catalog.items[0].id);

    var moved = try definitions.Registry.parse_json(alloc,
        \\{"local":{"protocol":"openai-chat-completions","base_url":"https://elsewhere.example/v1","auth":{"type":"none"}}}
    );
    defer moved.deinit(alloc);
    try std.testing.expect(bundle(&context, &moved.definitions[0]).agent_stream == null);
    try std.testing.expect(bundle(null, &same.definitions[0]).agent_stream == null);
}

test "host chat completions context refuses settings it cannot honor" {
    const alloc = std.testing.allocator;
    var fake = FakeTransport{ .responses = &.{} };
    defer fake.deinit();
    for ([_][]const u8{
        \\{}
        ,
        \\{"one":{"protocol":"openai-chat-completions","base_url":"https://a.example/v1","auth":{"type":"none"}},
        \\"two":{"protocol":"openai-chat-completions","base_url":"https://b.example/v1","auth":{"type":"none"}}}
        ,
        \\{"keyed":{"protocol":"openai-chat-completions","base_url":"https://a.example/v1","auth":{"type":"bearer","env":"PROVIDER_KEY"}}}
    }) |json| {
        try std.testing.expectError(error.InvalidConfiguredProvider, Context.init(alloc, fake.transport(), json));
    }
    try std.testing.expectError(error.InsecureBaseUrl, Context.init(alloc, fake.transport(),
        \\{"plain":{"protocol":"openai-chat-completions","base_url":"http://models.example/v1","auth":{"type":"none"}}}
    ));
}

test "host configured Responses binds endpoint and retains cached usage" {
    const alloc = std.testing.allocator;
    const body = "data: {\"type\":\"response.output_text.delta\",\"output_index\":0,\"delta\":\"hello\"}\n\n" ++
        "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"usage\":{\"input_tokens\":128,\"output_tokens\":3,\"input_tokens_details\":{\"cached_tokens\":64}}}}\n\n";
    var fake = FakeTransport{ .model = "local-model", .responses = &.{.{ .status = 200, .body = body }} };
    defer fake.deinit();
    var context = try Context.init(alloc, fake.transport(),
        \\{"local":{"protocol":"openai-responses","base_url":"https://models.example/v1","auth":{"type":"none"},"model_metadata":{"local-model":{"supports_tool_use":true}}}}
    );
    defer context.deinit(alloc);
    const provider = bundle(&context, context.definition()).agent_stream.?;
    var request = fake.request(.host_managed);
    request.prepared_request_body = null;
    var result = try provider.stream(alloc, request);
    defer result.deinit(alloc);
    try std.testing.expectEqualStrings("https://models.example/v1/responses", fake.urls[0]);
    try std.testing.expect(std.mem.find(u8, fake.bodies[0], "\"input\":[") != null);
    try std.testing.expectEqual(@as(?u64, 64), result.completed.completion.usage.cache_read_tokens);
    try std.testing.expectEqualStrings("hello", result.completed.completion.content.?);
}

test "deferred Messages negotiate HTTP status and checkpoint only successful modes" {
    const alloc = std.testing.allocator;
    const Mode = @import("../core/agent/deferred_tool_mode.zig").Mode;
    const Agent = @import("../core/agent/runtime/agent.zig").Agent;
    const success = "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"ok\"}}\n\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}\n\ndata: {\"type\":\"message_stop\"}\n\n";
    const cases = [_]struct { statuses: []const u16, initial: Mode = .native, expected: Mode, deferred: bool = true }{
        .{ .statuses = &.{ 422, 200 }, .expected = .reference },
        .{ .statuses = &.{ 422, 400, 200 }, .expected = .call_tool },
        .{ .statuses = &.{ 400, 503 }, .expected = .native },
        .{ .statuses = &.{ 422, 400, 422 }, .expected = .native },
        .{ .statuses = &.{400}, .expected = .native, .deferred = false },
        .{ .statuses = &.{ 400, 200 }, .initial = .reference, .expected = .call_tool },
    };
    for (cases) |case| {
        var replies: [4]FakeTransport.Response = undefined;
        for (case.statuses, 0..) |status, i| replies[i] = .{ .status = status, .body = if (status == 200) success else "arbitrary failure" };
        var fake: FakeTransport = .{ .responses = replies[0..case.statuses.len] };
        defer fake.deinit();
        var context = try Context.init(alloc, fake.transport(), "{\"local\":{\"protocol\":\"anthropic-messages\",\"base_url\":\"https://models.example/v1\",\"auth\":{\"type\":\"none\"}}}");
        defer context.deinit(alloc);
        var agent: Agent = .{ .deferred_tool_mode = case.initial };
        defer agent.deinit(alloc);
        var request = fake.request(.host_managed);
        request.prepared_request_body = null;
        request.deferred_tool_mode = agent.deferred_tool_mode;
        request.negotiated_deferred_tool_mode = &agent.deferred_tool_mode;
        request.tools = .{ .advertised_names = &.{ "tool_search", "call_tool" }, .advertised_functions = &.{ .{ .name = "tool_search", .description = "Search" }, .{ .name = "call_tool", .description = "Call a deferred tool by name" } } };
        request.messages = if (case.deferred) &.{
            .{ .role = .assistant, .tool_calls = &.{.{ .id = "search", .name = "tool_search", .arguments_json = "{}" }} },
            .{ .role = .tool, .tool_call_id = "search", .content = "Found", .tool_result_memory = .{ .loaded_tools_json = "[{\"name\":\"found\",\"description\":\"Found\",\"inputSchema\":{\"type\":\"object\"}}]" } },
        } else &.{.{ .role = .user, .content = "Hello" }};
        var result = try @import("../core/agent/runtime/gateway_step.zig").streamModelCompletion(bundle(&context, context.definition()).agent_stream.?, alloc, request);
        defer result.deinit(alloc);
        try std.testing.expectEqual(case.statuses.len, fake.calls);
        try std.testing.expectEqual(fake.calls, fake.closed);
        try std.testing.expectEqual(case.expected, agent.deferred_tool_mode);
        if (case.statuses[case.statuses.len - 1] != 200) try std.testing.expectEqual(case.statuses[case.statuses.len - 1], result.failed.http_status.?);
        for (0..fake.calls) |i| {
            const native = case.initial == .native and i == 0;
            try std.testing.expectEqual(native, std.mem.find(u8, fake.headers[i], "anthropic-beta") != null);
        }
        const checkpoint = try agent.checkpoint(alloc, .{});
        defer alloc.free(checkpoint);
        var restored: Agent = .{};
        defer restored.deinit(alloc);
        const meta = try restored.restoreCheckpoint(alloc, checkpoint);
        defer meta.free(alloc);
        try std.testing.expectEqual(case.expected, restored.deferred_tool_mode);
        if (case.expected == .reference) {
            // Reopened conversation sends reference immediately, without another native rejection.
            request.deferred_tool_mode = restored.deferred_tool_mode;
            const body = try buildRequest(&context, alloc, request.data());
            defer alloc.free(body);
            try std.testing.expect(std.mem.find(u8, body, "tool_reference") != null);
            try std.testing.expect(std.mem.find(u8, body, "tool_addition") == null);
        }
    }
}

test "deferred summary forks commit negotiation once and reuse the learned mode" {
    const alloc = std.testing.allocator;
    const Mode = @import("../core/agent/deferred_tool_mode.zig").Mode;
    const Host = struct {
        saved: Mode = .native,
        commits: usize = 0,
        memory: ?*Mode = null,
        fn save(raw: *anyopaque, mode: Mode) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (self.memory) |current| try std.testing.expectEqual(mode, current.*);
            self.saved = mode;
            self.commits += 1;
        }
        fn capabilities(_: *anyopaque, _: []const u8) @import("../core/config/model_capabilities.zig").Capabilities {
            return .{};
        }
    };
    var host: Host = .{};
    var mode: Mode = .native;
    host.memory = &mode;
    const success = "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"ok\"}}\n\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}\n\ndata: {\"type\":\"message_stop\"}\n\n";
    var fake: FakeTransport = .{ .responses = &.{ .{ .status = 422, .body = "rejected" }, .{ .status = 200, .body = success }, .{ .status = 200, .body = success } } };
    defer fake.deinit();
    var context = try Context.init(alloc, fake.transport(), "{\"local\":{\"protocol\":\"anthropic-messages\",\"base_url\":\"https://models.example/v1\",\"auth\":{\"type\":\"none\"}}}");
    defer context.deinit(alloc);
    var caller_state: @import("../core/agent/runtime/text_completion.zig").CompactorCaller = .{
        .negotiated_deferred_tool_mode = &mode,
        .deferred_tool_mode_commit = .{ .context = &host, .save_fn = Host.save },
        .stream_provider = bundle(&context, context.definition()).agent_stream.?,
        .provider = .gateway,
        .model = fake.model,
        .api_key = "",
        .credential_source = .host_managed,
        .retry_count = 0,
        .capabilities_context = &host,
        .capabilities_fn = Host.capabilities,
        .conversation = .{
            .model = fake.model,
            .instructions = &.{.{ .role = .system, .content = "Stable" }},
            .messages = &.{
                .{ .role = .assistant, .tool_calls = &.{.{ .id = "s", .name = "tool_search", .arguments_json = "{}" }} },
                .{ .role = .tool, .tool_call_id = "s", .content = "Found", .tool_result_memory = .{ .loaded_tools_json = "[{\"name\":\"found\",\"description\":\"Found\",\"inputSchema\":{\"type\":\"object\"}}]" } },
            },
            .tools = .{ .advertised_names = &.{"tool_search"}, .advertised_functions = &.{.{ .name = "tool_search", .description = "Search" }} },
            .tool_choice = .auto,
            .provider_options = .{},
        },
    };
    const caller = caller_state.caller();
    const call: @import("../core/compactor/compactor.zig").Call = .{ .model = fake.model, .reasoning = null, .system = "unused", .user = "Summarize", .after_conversation = true, .max_bytes = 1024, .cancel_flag = &fake.cancel_flag, .trace_ctx = .{} };
    for (0..2) |_| {
        const reply = try caller.vtable.send(caller.context, alloc, call);
        defer switch (reply) {
            .text => |text| alloc.free(text),
            .failed => |failure| alloc.free(failure.detail),
        };
        try std.testing.expect(reply == .text);
        try std.testing.expectEqualStrings("ok", reply.text);
        try std.testing.expectEqual(Mode.reference, mode);
        try std.testing.expectEqual(Mode.reference, host.saved);
        try std.testing.expectEqual(@as(usize, 1), host.commits);
    }
    try std.testing.expectEqual(@as(usize, 3), fake.calls);
    try std.testing.expectEqualStrings(fake.bodies[1], fake.bodies[2]);
}
