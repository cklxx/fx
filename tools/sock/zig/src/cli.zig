const std = @import("std");
const proto = @import("proto");
const client_mod = @import("client");

const usage =
    \\asock-cli: thin shell client for agent-sock
    \\
    \\usage:
    \\  asock-cli declare <queue> [--semantics workqueue|topic] [--max-depth N] [--overflow block|drop_oldest]
    \\  asock-cli publish <queue> <message_id> <payload|->          (payload "-" reads stdin)
    \\  asock-cli consume <queue> <group> [--timeout-s N] [--ack-wait-s 30] [--max-deliver 5]
    \\      -> prints "delivery_id\tpayload" on stdout; exit 2 on timeout
    \\  asock-cli ack <queue> <group> <delivery_id> [--requeue]
    \\  asock-cli unconsume <queue> <group>
    \\
    \\env:
    \\  ASOCK_PATH   unix socket path (default .agent-sock/agent.sock)
    \\  ASOCK_FROM   client identity (default asock-cli-<pid>)
;

fn fatal(io: std.Io, comptime fmt: []const u8, args: anytype) noreturn {
    var buf: [256]u8 = undefined;
    var w = std.Io.File.stderr().writerStreaming(io, &buf);
    w.interface.print("asock-cli: " ++ fmt ++ "\n", args) catch {};
    w.interface.flush() catch {};
    std.process.exit(1);
}

fn sockPath(alloc: std.mem.Allocator, env: *std.process.Environ.Map) ![]u8 {
    if (env.get("ASOCK_PATH")) |p| return alloc.dupe(u8, p);
    return alloc.dupe(u8, ".agent-sock/agent.sock");
}

fn fromId(alloc: std.mem.Allocator, env: *std.process.Environ.Map) ![]u8 {
    if (env.get("ASOCK_FROM")) |p| return alloc.dupe(u8, p);
    var buf: [64]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "asock-cli-{d}", .{std.os.linux.getpid()});
    return alloc.dupe(u8, s);
}

fn readStdin(io: std.Io, alloc: std.mem.Allocator) ![]u8 {
    var list = std.ArrayList(u8).empty;
    defer list.deinit(alloc);
    var buf: [8192]u8 = undefined;
    var reader = std.Io.File.stdin().readerStreaming(io, &buf);
    while (true) {
        const chunk = reader.interface.readSliceShort(&buf) catch break;
        if (chunk == 0) break;
        try list.appendSlice(alloc, buf[0..chunk]);
    }
    return list.toOwnedSlice(alloc);
}

fn opt(args: []const []const u8, name: []const u8, fallback: []const u8) []const u8 {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], name) and i + 1 < args.len) return args[i + 1];
    }
    return fallback;
}

fn optU32(args: []const []const u8, name: []const u8, fallback: u32) u32 {
    const s = opt(args, name, "");
    if (s.len == 0) return fallback;
    return std.fmt.parseInt(u32, s, 10) catch fallback;
}

