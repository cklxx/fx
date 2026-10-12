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

/// Per-group consumption state (workqueue).
pub const GroupState = struct {
    name: []const u8,
    cursor: u64 = 0, // next mid to consider
    pending: std.AutoHashMap(u64, PendingEntry), // delivery_id -> entry
    members: std.StringHashMap(void), // consumer from-ids
    ack_wait_s: u32 = 30,
    max_deliver: u32 = 5,

    pub fn deinit(self: *GroupState, alloc: std.mem.Allocator) void {
        var pit = self.pending.iterator();
        while (pit.next()) |e| alloc.free(e.value_ptr.consumer);
        self.pending.deinit();
        var mit = self.members.keyIterator();
        while (mit.next()) |k| alloc.free(k.*);
        self.members.deinit();
        alloc.free(self.name);
    }
};

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

    /// MVP: WAL is a no-op. Batch fsync comes later per DESIGN §3.1.
    fn walAppend(self: *Queue, line: []const u8) void {
        _ = self;
        _ = line;
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
        var line_buf: [256]u8 = undefined;
        const line = try std.fmt.bufPrint(&line_buf, "{{\"op\":\"publish\",\"mid\":{d}}}", .{mid});
        self.walAppend(line);
        return mid;
    }

    pub fn getOrCreateGroup(self: *Queue, name: []const u8) !*GroupState {
        if (self.groups.get(name)) |g| return g;
        const g = try self.alloc.create(GroupState);
        g.* = .{
            .name = try self.alloc.dupe(u8, name),
            .pending = std.AutoHashMap(u64, PendingEntry).init(self.alloc),
            .members = std.StringHashMap(void).init(self.alloc),
        };
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
    pub fn nextForGroup(self: *Queue, group: *GroupState, cancelled: *CancelledSet) ?*QueuedMessage {
        for (self.messages.items) |*m| {
            if (m.mid < group.cursor) continue;
            if (cancelled.contains(m.message_id)) continue; // tombstone: skip, don't block head
            if (m.cancelled) continue;
            return m;
        }
        return null;
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
    const next = q.nextForGroup(g, &cancelled);
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
