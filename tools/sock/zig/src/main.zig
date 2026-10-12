const std = @import("std");
const proto = @import("proto");
const srv = @import("server");

const net = std.Io.net;
const b64 = std.base64.standard;

// ================= WAL =================
// Single append-only log: .agent-sock/data/wal.jsonl
// Records: declare | pub | deliver | ack | cursor | cancel | dead
// Replay rebuilds queues, seen_ids, cancelled set, group cursors,
// and pulls cursors back over crash-time in-flight messages.

fn jsonEscape(out: *std.ArrayList(u8), alloc: std.mem.Allocator, s: []const u8) !void {
    try out.append(alloc, '"');
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(alloc, "\\\""),
            '\\' => try out.appendSlice(alloc, "\\\\"),
            '\n' => try out.appendSlice(alloc, "\\n"),
            '\r' => try out.appendSlice(alloc, "\\r"),
            '\t' => try out.appendSlice(alloc, "\\t"),
            else => {
                if (c < 0x20) {
                    try out.print(alloc, "\\u{x:0>4}", .{c});
                } else {
                    try out.append(alloc, c);
                }
            },
        }
    }
    try out.append(alloc, '"');
}

const Wal = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
    path: []const u8,
    offset: u64,

    fn open(alloc: std.mem.Allocator, io: std.Io, data_dir: []const u8) !Wal {
        std.Io.Dir.createDirPath(std.Io.Dir.cwd(), io, data_dir) catch {};
        var pb: [1024]u8 = undefined;
        const path = try std.fmt.bufPrint(&pb, "{s}/wal.jsonl", .{data_dir});
        const path_owned = try alloc.dupe(u8, path);
        errdefer alloc.free(path_owned);
        const file = std.Io.Dir.openFile(std.Io.Dir.cwd(), io, path, .{ .mode = .write_only }) catch
            try std.Io.Dir.createFile(std.Io.Dir.cwd(), io, path, .{ .truncate = false });
        errdefer std.Io.File.close(file, io);
        const st = try std.Io.File.stat(file, io);
        return .{ .alloc = alloc, .io = io, .file = file, .path = path_owned, .offset = st.size };
    }

    fn close(self: *Wal) void {
        std.Io.File.close(self.file, self.io);
        self.alloc.free(self.path);
    }

    fn appendLine(self: *Wal, text: []const u8) !void {
        try std.Io.File.writePositionalAll(self.file, self.io, text, self.offset);
        self.offset += text.len;
        try std.Io.File.writePositionalAll(self.file, self.io, "\n", self.offset);
        self.offset += 1;
        try std.Io.File.sync(self.file, self.io);
    }

    fn emit(self: *Wal, build: *std.ArrayList(u8)) void {
        self.appendLine(build.items) catch {};
    }

    fn readAll(self: *Wal) ![]u8 {
        const f = try std.Io.Dir.openFile(std.Io.Dir.cwd(), self.io, self.path, .{ .mode = .read_only });
        defer std.Io.File.close(f, self.io);
        const st = try std.Io.File.stat(f, self.io);
        const buf = try self.alloc.alloc(u8, st.size);
        errdefer self.alloc.free(buf);
        _ = try std.Io.File.readPositionalAll(f, self.io, buf, 0);
        return buf;
    }
};

// ================= Engine =================