fn hasFlag(args: []const []const u8, name: []const u8) bool {
    for (args) |a| if (std.mem.eql(u8, a, name)) return true;
    return false;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // Collect args via init.minimal.args iterator.
    var arg_list = std.ArrayList([]const u8).empty;
    defer arg_list.deinit(alloc);
    var ait = init.minimal.args.iterate();
    while (ait.next()) |a| try arg_list.append(alloc, a);
    const argv = arg_list.items;
    if (argv.len < 2) {
        var sb: [1024]u8 = undefined;
        var w = std.Io.File.stderr().writerStreaming(io, &sb);
        try w.interface.writeAll(usage);
        try w.interface.flush();
        std.process.exit(2);
    }
    const cmd = argv[1];
    const rest = argv[2..];

    const sp = try sockPath(alloc, init.environ_map);
    defer alloc.free(sp);
    const fid = try fromId(alloc, init.environ_map);
    defer alloc.free(fid);

    var client = client_mod.Client.connect(alloc, io, sp, fid) catch
        fatal(io, "cannot connect to {s}", .{sp});
    defer client.deinit();

    if (std.mem.eql(u8, cmd, "declare")) {
        if (rest.len < 1) fatal(io, "declare needs <queue>", .{});
        const semantics = opt(rest, "--semantics", "workqueue");
        const max_depth: usize = optU32(rest, "--max-depth", 10000);
        const overflow = opt(rest, "--overflow", "block");
        const seq = try client.declareQueue(rest[0], semantics, max_depth, overflow);
        var reply = try client.recvTimeout(seq, 5000);
        defer reply.deinit();
        if (reply.envelope.primitive == .err) {
            const m = try reply.root.child("message").?.textContent(alloc);
            defer alloc.free(m);
            fatal(io, "server error: {s}", .{m});
        }
        std.debug.print("declared {s}\n", .{rest[0]});
    } else if (std.mem.eql(u8, cmd, "publish")) {
        if (rest.len < 3) fatal(io, "publish needs <queue> <message_id> <payload|->", .{});
        const payload = if (std.mem.eql(u8, rest[2], "-")) try readStdin(io, alloc) else rest[2];
        defer if (std.mem.eql(u8, rest[2], "-")) alloc.free(payload);
        const seq = try client.publish(rest[0], rest[1], payload);
        var reply = try client.recvTimeout(seq, 5000);
        defer reply.deinit();
        if (reply.envelope.primitive == .err) {
            const m = try reply.root.child("message").?.textContent(alloc);
            defer alloc.free(m);
            fatal(io, "server error: {s}", .{m});
        }
        std.debug.print("published {s}\n", .{rest[1]});
    } else if (std.mem.eql(u8, cmd, "consume")) {
        if (rest.len < 2) fatal(io, "consume needs <queue> <group>", .{});
        const timeout_s = optU32(rest, "--timeout-s", 30);
        const ack_wait_s = optU32(rest, "--ack-wait-s", 30);
        const max_deliver = optU32(rest, "--max-deliver", 5);
        const deadline = proto.nowMs() + @as(i64, @intCast(timeout_s)) * 1000;
        // Single consume; server has no push, so poll by re-consuming.
        // Note: each consume that finds a message creates a delivery; we
        // only re-consume when the previous attempt got nothing.
        while (proto.nowMs() < deadline) {
            _ = try client.consume(rest[0], rest[1], ack_wait_s, max_deliver);
            const remain = deadline - proto.nowMs();
            if (remain <= 0) break;
            // Wait up to 2s for a deliver; then re-consume (poll).
            // recvDeadline takes an ABSOLUTE timestamp, not a relative timeout.
            const m = try client.recvDeadline(proto.nowMs() + @min(remain, 2000));
            if (m) |msg| {
                var mm = msg;
                defer mm.deinit();
                if (mm.envelope.primitive == .queue_deliver) {
                    const dlv = try mm.root.child("delivery_id").?.textContent(alloc);
                    defer alloc.free(dlv);
                    const pl = try mm.root.child("payload").?.textContent(alloc);
                    defer alloc.free(pl);
                    var out_buf: [64 * 1024]u8 = undefined;
                    var out = std.Io.File.stdout().writerStreaming(io, &out_buf);
                    try out.interface.print("{s}\t{s}\n", .{ dlv, pl });
                    try out.interface.flush();
                    return;
                }
                if (mm.envelope.primitive == .err) {
                    const em = try mm.root.child("message").?.textContent(alloc);
                    defer alloc.free(em);
                    fatal(io, "server error: {s}", .{em});
                }
                // Non-deliver, non-error: keep waiting (do not re-consume yet).
                // Fall through to short sleep, then loop re-consumes.
            }
            {
                var ts = std.os.linux.timespec{ .sec = 0, .nsec = 200 * 1000 * 1000 };
                _ = std.os.linux.nanosleep(&ts, null);
            }
        }
        std.process.exit(2); // timeout: no message
    } else if (std.mem.eql(u8, cmd, "ack")) {
        if (rest.len < 3) fatal(io, "ack needs <queue> <group> <delivery_id>", .{});
        const seq = try client.ack(rest[0], rest[1], rest[2], hasFlag(rest, "--requeue"));
        var reply = try client.recvTimeout(seq, 5000);
        defer reply.deinit();
        if (reply.envelope.primitive == .err) {
            const m = try reply.root.child("message").?.textContent(alloc);
            defer alloc.free(m);
            fatal(io, "server error: {s}", .{m});
        }
        std.debug.print("acked {s}\n", .{rest[2]});
    } else if (std.mem.eql(u8, cmd, "unconsume")) {
        if (rest.len < 2) fatal(io, "unconsume needs <queue> <group>", .{});
        const seq = try client.unconsume(rest[0], rest[1]);
        var reply = try client.recvTimeout(seq, 5000);
        defer reply.deinit();
        std.debug.print("unconsumed {s}/{s}\n", .{ rest[0], rest[1] });
    } else {
        fatal(io, "unknown command: {s}", .{cmd});
    }
}
