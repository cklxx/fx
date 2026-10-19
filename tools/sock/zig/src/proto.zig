const std = @import("std");

pub const max_frame_bytes: usize = 16 * 1024 * 1024;
pub const max_payload_bytes: usize = 8 * 1024 * 1024;
pub const max_xml_depth: u32 = 32;
pub const max_xml_elements: usize = 100_000;
pub const protocol_version: u8 = 1;

/// Wall-clock time helpers (std.time lost these in 0.16).
pub fn nowNs() i128 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.REALTIME, &ts);
    return @as(i128, ts.sec) * 1_000_000_000 + ts.nsec;
}

pub fn nowTs() f64 {
    return @as(f64, @floatFromInt(nowNs())) / 1e9;
}

pub fn nowMs() i64 {
    return @intCast(@divTrunc(nowNs(), 1_000_000));
}

/// Simple spinlock for the MVP (single-threaded asyncio comes later per DESIGN).
pub const SpinLock = struct {
    state: std.atomic.Value(u32) = .init(0),

    pub fn lock(self: *SpinLock) void {
        while (self.state.cmpxchgStrong(0, 1, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    pub fn unlock(self: *SpinLock) void {
        self.state.store(0, .release);
    }
};

pub const ProtoError = error{
    FrameTooLarge,
    PayloadTooLarge,
    BadXml,
    DoctypeRejected,
    XmlTooDeep,
    TooManyElements,
    MissingAttribute,
    BadAttribute,
    UnsupportedVersion,
    UnknownPrimitive,
    OutOfMemory,
};

/// Wire primitives. v4 has 11.
pub const Primitive = enum {
    agent_register,
    agent_heartbeat,
    agent_deregister,
    agent_card,
    queue_declare,
    queue_publish,
    queue_consume,
    queue_unconsume,
    queue_deliver,
    queue_ack,
    err,
    /// §11 任务层 task.* 原语。Zig server 不实现，只识别后回 AEVT-4110。
    task_unsupported,

    pub fn wireName(self: Primitive) []const u8 {
        return switch (self) {
            .agent_register => "agent.register",
            .agent_heartbeat => "agent.heartbeat",
            .agent_deregister => "agent.deregister",
            .agent_card => "agent.card",
            .queue_declare => "queue.declare",
            .queue_publish => "queue.publish",
            .queue_consume => "queue.consume",
            .queue_unconsume => "queue.unconsume",
            .queue_deliver => "queue.deliver",
            .queue_ack => "queue.ack",
            .err => "error",
            .task_unsupported => "task.unsupported",
        };
    }

    pub fn fromWireName(name: []const u8) ProtoError!Primitive {
        if (std.mem.eql(u8, name, "agent.register")) return .agent_register;
        if (std.mem.eql(u8, name, "agent.heartbeat")) return .agent_heartbeat;
        if (std.mem.eql(u8, name, "agent.deregister")) return .agent_deregister;
        if (std.mem.eql(u8, name, "agent.card")) return .agent_card;
        if (std.mem.eql(u8, name, "queue.declare")) return .queue_declare;
        if (std.mem.eql(u8, name, "queue.publish")) return .queue_publish;
        if (std.mem.eql(u8, name, "queue.consume")) return .queue_consume;
        if (std.mem.eql(u8, name, "queue.unconsume")) return .queue_unconsume;
        if (std.mem.eql(u8, name, "queue.deliver")) return .queue_deliver;
        if (std.mem.eql(u8, name, "queue.ack")) return .queue_ack;
        if (std.mem.eql(u8, name, "error")) return .err;
        if (std.mem.startsWith(u8, name, "task.")) return .task_unsupported;
        return ProtoError.UnknownPrimitive;
    }
};

pub const Envelope = struct {
    primitive: Primitive,
    seq: u64,
    ack: u64,
    ts: f64,
    from: []const u8,
    in_reply_to: ?u64 = null,
};

/// Minimal DOM node for protocol messages.
pub const Node = union(enum) {
    element: *Element,
    text: []const u8,
    cdata: []const u8,
};

pub const Attr = struct {
    name: []const u8,
    value: []const u8,
};

pub const Element = struct {
    name: []const u8,
    attrs: std.ArrayList(Attr),
    children: std.ArrayList(Node),
    owned: std.ArrayList([]u8),
    alloc: std.mem.Allocator,

    pub fn deinit(self: *Element) void {
        for (self.children.items) |node| {
            switch (node) {
                .element => |e| {
                    e.deinit();
                    self.alloc.destroy(e);
                },
                else => {},
            }
        }
        for (self.attrs.items) |a| {
            self.alloc.free(a.value);
        }
        for (self.owned.items) |s| {
            self.alloc.free(s);
        }
        self.attrs.deinit(self.alloc);
        self.children.deinit(self.alloc);
        self.owned.deinit(self.alloc);
    }

    /// Register an owned string to be freed on deinit.
    pub fn own(self: *Element, s: []u8) !void {
        try self.owned.append(self.alloc, s);
    }

    pub fn attr(self: *const Element, name: []const u8) ?[]const u8 {
        for (self.attrs.items) |a| {
            if (std.mem.eql(u8, a.name, name)) return a.value;
        }
        return null;
    }

    /// First child element with the given name.
    pub fn child(self: *const Element, name: []const u8) ?*Element {
        for (self.children.items) |c| {
            switch (c) {
                .element => |e| if (std.mem.eql(u8, e.name, name)) return e,
                else => {},
            }
        }
        return null;
    }

    /// Concatenated text/cdata of direct children.
    pub fn textContent(self: *const Element, alloc: std.mem.Allocator) ![]u8 {
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(alloc);
        for (self.children.items) |c| {
            switch (c) {
                .text => |t| try out.appendSlice(alloc, t),
                .cdata => |t| try out.appendSlice(alloc, t),
                else => {},
            }
        }
        return out.toOwnedSlice(alloc);
    }
};

const Parser = struct {
    alloc: std.mem.Allocator,
    src: []const u8,
    pos: usize = 0,
    depth: u32 = 0,
    element_count: usize = 0,

    fn peek(self: *Parser) ?u8 {
        if (self.pos >= self.src.len) return null;
        return self.src[self.pos];
    }

    fn expect(self: *Parser, c: u8) ProtoError!void {
        if (self.peek() != c) return ProtoError.BadXml;
        self.pos += 1;
    }

    fn skipWs(self: *Parser) void {
        while (self.peek()) |c| {
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                self.pos += 1;
            } else break;
        }
    }

    fn parseName(self: *Parser) ProtoError![]const u8 {
        const start = self.pos;
        while (self.peek()) |c| {
            if (std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.' or c == ':') {
                self.pos += 1;
            } else break;
        }
        if (self.pos == start) return ProtoError.BadXml;
        return self.src[start..self.pos];
    }

    fn parseAttrValue(self: *Parser) ProtoError![]const u8 {
        const q = self.peek() orelse return ProtoError.BadXml;
        if (q != '"' and q != '\'') return ProtoError.BadXml;
        self.pos += 1;
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(self.alloc);
        while (true) {
            const c = self.peek() orelse return ProtoError.BadXml;
            if (c == q) {
                self.pos += 1;
                break;
            }
            if (c == '&') {
                try self.parseEntity(&out);
            } else {
                try out.append(self.alloc, c);
                self.pos += 1;
            }
        }
        return out.toOwnedSlice(self.alloc);
    }

    fn parseEntity(self: *Parser, out: *std.ArrayList(u8)) ProtoError!void {
        // self.src[self.pos] == '&'
        const semi = std.mem.indexOfScalarPos(u8, self.src, self.pos, ';') orelse return ProtoError.BadXml;
        const name = self.src[self.pos + 1 .. semi];
        if (std.mem.eql(u8, name, "lt")) try out.appendSlice(self.alloc, "<") else if (std.mem.eql(u8, name, "gt")) try out.appendSlice(self.alloc, ">") else if (std.mem.eql(u8, name, "amp")) try out.appendSlice(self.alloc, "&") else if (std.mem.eql(u8, name, "apos")) try out.appendSlice(self.alloc, "'") else if (std.mem.eql(u8, name, "quot")) try out.appendSlice(self.alloc, "\"") else return ProtoError.BadXml;
        self.pos = semi + 1;
    }

    fn parseElement(self: *Parser) ProtoError!*Element {
        self.depth += 1;
        if (self.depth > max_xml_depth) return ProtoError.XmlTooDeep;
        self.element_count += 1;
        if (self.element_count > max_xml_elements) return ProtoError.TooManyElements;
        errdefer self.depth -= 1;

        try self.expect('<');
        // Reject DOCTYPE, comments, PIs at element position.
        if (self.peek() == '!') {
            if (std.mem.startsWith(u8, self.src[self.pos..], "!--")) {
                try self.skipComment();
                self.depth -= 1;
                return self.parseElement();
            }
            return ProtoError.DoctypeRejected;
        }
        if (self.peek() == '?') return ProtoError.BadXml;

        const name = try self.parseName();
        var el = try self.alloc.create(Element);
        errdefer self.alloc.destroy(el);
        el.* = .{
            .name = name,
            .attrs = std.ArrayList(Attr).empty,
            .children = std.ArrayList(Node).empty,
            .owned = std.ArrayList([]u8).empty,
            .alloc = self.alloc,
        };
        errdefer el.deinit();

        while (true) {
            self.skipWs();
            const c = self.peek() orelse return ProtoError.BadXml;
            if (c == '/') {
                self.pos += 1;
                try self.expect('>');
                self.depth -= 1;
                return el;
            }
            if (c == '>') {
                self.pos += 1;
                break;
            }
            const aname = try self.parseName();
            self.skipWs();
            try self.expect('=');
            self.skipWs();
            const aval = try self.parseAttrValue();
            try el.attrs.append(self.alloc, .{ .name = aname, .value = aval });
        }

        // Children.
        while (true) {
            if (std.mem.startsWith(u8, self.src[self.pos..], "</")) {
                self.pos += 2;
                const cname = try self.parseName();
                if (!std.mem.eql(u8, cname, name)) return ProtoError.BadXml;
                self.skipWs();
                try self.expect('>');
                self.depth -= 1;
                return el;
            } else if (std.mem.startsWith(u8, self.src[self.pos..], "<![CDATA[")) {
                self.pos += 9;
                const end = std.mem.indexOf(u8, self.src[self.pos..], "]]>") orelse return ProtoError.BadXml;
                const data = self.src[self.pos .. self.pos + end];
                self.pos += end + 3;
                try el.children.append(self.alloc, .{ .cdata = data });
            } else if (std.mem.startsWith(u8, self.src[self.pos..], "<!--")) {
                try self.skipComment();
            } else if (self.peek() == '<') {
                const child = try self.parseElement();
                try el.children.append(self.alloc, .{ .element = child });
            } else {
                // Text node.
                const start = self.pos;
                while (self.peek()) |c| {
                    if (c == '<' or c == '&') break;
                    self.pos += 1;
                }
                if (self.pos > start) {
                    try el.children.append(self.alloc, .{ .text = self.src[start..self.pos] });
                }
                if (self.peek() == '&') {
                    var out = std.ArrayList(u8).empty;
                    try self.parseEntity(&out);
                    const s = try out.toOwnedSlice(self.alloc);
                    try el.own(s);
                    try el.children.append(self.alloc, .{ .text = s });
                }
                if (self.pos >= self.src.len) return ProtoError.BadXml;
            }
        }
    }

    fn skipComment(self: *Parser) ProtoError!void {
        // self.src[self.pos..] starts with "<!--"
        const end = std.mem.indexOf(u8, self.src[self.pos + 4 ..], "-->") orelse return ProtoError.BadXml;
        self.pos += 4 + end + 3;
    }
};

pub const Message = struct {
    envelope: Envelope,
    root: *Element,
    alloc: std.mem.Allocator,
    /// Owned frame buffer. Root slices point into it; freed on deinit.
    frame: []u8,

    pub fn deinit(self: *Message) void {
        self.root.deinit();
        self.alloc.destroy(self.root);
        self.alloc.free(self.envelope.from);
        self.alloc.free(self.frame);
    }
};

/// Parse one XML message. Caller owns the returned Message, including frame.
pub fn decode(alloc: std.mem.Allocator, frame: []u8) ProtoError!Message {
    var p = Parser{ .alloc = alloc, .src = frame };
    p.skipWs();
    const root = try p.parseElement();
    errdefer {
        root.deinit();
        alloc.destroy(root);
    }
    if (!std.mem.eql(u8, root.name, "msg")) return ProtoError.BadXml;

    const vstr = root.attr("v") orelse return ProtoError.MissingAttribute;
    const v = std.fmt.parseInt(u8, vstr, 10) catch return ProtoError.BadAttribute;
    if (v != protocol_version) return ProtoError.UnsupportedVersion;

    const tstr = root.attr("type") orelse return ProtoError.MissingAttribute;
    const primitive = try Primitive.fromWireName(tstr);

    const seq = parseU64(root.attr("seq") orelse return ProtoError.MissingAttribute) catch return ProtoError.BadAttribute;
    const ack = parseU64(root.attr("ack") orelse "0") catch return ProtoError.BadAttribute;
    const tsstr = root.attr("ts") orelse return ProtoError.MissingAttribute;
    const ts = std.fmt.parseFloat(f64, tsstr) catch return ProtoError.BadAttribute;
    const from = try alloc.dupe(u8, root.attr("from") orelse return ProtoError.MissingAttribute);
    errdefer alloc.free(from);
    const in_reply_to: ?u64 = if (root.attr("in_reply_to")) |s|
        std.fmt.parseInt(u64, s, 10) catch return ProtoError.BadAttribute
    else
        null;

    return .{
        .envelope = .{
            .primitive = primitive,
            .seq = seq,
            .ack = ack,
            .ts = ts,
            .from = from,
            .in_reply_to = in_reply_to,
        },
        .root = root,
        .alloc = alloc,
        .frame = frame,
    };
}

fn parseU64(s: []const u8) !u64 {
    return std.fmt.parseInt(u64, s, 10);
}

/// Escape `]]>` for CDATA embedding. Caller owns result.
pub fn escapeCdata(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < text.len) {
        if (std.mem.startsWith(u8, text[i..], "]]>")) {
            try out.appendSlice(alloc, "]]]]><![CDATA[>");
            i += 3;
        } else {
            try out.append(alloc, text[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(alloc);
}

/// Escape XML attribute value. Caller owns result.
pub fn escapeAttr(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    for (text) |c| {
        switch (c) {
            '&' => try out.appendSlice(alloc, "&amp;"),
            '<' => try out.appendSlice(alloc, "&lt;"),
            '>' => try out.appendSlice(alloc, "&gt;"),
            '"' => try out.appendSlice(alloc, "&quot;"),
            else => try out.append(alloc, c),
        }
    }
    return out.toOwnedSlice(alloc);
}

pub const XmlWriter = struct {
    alloc: std.mem.Allocator,
    buf: std.ArrayList(u8),

    pub fn init(alloc: std.mem.Allocator) XmlWriter {
        return .{ .alloc = alloc, .buf = std.ArrayList(u8).empty };
    }

    pub fn deinit(self: *XmlWriter) void {
        self.buf.deinit(self.alloc);
    }

    pub fn toOwnedSlice(self: *XmlWriter) ![]u8 {
        return self.buf.toOwnedSlice(self.alloc);
    }

    pub fn beginMsg(self: *XmlWriter, env: Envelope) !void {
        const from_esc = try escapeAttr(self.alloc, env.from);
        defer self.alloc.free(from_esc);
        try self.buf.print(self.alloc,
            \\<msg v="1" type="{s}" seq="{d}" ack="{d}" ts="{d:.3}" from="{s}"
        , .{ env.primitive.wireName(), env.seq, env.ack, env.ts, from_esc });
        if (env.in_reply_to) |irt| {
            try self.buf.print(self.alloc,
                \\ in_reply_to="{d}"
            , .{irt});
        }
        try self.buf.append(self.alloc, '>');
    }

    pub fn endMsg(self: *XmlWriter) !void {
        try self.buf.appendSlice(self.alloc, "</msg>");
    }

    pub fn element(self: *XmlWriter, name: []const u8, text: []const u8) !void {
        try self.buf.print(self.alloc, "<{s}>", .{name});
        const esc = try escapeCdata(self.alloc, text);
        defer self.alloc.free(esc);
        // Plain text: escape markup chars instead of CDATA for short fields.
        try self.writeEscapedText(esc);
        try self.buf.print(self.alloc, "</{s}>", .{name});
    }

    pub fn elementCdata(self: *XmlWriter, name: []const u8, text: []const u8) !void {
        try self.buf.print(self.alloc, "<{s}><![CDATA[", .{name});
        const esc = try escapeCdata(self.alloc, text);
        defer self.alloc.free(esc);
        try self.buf.appendSlice(self.alloc, esc);
        try self.buf.print(self.alloc, "]]></{s}>", .{name});
    }

    fn writeEscapedText(self: *XmlWriter, text: []const u8) !void {
        for (text) |c| {
            switch (c) {
                '&' => try self.buf.appendSlice(self.alloc, "&amp;"),
                '<' => try self.buf.appendSlice(self.alloc, "&lt;"),
                '>' => try self.buf.appendSlice(self.alloc, "&gt;"),
                else => try self.buf.append(self.alloc, c),
            }
        }
    }

    pub fn raw(self: *XmlWriter, s: []const u8) !void {
        try self.buf.appendSlice(self.alloc, s);
    }
};

/// Write one length-prefixed frame. 4-byte big-endian length + XML bytes.
pub fn writeFrame(writer: *std.Io.Writer, xml: []const u8) !void {
    if (xml.len > max_frame_bytes) return ProtoError.FrameTooLarge;
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, @intCast(xml.len), .big);
    try writer.writeAll(&len_buf);
    try writer.writeAll(xml);
}

/// Read one length-prefixed frame. Caller owns returned slice.
pub fn readFrame(alloc: std.mem.Allocator, reader: *std.Io.Reader) ![]u8 {
    var len_buf: [4]u8 = undefined;
    try reader.readSliceAll(&len_buf);
    const len = std.mem.readInt(u32, &len_buf, .big);
    if (len > max_frame_bytes) return ProtoError.FrameTooLarge;
    const buf = try alloc.alloc(u8, len);
    errdefer alloc.free(buf);
    try reader.readSliceAll(buf);
    return buf;
}

/// If payload is a <control><signal>cancel</signal><task_id>..</task_id></control>
/// document, return the owned task_id. Else return null.
pub fn extractCancelTaskId(alloc: std.mem.Allocator, payload: []const u8) !?[]u8 {
    var p = Parser{ .alloc = alloc, .src = payload };
    p.skipWs();
    const root = p.parseElement() catch return null;
    defer {
        root.deinit();
        alloc.destroy(root);
    }
    if (!std.mem.eql(u8, root.name, "control")) return null;
    const sig_el = root.child("signal") orelse return null;
    const sig = sig_el.textContent(alloc) catch return null;
    defer alloc.free(sig);
    const trimmed = std.mem.trim(u8, sig, " \t\r\n");
    if (!std.mem.eql(u8, trimmed, "cancel")) return null;
    const tid_el = root.child("task_id") orelse return null;
    const tid = tid_el.textContent(alloc) catch return null;
    errdefer alloc.free(tid);
    return tid;
}

// ---------------- tests ----------------

test "cdata escape round trip" {
    const alloc = std.testing.allocator;
    const esc = try escapeCdata(alloc, "a]]>b");
    defer alloc.free(esc);
    try std.testing.expectEqualStrings("a]]]]><![CDATA[>b", esc);
}

test "decode envelope" {
    const alloc = std.testing.allocator;
    const xml =
        \\<msg v="1" type="queue.publish" seq="61" ack="60" ts="1728500000.123" from="orchestrator"><queue>task.dispatch</queue></msg>
    ;
    var msg = try decode(alloc, try alloc.dupe(u8, xml));
    defer msg.deinit();
    try std.testing.expectEqual(Primitive.queue_publish, msg.envelope.primitive);
    try std.testing.expectEqual(@as(u64, 61), msg.envelope.seq);
    try std.testing.expectEqualStrings("orchestrator", msg.envelope.from);
    try std.testing.expect(msg.envelope.in_reply_to == null);
    const q = msg.root.child("queue").?;
    const t = try q.textContent(alloc);
    defer alloc.free(t);
    try std.testing.expectEqualStrings("task.dispatch", t);
}

test "decode in_reply_to" {
    const alloc = std.testing.allocator;
    const xml =
        \\<msg v="1" type="error" seq="14" ack="61" ts="1.0" from="server" in_reply_to="61"><code>AEVT-4001</code></msg>
    ;
    var msg = try decode(alloc, try alloc.dupe(u8, xml));
    defer msg.deinit();
    try std.testing.expectEqual(@as(u64, 61), msg.envelope.in_reply_to.?);
}

test "reject doctype" {
    const alloc = std.testing.allocator;
    const xml = "<!DOCTYPE foo><msg></msg>";
    {
        const f = try alloc.dupe(u8, xml);
        errdefer alloc.free(f);
        try std.testing.expectError(ProtoError.DoctypeRejected, decode(alloc, f));
        alloc.free(f);
    }
}

test "cdata content preserved" {
    const alloc = std.testing.allocator;
    const xml =
        \\<msg v="1" type="queue.publish" seq="1" ack="0" ts="1.0" from="a"><payload><![CDATA[<task/>]]></payload></msg>
    ;
    var msg = try decode(alloc, try alloc.dupe(u8, xml));
    defer msg.deinit();
    const p = msg.root.child("payload").?;
    const t = try p.textContent(alloc);
    defer alloc.free(t);
    try std.testing.expectEqualStrings("<task/>", t);
}

test "extract cancel task id" {
    const alloc = std.testing.allocator;
    const tid = try extractCancelTaskId(alloc, "<control><signal>cancel</signal><task_id>task-9</task_id></control>");
    defer if (tid) |t| alloc.free(t);
    try std.testing.expect(tid != null);
    try std.testing.expectEqualStrings("task-9", tid.?);

    const none1 = try extractCancelTaskId(alloc, "<task><task_id>x</task_id></task>");
    try std.testing.expect(none1 == null);
    const none2 = try extractCancelTaskId(alloc, "<control><signal>interrupt</signal><task_id>x</task_id></control>");
    try std.testing.expect(none2 == null);
    const none3 = try extractCancelTaskId(alloc, "not xml at all");
    try std.testing.expect(none3 == null);
}

test "cdata escape with nested cdata-break" {
    const alloc = std.testing.allocator;
    // payload containing ]]> must round-trip through escapeCdata
    const raw = "echo 'a]]>b'";
    const esc = try escapeCdata(alloc, raw);
    defer alloc.free(esc);
    // wrap in cdata and parse back
    var w = XmlWriter.init(alloc);
    defer w.deinit();
    try w.beginMsg(.{ .primitive = .queue_publish, .seq = 1, .ack = 0, .ts = 1.0, .from = "t", .in_reply_to = null });
    try w.elementCdata("payload", raw);
    try w.endMsg();
    const xml = try w.toOwnedSlice();
    var msg = try decode(alloc, xml);
    defer msg.deinit();
    const p = msg.root.child("payload").?;
    const t = try p.textContent(alloc);
    defer alloc.free(t);
    try std.testing.expectEqualStrings(raw, t);
}

test "reject deep xml" {
    const alloc = std.testing.allocator;
    // 40 nested elements > max_xml_depth 32
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "<msg>");
    for (0..40) |_| try buf.appendSlice(alloc, "<a>");
    try buf.appendSlice(alloc, "x");
    for (0..40) |_| try buf.appendSlice(alloc, "</a>");
    try buf.appendSlice(alloc, "</msg>");
    const xml = try buf.toOwnedSlice(alloc);
    const f = try alloc.dupe(u8, xml);
    alloc.free(xml);
    errdefer alloc.free(f);
    try std.testing.expectError(ProtoError.XmlTooDeep, decode(alloc, f));
    alloc.free(f);
}

test "frame and payload limits sane" {
    // 16MB frame / 8MB payload per DESIGN v4 R-04
    try std.testing.expectEqual(@as(usize, 16 * 1024 * 1024), max_frame_bytes);
    try std.testing.expectEqual(@as(usize, 8 * 1024 * 1024), max_payload_bytes);
    try std.testing.expect(max_payload_bytes < max_frame_bytes);
}

test "task.* maps to task_unsupported (Zig server rejects with AEVT-4110)" {
    try std.testing.expectEqual(Primitive.task_unsupported, try Primitive.fromWireName("task.claim"));
    try std.testing.expectEqual(Primitive.task_unsupported, try Primitive.fromWireName("task.create"));
    try std.testing.expectError(ProtoError.UnknownPrimitive, Primitive.fromWireName("bogus.x"));
}
