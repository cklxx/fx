const std = @import("std");
const proto = @import("proto");
const client_mod = @import("client");

fn sockPath() []const u8 {
    return ".agent-sock/agent.sock";
}

fn usage() void {
    std.debug.print(
        \\usage: testkit <cmd> [args]
        \\  pub <queue> <message_id> <payload>        publish; prints PUB mid=N|DUP|CANCELLED | ERR <code>
        \\  pubfile <queue> <message_id> <file>
        \\  consume1 <queue> <group> [timeout_ms] [aw_s] [md] [--id NAME]
        \\                                          consume once; prints DLV <dlv> <mid> <b64payload> | NONE
        \\  ack <queue> <group> <delivery_id> [--requeue]
        \\  cancel <task_id>                         publish control-cancel to task.dispatch
        \\  declare <queue> <semantics> <max_depth> <overflow>
        \\  reg <name>                               register; prints REG OK
        \\  dereg <name>                              register then deregister
        \\  card <name>                               agent.card; prints CARD OK
        \\  pipeline <name> <n>                       n pipelined card reqs; verifies in_reply_to
        \\  worker <queue> <group> <outdir> [--hold <dir>] [--aw S] [--md N] [--idle N] [--id NAME]
        \\                                          loop consume->write file->ack
        \\  raw <hexfile>                            send raw bytes from file, report close/error
        \\
    , .{});
}

/// Machine-readable result output goes to STDOUT (e2e.sh captures it).
/// Diagnostics stay on stderr via std.debug.print.
const Out = struct {
    io: std.Io,
    buf: [8192]u8 = [_]u8{0} ** 8192,
    w: std.Io.File.Writer = undefined,
    init_done: bool = false,

    fn writer(self: *Out) *std.Io.Writer {
        if (!self.init_done) {
            self.w = std.Io.File.stdout().writerStreaming(self.io, &self.buf);
            self.init_done = true;
        }
        return &self.w.interface;
    }

    fn print(self: *Out, comptime fmt: []const u8, args: anytype) void {
        self.writer().print(fmt, args) catch {};
        self.writer().flush() catch {};
    }
};

