const std = @import("std");
const proto = @import("proto");

/// Queue semantics: workqueue (one consumer per message within a group)
/// or topic (every subscriber gets every message).
pub const Semantics = enum { workqueue, topic };

pub const Overflow = enum { block, drop_oldest };

/// A single queued message.
pub const QueuedMessage = struct {
    mid: u64, // server-assigned sequence
    message_id: []const u8, // idempotency key from publisher
    payload: []const u8, // owned
    cancelled: bool = false,
};

pub const DeadReason = enum {
    rejected, // consumer sent ack+<reject/>: no redelivery
    max_deliver, // deliver count reached max_deliver

    pub fn str(self: DeadReason) []const u8 {
        return switch (self) {
            .rejected => "rejected",
            .max_deliver => "max_deliver",
        };
    }

    pub fn parse(s: []const u8) DeadReason {
        return if (std.mem.eql(u8, s, "rejected")) .rejected else .max_deliver;
    }
};

pub const DeadInfo = struct {
    reason: DeadReason,
    deliver_count: u32,
    at_ms: i64,
};

pub const default_backoff_base_ms: u64 = 1000;
pub const default_backoff_max_ms: u64 = 60_000;

/// Per-group consumption state.
/// A message is deliverable to a group when it is not done (acked or dead),
/// not in flight, not cancelled, and not in backoff. The old cursor-only
/// model redelivered every message after a requeued one (acked and in-flight
/// ones too); per-mid sets fix that.
pub const GroupState = struct {
    name: []const u8,
    cursor: u64 = 0, // legacy WAL field; not used for selection
    pending: std.AutoHashMap(u64, PendingEntry), // delivery_id -> entry
    members: std.StringHashMap(void), // consumer from-ids
    done: std.AutoHashMap(u64, void), // mid acked or dead
    inflight: std.AutoHashMap(u64, void), // mid delivered, not acked
    not_before_ms: std.AutoHashMap(u64, i64), // mid -> backoff end (wall ms)
    dead: std.AutoHashMap(u64, DeadInfo), // dead-letter entries
    ack_wait_s: u32 = 30,
    max_deliver: u32 = 5,
    backoff_base_ms: u64 = default_backoff_base_ms,
    backoff_max_ms: u64 = default_backoff_max_ms,

    pub fn init(alloc: std.mem.Allocator, name: []const u8) !GroupState {
        return .{
            .name = try alloc.dupe(u8, name),
            .pending = std.AutoHashMap(u64, PendingEntry).init(alloc),
            .members = std.StringHashMap(void).init(alloc),
            .done = std.AutoHashMap(u64, void).init(alloc),
            .inflight = std.AutoHashMap(u64, void).init(alloc),
            .not_before_ms = std.AutoHashMap(u64, i64).init(alloc),
            .dead = std.AutoHashMap(u64, DeadInfo).init(alloc),
        };
    }

    pub fn deinit(self: *GroupState, alloc: std.mem.Allocator) void {
        var pit = self.pending.iterator();
        while (pit.next()) |e| alloc.free(e.value_ptr.consumer);
        self.pending.deinit();
        var mit = self.members.keyIterator();
        while (mit.next()) |k| alloc.free(k.*);
        self.members.deinit();
        self.done.deinit();
        self.inflight.deinit();
        self.not_before_ms.deinit();
        self.dead.deinit();
        alloc.free(self.name);
    }

    pub fn markAcked(self: *GroupState, mid: u64) !void {
        _ = self.inflight.remove(mid);
        _ = self.not_before_ms.remove(mid);
        try self.done.put(mid, {});
    }

    pub fn markDead(self: *GroupState, mid: u64, info: DeadInfo) !void {
        _ = self.inflight.remove(mid);
        _ = self.not_before_ms.remove(mid);
        try self.done.put(mid, {});
        try self.dead.put(mid, info);
    }

    /// Back to the pool. until_ms == 0 means no backoff.
    pub fn markRequeued(self: *GroupState, mid: u64, until_ms: i64) !void {
        _ = self.inflight.remove(mid);
        if (until_ms > 0) {
            try self.not_before_ms.put(mid, until_ms);
        } else {
            _ = self.not_before_ms.remove(mid);
        }
    }
};