const Engine = struct {
    alloc: std.mem.Allocator,
    mutex: proto.SpinLock = .{},
    queues: std.StringHashMap(*srv.Queue),
    cancelled: srv.CancelledSet,
    next_delivery_id: u64 = 1,
    wal: Wal,

    fn init(alloc: std.mem.Allocator, wal: Wal) Engine {
        return .{
            .alloc = alloc,
            .queues = std.StringHashMap(*srv.Queue).init(alloc),
            .cancelled = srv.CancelledSet.init(alloc),
            .wal = wal,
        };
    }

    fn deinit(self: *Engine) void {
        var it = self.queues.iterator();
        while (it.next()) |e| {
            e.value_ptr.*.deinit();
            self.alloc.free(e.key_ptr.*);
        }
        self.queues.deinit();
        self.cancelled.deinit();
        self.wal.close();
    }

    fn getQueue(self: *Engine, name: []const u8) ?*srv.Queue {
        return self.queues.get(name);
    }

    /// Declare if missing. Returns true if newly created.
    fn declareQueue(
        self: *Engine,
        name: []const u8,
        semantics: srv.Semantics,
        max_depth: usize,
        overflow: srv.Overflow,
    ) !bool {
        if (self.queues.contains(name)) return false;
        const q = try srv.Queue.init(self.alloc, name, semantics, max_depth, overflow);
        try self.queues.put(try self.alloc.dupe(u8, name), q);
        return true;
    }

    // ---- WAL writers (call with lock held) ----
    fn walDeclare(self: *Engine, name: []const u8, sem: srv.Semantics, max_depth: usize, ov: srv.Overflow) void {
        var b = std.ArrayList(u8).empty;
        defer b.deinit(self.alloc);
        b.appendSlice(self.alloc, "{\"op\":\"declare\",\"queue\":") catch return;
        jsonEscape(&b, self.alloc, name) catch return;
        const sem_s: []const u8 = if (sem == .workqueue) "workqueue" else "topic";
        const ov_s: []const u8 = if (ov == .block) "block" else "drop_oldest";
        b.print(self.alloc, ",\"semantics\":\"{s}\",\"max_depth\":{d},\"overflow\":\"{s}\"{c}", .{ sem_s, max_depth, ov_s, '}' }) catch return;
        self.wal.emit(&b);
    }

    fn walPub(self: *Engine, queue: []const u8, mid: u64, id: []const u8, payload: []const u8) void {
        const enc_len = b64.Encoder.calcSize(payload.len);
        const enc = self.alloc.alloc(u8, enc_len) catch return;
        defer self.alloc.free(enc);
        _ = b64.Encoder.encode(enc, payload);
        var b = std.ArrayList(u8).empty;
        defer b.deinit(self.alloc);
        b.print(self.alloc, "{{\"op\":\"pub\",\"queue\":", .{}) catch return;
        jsonEscape(&b, self.alloc, queue) catch return;
        b.print(self.alloc, ",\"mid\":{d},\"id\":", .{mid}) catch return;
        jsonEscape(&b, self.alloc, id) catch return;
        b.appendSlice(self.alloc, ",\"payload\":\"") catch return;
        b.appendSlice(self.alloc, enc) catch return;
        b.appendSlice(self.alloc, "\"}") catch return;
        self.wal.emit(&b);
    }

    fn walDeliver(self: *Engine, queue: []const u8, group: []const u8, mid: u64) void {
        var b = std.ArrayList(u8).empty;
        defer b.deinit(self.alloc);
        b.appendSlice(self.alloc, "{\"op\":\"deliver\",\"queue\":") catch return;
        jsonEscape(&b, self.alloc, queue) catch return;
        b.appendSlice(self.alloc, ",\"group\":") catch return;
        jsonEscape(&b, self.alloc, group) catch return;
        b.print(self.alloc, ",\"mid\":{d}{c}", .{ mid, '}' }) catch return;
        self.wal.emit(&b);
    }

    fn walAck(self: *Engine, queue: []const u8, group: []const u8, mid: u64) void {
        var b = std.ArrayList(u8).empty;
        defer b.deinit(self.alloc);
        b.appendSlice(self.alloc, "{\"op\":\"ack\",\"queue\":") catch return;
        jsonEscape(&b, self.alloc, queue) catch return;
        b.appendSlice(self.alloc, ",\"group\":") catch return;
        jsonEscape(&b, self.alloc, group) catch return;
        b.print(self.alloc, ",\"mid\":{d}{c}", .{ mid, '}' }) catch return;
        self.wal.emit(&b);
    }

    fn walCursor(self: *Engine, queue: []const u8, group: []const u8, cursor: u64) void {
        var b = std.ArrayList(u8).empty;
        defer b.deinit(self.alloc);
        b.appendSlice(self.alloc, "{\"op\":\"cursor\",\"queue\":") catch return;
        jsonEscape(&b, self.alloc, queue) catch return;
        b.appendSlice(self.alloc, ",\"group\":") catch return;
        jsonEscape(&b, self.alloc, group) catch return;
        b.print(self.alloc, ",\"cursor\":{d}{c}", .{ cursor, '}' }) catch return;
        self.wal.emit(&b);
    }

    fn walCancel(self: *Engine, id: []const u8) void {
        var b = std.ArrayList(u8).empty;
        defer b.deinit(self.alloc);
        b.appendSlice(self.alloc, "{\"op\":\"cancel\",\"id\":") catch return;
        jsonEscape(&b, self.alloc, id) catch return;
        b.appendSlice(self.alloc, "}") catch return;
        self.wal.emit(&b);
    }

    fn walDead(self: *Engine, queue: []const u8, group: []const u8, mid: u64) void {
        var b = std.ArrayList(u8).empty;
        defer b.deinit(self.alloc);
        b.appendSlice(self.alloc, "{\"op\":\"dead\",\"queue\":") catch return;
        jsonEscape(&b, self.alloc, queue) catch return;
        b.appendSlice(self.alloc, ",\"group\":") catch return;
        jsonEscape(&b, self.alloc, group) catch return;
        b.print(self.alloc, ",\"mid\":{d}{c}", .{ mid, '}' }) catch return;
        self.wal.emit(&b);
    }
};

