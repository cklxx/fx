//! Simulated LLM API server for agent-bench.
//!
//! Serves OpenAI-compatible `POST /v1/chat/completions` with controllable
//! timing profiles, failure injection, and script mode for trajectory replay.
//! Emits per-request timing logs as JSONL.
//!
//! Timing model: prefill/decode separation. TTFT = ttft_fixed_ms +
//! (1 - prefix_hit_ratio) * prompt_tokens / prefill_tps. TPOT =
//! 1000 / decode_tps. An optional prefix cache (block-hash LCP over the
//! request body) models KV-cache reuse across rounds.
//!
//! Prefix-cache discipline (structural, not configurable):
//! - The shared pool holds prefill KV only. Decode-generated tokens are
//!   per-request and never enter the pool.
//! - The last prompt token is always a miss (only full blocks are cached).
//!   Hence prefix_hit_ratio < 100% always: hits are partial by construction.
//! - Mirrors vLLM automatic prefix caching semantics.
//!
//! Usage:
//!   sim-server --profile flash|pro|slow|flaky|zero|ultrafast|cached [--port N]
//!              [--profile-json file] [--script file] [--timing-log file]
//!              [--jitter pct]

const std = @import("std");

const max_request_bytes = 8 * 1024 * 1024;

var next_request_id: std.atomic.Value(u64) = .init(1);
var next_seq: std.atomic.Value(u64) = .init(1);
var next_script_seq: std.atomic.Value(u64) = .init(1);

const Profile = struct {
    name: []const u8,
    // Legacy fixed timing (used when prefill_tps == 0).
    ttft_ms: u64,
    tpot_ms: u64,
    // Prefill/decode model. prefill_tps == 0 selects the legacy path.
    prefill_tps: f64,
    decode_tps: f64,
    ttft_fixed_ms: u64,
    // Prefix cache (KV-cache reuse across rounds).
    prefix_cache: bool,
    // -1 = auto (real longest-common-prefix over block hashes),
    // 0..100 = forced hit ratio percent.
    prefix_hit_pct: i64,
    fail_500_pct: u64,
    fail_429_pct: u64,
    jitter_pct: u64,
};

// Reference: ~6700 prompt tokens (measured: 27 KB fx request body / 4).
// prefill/decode rates are calibrated so the no-cache TTFT/TPOT reproduce
// the legacy fixed values at this prompt size.
const builtin_profiles = [_]Profile{
    .{ .name = "flash", .ttft_ms = 200, .tpot_ms = 8, .prefill_tps = 42000, .decode_tps = 125, .ttft_fixed_ms = 40, .prefix_cache = false, .prefix_hit_pct = -1, .fail_500_pct = 0, .fail_429_pct = 0, .jitter_pct = 10 },
    .{ .name = "pro", .ttft_ms = 800, .tpot_ms = 25, .prefill_tps = 8800, .decode_tps = 40, .ttft_fixed_ms = 40, .prefix_cache = false, .prefix_hit_pct = -1, .fail_500_pct = 0, .fail_429_pct = 0, .jitter_pct = 10 },
    .{ .name = "slow", .ttft_ms = 2000, .tpot_ms = 80, .prefill_tps = 3440, .decode_tps = 12.5, .ttft_fixed_ms = 50, .prefix_cache = false, .prefix_hit_pct = -1, .fail_500_pct = 0, .fail_429_pct = 0, .jitter_pct = 10 },
    .{ .name = "flaky", .ttft_ms = 800, .tpot_ms = 25, .prefill_tps = 8800, .decode_tps = 40, .ttft_fixed_ms = 40, .prefix_cache = false, .prefix_hit_pct = -1, .fail_500_pct = 5, .fail_429_pct = 5, .jitter_pct = 10 },
    .{ .name = "zero", .ttft_ms = 0, .tpot_ms = 0, .prefill_tps = 0, .decode_tps = 0, .ttft_fixed_ms = 0, .prefix_cache = false, .prefix_hit_pct = -1, .fail_500_pct = 0, .fail_429_pct = 0, .jitter_pct = 0 },
    // High-performance inference: fast decode (1000 tok/s), moderate prefill,
    // real LCP prefix cache. Round 1 is cold (full prefill); rounds 2+ hit.
    .{ .name = "ultrafast", .ttft_ms = 0, .tpot_ms = 1, .prefill_tps = 5000, .decode_tps = 1000, .ttft_fixed_ms = 10, .prefix_cache = true, .prefix_hit_pct = -1, .fail_500_pct = 0, .fail_429_pct = 0, .jitter_pct = 5 },
    // Steady-state cached rounds: system prompt + tool defs near-fully hit.
    // Forced 95%: the last-token structural cap keeps hits partial (<100%).
    .{ .name = "cached", .ttft_ms = 0, .tpot_ms = 1, .prefill_tps = 5000, .decode_tps = 1000, .ttft_fixed_ms = 5, .prefix_cache = true, .prefix_hit_pct = 95, .fail_500_pct = 0, .fail_429_pct = 0, .jitter_pct = 5 },
};

