//! Simulated LLM API server for agent-bench.
//!
//! Serves OpenAI-compatible `POST /v1/chat/completions` with controllable
//! timing profiles (TTFT/TPOT), failure injection, and script mode for
//! trajectory replay. Emits per-request timing logs as JSONL.
//!
//! Usage:
//!   sim-server --profile flash|pro|slow|flaky|zero [--port N]
//!              [--profile-json file] [--script file] [--timing-log file]
//!              [--jitter pct]

const std = @import("std");

const max_request_bytes = 8 * 1024 * 1024;

var next_request_id: std.atomic.Value(u64) = .init(1);
var next_seq: std.atomic.Value(u64) = .init(1);
var next_script_seq: std.atomic.Value(u64) = .init(1);

const Profile = struct {
    name: []const u8,
    ttft_ms: u64,
    tpot_ms: u64,
    fail_500_pct: u64,
    fail_429_pct: u64,
    jitter_pct: u64,
};

const builtin_profiles = [_]Profile{
    .{ .name = "flash", .ttft_ms = 200, .tpot_ms = 8, .fail_500_pct = 0, .fail_429_pct = 0, .jitter_pct = 10 },
    .{ .name = "pro", .ttft_ms = 800, .tpot_ms = 25, .fail_500_pct = 0, .fail_429_pct = 0, .jitter_pct = 10 },
    .{ .name = "slow", .ttft_ms = 2000, .tpot_ms = 80, .fail_500_pct = 0, .fail_429_pct = 0, .jitter_pct = 10 },
    .{ .name = "flaky", .ttft_ms = 800, .tpot_ms = 25, .fail_500_pct = 5, .fail_429_pct = 5, .jitter_pct = 10 },
    .{ .name = "zero", .ttft_ms = 0, .tpot_ms = 0, .fail_500_pct = 0, .fail_429_pct = 0, .jitter_pct = 0 },
};

const Config = struct {
    profile: Profile,
    script_path: ?[]const u8,
    timing_log_path: ?[]const u8,
    port: u16,
};

var g_config: Config = undefined;
var g_script_steps: ?[]ScriptStep = null;
var g_timing_mutex: std.Io.Mutex = .init;
var g_timing_file: ?std.Io.File = null;

const ScriptStep = struct {
    tool_calls: ?[]ScriptToolCall,
    text: []const u8,
    finish: bool,
};

const ScriptToolCall = struct {
    name: []const u8,
    arguments: []const u8,
};

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    g_config = try parseArgs(alloc, init.minimal.args);

    if (g_config.script_path) |path| {
        g_script_steps = try loadScript(alloc, path);
    }

    // Open timing log once at startup to avoid per-request open/stat/close.
    if (g_config.timing_log_path) |path| {
        var f = try std.Io.Dir.cwd().createFile(init.io, path, .{ .truncate = false });
        const st = try f.stat(init.io);
        g_timing_offset = st.size;
        g_timing_file = f;
        // Intentionally not closed until process exit; harness kills the server.
    }

    var address = try std.Io.net.IpAddress.parse("127.0.0.1", g_config.port);
    var listener = try address.listen(init.io, .{ .reuse_address = true });
    defer listener.deinit(init.io);

    var stdout_buffer: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    try stdout.interface.print("{{\"port\":{d}}}\n", .{listener.socket.address.getPort()});
    try stdout.interface.flush();

    while (true) {
        const stream = try listener.accept(init.io);
        const thread = std.Thread.spawn(.{ .stack_size = 512 * 1024 }, serveConnection, .{stream}) catch {
            stream.close(init.io);
            continue;
        };
        thread.detach();
    }
}

fn parseArgs(alloc: std.mem.Allocator, raw_args: std.process.Args) !Config {
    var args = try std.process.Args.Iterator.initAllocator(raw_args, std.heap.page_allocator);
    defer args.deinit();
    _ = args.next();

    var cfg = Config{
        .profile = builtin_profiles[1], // pro
        .script_path = null,
        .timing_log_path = null,
        .port = 0,
    };
    var profile_json: ?[]const u8 = null;
    var jitter_override: ?u64 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--profile")) {
            const name = args.next() orelse return error.InvalidArgument;
            cfg.profile = findProfile(name) orelse return error.UnknownProfile;
        } else if (std.mem.eql(u8, arg, "--profile-json")) {
            profile_json = args.next() orelse return error.InvalidArgument;
        } else if (std.mem.eql(u8, arg, "--script")) {
            cfg.script_path = try alloc.dupe(u8, args.next() orelse return error.InvalidArgument);
        } else if (std.mem.eql(u8, arg, "--timing-log")) {
            cfg.timing_log_path = try alloc.dupe(u8, args.next() orelse return error.InvalidArgument);
        } else if (std.mem.eql(u8, arg, "--port")) {
            const v = args.next() orelse return error.InvalidArgument;
            cfg.port = try std.fmt.parseInt(u16, v, 10);
        } else if (std.mem.eql(u8, arg, "--jitter")) {
            const v = args.next() orelse return error.InvalidArgument;
            jitter_override = try std.fmt.parseInt(u64, v, 10);
        } else {
            return error.InvalidArgument;
        }
    }

    if (profile_json) |path| {
        cfg.profile = try loadProfileJson(alloc, path);
    }
    if (jitter_override) |j| {
        cfg.profile.jitter_pct = j;
    }
    return cfg;
}