// ================= WAL replay =================

fn replayWal(e: *Engine) !void {
    const content = e.wal.readAll() catch return;
    defer e.alloc.free(content);

    // inflight: queue -> group -> list of mids delivered but not acked
    var inflight = std.StringHashMap(std.StringHashMap(std.ArrayList(u64))).init(e.alloc);
    defer {
        var qit = inflight.iterator();
        while (qit.next()) |qe| {
            var git = qe.value_ptr.iterator();
            while (git.next()) |ge| {
                ge.value_ptr.deinit(e.alloc);
                e.alloc.free(ge.key_ptr.*);
            }
            qe.value_ptr.deinit();
            e.alloc.free(qe.key_ptr.*);
        }
        inflight.deinit();
    }

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const parsed = std.json.parseFromSlice(std.json.Value, e.alloc, line, .{}) catch continue;
        defer parsed.deinit();
        const obj = parsed.value.object;
        const op_v = obj.get("op") orelse continue;
        if (op_v != .string) continue;
        const op = op_v.string;

        const getStr = struct {
            fn f(o: std.json.ObjectMap, k: []const u8) ?[]const u8 {
                const v = o.get(k) orelse return null;
                if (v != .string) return null;
                return v.string;
            }
        }.f;
        const getU64 = struct {
            fn f(o: std.json.ObjectMap, k: []const u8) ?u64 {
                const v = o.get(k) orelse return null;
                if (v != .integer) return null;
                return @intCast(v.integer);
            }
        }.f;

        if (std.mem.eql(u8, op, "declare")) {
            const qn = getStr(obj, "queue") orelse continue;
            const sem = getStr(obj, "semantics") orelse "workqueue";
            const md = getU64(obj, "max_depth") orelse 10000;
            const ov = getStr(obj, "overflow") orelse "block";
            _ = e.declareQueue(qn, if (std.mem.eql(u8, sem, "topic")) .topic else .workqueue, @intCast(md), if (std.mem.eql(u8, ov, "drop_oldest")) .drop_oldest else .block) catch continue;
        } else if (std.mem.eql(u8, op, "pub")) {
            const qn = getStr(obj, "queue") orelse continue;
            const id = getStr(obj, "id") orelse continue;
            const pb64 = getStr(obj, "payload") orelse continue;
            const q = e.getQueue(qn) orelse continue;
            const dec_len = b64.Decoder.calcSizeForSlice(pb64) catch continue;
            const dec = e.alloc.alloc(u8, dec_len) catch continue;
            defer e.alloc.free(dec);
            b64.Decoder.decode(dec, pb64) catch continue;
            _ = q.publish(id, dec) catch continue;
        } else if (std.mem.eql(u8, op, "deliver")) {
            const qn = getStr(obj, "queue") orelse continue;
            const gn = getStr(obj, "group") orelse continue;
            const mid = getU64(obj, "mid") orelse continue;
            const qe = try inflight.getOrPut(try e.alloc.dupe(u8, qn));
            if (!qe.found_existing) qe.value_ptr.* = std.StringHashMap(std.ArrayList(u64)).init(e.alloc);
            const ge = try qe.value_ptr.getOrPut(try e.alloc.dupe(u8, gn));
            if (!ge.found_existing) ge.value_ptr.* = std.ArrayList(u64).empty;
            try ge.value_ptr.append(e.alloc, mid);
            // also bump deliver count so redelivery accounting survives restart
            if (e.getQueue(qn)) |q| _ = q.noteDeliver(mid);
        } else if (std.mem.eql(u8, op, "ack")) {
            const qn = getStr(obj, "queue") orelse continue;
            const gn = getStr(obj, "group") orelse continue;
            const mid = getU64(obj, "mid") orelse continue;
            if (inflight.getPtr(qn)) |qm| {
                if (qm.getPtr(gn)) |gm| {
                    var i: usize = 0;
                    while (i < gm.items.len) {
                        if (gm.items[i] == mid) {
                            _ = gm.orderedRemove(i);
                        } else i += 1;
                    }
                }
            }
        } else if (std.mem.eql(u8, op, "cursor")) {
            const qn = getStr(obj, "queue") orelse continue;
            const gn = getStr(obj, "group") orelse continue;
            const cur = getU64(obj, "cursor") orelse continue;
            if (e.getQueue(qn)) |q| {
                const g = q.getOrCreateGroup(gn) catch continue;
                g.cursor = @max(g.cursor, cur);
            }
        } else if (std.mem.eql(u8, op, "cancel")) {
            const id = getStr(obj, "id") orelse continue;
            e.cancelled.add(id) catch continue;
        }
        // "dead": no state change needed
    }

    // Pull cursors back over crash-time in-flight messages so they redeliver.
    var qit = inflight.iterator();
    while (qit.next()) |qe| {
        const q = e.getQueue(qe.key_ptr.*) orelse continue;
        var git = qe.value_ptr.iterator();
        while (git.next()) |ge| {
            if (ge.value_ptr.items.len == 0) continue;
            const g = q.getOrCreateGroup(ge.key_ptr.*) catch continue;
            var min_mid: u64 = std.math.maxInt(u64);
            for (ge.value_ptr.items) |m| min_mid = @min(min_mid, m);
            g.cursor = @min(g.cursor, min_mid);
        }
    }
}