const Config = struct {
    profile: Profile,
    script_path: ?[]const u8,
    timing_log_path: ?[]const u8,
    dump_bodies_dir: ?[]const u8,
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
        .dump_bodies_dir = null,
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
        } else if (std.mem.eql(u8, arg, "--dump-bodies")) {
            cfg.dump_bodies_dir = try alloc.dupe(u8, args.next() orelse return error.InvalidArgument);
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
        .prefill_tps = jsonOptFloat(obj, "prefill_tps") orelse 0,
        .decode_tps = jsonOptFloat(obj, "decode_tps") orelse 0,
        .ttft_fixed_ms = @intCast(jsonOptInt(obj, "ttft_fixed_ms") orelse 0),
        .prefix_cache = if (obj.get("prefix_cache")) |v| v.bool else false,
        .prefix_hit_pct = jsonOptInt(obj, "prefix_hit_pct") orelse -1,
        .fail_500_pct = @intCast(obj.get("fail_500_pct").?.integer),
        .fail_429_pct = @intCast(obj.get("fail_429_pct").?.integer),
        .jitter_pct = @intCast(obj.get("jitter_pct").?.integer),
    };
}

fn jsonOptInt(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => null,
    };
}

fn jsonOptFloat(obj: std.json.ObjectMap, key: []const u8) ?f64 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => null,
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
    _ = std.os.linux.clock_gettime(.REALTIME, &ts);
    return ts.sec * 1000 + @divTrunc(ts.nsec, 1_000_000);
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

// ---------------------------------------------------------------------------
// Prefix cache (KV-cache reuse model).
//
// The request body is hashed in 64-byte blocks (FNV-1a). The cache keeps the
// block hashes of the most recent request. On each request we count leading
// blocks identical to the cached ones: that is the longest common prefix,
// i.e. the tokens whose KV-cache hits and skip prefill.
//
// prompt_tokens is estimated as body_bytes / 4.

const prefix_block_size = 64;
const prefix_max_blocks = 4096; // 256 KB body coverage; fx requests are ~27 KB
const chars_per_token: u64 = 4;

var g_prefix_mutex: std.Io.Mutex = .init;
var g_prefix_hashes: [prefix_max_blocks]u64 = undefined;
var g_prefix_block_count: usize = 0;
var g_prefix_valid: bool = false;

fn fnv1a64(data: []const u8) u64 {
    var h: u64 = 14695981039346656037;
    for (data) |b| {
        h ^= b;
        h *%= 1099511628211;
    }
    return h;
}

const BodyScan = struct {
    hashes: [prefix_max_blocks]u64,
    block_count: usize,
    total_bytes: usize,
};

/// Find the JSON value of a top-level `"field":` key and return its raw
/// text (balanced brackets, string-aware). Used to build the canonical
/// prefix-cache key. Returns null if not found.
fn findFieldValue(body: []const u8, field: []const u8) ?[]const u8 {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, body, from, field)) |fi| {
        from = fi + 1;
        if (fi == 0 or body[fi - 1] != '"') continue;
        const after = fi + field.len;
        if (after + 1 >= body.len or body[after] != '"' or body[after + 1] != ':') continue;
        var j = after + 2;
        while (j < body.len and (body[j] == ' ' or body[j] == '\t' or body[j] == '\n' or body[j] == '\r')) : (j += 1) {}
        if (j < body.len and (body[j] == '[' or body[j] == '{')) {
            return extractBalanced(body, j);
        }
        return null;
    }
    return null;
}

fn extractBalanced(body: []const u8, start: usize) ?[]const u8 {
    const open = body[start];
    const close: u8 = if (open == '[') ']' else '}';
    var depth: usize = 0;
    var in_str = false;
    var esc = false;
    var i = start;
    while (i < body.len) : (i += 1) {
        const c = body[i];
        if (in_str) {
            if (esc) {
                esc = false;
            } else if (c == '\\') {
                esc = true;
            } else if (c == '"') {
                in_str = false;
            }
        } else if (c == '"') {
            in_str = true;
        } else if (c == open) {
            depth += 1;
        } else if (c == close) {
            depth -= 1;
            if (depth == 0) return body[start .. i + 1];
        }
    }
    return null;
}