fn findProfile(name: []const u8) ?Profile {
    for (builtin_profiles) |p| {
        if (std.mem.eql(u8, p.name, name)) return p;
    }
    return null;
}

fn loadProfileJson(alloc: std.mem.Allocator, path: []const u8) !Profile {
    var io_backend: std.Io.Threaded = .init_single_threaded;
    defer io_backend.deinit();
    const io = io_backend.io();
    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(64 * 1024));
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, data, .{});
    const obj = parsed.value.object;
    return Profile{
        .name = "custom",
        .ttft_ms = @intCast(obj.get("ttft_ms").?.integer),
        .tpot_ms = @intCast(obj.get("tpot_ms").?.integer),
        .fail_500_pct = @intCast(obj.get("fail_500_pct").?.integer),
        .fail_429_pct = @intCast(obj.get("fail_429_pct").?.integer),
        .jitter_pct = @intCast(obj.get("jitter_pct").?.integer),
    };
}

fn loadScript(alloc: std.mem.Allocator, path: []const u8) ![]ScriptStep {
    var io_backend: std.Io.Threaded = .init_single_threaded;
    defer io_backend.deinit();
    const io = io_backend.io();
    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(4 * 1024 * 1024));
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, data, .{});
    const steps_json = parsed.value.object.get("steps").?.array;

    var steps = try alloc.alloc(ScriptStep, steps_json.items.len);
    for (steps_json.items, 0..) |sj, i| {
        const sobj = sj.object;
        var calls: ?[]ScriptToolCall = null;
        if (sobj.get("tool_calls")) |tc| {
            const arr = tc.array;
            calls = try alloc.alloc(ScriptToolCall, arr.items.len);
            for (arr.items, 0..) |cj, j| {
                const cobj = cj.object;
                const args_val = cobj.get("arguments").?;
                var arg_buf: std.Io.Writer.Allocating = .init(alloc);
                defer arg_buf.deinit();
                try std.json.Stringify.value(args_val, .{}, &arg_buf.writer);
                calls.?[j] = .{
                    .name = try alloc.dupe(u8, cobj.get("name").?.string),
                    .arguments = try arg_buf.toOwnedSlice(),
                };
            }
        }
        const text = if (sobj.get("text")) |t| try alloc.dupe(u8, t.string) else try alloc.dupe(u8, "");
        const finish = if (sobj.get("finish")) |f| std.mem.eql(u8, f.string, "stop") else false;
        steps[i] = .{ .tool_calls = calls, .text = text, .finish = finish };
    }
    return steps;
}

fn serveConnection(stream: std.Io.net.Stream) void {
    var io_backend: std.Io.Threaded = .init_single_threaded;
    defer io_backend.deinit();
    serveConnectionFallible(io_backend.io(), stream) catch |err| {
        std.log.err("sim-server failed: {s}", .{@errorName(err)});
    };
}

/// Milliseconds since Unix epoch, via clock_gettime.
fn nowMs() i64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.REALTIME, &ts);    return ts.sec * 1000 + @divTrunc(ts.nsec, 1_000_000);
}

/// Sleep for the given number of milliseconds.
fn sleepMs(ms: u64) void {
    const req: std.os.linux.timespec = .{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * 1_000_000),
    };
    _ = std.os.linux.nanosleep(&req, null);
}

fn applyJitter(profile: Profile, base_ms: u64, rand: std.Random) u64 {
    if (profile.jitter_pct == 0 or base_ms == 0) return base_ms;
    const pct = profile.jitter_pct;
    const delta = base_ms * pct / 100;
    const r = rand.intRangeLessThan(i64, -@as(i64, @intCast(delta)), @as(i64, @intCast(delta)) + 1);
    const out: i64 = @as(i64, @intCast(base_ms)) + r;
    return @intCast(@max(0, out));
}