// ================= timeout sweeper =================

fn sweeperMain(e: *Engine) void {
    var ts = std.os.linux.timespec{ .sec = 0, .nsec = 500_000_000 };
    while (true) {
        _ = std.os.linux.nanosleep(&ts, null);
        e.mutex.lock();
        const now = proto.nowNs();
        var qit = e.queues.iterator();
        while (qit.next()) |qe| {
            const q = qe.value_ptr.*;
            var git = q.groups.iterator();
            while (git.next()) |ge| {
                const g = ge.value_ptr.*;
                var expired = std.ArrayList(u64).empty;
                var pit = g.pending.iterator();
                while (pit.next()) |pe| {
                    if (pe.value_ptr.deadline_ns <= now) {
                        expired.append(e.alloc, pe.key_ptr.*) catch continue;
                    }
                }
                for (expired.items) |dlv| {
                    if (g.pending.fetchRemove(dlv)) |kv| {
                        const count = q.deliver_counts.get(kv.value.mid) orelse 1;
                        e.alloc.free(kv.value.consumer);
                        if (srv.requeueOrDead(count, g.max_deliver) == .requeued) {
                            g.cursor = @min(g.cursor, kv.value.mid);
                            e.walCursor(qe.key_ptr.*, g.name, g.cursor);
                        } else {
                            e.walDead(qe.key_ptr.*, g.name, kv.value.mid);
                        }
                    }
                }
                expired.deinit(e.alloc);
            }
        }
        e.mutex.unlock();
    }
}

// ================= deregister recycle (TLA+ Leave) =================