/// Canonical prefix-cache key for a chat completion body: tools JSON ++
/// 0x00 ++ messages JSON. An inference server tokenizes the *rendered*
/// prompt (tool definitions before the conversation), so prefix matching
/// must follow that order. Hashing the raw JSON bytes instead would break
/// the prefix at the first new message whenever the `"messages"` field
/// precedes `"tools"` in the JSON object, even though the tools are
/// identical. Falls back to the raw body when the fields are absent.
fn canonicalBody(body: []const u8, alloc: std.mem.Allocator) ![]u8 {
    const tools = findFieldValue(body, "tools");
    const messages = findFieldValue(body, "messages");
    if (tools == null or messages == null) return alloc.dupe(u8, body);
    var out = try alloc.alloc(u8, tools.?.len + 1 + messages.?.len);
    @memcpy(out[0..tools.?.len], tools.?);
    out[tools.?.len] = 0;
    @memcpy(out[tools.?.len + 1 ..], messages.?);
    return out;
}

/// Consume the request body, hashing its canonical form block by block.
/// Returns per-block hashes plus the total byte count (for prompt token
/// estimation). If dump_file is set, the raw body is also written there.
fn scanBody(req_body: *std.Io.Reader, io: std.Io, dump_file: ?std.Io.File) !BodyScan {
    // Buffer the body (benchmark bodies are ~27 KB; endpoint caps at 8 MB).
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.heap.page_allocator);
    var tmp: [4096]u8 = undefined;
    while (true) {
        const n = try req_body.readSliceShort(&tmp);
        if (n == 0) break;
        if (dump_file) |f| try f.writeStreamingAll(io, tmp[0..n]);
        try buf.appendSlice(std.heap.page_allocator, tmp[0..n]);
    }
    const raw = buf.items;
    const canon = try canonicalBody(raw, std.heap.page_allocator);
    defer std.heap.page_allocator.free(canon);

    var out = BodyScan{ .hashes = undefined, .block_count = 0, .total_bytes = raw.len };
    var off: usize = 0;
    while (off + prefix_block_size <= canon.len and out.block_count < prefix_max_blocks) : (off += prefix_block_size) {
        out.hashes[out.block_count] = fnv1a64(canon[off..][0..prefix_block_size]);
        out.block_count += 1;
    }
    return out;
}

const PrefixHit = struct {
    hit_tokens: u64,
    hit_ratio_pct: u64, // 0..100
    prompt_tokens: u64,
};

/// Compute the prefix hit for this request against the cache, then replace
/// the cache with this request's blocks. Cold cache (first request) always
/// yields 0 hit: prefill cannot be skipped before anything is cached.
///
/// Structural constraint: prefix hits are always partial (hit_ratio < 100%).
/// 1. The shared pool holds prefill KV only. Decode-generated tokens are
///    per-request (their KV depends on the request's own context) and never
///    enter the pool. The cache is therefore built from request bodies
///    (prefill input) alone; decode output is never hashed or stored.
/// 2. Only full blocks are cached; the trailing partial block holding the
///    last prompt token is always recomputed. Modeled as: the last token
///    is always a miss, i.e. hit_tokens <= prompt_tokens - 1.
///
/// Origin: this mirrors vLLM automatic prefix caching semantics, where
/// blocks are content-hashed at fixed granularity, only fully-filled blocks
/// are cached, and APC accelerates prefill specifically (decode generates
/// new tokens rather than reprocessing existing ones).
fn prefixLookupAndUpdate(io: std.Io, scan: *const BodyScan, forced_pct: i64) PrefixHit {
    const prompt_tokens: u64 = @max(1, scan.total_bytes / chars_per_token);
    g_prefix_mutex.lockUncancelable(io);
    defer g_prefix_mutex.unlock(io);

    var hit_tokens: u64 = 0;
    if (g_prefix_valid) {
        if (forced_pct >= 0) {
            hit_tokens = @min(prompt_tokens, prompt_tokens * @as(u64, @intCast(forced_pct)) / 100);
        } else {
            var hit_blocks: usize = 0;
            const n = @min(scan.block_count, g_prefix_block_count);
            while (hit_blocks < n and scan.hashes[hit_blocks] == g_prefix_hashes[hit_blocks]) : (hit_blocks += 1) {}
            hit_tokens = @min(prompt_tokens, hit_blocks * prefix_block_size / chars_per_token);
        }
        // Last-token rule: no reusable KV for the final prompt token.
        if (prompt_tokens > 0) hit_tokens = @min(hit_tokens, prompt_tokens - 1);
    }

    const c = @min(scan.block_count, prefix_max_blocks);
    @memcpy(g_prefix_hashes[0..c], scan.hashes[0..c]);
    g_prefix_block_count = c;
    g_prefix_valid = true;

    const hit_ratio_pct: u64 = @min(100, hit_tokens * 100 / prompt_tokens);
    return .{ .hit_tokens = hit_tokens, .hit_ratio_pct = hit_ratio_pct, .prompt_tokens = prompt_tokens };
}