fn printErr(o: *Out, msg: *proto.Message) void {
    const code_el = msg.root.child("code");
    if (code_el) |ce| {
        const alloc = std.heap.page_allocator;
        const t = ce.textContent(alloc) catch "?";
        defer alloc.free(t);
        o.print("ERR {s}\n", .{t});
    } else {
        o.print("ERR ?\n", .{});
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    const args = try init.minimal.args.toSlice(alloc);
    var out = Out{ .io = io };
    if (args.len < 2) {
        usage();
        std.process.exit(2);
    }
    const cmd = args[1];
    const sp = sockPath();

    if (std.mem.eql(u8, cmd, "pub")) {
        if (args.len < 5) return error.BadArgs;
        var c = try client_mod.Client.connect(alloc, io, sp, "testkit");
        defer c.deinit();
        const seq = try c.publish(args[2], args[3], args[4]);
        // read reply with matching in_reply_to
        var t = try c.recvTimeout(seq, 3000);
        defer t.deinit();
        if (t.envelope.primitive == .err) {
            printErr(&out, &t);
            std.process.exit(3);
        }
        if (t.root.child("cancelled")) |_| {
            out.print("PUB CANCELLED\n", .{});
            return;
        }
        if (t.root.child("duplicate")) |de| {
            const dt = try de.textContent(alloc);
            defer alloc.free(dt);
            if (std.mem.eql(u8, std.mem.trim(u8, dt, " \t\r\n"), "true")) {
                out.print("PUB DUP\n", .{});
                return;
            }
        }
        const mid_el = t.root.child("mid") orelse {
            out.print("PUB ?\n", .{});
            return;
        };
        const mt = try mid_el.textContent(alloc);
        defer alloc.free(mt);
        out.print("PUB mid={s}\n", .{std.mem.trim(u8, mt, " \t\r\n")});
    } else if (std.mem.eql(u8, cmd, "pubfile")) {
        if (args.len < 5) return error.BadArgs;
        const data = try readFileAlloc(alloc, io, args[4]);
        defer alloc.free(data);
        var c = try client_mod.Client.connect(alloc, io, sp, "testkit");
        defer c.deinit();
        const seq = try c.publish(args[2], args[3], data);
        var t = try c.recvTimeout(seq, 10000);
        defer t.deinit();
        if (t.envelope.primitive == .err) {
            printErr(&out, &t);
            std.process.exit(3);
        }
        out.print("PUBFILE OK\n", .{});
    } else if (std.mem.eql(u8, cmd, "consume1")) {
        if (args.len < 4) return error.BadArgs;
        var timeout: u32 = 3000;
        var aw: u32 = 30;
        var md: u32 = 5;
        var cid: []const u8 = "testkit";
        var pos: usize = 0; // positional index for timeout/aw/md
        var i: usize = 4;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--id") and i + 1 < args.len) {
                cid = args[i + 1];
                i += 1;
            } else if (pos == 0) {
                timeout = try std.fmt.parseInt(u32, args[i], 10);
                pos = 1;
            } else if (pos == 1) {
                aw = try std.fmt.parseInt(u32, args[i], 10);
                pos = 2;
            } else if (pos == 2) {
                md = try std.fmt.parseInt(u32, args[i], 10);
                pos = 3;
            } else return error.BadArgs;
        }
        var c = try client_mod.Client.connect(alloc, io, sp, cid);
        defer c.deinit();
        _ = try c.consume(args[2], args[3], aw, md);
        while (true) {
            const m_opt = try c.recvDeadline(proto.nowMs() + @as(i64, @intCast(timeout)));
            if (m_opt == null) {
                out.print("NONE\n", .{});
                return;
            }
            var m = m_opt.?;
            defer m.deinit();
            if (m.envelope.primitive == .queue_deliver) {
                const dlv = try m.root.child("delivery_id").?.textContent(alloc);
                defer alloc.free(dlv);
                const mid = try m.root.child("message_id").?.textContent(alloc);
                defer alloc.free(mid);
                const pay = try m.root.child("payload").?.textContent(alloc);
                defer alloc.free(pay);
                const enc_len = std.base64.standard.Encoder.calcSize(pay.len);
                const enc = try alloc.alloc(u8, enc_len);
                defer alloc.free(enc);
                _ = std.base64.standard.Encoder.encode(enc, pay);
                const redel = if (m.root.child("redelivered")) |re| blk: {
                    const rt = try re.textContent(alloc);
                    defer alloc.free(rt);
                    break :blk std.mem.eql(u8, std.mem.trim(u8, rt, " \t\r\n"), "true");
                } else false;
                out.print("DLV {s} {s} redelivered={s} {s}\n", .{
                    std.mem.trim(u8, dlv, " \t\r\n"),
                    std.mem.trim(u8, mid, " \t\r\n"),
                    if (redel) "true" else "false",
                    enc,
                });
                return;
            } else if (m.envelope.primitive == .err) {
                printErr(&out, &m);
                std.process.exit(3);
            }
            // ignore other messages (e.g. declare acks)
        }
    } else if (std.mem.eql(u8, cmd, "ack")) {
        if (args.len < 5) return error.BadArgs;
        const requeue = args.len > 5 and std.mem.eql(u8, args[5], "--requeue");
        var c = try client_mod.Client.connect(alloc, io, sp, "testkit");
        defer c.deinit();
        _ = try c.ack(args[2], args[3], args[4], requeue);
        out.print("ACKED\n", .{});
    } else if (std.mem.eql(u8, cmd, "cancel")) {
        if (args.len < 3) return error.BadArgs;
        var c = try client_mod.Client.connect(alloc, io, sp, "testkit");
        defer c.deinit();
        const seq = try c.cancelTask("task.dispatch", args[2]);
        var t = try c.recvTimeout(seq, 3000);
        defer t.deinit();
        out.print("CANCELLED {s}\n", .{args[2]});
    } else if (std.mem.eql(u8, cmd, "declare")) {
        if (args.len < 6) return error.BadArgs;
        var c = try client_mod.Client.connect(alloc, io, sp, "testkit");
        defer c.deinit();
        const max_depth = try std.fmt.parseInt(usize, args[4], 10);
        const seq = try c.declareQueue(args[2], args[3], max_depth, args[5]);
        var t = try c.recvTimeout(seq, 3000);
        defer t.deinit();
        if (t.envelope.primitive == .err) {
            printErr(&out, &t);
            std.process.exit(3);
        }
        out.print("DECLARED\n", .{});
    } else if (std.mem.eql(u8, cmd, "reg")) {
        if (args.len < 3) return error.BadArgs;
        var c = try client_mod.Client.connect(alloc, io, sp, args[2]);
        defer c.deinit();
        var r = try c.register(9999, &.{"shell.exec"}, 5000);
        defer r.deinit();
        out.print("REG OK in_reply_to={?d}\n", .{r.envelope.in_reply_to});
    } else if (std.mem.eql(u8, cmd, "dereg")) {
        if (args.len < 3) return error.BadArgs;
        var c = try client_mod.Client.connect(alloc, io, sp, args[2]);
        defer c.deinit();
        var r = try c.register(9999, &.{"shell.exec"}, 5000);
        r.deinit();
        _ = try c.deregister();
        out.print("DEREG OK\n", .{});
    } else if (std.mem.eql(u8, cmd, "card")) {
        if (args.len < 3) return error.BadArgs;
        var c = try client_mod.Client.connect(alloc, io, sp, args[2]);
        defer c.deinit();
        const seq = try c.card();
        var t = try c.recvTimeout(seq, 3000);
        defer t.deinit();
        out.print("CARD OK in_reply_to={?d}\n", .{t.envelope.in_reply_to});
    } else if (std.mem.eql(u8, cmd, "pipeline")) {
        if (args.len < 4) return error.BadArgs;
        const n = try std.fmt.parseInt(usize, args[3], 10);
        var c = try client_mod.Client.connect(alloc, io, sp, args[2]);
        defer c.deinit();
        var seqs = try alloc.alloc(u64, n);
        defer alloc.free(seqs);
        for (0..n) |i| seqs[i] = try c.card();
        var seen = try alloc.alloc(bool, n);
        defer alloc.free(seen);
        @memset(seen, false);
        var got: usize = 0;
        const deadline = proto.nowMs() + 15000;
        while (got < n) {
            const m_opt = try c.recvDeadline(deadline);
            if (m_opt == null) {
                out.print("PIPELINE FAIL: timeout waiting for reply {d}/{d}\n", .{ got, n });
                std.process.exit(4);
            }
            var m = m_opt.?;
            defer m.deinit();
            const irt = m.envelope.in_reply_to orelse {
                out.print("PIPELINE FAIL: reply without in_reply_to\n", .{});
                std.process.exit(4);
            };
            var found = false;
            for (seqs, 0..) |s, i| {
                if (s == irt) {
                    if (seen[i]) {
                        out.print("PIPELINE FAIL: duplicate reply for seq {d}\n", .{s});
                        std.process.exit(4);
                    }
                    seen[i] = true;
                    found = true;
                    break;
                }
            }
            if (!found) {
                out.print("PIPELINE FAIL: in_reply_to={d} not in sent seqs\n", .{irt});
                std.process.exit(4);
            }
            got += 1;
        }
        out.print("PIPELINE OK n={d}\n", .{n});
    } else if (std.mem.eql(u8, cmd, "worker")) {
        if (args.len < 5) return error.BadArgs;
        const queue = args[2];
        const group = args[3];
        const outdir = args[4];
        var hold_dir: ?[]const u8 = null;
        var aw: u32 = 30;
        var idle_limit: u32 = 3;
        var wid: []const u8 = "w?";
        var i: usize = 5;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--hold") and i + 1 < args.len) {
                hold_dir = args[i + 1];
                i += 1;
            } else if (std.mem.eql(u8, args[i], "--aw") and i + 1 < args.len) {
                aw = try std.fmt.parseInt(u32, args[i + 1], 10);
                i += 1;
            } else if (std.mem.eql(u8, args[i], "--idle") and i + 1 < args.len) {
                idle_limit = try std.fmt.parseInt(u32, args[i + 1], 10);
                i += 1;
            } else if (std.mem.eql(u8, args[i], "--id") and i + 1 < args.len) {
                wid = args[i + 1];
                i += 1;
            }
        }
        var c = try client_mod.Client.connect(alloc, io, sp, wid);
        defer c.deinit();
        var r = try c.register(9999, &.{"shell.exec"}, 5000);
        r.deinit();
        var idle: u32 = 0;
        while (idle < idle_limit) {
            _ = try c.consume(queue, group, aw, 5);
            const m_opt = try c.recvDeadline(proto.nowMs() + 2000);
            if (m_opt == null) {
                idle += 1;
                continue;
            }
            var m = m_opt.?;
            defer m.deinit();
            if (m.envelope.primitive != .queue_deliver) continue;
            idle = 0;
            const dlv = try m.root.child("delivery_id").?.textContent(alloc);
            defer alloc.free(dlv);
            const mid = try m.root.child("message_id").?.textContent(alloc);
            defer alloc.free(mid);
            const mid_t = std.mem.trim(u8, mid, " \t\r\n");
            const dlv_t = std.mem.trim(u8, dlv, " \t\r\n");
            // write delivery file
            var pbuf: [1024]u8 = undefined;
            const p = try std.fmt.bufPrint(&pbuf, "{s}/{s}.got", .{ outdir, mid_t });
            const f = try std.Io.Dir.createFile(std.Io.Dir.cwd(), io, p, .{});
            defer std.Io.File.close(f, io);
            try std.Io.File.writeStreamingAll(f, io, wid);
            if (hold_dir) |hd| {
                // wait for go-file before acking (test kills us mid-hold to simulate crash)
                var hbuf: [1024]u8 = undefined;
                const hp = try std.fmt.bufPrint(&hbuf, "{s}/go-{s}", .{ hd, mid_t });
                var waited: u32 = 0;
                while (waited < 600) : (waited += 1) {
                    const probe = std.Io.Dir.openFile(std.Io.Dir.cwd(), io, hp, .{ .mode = .read_only }) catch {
                        var ts = std.os.linux.timespec{ .sec = 0, .nsec = 100_000_000 };
                        _ = std.os.linux.nanosleep(&ts, null);
                        continue;
                    };
                    std.Io.File.close(probe, io);
                    break;
                }
            }
            _ = try c.ack(queue, group, dlv_t, false);
            var dbuf: [1024]u8 = undefined;
            const dp = try std.fmt.bufPrint(&dbuf, "{s}/{s}.done", .{ outdir, mid_t });
            const df = try std.Io.Dir.createFile(std.Io.Dir.cwd(), io, dp, .{});
            defer std.Io.File.close(df, io);
            try std.Io.File.writeStreamingAll(df, io, wid);
        }
        std.debug.print("WORKER {s} idle-exit\n", .{wid});
    } else if (std.mem.eql(u8, cmd, "raw")) {
        if (args.len < 3) return error.BadArgs;
        // args[2]: file containing raw bytes to send (e.g. oversized length prefix)
        const data = try readFileAlloc(alloc, io, args[2]);
        defer alloc.free(data);
        var c = try client_mod.Client.connect(alloc, io, sp, "testkit");
        defer c.deinit();
        var wbuf: [64 * 1024]u8 = undefined;
        var w = c.stream.writer(io, &wbuf);
        w.interface.writeAll(data) catch |e| {
            out.print("RAW WRITE-ERR {s}\n", .{@errorName(e)});
            return;
        };
        w.interface.flush() catch {};
        const m_opt = c.recvDeadline(proto.nowMs() + 2000) catch |e| {
            out.print("RAW CLOSED {s}\n", .{@errorName(e)});
            return;
        };
        if (m_opt == null) {
            out.print("RAW CLOSED timeout\n", .{});
            return;
        }
        var m = m_opt.?;
        defer m.deinit();
        out.print("RAW REPLY type={s}\n", .{m.envelope.primitive.wireName()});
    } else {
        usage();
        std.process.exit(2);
    }
}

fn readFileAlloc(alloc: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const f = try std.Io.Dir.openFile(std.Io.Dir.cwd(), io, path, .{ .mode = .read_only });
    defer std.Io.File.close(f, io);
    const st = try std.Io.File.stat(f, io);
    const buf = try alloc.alloc(u8, st.size);
    errdefer alloc.free(buf);
    var off: u64 = 0;
    while (off < buf.len) {
        const n = try std.Io.File.readStreaming(f, io, &[_][]u8{buf[off..]});
        if (n == 0) break;
        off += n;
    }
    return buf;
}