fn recycleConsumer(e: *Engine, from: []const u8) void {
    e.mutex.lock();
    defer e.mutex.unlock();
    var qit = e.queues.iterator();
    while (qit.next()) |qe| {
        const q = qe.value_ptr.*;
        var git = q.groups.iterator();
        while (git.next()) |ge| {
            const g = ge.value_ptr.*;
            var todrop = std.ArrayList(u64).empty;
            var pit = g.pending.iterator();
            while (pit.next()) |pe| {
                if (std.mem.eql(u8, pe.value_ptr.consumer, from)) {
                    todrop.append(e.alloc, pe.key_ptr.*) catch continue;
                }
            }
            for (todrop.items) |dlv| {
                if (g.pending.fetchRemove(dlv)) |kv| {
                    const count = q.deliver_counts.get(kv.value.mid) orelse 1;
                    e.alloc.free(kv.value.consumer);
                    if (srv.requeueOrDead(count, g.max_deliver) == .requeued) {
                        g.cursor = @min(g.cursor, kv.value.mid);
                        e.walCursor(qe.key_ptr.*, g.name, g.cursor);
                    } else {
                        e.walDead(qe.key_ptr.*, g.name, kv.value.mid);
                    }
                }
            }
            todrop.deinit(e.alloc);
            if (g.members.fetchRemove(from)) |kv| e.alloc.free(kv.key);
        }
    }
}

// ================= connection =================