/// TTFT under the prefill/decode model. Legacy path when prefill_tps == 0.
fn computeTtftMs(profile: Profile, hit: PrefixHit) u64 {
    if (profile.prefill_tps <= 0) return profile.ttft_ms;
    const miss_tokens = @as(f64, @floatFromInt(hit.prompt_tokens - hit.hit_tokens));
    const prefill_ms = miss_tokens / profile.prefill_tps * 1000.0;
    return profile.ttft_fixed_ms + @as(u64, @intFromFloat(@round(prefill_ms)));
}

/// TPOT under the decode model. Legacy path when decode_tps == 0.
fn effectiveTpotMs(profile: Profile) u64 {
    if (profile.decode_tps > 0) return @as(u64, @intFromFloat(@round(1000.0 / profile.decode_tps)));
    return profile.tpot_ms;
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
        // Scan the body for prompt token estimation + prefix-cache LCP.
        var dump_file: ?std.Io.File = null;
        var dump_name_buf: [128]u8 = undefined;
        if (g_config.dump_bodies_dir) |dir| {
            const name = try std.fmt.bufPrint(&dump_name_buf, "{s}/body-{d}.json", .{ dir, seq });
            // Best effort: ignore errors (debug path).
            dump_file = std.Io.Dir.cwd().createFile(io, name, .{}) catch null;
        }
        defer if (dump_file) |f| f.close(io);
        const scan = try scanBody(req_body, io, dump_file);
        const t_body_read = nowMs();

        const profile = g_config.profile;

        // Prefix cache lookup (also refreshes the cache with this request).
        // Computed before failure injection so retries see a warm cache,
        // matching real servers where the prefill happened anyway.
        const hit: PrefixHit = if (profile.prefix_cache)
            prefixLookupAndUpdate(io, &scan, profile.prefix_hit_pct)
        else
            .{ .hit_tokens = 0, .hit_ratio_pct = 0, .prompt_tokens = @max(1, scan.total_bytes / chars_per_token) };
        const prefill_ms = computeTtftMs(profile, hit);

        // Failure injection.
        const roll = rand.intRangeLessThan(u64, 0, 100);
        var status: std.http.Status = .ok;
        if (roll < profile.fail_500_pct) {
            status = .internal_server_error;
        } else if (roll < profile.fail_500_pct + profile.fail_429_pct) {
            status = .too_many_requests;
        }

        var t_first_chunk: i64 = -1;
        var t_headers_sent: i64 = -1;
        var t_first_byte: i64 = -1;
        var t_last_byte: i64 = -1;
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
            const ttft = applyJitter(profile, prefill_ms, rand);
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
            try request.server.out.flush();
            t_headers_sent = nowMs();

            // Script seq only advances on successful responses, so that
            // client retries after injected failures receive the same step.
            const script_seq = next_script_seq.fetchAdd(1, .monotonic);
            const step = pickStep(script_seq);
            var conn_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer conn_arena.deinit();
            var chunk_times = ChunkTimes{ .first_byte = -1, .last_byte = -1 };
            tokens = try writeSseChunks(io, &response.writer, conn_arena.allocator(), step, profile, rand, &chunk_times);
            t_first_byte = chunk_times.first_byte;
            t_last_byte = chunk_times.last_byte;
            try response.end();
            try request.server.out.flush();
        }

        const t_end = nowMs();
        try logTiming(io, .{
            .t_start_ms = t_start,
            .t_body_read_ms = t_body_read,
            .t_first_chunk_ms = t_first_chunk,
            .t_headers_sent_ms = t_headers_sent,
            .t_first_byte_ms = t_first_byte,
            .t_last_byte_ms = t_last_byte,
            .t_end_ms = t_end,
            .ttft_ms = if (t_first_chunk >= 0) t_first_chunk - t_start else -1,
            .tokens = tokens,
            .profile = profile.name,
            .req_seq = seq,
            .status = @backingInt(status),
            .prompt_tokens = hit.prompt_tokens,
            .prefix_hit_tokens = hit.hit_tokens,
            .prefix_hit_ratio_pct = hit.hit_ratio_pct,
            .prefill_ms = prefill_ms,
        });

        if (!keep_alive) return;
    }
}

