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

// The Wal type (append + group-commit fsync + torn-tail repair) lives in
// server.zig so `zig build test` covers it. Records here:
//   declare | pub | deliver(dlv) | ack | requeue(not_before_ms) | dead(reason)
//   | cancel | cursor (legacy, ignored on replay)
// Rule: a handler takes wal.lastSeq() under the engine lock, unlocks, then
// calls wal.commit(seq) before it sends any reply or delivery.

// ================= Engine =================

const Engine = struct {
    alloc: std.mem.Allocator,
    mutex: proto.SpinLock = .{},
    queues: std.StringHashMap(*srv.Queue),
    cancelled: srv.CancelledSet,
    next_delivery_id: u64 = 1,
    wal: srv.Wal,
    prng: std.Random.DefaultPrng,

    fn init(alloc: std.mem.Allocator, wal: srv.Wal) Engine {
        return .{
            .alloc = alloc,
            .queues = std.StringHashMap(*srv.Queue).init(alloc),
            .cancelled = srv.CancelledSet.init(alloc),
            .wal = wal,
            .prng = std.Random.DefaultPrng.init(@truncate(@as(u128, @bitCast(proto.nowNs())))),
        };
    }

    /// requeue_or_dead (S2): the single reentry path for timeout, leave and
    /// ack+<requeue/>. Requeue sets a backoff deadline; the last attempt goes
    /// to the dead-letter set. Call with the lock held. Returns true if dead.
    fn reenter(self: *Engine, qname: []const u8, q: *srv.Queue, g: *srv.GroupState, mid: u64) bool {
        const count = q.deliver_counts.get(mid) orelse 1;
        if (srv.requeueOrDead(count, g.max_deliver) == .dead) {
            const info = srv.DeadInfo{ .reason = .max_deliver, .deliver_count = count, .at_ms = proto.nowMs() };
            g.markDead(mid, info) catch {};
            self.walDead(qname, g.name, mid, info.reason);
            return true;
        }
        const delay = srv.backoffDelayMs(count, g.backoff_base_ms, g.backoff_max_ms, self.prng.random().float(f64));
        const until: i64 = if (delay == 0) 0 else proto.nowMs() + @as(i64, @intCast(delay));
        g.markRequeued(mid, until) catch {};
        self.walRequeue(qname, g.name, mid, until);
        return false;
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

    fn emit(self: *Engine, b: *std.ArrayList(u8)) void {
        // On error the Wal goes fail-stop; the next commit() fails, so the
        // handler replies AEVT-3001 instead of an ack.
        _ = self.wal.append(self.alloc, b.items) catch {};
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
        self.emit(&b);
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
        self.emit(&b);
    }

    fn walDeliver(self: *Engine, queue: []const u8, group: []const u8, mid: u64, dlv: u64) void {
        var b = std.ArrayList(u8).empty;
        defer b.deinit(self.alloc);
        b.appendSlice(self.alloc, "{\"op\":\"deliver\",\"queue\":") catch return;
        jsonEscape(&b, self.alloc, queue) catch return;
        b.appendSlice(self.alloc, ",\"group\":") catch return;
        jsonEscape(&b, self.alloc, group) catch return;
        b.print(self.alloc, ",\"mid\":{d},\"dlv\":{d}{c}", .{ mid, dlv, '}' }) catch return;
        self.emit(&b);
    }

    fn walRequeue(self: *Engine, queue: []const u8, group: []const u8, mid: u64, not_before_ms: i64) void {
        var b = std.ArrayList(u8).empty;
        defer b.deinit(self.alloc);
        b.appendSlice(self.alloc, "{\"op\":\"requeue\",\"queue\":") catch return;
        jsonEscape(&b, self.alloc, queue) catch return;
        b.appendSlice(self.alloc, ",\"group\":") catch return;
        jsonEscape(&b, self.alloc, group) catch return;
        b.print(self.alloc, ",\"mid\":{d},\"not_before_ms\":{d}{c}", .{ mid, not_before_ms, '}' }) catch return;
        self.emit(&b);
    }

    fn walAck(self: *Engine, queue: []const u8, group: []const u8, mid: u64) void {
        var b = std.ArrayList(u8).empty;
        defer b.deinit(self.alloc);
        b.appendSlice(self.alloc, "{\"op\":\"ack\",\"queue\":") catch return;
        jsonEscape(&b, self.alloc, queue) catch return;
        b.appendSlice(self.alloc, ",\"group\":") catch return;
        jsonEscape(&b, self.alloc, group) catch return;
        b.print(self.alloc, ",\"mid\":{d}{c}", .{ mid, '}' }) catch return;
        self.emit(&b);
    }

    fn walCursor(self: *Engine, queue: []const u8, group: []const u8, cursor: u64) void {
        var b = std.ArrayList(u8).empty;
        defer b.deinit(self.alloc);
        b.appendSlice(self.alloc, "{\"op\":\"cursor\",\"queue\":") catch return;
        jsonEscape(&b, self.alloc, queue) catch return;
        b.appendSlice(self.alloc, ",\"group\":") catch return;
        jsonEscape(&b, self.alloc, group) catch return;
        b.print(self.alloc, ",\"cursor\":{d}{c}", .{ cursor, '}' }) catch return;
        self.emit(&b);
    }

    fn walCancel(self: *Engine, id: []const u8) void {
        var b = std.ArrayList(u8).empty;
        defer b.deinit(self.alloc);
        b.appendSlice(self.alloc, "{\"op\":\"cancel\",\"id\":") catch return;
        jsonEscape(&b, self.alloc, id) catch return;
        b.appendSlice(self.alloc, "}") catch return;
        self.emit(&b);
    }

    fn walDead(self: *Engine, queue: []const u8, group: []const u8, mid: u64, reason: srv.DeadReason) void {
        var b = std.ArrayList(u8).empty;
        defer b.deinit(self.alloc);
        b.appendSlice(self.alloc, "{\"op\":\"dead\",\"queue\":") catch return;
        jsonEscape(&b, self.alloc, queue) catch return;
        b.appendSlice(self.alloc, ",\"group\":") catch return;
        jsonEscape(&b, self.alloc, group) catch return;
        b.print(self.alloc, ",\"mid\":{d},\"reason\":\"{s}\"{c}", .{ mid, reason.str(), '}' }) catch return;
        self.emit(&b);
    }
};

// ================= WAL replay =================

fn replayWal(e: *Engine) !void {
    const content = try e.wal.readAll(e.alloc);
    defer e.alloc.free(content);

    var max_dlv: u64 = 0;
    var n_deliver: u64 = 0;
    var bad_lines: usize = 0;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const parsed = std.json.parseFromSlice(std.json.Value, e.alloc, line, .{}) catch {
            bad_lines += 1;
            continue;
        };
        defer parsed.deinit();
        if (parsed.value != .object) continue;
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
                if (v != .integer or v.integer < 0) return null;
                return @intCast(v.integer);
            }
        }.f;
        const getI64 = struct {
            fn f(o: std.json.ObjectMap, k: []const u8) ?i64 {
                const v = o.get(k) orelse return null;
                if (v != .integer) return null;
                return v.integer;
            }
        }.f;

        if (std.mem.eql(u8, op, "declare")) {
            const qn = getStr(obj, "queue") orelse continue;
            const sem = getStr(obj, "semantics") orelse "workqueue";
            const md = getU64(obj, "max_depth") orelse 10000;
            const ov = getStr(obj, "overflow") orelse "block";
            _ = e.declareQueue(qn, if (std.mem.eql(u8, sem, "topic")) .topic else .workqueue, @intCast(md), if (std.mem.eql(u8, ov, "drop_oldest")) .drop_oldest else .block) catch continue;
            continue;
        }
        if (std.mem.eql(u8, op, "cancel")) {
            const id = getStr(obj, "id") orelse continue;
            e.cancelled.add(id) catch continue;
            continue;
        }
        const qn = getStr(obj, "queue") orelse continue;
        const q = e.getQueue(qn) orelse continue;
        if (std.mem.eql(u8, op, "pub")) {
            const id = getStr(obj, "id") orelse continue;
            const pb64 = getStr(obj, "payload") orelse continue;
            const dec_len = b64.Decoder.calcSizeForSlice(pb64) catch continue;
            const dec = e.alloc.alloc(u8, dec_len) catch continue;
            defer e.alloc.free(dec);
            b64.Decoder.decode(dec, pb64) catch continue;
            _ = q.publish(id, dec) catch continue;
            continue;
        }
        const gn = getStr(obj, "group") orelse continue;
        const mid = getU64(obj, "mid") orelse continue;
        const g = q.getOrCreateGroup(gn) catch continue;
        if (std.mem.eql(u8, op, "deliver")) {
            // Deliver count survives restart: max_deliver holds across crashes.
            _ = q.noteDeliver(mid);
            n_deliver += 1;
            if (getU64(obj, "dlv")) |d| max_dlv = @max(max_dlv, d);
            _ = g.not_before_ms.remove(mid);
        } else if (std.mem.eql(u8, op, "ack")) {
            g.markAcked(mid) catch continue;
        } else if (std.mem.eql(u8, op, "requeue")) {
            g.markRequeued(mid, getI64(obj, "not_before_ms") orelse 0) catch continue;
        } else if (std.mem.eql(u8, op, "dead")) {
            const reason = srv.DeadReason.parse(getStr(obj, "reason") orelse "max_deliver");
            g.markDead(mid, .{ .reason = reason, .deliver_count = q.deliver_counts.get(mid) orelse 0, .at_ms = 0 }) catch continue;
        }
        // "cursor": legacy record, ignored. Messages that were in flight at
        // crash time are neither done nor in flight now, so they redeliver.
    }
    // Delivery ids must not repeat across restarts: a stale ack for an old
    // id must not hit a new delivery.
    e.next_delivery_id = @max(max_dlv, n_deliver) + 1;
    if (bad_lines > 0) std.debug.print("wal replay: skipped {d} corrupt line(s)\n", .{bad_lines});
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
                        e.alloc.free(kv.value.consumer);
                        _ = e.reenter(qe.key_ptr.*, q, g, kv.value.mid);
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
                    e.alloc.free(kv.value.consumer);
                    _ = e.reenter(qe.key_ptr.*, q, g, kv.value.mid);
                }
            }
            todrop.deinit(e.alloc);
            if (g.members.fetchRemove(from)) |kv| e.alloc.free(kv.key);
        }
    }
}