/// Backoff delay after the `attempts`-th failed delivery.
/// d = min(max, base * 2^(attempts-1)); result in [d/2, d) (equal jitter).
/// `u` is a uniform random number in [0, 1).
pub fn backoffDelayMs(attempts: u32, base_ms: u64, max_ms: u64, u: f64) u64 {
    if (base_ms == 0 or attempts == 0) return 0;
    const shift: u6 = @intCast(@min(attempts - 1, 30));
    const raw = std.math.mul(u64, base_ms, @as(u64, 1) << shift) catch max_ms;
    const d: f64 = @floatFromInt(@min(raw, max_ms));
    return @intFromFloat(d * (0.5 + 0.5 * u));
}

pub const PendingEntry = struct {
    mid: u64,
    deliver_count: u32 = 1,
    consumer: []const u8, // owned copy of from-id
    deadline_ns: i128, // ack_wait expiry
};

pub const Subscriber = struct {
    from: []const u8,
    filter: ?[]const u8, // topic filter, supports * and >
    since: u64,
};

pub const Queue = struct {
    alloc: std.mem.Allocator,
    name: []const u8,
    semantics: Semantics,
    max_depth: usize,
    overflow: Overflow,
    messages: std.ArrayList(QueuedMessage),
    next_mid: u64 = 1,
    seen_ids: std.StringHashMap(void), // message_id dedup
    deliver_counts: std.AutoHashMap(u64, u32), // mid -> times delivered
    groups: std.StringHashMap(*GroupState), // workqueue
    subscribers: std.ArrayList(Subscriber), // topic

    pub fn init(
        alloc: std.mem.Allocator,
        name: []const u8,
        semantics: Semantics,
        max_depth: usize,
        overflow: Overflow,
    ) !*Queue {
        const q = try alloc.create(Queue);
        q.* = .{
            .alloc = alloc,
            .name = try alloc.dupe(u8, name),
            .semantics = semantics,
            .max_depth = max_depth,
            .overflow = overflow,
            .messages = std.ArrayList(QueuedMessage).empty,
            .seen_ids = std.StringHashMap(void).init(alloc),
            .deliver_counts = std.AutoHashMap(u64, u32).init(alloc),
            .groups = std.StringHashMap(*GroupState).init(alloc),
            .subscribers = std.ArrayList(Subscriber).empty,
        };
        return q;
    }

    pub fn deinit(self: *Queue) void {
        const alloc = self.alloc;
        for (self.messages.items) |m| {
            alloc.free(m.message_id);
            alloc.free(m.payload);
        }
        self.messages.deinit(alloc);
        var it = self.seen_ids.keyIterator();
        while (it.next()) |k| alloc.free(k.*);
        self.seen_ids.deinit();
        self.deliver_counts.deinit();
        var git = self.groups.iterator();
        while (git.next()) |e| {
            e.value_ptr.*.deinit(alloc);
            alloc.destroy(e.value_ptr.*);
            alloc.free(e.key_ptr.*);
        }
        self.groups.deinit();
        for (self.subscribers.items) |s| {
            alloc.free(s.from);
            if (s.filter) |f| alloc.free(f);
        }
        self.subscribers.deinit(alloc);
        alloc.free(self.name);
        alloc.destroy(self);
    }

    /// Publish. Returns mid, or 0 if duplicate (idempotent).
    /// Tombstone note: cancelled tombstones live in the engine, checked at deliver.
    pub fn publish(self: *Queue, message_id: []const u8, payload: []const u8) !u64 {
        if (self.seen_ids.contains(message_id)) return 0; // duplicate
        if (self.messages.items.len >= self.max_depth) {
            if (self.overflow == .block) return error.QueueFull;
            // drop_oldest: evict oldest unconsumed
            const old = self.messages.orderedRemove(0);
            self.alloc.free(old.message_id);
            self.alloc.free(old.payload);
        }
        const mid = self.next_mid;
        self.next_mid += 1;
        try self.messages.append(self.alloc, .{
            .mid = mid,
            .message_id = try self.alloc.dupe(u8, message_id),
            .payload = try self.alloc.dupe(u8, payload),
        });
        try self.seen_ids.put(try self.alloc.dupe(u8, message_id), {});
        // Durability: the engine writes the "pub" record to the Wal (below)
        // and commits it before it replies.
        return mid;
    }

    pub fn getOrCreateGroup(self: *Queue, name: []const u8) !*GroupState {
        if (self.groups.get(name)) |g| return g;
        const g = try self.alloc.create(GroupState);
        g.* = try GroupState.init(self.alloc, name);
        try self.groups.put(try self.alloc.dupe(u8, name), g);
        return g;
    }

    /// Record a delivery of mid; returns the new deliver count.
    pub fn noteDeliver(self: *Queue, mid: u64) u32 {
        const e = self.deliver_counts.getOrPut(mid) catch return 1;
        if (!e.found_existing) e.value_ptr.* = 0;
        e.value_ptr.* += 1;
        return e.value_ptr.*;
    }

    /// Next deliverable message for a group, skipping cancelled heads.
    /// Tombstone must not block the head: filter before taking min mid.
    /// Backoff entries do not block the head either.
    pub fn nextForGroup(self: *Queue, group: *GroupState, cancelled: *CancelledSet, now_ms: i64) ?*QueuedMessage {
        for (self.messages.items) |*m| {
            if (group.done.contains(m.mid)) continue;
            if (group.inflight.contains(m.mid)) continue;
            if (cancelled.contains(m.message_id)) continue; // tombstone: skip, don't block head
            if (m.cancelled) continue;
            if (group.not_before_ms.get(m.mid)) |nb| {
                if (nb > now_ms) continue;
            }
            return m;
        }
        return null;
    }
};