const TimingRow = struct {
    t_start_ms: i64,
    t_body_read_ms: i64,
    t_first_chunk_ms: i64,
    t_headers_sent_ms: i64,
    t_first_byte_ms: i64,
    t_last_byte_ms: i64,
    t_end_ms: i64,
    ttft_ms: i64,
    tokens: u64,
    profile: []const u8,
    req_seq: u64,
    status: u16,
    prompt_tokens: u64,
    prefix_hit_tokens: u64,
    prefix_hit_ratio_pct: u64,
    prefill_ms: u64,
};

const ChunkTimes = struct {
    first_byte: i64,
    last_byte: i64,
};

fn logTiming(io: std.Io, row: TimingRow) !void {
    const file = g_timing_file orelse return;
    // Note: file was opened once at startup with truncate=false; we track
    // the write offset manually to avoid stat() per request.
    g_timing_mutex.lockUncancelable(io);
    defer g_timing_mutex.unlock(io);

    var tmp: [1024]u8 = undefined;
    const line = try std.fmt.bufPrint(&tmp, "{{\"t_start_ms\":{d},\"t_body_read_ms\":{d},\"t_first_chunk_ms\":{d},\"t_headers_sent_ms\":{d},\"t_first_byte_ms\":{d},\"t_last_byte_ms\":{d},\"t_end_ms\":{d},\"ttft_ms\":{d},\"tokens\":{d},\"profile\":\"{s}\",\"req_seq\":{d},\"status\":{d},\"prompt_tokens\":{d},\"prefix_hit_tokens\":{d},\"prefix_hit_ratio_pct\":{d},\"prefill_ms\":{d}}}\n", .{ row.t_start_ms, row.t_body_read_ms, row.t_first_chunk_ms, row.t_headers_sent_ms, row.t_first_byte_ms, row.t_last_byte_ms, row.t_end_ms, row.ttft_ms, row.tokens, row.profile, row.req_seq, row.status, row.prompt_tokens, row.prefix_hit_tokens, row.prefix_hit_ratio_pct, row.prefill_ms });
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
    chunk_times: *ChunkTimes,
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
        const line = try std.fmt.bufPrint(&buf, "data: {{\"id\":\"sim-{d}\",\"object\":\"chat.completion.chunk\",\"choices\":[{{\"index\":0,\"delta\":{{\"content\":\"{s}\"}},\"finish_reason\":null}}]}}\n\n", .{ req_id, esc });
        try w.writeAll(line);
        if (chunk_times.first_byte < 0) chunk_times.first_byte = nowMs();
        tokens += 1;
        ti = end;
        const tpot = applyJitter(profile, effectiveTpotMs(profile), rand);
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
            const line = try std.fmt.bufPrint(&buf, "data: {{\"id\":\"sim-{d}\",\"object\":\"chat.completion.chunk\",\"choices\":[{{\"index\":0,\"delta\":{{\"tool_calls\":[{{\"index\":{d},\"id\":\"call_{d}_{d}\",\"type\":\"function\",\"function\":{{\"name\":\"{s}\",\"arguments\":\"{s}\"}}}}]}},\"finish_reason\":null}}]}}\n\n", .{ req_id, idx, req_id, idx, esc_name, esc_args });
            try w.writeAll(line);
            if (chunk_times.first_byte < 0) chunk_times.first_byte = nowMs();
            tokens += 8; // rough: tool call ~8 tokens
            const tpot = applyJitter(profile, effectiveTpotMs(profile), rand);
            if (tpot > 0) sleepMs(tpot);
        }
    }

    const finish_reason: []const u8 = if (has_tools) "tool_calls" else "stop";
    const line = try std.fmt.bufPrint(&buf, "data: {{\"id\":\"sim-{d}\",\"object\":\"chat.completion.chunk\",\"choices\":[{{\"index\":0,\"delta\":{{}},\"finish_reason\":\"{s}\"}}],\"usage\":{{\"prompt_tokens\":800,\"completion_tokens\":{d},\"total_tokens\":{d}}}}}\n\ndata: [DONE]\n\n", .{ req_id, finish_reason, tokens, 800 + tokens });
    try w.writeAll(line);
    if (chunk_times.first_byte < 0) chunk_times.first_byte = nowMs();
    chunk_times.last_byte = nowMs();
    return tokens;
}