const Conn = struct {
    io: std.Io,
    engine: *Engine,
    stream: net.Stream,
    alloc: std.mem.Allocator,
    next_seq: u64 = 1,

    fn sendXml(self: *Conn, primitive: proto.Primitive, in_reply_to: ?u64, body: []const u8) !void {
        var w = proto.XmlWriter.init(self.alloc);
        defer w.deinit();
        const seq = self.next_seq;
        self.next_seq += 1;
        try w.beginMsg(.{
            .primitive = primitive,
            .seq = seq,
            .ack = 0,
            .ts = proto.nowTs(),
            .from = "server",
            .in_reply_to = in_reply_to,
        });
        try w.raw(body);
        try w.endMsg();
        const xml = try w.toOwnedSlice();
        defer self.alloc.free(xml);
        var buf: [64 * 1024]u8 = undefined;
        var writer = self.stream.writer(self.io, &buf);
        try proto.writeFrame(&writer.interface, xml);
        try writer.interface.flush();
    }

    fn sendError(self: *Conn, in_reply_to: u64, code: []const u8, message: []const u8) !void {
        var w = proto.XmlWriter.init(self.alloc);
        defer w.deinit();
        const seq = self.next_seq;
        self.next_seq += 1;
        try w.beginMsg(.{
            .primitive = .err,
            .seq = seq,
            .ack = 0,
            .ts = proto.nowTs(),
            .from = "server",
            .in_reply_to = in_reply_to,
        });
        try w.element("code", code);
        try w.element("message", message);
        try w.element("retryable", "false");
        try w.endMsg();
        const xml = try w.toOwnedSlice();
        defer self.alloc.free(xml);
        var buf: [64 * 1024]u8 = undefined;
        var writer = self.stream.writer(self.io, &buf);
        try proto.writeFrame(&writer.interface, xml);
        try writer.interface.flush();
    }

    fn textOf(self: *Conn, msg: *proto.Message, name: []const u8) !?[]u8 {
        const el = msg.root.child(name) orelse return null;
        return try el.textContent(self.alloc);
    }

    fn handle(self: *Conn, msg: *proto.Message) !void {
        const env = msg.envelope;
        switch (env.primitive) {
            .agent_register => {
                try self.sendXml(.agent_register, env.seq, "<lease_s>15</lease_s>");
            },
            .agent_heartbeat => {},
            .agent_deregister => {
                recycleConsumer(self.engine, env.from);
            },
            .agent_card => {
                try self.sendXml(.agent_card, env.seq, "<skills></skills>");
            },
            .queue_declare => {
                const qt = try self.textOf(msg, "queue") orelse return self.sendError(env.seq, "AEVT-4007", "missing queue");
                defer self.alloc.free(qt);
                const sem_t = try self.textOf(msg, "semantics") orelse return self.sendError(env.seq, "AEVT-4007", "missing semantics");
                defer self.alloc.free(sem_t);
                const semantics: srv.Semantics = if (std.mem.eql(u8, sem_t, "workqueue")) .workqueue else if (std.mem.eql(u8, sem_t, "topic")) .topic else return self.sendError(env.seq, "AEVT-4007", "bad semantics");
                var max_depth: usize = 10000;
                if (try self.textOf(msg, "max_depth")) |md_t| {
                    defer self.alloc.free(md_t);
                    max_depth = std.fmt.parseInt(usize, std.mem.trim(u8, md_t, " \t\r\n"), 10) catch
                        return self.sendError(env.seq, "AEVT-4007", "bad max_depth");
                }
                var overflow: srv.Overflow = .block;
                if (try self.textOf(msg, "overflow")) |ov_t| {
                    defer self.alloc.free(ov_t);
                    const ov_trim = std.mem.trim(u8, ov_t, " \t\r\n");
                    if (std.mem.eql(u8, ov_trim, "drop_oldest")) overflow = .drop_oldest else if (!std.mem.eql(u8, ov_trim, "block")) return self.sendError(env.seq, "AEVT-4007", "bad overflow");
                }
                self.engine.mutex.lock();
                const created = self.engine.declareQueue(qt, semantics, max_depth, overflow) catch {
                    self.engine.mutex.unlock();
                    return;
                };
                if (created) self.engine.walDeclare(qt, semantics, max_depth, overflow);
                self.engine.mutex.unlock();
                try self.sendXml(.queue_declare, env.seq, "<ok/>");
            },
            .queue_publish => {
                const qt = try self.textOf(msg, "queue") orelse return self.sendError(env.seq, "AEVT-4007", "missing queue");
                defer self.alloc.free(qt);
                const mid_t = try self.textOf(msg, "message_id") orelse return self.sendError(env.seq, "AEVT-4007", "missing message_id");
                defer self.alloc.free(mid_t);
                const p_t = try self.textOf(msg, "payload") orelse return self.sendError(env.seq, "AEVT-4007", "missing payload");
                defer self.alloc.free(p_t);
                if (p_t.len > proto.max_payload_bytes) {
                    try self.sendError(env.seq, "AEVT-4007", "payload too large");
                    return;
                }
                // Cancel intercept: control-cancel payloads become tombstones, never queued.
                if (try proto.extractCancelTaskId(self.alloc, p_t)) |task_id| {
                    defer self.alloc.free(task_id);
                    self.engine.mutex.lock();
                    self.engine.cancelled.add(task_id) catch {};
                    self.engine.walCancel(task_id);
                    self.engine.mutex.unlock();
                    try self.sendXml(.queue_publish, env.seq, "<cancelled>true</cancelled>");
                    return;
                }
                self.engine.mutex.lock();
                const q = self.engine.getQueue(qt);
                if (q == null) {
                    self.engine.mutex.unlock();
                    try self.sendError(env.seq, "AEVT-4006", "queue not declared");
                    return;
                }
                const mid = q.?.publish(mid_t, p_t) catch |e| {
                    self.engine.mutex.unlock();
                    if (e == error.QueueFull) try self.sendError(env.seq, "AEVT-4001", "queue full");
                    return;
                };
                if (mid != 0) self.engine.walPub(qt, mid, mid_t, p_t);
                self.engine.mutex.unlock();
                var body_buf: [128]u8 = undefined;
                const body = try std.fmt.bufPrint(&body_buf, "<mid>{d}</mid><duplicate>{s}</duplicate>", .{ mid, if (mid == 0) "true" else "false" });
                try self.sendXml(.queue_publish, env.seq, body);
            },
            .queue_consume => {
                const qt = try self.textOf(msg, "queue") orelse return self.sendError(env.seq, "AEVT-4007", "missing queue");
                defer self.alloc.free(qt);
                var grp_buf: [128]u8 = undefined;
                var grp_len: usize = 0;
                if (try self.textOf(msg, "group")) |gt| {
                    defer self.alloc.free(gt);
                    const t = std.mem.trim(u8, gt, " \t\r\n");
                    grp_len = @min(t.len, grp_buf.len);
                    @memcpy(grp_buf[0..grp_len], t[0..grp_len]);
                }
                var ack_wait_s: u32 = 30;
                if (try self.textOf(msg, "ack_wait_s")) |aw_t| {
                    defer self.alloc.free(aw_t);
                    ack_wait_s = std.fmt.parseInt(u32, std.mem.trim(u8, aw_t, " \t\r\n"), 10) catch
                        return self.sendError(env.seq, "AEVT-4007", "bad ack_wait_s");
                }
                var max_deliver: u32 = 5;
                if (try self.textOf(msg, "max_deliver")) |md_t| {
                    defer self.alloc.free(md_t);
                    max_deliver = std.fmt.parseInt(u32, std.mem.trim(u8, md_t, " \t\r\n"), 10) catch
                        return self.sendError(env.seq, "AEVT-4007", "bad max_deliver");
                }

                self.engine.mutex.lock();
                const q = self.engine.getQueue(qt);
                if (q == null) {
                    self.engine.mutex.unlock();
                    try self.sendError(env.seq, "AEVT-4006", "queue not declared");
                    return;
                }
                // Topic: each subscriber gets its own group (every subscriber gets every message).
                var gname_buf: [256]u8 = undefined;
                const gname: []const u8 = if (q.?.semantics == .topic) blk: {
                    break :blk std.fmt.bufPrint(&gname_buf, "topic:{s}", .{env.from}) catch {
                        self.engine.mutex.unlock();
                        return;
                    };
                } else if (grp_len > 0) grp_buf[0..grp_len] else "default";
                const group = q.?.getOrCreateGroup(gname) catch {
                    self.engine.mutex.unlock();
                    return;
                };
                group.ack_wait_s = ack_wait_s;
                group.max_deliver = max_deliver;
                if (!group.members.contains(env.from)) {
                    const from_copy = self.alloc.dupe(u8, env.from) catch {
                        self.engine.mutex.unlock();
                        return;
                    };
                    group.members.put(from_copy, {}) catch {
                        self.alloc.free(from_copy);
                        self.engine.mutex.unlock();
                        return;
                    };
                }
                var deliver_body: ?[]u8 = null;
                defer if (deliver_body) |d| self.alloc.free(d);
                if (q.?.nextForGroup(group, &self.engine.cancelled)) |m| {
                    const dcnt = q.?.noteDeliver(m.mid);
                    const dlv_id = self.engine.next_delivery_id;
                    self.engine.next_delivery_id += 1;
                    const consumer = self.alloc.dupe(u8, env.from) catch {
                        self.engine.mutex.unlock();
                        return;
                    };
                    group.pending.put(dlv_id, .{
                        .mid = m.mid,
                        .deliver_count = dcnt,
                        .consumer = consumer,
                        .deadline_ns = proto.nowNs() + @as(i128, ack_wait_s) * 1000000000,
                    }) catch {
                        self.alloc.free(consumer);
                        self.engine.mutex.unlock();
                        return;
                    };
                    group.cursor = @max(group.cursor, m.mid + 1);
                    var w = proto.XmlWriter.init(self.alloc);
                    defer w.deinit();
                    var dbuf: [64]u8 = undefined;
                    w.element("queue", qt) catch {};
                    w.element("group", group.name) catch {};
                    w.element("delivery_id", std.fmt.bufPrint(&dbuf, "dlv-{d}", .{dlv_id}) catch "dlv-0") catch {};
                    w.element("redelivered", if (dcnt > 1) "true" else "false") catch {};
                    w.element("message_id", m.message_id) catch {};
                    w.elementCdata("payload", m.payload) catch {};
                    deliver_body = w.buf.toOwnedSlice(self.alloc) catch null;
                    self.engine.walDeliver(qt, group.name, m.mid);
                    self.engine.walCursor(qt, group.name, group.cursor);
                }
                self.engine.mutex.unlock();
                if (deliver_body) |dx| {
                    try self.sendXml(.queue_deliver, null, dx);
                }
            },
            .queue_unconsume => {
                const qt = try self.textOf(msg, "queue") orelse return self.sendError(env.seq, "AEVT-4007", "missing queue");
                defer self.alloc.free(qt);
                const grp_t = try self.textOf(msg, "group") orelse return self.sendError(env.seq, "AEVT-4007", "missing group");
                defer self.alloc.free(grp_t);
                self.engine.mutex.lock();
                defer self.engine.mutex.unlock();
                if (self.engine.getQueue(qt)) |q| {
                    if (q.groups.get(std.mem.trim(u8, grp_t, " \t\r\n"))) |g| {
                        if (g.members.fetchRemove(env.from)) |kv| self.alloc.free(kv.key);
                    }
                }
            },
            .queue_deliver => {},
            .queue_ack => {
                const qt = try self.textOf(msg, "queue") orelse return;
                defer self.alloc.free(qt);
                const grp_t = try self.textOf(msg, "group") orelse return;
                defer self.alloc.free(grp_t);
                const dlv_t = try self.textOf(msg, "delivery_id") orelse return;
                defer self.alloc.free(dlv_t);
                const dash = std.mem.indexOfScalar(u8, dlv_t, '-') orelse return;
                const dlv_id = std.fmt.parseInt(u64, std.mem.trim(u8, dlv_t[dash + 1 ..], " \t\r\n"), 10) catch return;
                const requeue = msg.root.child("requeue") != null;
                self.engine.mutex.lock();
                const q = self.engine.getQueue(qt) orelse {
                    self.engine.mutex.unlock();
                    return;
                };
                const group = q.groups.get(std.mem.trim(u8, grp_t, " \t\r\n")) orelse {
                    self.engine.mutex.unlock();
                    return;
                };
                if (group.pending.fetchRemove(dlv_id)) |kv| {
                    const count = q.deliver_counts.get(kv.value.mid) orelse 1;
                    self.alloc.free(kv.value.consumer);
                    if (requeue) {
                        if (srv.requeueOrDead(count, group.max_deliver) == .requeued) {
                            group.cursor = @min(group.cursor, kv.value.mid);
                            self.engine.walCursor(qt, group.name, group.cursor);
                        } else {
                            self.engine.walDead(qt, group.name, kv.value.mid);
                        }
                    } else {
                        self.engine.walAck(qt, group.name, kv.value.mid);
                    }
                }
                self.engine.mutex.unlock();
            },
            .err => {},
        }
    }

    fn run(self: *Conn) void {
        defer self.stream.close(self.io);
        var read_buf: [64 * 1024]u8 = undefined;
        var reader = self.stream.reader(self.io, &read_buf);
        while (true) {
            const frame = proto.readFrame(self.alloc, &reader.interface) catch break;
            var msg = proto.decode(self.alloc, frame) catch {
                self.alloc.free(frame);
                break;
            };
            defer msg.deinit();
            self.handle(&msg) catch break;
        }
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const sock_path = ".agent-sock/agent.sock";
    const data_dir = ".agent-sock/data";

    const wal = try Wal.open(alloc, io, data_dir);
    var engine = Engine.init(alloc, wal);
    defer engine.deinit();

    // Replay before declaring defaults: replay recreates queues from WAL.
    replayWal(&engine) catch |e| {
        std.debug.print("wal replay failed: {s}\n", .{@errorName(e)});
    };

    engine.mutex.lock();
    if (try engine.declareQueue("task.dispatch", .workqueue, 10000, .block))
        engine.walDeclare("task.dispatch", .workqueue, 10000, .block);
    if (try engine.declareQueue("events", .topic, 100000, .drop_oldest))
        engine.walDeclare("events", .topic, 100000, .drop_oldest);
    if (try engine.declareQueue("approval.requests", .workqueue, 10000, .block))
        engine.walDeclare("approval.requests", .workqueue, 10000, .block);
    engine.mutex.unlock();

    // Timeout sweeper (ack_wait expiry -> requeue_or_dead).
    const sweeper = try std.Thread.spawn(.{}, sweeperMain, .{&engine});
    sweeper.detach();

    const ua = try net.UnixAddress.init(sock_path);
    // Remove stale socket file from a previous crash; otherwise bind fails
    // with AddressInUse and the server cannot restart (WAL recovery never runs).
    std.Io.Dir.cwd().deleteFile(io, sock_path) catch {};
    var listener = try ua.listen(io, .{});
    defer listener.deinit(io);

    var out_buf: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &out_buf);
    try stdout.interface.print("asock-server listening on {s}\n", .{sock_path});
    try stdout.interface.flush();

    while (true) {
        const stream = try listener.accept(io);
        const Ctx = struct {
            engine: *Engine,
            stream: net.Stream,
            io: std.Io,
            alloc: std.mem.Allocator,
        };
        const ctx = try alloc.create(Ctx);
        ctx.* = .{ .engine = &engine, .stream = stream, .io = io, .alloc = alloc };
        const thread = std.Thread.spawn(.{}, struct {
            fn run(c: *Ctx) void {
                var conn = Conn{ .io = c.io, .engine = c.engine, .stream = c.stream, .alloc = c.alloc };
                conn.run();
                c.alloc.destroy(c);
            }
        }.run, .{ctx}) catch {
            stream.close(io);
            alloc.destroy(ctx);
            continue;
        };
        thread.detach();
    }
}