fn serveConnectionFallible(io: std.Io, stream: std.Io.net.Stream) !void {
    defer stream.close(io);
    const no_delay: c_int = 1;
    try std.posix.setsockopt(stream.socket.handle, std.posix.IPPROTO.TCP, std.posix.TCP.NODELAY, std.mem.asBytes(&no_delay));

    var read_buffer: [64 * 1024]u8 = undefined;
    var write_buffer: [64 * 1024]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    var writer = stream.writer(io, &write_buffer);
    var server = std.http.Server.init(&reader.interface, &writer.interface);

    var prng = std.Random.DefaultPrng.init(@intCast(nowMs()));
    const rand = prng.random();

    while (true) {
        var request = server.receiveHead() catch return;
        const keep_alive = request.head.keep_alive;
        if (request.head.method != .POST or !std.mem.eql(u8, request.head.target, "/v1/chat/completions")) {
            try request.respond("unknown endpoint\n", .{ .status = .not_found, .keep_alive = false });
            return;
        }
        if (request.head.transfer_encoding == .chunked or (request.head.content_length orelse 0) > max_request_bytes) {
            try request.respond("bounded content-length required\n", .{ .status = .payload_too_large, .keep_alive = false });
            return;
        }

        const t_start = nowMs();
        const seq = next_seq.fetchAdd(1, .monotonic);
        var req_body_buf: [8 * 1024]u8 = undefined;
        const req_body = try request.readerExpectContinue(&req_body_buf);
        _ = try req_body.discardRemaining();

        const profile = g_config.profile;

        // Failure injection.
        const roll = rand.intRangeLessThan(u64, 0, 100);
        var status: std.http.Status = .ok;
        if (roll < profile.fail_500_pct) {
            status = .internal_server_error;
        } else if (roll < profile.fail_500_pct + profile.fail_429_pct) {
            status = .too_many_requests;
        }

        var t_first_chunk: i64 = -1;
        var tokens: u64 = 0;

        if (status != .ok) {
            if (status == .too_many_requests) {
                try request.respond("rate limited\n", .{
                    .status = .too_many_requests,
                    .keep_alive = keep_alive,
                    .extra_headers = &[_]std.http.Header{.{ .name = "retry-after", .value = "1" }},
                });
            } else {
                try request.respond("injected failure\n", .{ .status = .internal_server_error, .keep_alive = keep_alive });
            }
        } else {
            const ttft = applyJitter(profile, profile.ttft_ms, rand);
            if (ttft > 0) sleepMs(ttft);

            const headers = [_]std.http.Header{
                .{ .name = "content-type", .value = "text/event-stream" },
                .{ .name = "cache-control", .value = "no-cache" },
            };
            var response_buffer: [64 * 1024]u8 = undefined;
            var response = try request.respondStreaming(&response_buffer, .{
                .respond_options = .{ .keep_alive = keep_alive, .extra_headers = &headers },
            });
            t_first_chunk = nowMs();

            // Script seq only advances on successful responses, so that
            // client retries after injected failures receive the same step.
            const script_seq = next_script_seq.fetchAdd(1, .monotonic);
            const step = pickStep(script_seq);
            var conn_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer conn_arena.deinit();
            tokens = try writeSseChunks(io, &response.writer, conn_arena.allocator(), step, profile, rand);
            try response.end();
            try request.server.out.flush();
        }

        const t_end = nowMs();
        try logTiming(io, .{
            .t_start_ms = t_start,
            .t_first_chunk_ms = t_first_chunk,
            .t_end_ms = t_end,
            .ttft_ms = if (t_first_chunk >= 0) t_first_chunk - t_start else -1,
            .tokens = tokens,
            .profile = profile.name,
            .req_seq = seq,
            .status = @intFromEnum(status),
        });

        if (!keep_alive) return;
    }
}

const TimingRow = struct {
    t_start_ms: i64,
    t_first_chunk_ms: i64,
    t_end_ms: i64,
    ttft_ms: i64,
    tokens: u64,
    profile: []const u8,
    req_seq: u64,
    status: u16,
};