fn parseSecondsMs(t: []const u8) ?u64 {
    const v = std.fmt.parseFloat(f64, std.mem.trim(u8, t, " \t\r\n")) catch return null;
    if (!(v >= 0) or v > 1e9) return null;
    return @intFromFloat(v * 1000.0);
}

/// `asock-server --dlq <queue>`: replay the WAL read-only and print the
/// dead letters of <queue> as JSON lines. Safe while a server runs.
fn printDlq(e: *Engine, io: std.Io, queue: []const u8) !void {
    var out_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &out_buf);
    const w = &stdout.interface;
    const q = e.getQueue(queue) orelse {
        try w.print("{{\"queue\":\"{s}\",\"error\":\"not found\"}}\n", .{queue});
        try w.flush();
        return;
    };
    var git = q.groups.iterator();
    while (git.next()) |ge| {
        const g = ge.value_ptr.*;
        var dit = g.dead.iterator();
        while (dit.next()) |de| {
            const mid = de.key_ptr.*;
            var id: []const u8 = "";
            for (q.messages.items) |m| {
                if (m.mid == mid) id = m.message_id;
            }
            var b = std.ArrayList(u8).empty;
            defer b.deinit(e.alloc);
            try b.appendSlice(e.alloc, "{\"queue\":");
            try jsonEscape(&b, e.alloc, queue);
            try b.appendSlice(e.alloc, ",\"group\":");
            try jsonEscape(&b, e.alloc, g.name);
            try b.print(e.alloc, ",\"mid\":{d},\"message_id\":", .{mid});
            try jsonEscape(&b, e.alloc, id);
            try b.print(e.alloc, ",\"reason\":\"{s}\",\"deliver_count\":{d}}}", .{ de.value_ptr.reason.str(), de.value_ptr.deliver_count });
            try w.print("{s}\n", .{b.items});
        }
    }
    try w.flush();
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

    /// Wait for the WAL to cover `seq`. On failure send AEVT-3001 and return
    /// null (the caller must not reply with success).
    fn commitOrError(self: *Conn, in_reply_to: u64, seq: u64) !?void {
        self.engine.wal.commit(self.io, seq) catch {
            try self.sendError(in_reply_to, "AEVT-3001", "wal write failed");
            return null;
        };
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
                const seq = self.engine.wal.lastSeq();
                self.engine.mutex.unlock();
                try self.commitOrError(env.seq, seq) orelse return;
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
                    const seq = self.engine.wal.lastSeq();
                    self.engine.mutex.unlock();
                    try self.commitOrError(env.seq, seq) orelse return;
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
                const seq = self.engine.wal.lastSeq();
                self.engine.mutex.unlock();
                // Fsync before the publish reply: an acked publish survives a crash.
                try self.commitOrError(env.seq, seq) orelse return;
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
                // Backoff in seconds (same field names as the Python server).
                var backoff_base_ms: ?u64 = null;
                if (try self.textOf(msg, "backoff_base_s")) |t| {
                    defer self.alloc.free(t);
                    backoff_base_ms = parseSecondsMs(t) orelse return self.sendError(env.seq, "AEVT-4007", "bad backoff_base_s");
                }
                var backoff_max_ms: ?u64 = null;
                if (try self.textOf(msg, "backoff_max_s")) |t| {
                    defer self.alloc.free(t);
                    backoff_max_ms = parseSecondsMs(t) orelse return self.sendError(env.seq, "AEVT-4007", "bad backoff_max_s");
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
                if (backoff_base_ms) |v| group.backoff_base_ms = v;
                if (backoff_max_ms) |v| group.backoff_max_ms = v;
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
                if (q.?.nextForGroup(group, &self.engine.cancelled, proto.nowMs())) |m| {
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
                    group.inflight.put(m.mid, {}) catch {};
                    _ = group.not_before_ms.remove(m.mid);
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
                    self.engine.walDeliver(qt, group.name, m.mid, dlv_id);
                }
                const seq = self.engine.wal.lastSeq();
                self.engine.mutex.unlock();
                if (deliver_body) |dx| {
                    // Deliver count is on disk before the consumer sees it.
                    try self.commitOrError(env.seq, seq) orelse return;
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
                const reject = msg.root.child("reject") != null; // straight to dead letters
                if (requeue and reject) return self.sendError(env.seq, "AEVT-4007", "requeue and reject are exclusive");
                self.engine.mutex.lock();
                const q = self.engine.getQueue(qt) orelse {
                    self.engine.mutex.unlock();
                    return self.sendError(env.seq, "AEVT-4006", "queue not declared");
                };
                const group = q.groups.get(std.mem.trim(u8, grp_t, " \t\r\n")) orelse {
                    self.engine.mutex.unlock();
                    return self.sendError(env.seq, "AEVT-4007", "unknown group");
                };
                var result: []const u8 = "acked";
                if (group.pending.fetchRemove(dlv_id)) |kv| {
                    self.alloc.free(kv.value.consumer);
                    const mid = kv.value.mid;
                    if (reject) {
                        const info = srv.DeadInfo{ .reason = .rejected, .deliver_count = q.deliver_counts.get(mid) orelse 1, .at_ms = proto.nowMs() };
                        group.markDead(mid, info) catch {};
                        self.engine.walDead(qt, group.name, mid, .rejected);
                        result = "dead";
                    } else if (requeue) {
                        result = if (self.engine.reenter(qt, q, group, mid)) "dead" else "queued";
                    } else {
                        group.markAcked(mid) catch {};
                        self.engine.walAck(qt, group.name, mid);
                    }
                } else {
                    self.engine.mutex.unlock();
                    return self.sendError(env.seq, "AEVT-4007", "ack on non-pending delivery");
                }
                const seq = self.engine.wal.lastSeq();
                self.engine.mutex.unlock();
                // Reply only after the ack record is on disk.
                try self.commitOrError(env.seq, seq) orelse return;
                var rb: [64]u8 = undefined;
                try self.sendXml(.queue_ack, env.seq, std.fmt.bufPrint(&rb, "<ok>true</ok><result>{s}</result>", .{result}) catch "<ok>true</ok>");
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

    var dlq_queue: ?[]const u8 = null;
    var fsync_enabled = true;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var ai: usize = 1;
    while (ai < args.len) : (ai += 1) {
        if (std.mem.eql(u8, args[ai], "--dlq") and ai + 1 < args.len) {
            dlq_queue = args[ai + 1];
            ai += 1;
        } else if (std.mem.eql(u8, args[ai], "--no-fsync")) {
            fsync_enabled = false; // measurement only: unsafe
        }
    }

    if (dlq_queue) |qn| {
        const ro = try srv.Wal.open(data_dir, "wal.jsonl", false, true);
        var ro_engine = Engine.init(alloc, ro);
        defer ro_engine.deinit();
        try replayWal(&ro_engine);
        try printDlq(&ro_engine, io, qn);
        return;
    }

    const wal = try srv.Wal.open(data_dir, "wal.jsonl", fsync_enabled, false);
    if (wal.torn_bytes > 0) std.debug.print("wal: truncated {d} torn byte(s)\n", .{wal.torn_bytes});
    var engine = Engine.init(alloc, wal);
    defer engine.deinit();

    // Replay before declaring defaults: replay recreates queues from WAL.
    // A replay error is fatal: serving from a partial state would ack
    // publishes on top of lost ones.
    try replayWal(&engine);

    engine.mutex.lock();
    if (try engine.declareQueue("task.dispatch", .workqueue, 10000, .block))
        engine.walDeclare("task.dispatch", .workqueue, 10000, .block);
    if (try engine.declareQueue("events", .topic, 100000, .drop_oldest))
        engine.walDeclare("events", .topic, 100000, .drop_oldest);
    if (try engine.declareQueue("approval.requests", .workqueue, 10000, .block))
        engine.walDeclare("approval.requests", .workqueue, 10000, .block);
    const decl_seq = engine.wal.lastSeq();
    engine.mutex.unlock();
    try engine.wal.commit(io, decl_seq);

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