// ================= WAL =================
// Append-only log with group commit (DESIGN §3.1).
//   append(): one write(2) per record, under the engine lock. No fsync.
//   commit(seq): returns when every record up to seq is on disk. One thread
//     runs fsync for the whole batch; other threads wait on a condition and
//     reuse that fsync. The engine lock is not held during fsync.
//   Rule: the server sends a reply only after commit() returns.
//   Fail-stop: after a write or fsync error, commit() always fails, so the
//     server never acknowledges a record that may be lost.
//   open(): creates parent dirs and fsyncs them; truncates a torn tail
//     (a partial last line from a crash) so new records start on a new line.

pub const WalError = error{ WalFailed, WalOpen, WalIo, OutOfMemory };

pub const Wal = struct {
    fd: i32,
    fsync_enabled: bool,
    read_only: bool,
    written: std.atomic.Value(u64) = .init(0),
    synced: std.atomic.Value(u64) = .init(0),
    failed: std.atomic.Value(bool) = .init(false),
    batches: std.atomic.Value(u64) = .init(0),
    torn_bytes: u64 = 0,
    cm: std.Io.Mutex = .init,
    cv: std.Io.Condition = .init,
    syncing: bool = false,

    const linux = std.os.linux;

    fn fsyncDir(path_z: [*:0]const u8) void {
        const rc = linux.open(path_z, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
        if (linux.errno(rc) != .SUCCESS) return;
        const fd: i32 = @intCast(rc);
        _ = linux.fsync(fd);
        _ = linux.close(fd);
    }

    /// mkdir -p. Each new directory gets its parent fsynced.
    fn makeDirs(path: []const u8) !void {
        var buf: [4096]u8 = undefined;
        if (path.len == 0 or path.len >= buf.len) return error.WalOpen;
        var i: usize = 1;
        while (i <= path.len) : (i += 1) {
            if (i != path.len and path[i] != '/') continue;
            @memcpy(buf[0..i], path[0..i]);
            buf[i] = 0;
            const rc = linux.mkdir(@ptrCast(&buf), 0o700);
            switch (linux.errno(rc)) {
                .SUCCESS => {
                    // fsync the parent so the new entry survives a crash.
                    var j: usize = i;
                    while (j > 0 and buf[j - 1] != '/') j -= 1;
                    if (j == 0) {
                        fsyncDir(".");
                    } else {
                        var pb: [4096]u8 = undefined;
                        const plen = if (j == 1) 1 else j - 1;
                        @memcpy(pb[0..plen], buf[0..plen]);
                        pb[plen] = 0;
                        fsyncDir(@ptrCast(&pb));
                    }
                },
                .EXIST => {},
                else => return error.WalOpen,
            }
        }
    }

    /// Open `<dir>/<name>`. read_only: no create, no truncate, no writes.
    pub fn open(dir: []const u8, name: []const u8, fsync_enabled: bool, read_only: bool) !Wal {
        var pb: [4096]u8 = undefined;
        const path = std.fmt.bufPrintZ(&pb, "{s}/{s}", .{ dir, name }) catch return error.WalOpen;
        var dbuf: [4096]u8 = undefined;
        const dir_z = std.fmt.bufPrintZ(&dbuf, "{s}", .{dir}) catch return error.WalOpen;
        if (read_only) {
            const rc = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
            if (linux.errno(rc) != .SUCCESS) return error.WalOpen;
            return .{ .fd = @intCast(rc), .fsync_enabled = false, .read_only = true };
        }
        try makeDirs(dir);
        // O_EXCL probe tells us whether we create the file (then fsync dir).
        var created = false;
        var rc = linux.open(path, .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true, .APPEND = true, .CLOEXEC = true }, 0o600);
        if (linux.errno(rc) == .SUCCESS) {
            created = true;
        } else if (linux.errno(rc) == .EXIST) {
            rc = linux.open(path, .{ .ACCMODE = .RDWR, .APPEND = true, .CLOEXEC = true }, 0o600);
            if (linux.errno(rc) != .SUCCESS) return error.WalOpen;
        } else return error.WalOpen;
        var w = Wal{ .fd = @intCast(rc), .fsync_enabled = fsync_enabled, .read_only = false };
        if (created and fsync_enabled) fsyncDir(dir_z);
        try w.truncateTornTail();
        return w;
    }

    pub fn close(self: *Wal) void {
        _ = linux.close(self.fd);
    }

    fn size(self: *Wal) !u64 {
        const rc = linux.lseek(self.fd, 0, 2); // SEEK_END
        if (linux.errno(rc) != .SUCCESS) return error.WalIo;
        return @intCast(rc);
    }

    /// Drop a partial last line (crash during write).
    fn truncateTornTail(self: *Wal) !void {
        const n = try self.size();
        if (n == 0) return;
        var keep: u64 = n;
        var buf: [4096]u8 = undefined;
        var end: u64 = n;
        outer: while (end > 0) {
            const start = if (end > buf.len) end - buf.len else 0;
            const len: usize = @intCast(end - start);
            const rc = linux.pread(self.fd, &buf, len, @intCast(start));
            if (linux.errno(rc) != .SUCCESS or rc != len) return error.WalIo;
            var k: usize = len;
            while (k > 0) : (k -= 1) {
                if (buf[k - 1] == '\n') {
                    keep = start + k;
                    break :outer;
                }
            }
            end = start;
            keep = 0;
        }
        if (keep == n) return;
        self.torn_bytes = n - keep;
        if (linux.errno(linux.ftruncate(self.fd, @intCast(keep))) != .SUCCESS) return error.WalIo;
        if (self.fsync_enabled) _ = linux.fsync(self.fd);
    }

    /// Whole file content. Caller owns it.
    pub fn readAll(self: *Wal, alloc: std.mem.Allocator) ![]u8 {
        const n: usize = @intCast(try self.size());
        const buf = try alloc.alloc(u8, n);
        errdefer alloc.free(buf);
        var off: usize = 0;
        while (off < n) {
            const rc = linux.pread(self.fd, buf.ptr + off, n - off, @intCast(off));
            if (linux.errno(rc) != .SUCCESS or rc == 0) return error.WalIo;
            off += rc;
        }
        return buf;
    }

    /// Append one record (a line without the newline). Call with the engine
    /// lock held so record order matches state-change order. Returns the
    /// record's sequence number for commit().
    pub fn append(self: *Wal, alloc: std.mem.Allocator, text: []const u8) WalError!u64 {
        if (self.read_only) return error.WalFailed;
        if (self.failed.load(.acquire)) return error.WalFailed;
        const line = try alloc.alloc(u8, text.len + 1);
        defer alloc.free(line);
        @memcpy(line[0..text.len], text);
        line[text.len] = '\n';
        var off: usize = 0;
        while (off < line.len) {
            const rc = linux.write(self.fd, line.ptr + off, line.len - off);
            if (linux.errno(rc) == .INTR) continue;
            if (linux.errno(rc) != .SUCCESS or rc == 0) {
                self.failed.store(true, .release);
                return error.WalFailed;
            }
            off += rc;
        }
        return self.written.fetchAdd(1, .acq_rel) + 1;
    }

    /// Current last sequence number (read under the engine lock).
    pub fn lastSeq(self: *Wal) u64 {
        return self.written.load(.acquire);
    }

    /// Block until records up to `seq` are on disk.
    pub fn commit(self: *Wal, io: std.Io, seq: u64) WalError!void {
        if (self.failed.load(.acquire)) return error.WalFailed;
        if (!self.fsync_enabled) {
            if (self.synced.load(.acquire) < seq) self.synced.store(seq, .release);
            return;
        }
        if (self.synced.load(.acquire) >= seq) return;
        self.cm.lockUncancelable(io);
        defer self.cm.unlock(io);
        while (true) {
            if (self.failed.load(.acquire)) return error.WalFailed;
            if (self.synced.load(.acquire) >= seq) return;
            if (self.syncing) {
                self.cv.waitUncancelable(io, &self.cm);
                continue;
            }
            // Leader: fsync everything written so far, outside the lock.
            self.syncing = true;
            const target = self.written.load(.acquire);
            self.cm.unlock(io);
            const rc = linux.fsync(self.fd);
            self.cm.lockUncancelable(io);
            self.syncing = false;
            if (linux.errno(rc) != .SUCCESS) {
                self.failed.store(true, .release);
                self.cv.broadcast(io);
                return error.WalFailed;
            }
            if (target > self.synced.load(.acquire)) {
                self.synced.store(target, .release);
                _ = self.batches.fetchAdd(1, .monotonic);
            }
            self.cv.broadcast(io);
        }
    }
};