fn logTiming(io: std.Io, row: TimingRow) !void {
    const file = g_timing_file orelse return;
    // Note: file was opened once at startup with truncate=false; we track
    // the write offset manually to avoid stat() per request.
    g_timing_mutex.lockUncancelable(io);
    defer g_timing_mutex.unlock(io);

    var tmp: [512]u8 = undefined;
    const line = try std.fmt.bufPrint(&tmp,
        "{{\"t_start_ms\":{d},\"t_first_chunk_ms\":{d},\"t_end_ms\":{d},\"ttft_ms\":{d},\"tokens\":{d},\"profile\":\"{s}\",\"req_seq\":{d},\"status\":{d}}}\n",
        .{ row.t_start_ms, row.t_first_chunk_ms, row.t_end_ms, row.ttft_ms, row.tokens, row.profile, row.req_seq, row.status });
    // Use positional write at tracked offset; updated atomically under mutex.
    try file.writePositionalAll(io, line, g_timing_offset);
    g_timing_offset += line.len;
}

var g_timing_offset: u64 = 0;

fn pickStep(seq: u64) ?ScriptStep {
    const steps = g_script_steps orelse return null;
    if (seq - 1 < steps.len) return steps[seq - 1];
    return null; // exhausted: caller writes terminal stop
}

/// Escape a string for embedding inside JSON double quotes.
/// Caller owns the returned slice (allocated from `alloc`).
fn jsonEscape(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(alloc, "\\\""),
            '\\' => try out.appendSlice(alloc, "\\\\"),
            '\n' => try out.appendSlice(alloc, "\\n"),
            '\r' => try out.appendSlice(alloc, "\\r"),
            '\t' => try out.appendSlice(alloc, "\\t"),
            else => try out.append(alloc, c),
        }
    }
    return out.toOwnedSlice(alloc);
}

fn writeSseChunks(
    io: std.Io,
    w: anytype,
    alloc: std.mem.Allocator,
    step: ?ScriptStep,
    profile: Profile,
    rand: std.Random,
) !u64 {
    _ = io;
    const req_id = next_request_id.fetchAdd(1, .monotonic);

    var tokens: u64 = 0;
    var buf: [8192]u8 = undefined;

    const text = if (step) |s| s.text else "ok";
    const has_tools = if (step) |s| s.tool_calls != null else false;

    // Emit text in ~4-char token chunks with TPOT pacing.
    var ti: usize = 0;
    while (ti < text.len) {
        const end = @min(ti + 4, text.len);
        const piece = text[ti..end];
        const esc = try jsonEscape(alloc, piece);
        defer alloc.free(esc);
        const line = try std.fmt.bufPrint(&buf,
            "data: {{\"id\":\"sim-{d}\",\"object\":\"chat.completion.chunk\",\"choices\":[{{\"index\":0,\"delta\":{{\"content\":\"{s}\"}},\"finish_reason\":null}}]}}\n\n",
            .{ req_id, esc });
        try w.writeAll(line);
        tokens += 1;
        ti = end;
        const tpot = applyJitter(profile, profile.tpot_ms, rand);
        if (tpot > 0) sleepMs(tpot);
    }

    // Chunk: tool calls.
    if (has_tools) {
        const s = step.?;
        for (s.tool_calls.?, 0..) |tc, idx| {
            const esc_name = try jsonEscape(alloc, tc.name);
            defer alloc.free(esc_name);
            const esc_args = try jsonEscape(alloc, tc.arguments);
            defer alloc.free(esc_args);
            const line = try std.fmt.bufPrint(&buf,
                "data: {{\"id\":\"sim-{d}\",\"object\":\"chat.completion.chunk\",\"choices\":[{{\"index\":0,\"delta\":{{\"tool_calls\":[{{\"index\":{d},\"id\":\"call_{d}_{d}\",\"type\":\"function\",\"function\":{{\"name\":\"{s}\",\"arguments\":\"{s}\"}}}}]}},\"finish_reason\":null}}]}}\n\n",
                .{ req_id, idx, req_id, idx, esc_name, esc_args });
            try w.writeAll(line);
            tokens += 8; // rough: tool call ~8 tokens
            const tpot = applyJitter(profile, profile.tpot_ms, rand);
            if (tpot > 0) sleepMs(tpot);
        }
    }

    const finish_reason: []const u8 = if (has_tools) "tool_calls" else "stop";
    const line = try std.fmt.bufPrint(&buf,
        "data: {{\"id\":\"sim-{d}\",\"object\":\"chat.completion.chunk\",\"choices\":[{{\"index\":0,\"delta\":{{}},\"finish_reason\":\"{s}\"}}],\"usage\":{{\"prompt_tokens\":800,\"completion_tokens\":{d},\"total_tokens\":{d}}}}}\n\ndata: [DONE]\n\n",
        .{ req_id, finish_reason, tokens, 800 + tokens });
    try w.writeAll(line);
    return tokens;
}
