const std = @import("std");
const proto = @import("proto");

const net = std.Io.net;

pub const ClientError = error{
    ConnectionFailed,
    RequestTimeout,
    IoError,
} || proto.ProtoError || std.mem.Allocator.Error;

/// Io-based Unix socket client.
pub const Client = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    stream: net.Stream,
    next_seq: u64 = 1,
    peer_ack: u64 = 0,
    from: []const u8,
    /// Persistent read buffer + reader. MUST persist across recv() calls:
    /// a single read may pull multiple frames (coalesced replies) and the
    /// surplus must not be discarded.
    read_buf: []u8,
    reader: net.Stream.Reader,
    reader_init: bool = false,

    pub fn connect(alloc: std.mem.Allocator, io: std.Io, sock_path: []const u8, from: []const u8) !Client {
        const ua = net.UnixAddress.init(sock_path) catch return ClientError.ConnectionFailed;
        const stream = ua.connect(io) catch return ClientError.ConnectionFailed;
        const read_buf = try alloc.alloc(u8, 64 * 1024);
        errdefer alloc.free(read_buf);
        return .{
            .alloc = alloc,
            .io = io,
            .stream = stream,
            .from = try alloc.dupe(u8, from),
            .read_buf = read_buf,
            .reader = undefined,
        };
    }

    pub fn deinit(self: *Client) void {
        self.stream.close(self.io);
        self.alloc.free(self.from);
        self.alloc.free(self.read_buf);
    }

    fn nowTs() f64 {
        return proto.nowTs();
    }

    fn beginSend(self: *Client, w: *proto.XmlWriter, primitive: proto.Primitive, in_reply_to: ?u64) !u64 {
        const seq = self.next_seq;
        self.next_seq += 1;
        try w.beginMsg(.{
            .primitive = primitive,
            .seq = seq,
            .ack = self.peer_ack,
            .ts = nowTs(),
            .from = self.from,
            .in_reply_to = in_reply_to,
        });
        return seq;
    }

    fn finishSend(self: *Client, w: *proto.XmlWriter) !void {
        try w.endMsg();
        const xml = try w.toOwnedSlice();
        defer self.alloc.free(xml);
        var buf: [64 * 1024]u8 = undefined;
        var writer = self.stream.writer(self.io, &buf);
        try proto.writeFrame(&writer.interface, xml);
        try writer.interface.flush();
    }

    /// Receive one frame and decode. Caller owns the message (frame included).
    /// Uses a persistent reader: never recreate per call, or coalesced
    /// frames are lost.
    pub fn recv(self: *Client) !proto.Message {
        if (!self.reader_init) {
            self.reader = self.stream.reader(self.io, self.read_buf);
            self.reader_init = true;
        }
        const frame = try proto.readFrame(self.alloc, &self.reader.interface);
        errdefer self.alloc.free(frame);
        const msg = try proto.decode(self.alloc, frame);
        self.peer_ack = @max(self.peer_ack, msg.envelope.seq);
        return msg;
    }

    pub fn declareQueue(
        self: *Client,
        queue: []const u8,
        semantics: []const u8,
        max_depth: usize,
        overflow: []const u8,
    ) !u64 {
        var w = proto.XmlWriter.init(self.alloc);
        defer w.deinit();
        const seq = try self.beginSend(&w, .queue_declare, null);
        try w.element("queue", queue);
        try w.element("semantics", semantics);
        var depth_buf: [32]u8 = undefined;
        try w.element("max_depth", try std.fmt.bufPrint(&depth_buf, "{d}", .{max_depth}));
        try w.element("overflow", overflow);
        try self.finishSend(&w);
        return seq;
    }

    pub fn publish(self: *Client, queue: []const u8, message_id: []const u8, payload: []const u8) !u64 {
        var w = proto.XmlWriter.init(self.alloc);
        defer w.deinit();
        const seq = try self.beginSend(&w, .queue_publish, null);
        try w.element("queue", queue);
        try w.element("message_id", message_id);
        try w.elementCdata("payload", payload);
        try self.finishSend(&w);
        return seq;
    }

    pub fn consume(
        self: *Client,
        queue: []const u8,
        group: []const u8,
        ack_wait_s: u32,
        max_deliver: u32,
    ) !u64 {
        var w = proto.XmlWriter.init(self.alloc);
        defer w.deinit();
        const seq = try self.beginSend(&w, .queue_consume, null);
        try w.element("queue", queue);
        try w.element("group", group);
        var num_buf: [64]u8 = undefined;
        try w.element("ack_wait_s", try std.fmt.bufPrint(&num_buf, "{d}", .{ack_wait_s}));
        try w.element("max_deliver", try std.fmt.bufPrint(&num_buf, "{d}", .{max_deliver}));
        try self.finishSend(&w);
        return seq;
    }

    pub fn ack(
        self: *Client,
        queue: []const u8,
        group: []const u8,
        delivery_id: []const u8,
        requeue: bool,
    ) !u64 {
        var w = proto.XmlWriter.init(self.alloc);
        defer w.deinit();
        const seq = try self.beginSend(&w, .queue_ack, null);
        try w.element("queue", queue);
        try w.element("group", group);
        try w.element("delivery_id", delivery_id);
        if (requeue) try w.raw("<requeue/>");
        try self.finishSend(&w);
        return seq;
    }

    pub fn register(self: *Client, pid: u32, caps: []const []const u8, timeout_ms: u64) !proto.Message {        var w = proto.XmlWriter.init(self.alloc);
        defer w.deinit();
        const seq = try self.beginSend(&w, .agent_register, null);
        try w.raw("<caps>");
        for (caps) |c| try w.element("cap", c);
        try w.raw("</caps>");
        var pid_buf: [32]u8 = undefined;
        try w.element("pid", try std.fmt.bufPrint(&pid_buf, "{d}", .{pid}));
        try w.element("resume", "false");
        try self.finishSend(&w);

        const deadline = proto.nowMs() + @as(i64, @intCast(timeout_ms));
        while (proto.nowMs() < deadline) {
            var msg = try self.recv();
            if (msg.envelope.in_reply_to == seq) return msg;
            msg.deinit();
        }
        return ClientError.RequestTimeout;
    }

    pub fn deregister(self: *Client) !u64 {
        var w = proto.XmlWriter.init(self.alloc);
        defer w.deinit();
        const seq = try self.beginSend(&w, .agent_deregister, null);
        try self.finishSend(&w);
        return seq;
    }

    pub fn heartbeat(self: *Client) !u64 {
        var w = proto.XmlWriter.init(self.alloc);
        defer w.deinit();
        const seq = try self.beginSend(&w, .agent_heartbeat, null);
        try self.finishSend(&w);
        return seq;
    }

    pub fn card(self: *Client) !u64 {
        var w = proto.XmlWriter.init(self.alloc);
        defer w.deinit();
        const seq = try self.beginSend(&w, .agent_card, null);
        try self.finishSend(&w);
        return seq;
    }

    pub fn unconsume(self: *Client, queue: []const u8, group: []const u8) !u64 {
        var w = proto.XmlWriter.init(self.alloc);
        defer w.deinit();
        const seq = try self.beginSend(&w, .queue_unconsume, null);
        try w.element("queue", queue);
        try w.element("group", group);
        try self.finishSend(&w);
        return seq;
    }

    /// Cancel a task: publishes a control-cancel payload; the server
    /// intercepts it into the tombstone set (never queued).
    pub fn cancelTask(self: *Client, queue: []const u8, task_id: []const u8) !u64 {
        var w = proto.XmlWriter.init(self.alloc);
        defer w.deinit();
        const seq = try self.beginSend(&w, .queue_publish, null);
        try w.element("queue", queue);
        try w.element("message_id", task_id);
        var cbuf: [512]u8 = undefined;
        const ctrl = try std.fmt.bufPrint(&cbuf, "<control><signal>cancel</signal><task_id>{s}</task_id></control>", .{task_id});
        try w.elementCdata("payload", ctrl);
        try self.finishSend(&w);
        return seq;
    }

    /// Wait until the socket is readable, up to timeout_ms.
    /// Returns false on timeout. Uses poll(2); safe with the Threaded Io backend
    /// (unlike SO_RCVTIMEO, which makes it panic on EAGAIN).
    pub fn waitReadable(self: *Client, timeout_ms: i32) !bool {
        var pfds = [_]std.posix.pollfd{.{
            .fd = self.stream.socket.handle,
            .events = std.os.linux.POLL.IN,
            .revents = 0,
        }};
        const n = try std.posix.poll(&pfds, timeout_ms);
        return n > 0 and (pfds[0].revents & std.os.linux.POLL.IN) != 0;
    }

    /// Receive one message, or null on timeout.
    /// Checks the reader's buffer BEFORE polling the fd: frames already
    /// pulled into userspace must not be missed by an fd-level poll.
    pub fn recvDeadline(self: *Client, deadline_ms: i64) !?proto.Message {
        while (proto.nowMs() < deadline_ms) {
            if (self.reader_init and self.reader.interface.bufferedLen() > 0) {
                return try self.recv();
            }
            const remain_ms = deadline_ms - proto.nowMs();
            if (remain_ms <= 0) return null;
            const poll_ms: i32 = @intCast(@min(remain_ms, 500));
            if (try self.waitReadable(poll_ms)) {
                return try self.recv();
            }
        }
        return null;
    }

    /// Receive until a message with in_reply_to == seq arrives (or timeout).
    /// Non-matching messages are discarded. Caller owns the returned message.
    pub fn recvTimeout(self: *Client, seq: u64, timeout_ms: u64) !proto.Message {
        const deadline = proto.nowMs() + @as(i64, @intCast(timeout_ms));
        while (true) {
            const m = try self.recvDeadline(deadline);
            if (m == null) return ClientError.RequestTimeout;
            var msg = m.?;
            if (msg.envelope.in_reply_to == seq) return msg;
            msg.deinit();
        }
    }
};