/// Cancelled task tombstones. 投递前过滤，取队头前也过滤。
pub const CancelledSet = struct {
    alloc: std.mem.Allocator,
    set: std.StringHashMap(void),

    pub fn init(alloc: std.mem.Allocator) CancelledSet {
        return .{ .alloc = alloc, .set = std.StringHashMap(void).init(alloc) };
    }

    pub fn deinit(self: *CancelledSet) void {
        var it = self.set.keyIterator();
        while (it.next()) |k| self.alloc.free(k.*);
        self.set.deinit();
    }

    pub fn add(self: *CancelledSet, task_id: []const u8) !void {
        if (self.set.contains(task_id)) return;
        try self.set.put(try self.alloc.dupe(u8, task_id), {});
    }

    pub fn contains(self: *CancelledSet, task_id: []const u8) bool {
        return self.set.contains(task_id);
    }
};

/// requeue_or_dead: single reentry primitive (S2, fixes Issue #1/#2).
/// All three reentry paths (timeout, leave-recycle, ack+requeue) call this.
pub const RequeueDecision = enum { requeued, dead };

pub fn requeueOrDead(
    deliver_count: u32,
    max_deliver: u32,
) RequeueDecision {
    if (deliver_count >= max_deliver) return .dead;
    return .requeued;
}

/// Topic filter match: `*` matches one segment, `>` matches rest.
pub fn filterMatch(filter: []const u8, subject: []const u8) bool {
    var fi = std.mem.splitScalar(u8, filter, '.');
    var si = std.mem.splitScalar(u8, subject, '.');
    while (fi.next()) |fseg| {
        if (std.mem.eql(u8, fseg, ">")) return true;
        const sseg = si.next() orelse return false;
        if (std.mem.eql(u8, fseg, "*")) continue;
        if (!std.mem.eql(u8, fseg, sseg)) return false;
    }
    return si.next() == null;
}

test "requeue_or_dead boundary" {
    try std.testing.expectEqual(RequeueDecision.requeued, requeueOrDead(1, 5));
    try std.testing.expectEqual(RequeueDecision.requeued, requeueOrDead(4, 5));
    try std.testing.expectEqual(RequeueDecision.dead, requeueOrDead(5, 5));
    try std.testing.expectEqual(RequeueDecision.dead, requeueOrDead(6, 5));
}

test "filter match" {
    try std.testing.expect(filterMatch("task.*", "task.queued"));
    try std.testing.expect(filterMatch("task.>", "task.queued.extra"));
    try std.testing.expect(!filterMatch("task.*", "task"));
    try std.testing.expect(!filterMatch("other.*", "task.queued"));
    try std.testing.expect(filterMatch("*", "task"));
}

test "tombstone does not block head" {
    const alloc = std.testing.allocator;
    var q = try Queue.init(alloc, "t", .workqueue, 100, .block);
    defer q.deinit();
    var cancelled = CancelledSet.init(alloc);
    defer cancelled.deinit();

    _ = try q.publish("task-1", "payload1");
    _ = try q.publish("task-2", "payload2");
    try cancelled.add("task-1"); // head is cancelled

    const g = try q.getOrCreateGroup("workers");
    const next = q.nextForGroup(g, &cancelled, 0);
    try std.testing.expect(next != null);
    try std.testing.expectEqualStrings("task-2", next.?.message_id);
}

test "publish dedup" {
    const alloc = std.testing.allocator;
    var q = try Queue.init(alloc, "t", .workqueue, 100, .block);
    defer q.deinit();
    const m1 = try q.publish("id-1", "p");
    try std.testing.expect(m1 != 0);
    const m2 = try q.publish("id-1", "p");
    try std.testing.expectEqual(@as(u64, 0), m2); // duplicate
}

test "backoff delay: exponential, capped, jitter in [d/2, d)" {
    try std.testing.expectEqual(@as(u64, 500), backoffDelayMs(1, 1000, 10_000, 0.0));
    try std.testing.expectEqual(@as(u64, 1000), backoffDelayMs(2, 1000, 10_000, 0.0));
    try std.testing.expectEqual(@as(u64, 2000), backoffDelayMs(3, 1000, 10_000, 0.0));
    try std.testing.expectEqual(@as(u64, 5000), backoffDelayMs(9, 1000, 10_000, 0.0));
    try std.testing.expectEqual(@as(u64, 5000), backoffDelayMs(64, 1000, 10_000, 0.0));
    try std.testing.expectEqual(@as(u64, 3999), backoffDelayMs(3, 1000, 10_000, 0.99975));
    try std.testing.expectEqual(@as(u64, 0), backoffDelayMs(3, 0, 10_000, 0.5));
    try std.testing.expectEqual(@as(u64, 0), backoffDelayMs(0, 1000, 10_000, 0.5));
}

test "nextForGroup skips done, inflight and backoff; backoff does not block head" {
    const alloc = std.testing.allocator;
    var q = try Queue.init(alloc, "t", .workqueue, 100, .block);
    defer q.deinit();
    var cancelled = CancelledSet.init(alloc);
    defer cancelled.deinit();
    const m1 = try q.publish("a", "1");
    const m2 = try q.publish("b", "2");
    const m3 = try q.publish("c", "3");
    const g = try q.getOrCreateGroup("g");
    try g.markAcked(m1);
    try g.inflight.put(m2, {});
    try std.testing.expectEqual(m3, q.nextForGroup(g, &cancelled, 1000).?.mid);
    // m2 requeued with backoff until t=5000: m3 is still the next one.
    try g.markRequeued(m2, 5000);
    try g.inflight.put(m3, {});
    try std.testing.expect(q.nextForGroup(g, &cancelled, 4999) == null);
    try std.testing.expectEqual(m2, q.nextForGroup(g, &cancelled, 5000).?.mid);
    // Dead letters are never redelivered.
    try g.markDead(m2, .{ .reason = .rejected, .deliver_count = 1, .at_ms = 1 });
    try std.testing.expect(q.nextForGroup(g, &cancelled, 9999) == null);
    try std.testing.expectEqual(DeadReason.rejected, g.dead.get(m2).?.reason);
}

test "requeue of one message does not redeliver acked or in-flight ones" {
    // Regression: the cursor model set cursor=min(cursor, mid) on requeue,
    // which made every later message deliverable again.
    const alloc = std.testing.allocator;
    var q = try Queue.init(alloc, "t", .workqueue, 100, .block);
    defer q.deinit();
    var cancelled = CancelledSet.init(alloc);
    defer cancelled.deinit();
    const m1 = try q.publish("a", "1");
    const m2 = try q.publish("b", "2");
    const m3 = try q.publish("c", "3");
    const g = try q.getOrCreateGroup("g");
    try g.inflight.put(m1, {});
    try g.markAcked(m2);
    try g.inflight.put(m3, {});
    try g.markRequeued(m1, 0);
    try std.testing.expectEqual(m1, q.nextForGroup(g, &cancelled, 0).?.mid);
    try g.inflight.put(m1, {});
    try std.testing.expect(q.nextForGroup(g, &cancelled, 0) == null);
}

fn tmpDirPath(buf: []u8, tag: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "/tmp/asock-wal-test-{s}-{d}", .{ tag, std.os.linux.getpid() });
}

fn rmTree(path: []const u8) void {
    var pb: [4200]u8 = undefined;
    const p1 = std.fmt.bufPrintZ(&pb, "{s}/wal.jsonl", .{path}) catch return;
    _ = std.os.linux.unlink(p1);
    var db: [4200]u8 = undefined;
    const d = std.fmt.bufPrintZ(&db, "{s}", .{path}) catch return;
    _ = std.os.linux.rmdir(d);
}

test "wal append, commit, reopen, torn tail truncated" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var buf: [256]u8 = undefined;
    const dir = try tmpDirPath(&buf, "torn");
    rmTree(dir);
    defer rmTree(dir);
    {
        var w = try Wal.open(dir, "wal.jsonl", true, false);
        defer w.close();
        const s1 = try w.append(alloc, "{\"a\":1}");
        const s2 = try w.append(alloc, "{\"a\":2}");
        try std.testing.expectEqual(@as(u64, 2), s2);
        try w.commit(io, s1);
        try w.commit(io, s2);
        try std.testing.expectEqual(@as(u64, 1), w.batches.load(.monotonic));
        // Simulate a crash in the middle of a write.
        const torn = "{\"a\":3,\"pay";
        _ = std.os.linux.write(w.fd, torn, torn.len);
    }
    var w2 = try Wal.open(dir, "wal.jsonl", true, false);
    defer w2.close();
    try std.testing.expectEqual(@as(u64, 11), w2.torn_bytes);
    _ = try w2.append(alloc, "{\"a\":4}");
    const content = try w2.readAll(alloc);
    defer alloc.free(content);
    try std.testing.expectEqualStrings("{\"a\":1}\n{\"a\":2}\n{\"a\":4}\n", content);
}

test "wal read-only open does not truncate" {
    const alloc = std.testing.allocator;
    var buf: [256]u8 = undefined;
    const dir = try tmpDirPath(&buf, "ro");
    rmTree(dir);
    defer rmTree(dir);
    {
        var w = try Wal.open(dir, "wal.jsonl", false, false);
        defer w.close();
        _ = try w.append(alloc, "{}");
        _ = std.os.linux.write(w.fd, "{\"x", 3);
    }
    var r = try Wal.open(dir, "wal.jsonl", false, true);
    defer r.close();
    const c = try r.readAll(alloc);
    defer alloc.free(c);
    try std.testing.expectEqual(@as(usize, 6), c.len);
    try std.testing.expectError(error.WalFailed, r.append(alloc, "{}"));
}

test "wal group commit: concurrent committers share fsyncs" {
    const alloc = std.heap.page_allocator;
    const io = std.testing.io;
    var buf: [256]u8 = undefined;
    const dir = try tmpDirPath(&buf, "gc");
    rmTree(dir);
    defer rmTree(dir);
    var w = try Wal.open(dir, "wal.jsonl", true, false);
    defer w.close();
    var lock: std.Io.Mutex = .init;
    const N = 8;
    const per = 50;
    const Worker = struct {
        fn run(wp: *Wal, lk: *std.Io.Mutex, iop: std.Io) void {
            var i: usize = 0;
            while (i < per) : (i += 1) {
                lk.lockUncancelable(iop);
                const seq = wp.append(alloc, "{\"r\":1}") catch unreachable;
                lk.unlock(iop);
                wp.commit(iop, seq) catch unreachable;
                std.debug.assert(wp.synced.load(.acquire) >= seq);
            }
        }
    };
    var ts: [N]std.Thread = undefined;
    for (&ts) |*t| t.* = try std.Thread.spawn(.{}, Worker.run, .{ &w, &lock, io });
    for (ts) |t| t.join();
    try std.testing.expectEqual(@as(u64, N * per), w.synced.load(.acquire));
    try std.testing.expect(w.batches.load(.monotonic) <= N * per);
}
