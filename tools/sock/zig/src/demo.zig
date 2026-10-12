const std = @import("std");
const proto = @import("proto");
const client_mod = @import("client");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const sock_path = ".agent-sock/agent.sock";

    // --- Orchestrator: publish a task ---
    var orch = try client_mod.Client.connect(alloc, io, sock_path, "orchestrator");
    defer orch.deinit();
    std.debug.print("[orchestrator] connected\n", .{});

    _ = try orch.declareQueue("task.dispatch", "workqueue", 10000, "block");
    std.debug.print("[orchestrator] declared task.dispatch\n", .{});

    const task_payload =
        \\<task><task_id>task-001</task_id><timeout_s>60</timeout_s></task>
    ;
    _ = try orch.publish("task.dispatch", "task-001", task_payload);
    std.debug.print("[orchestrator] published task-001\n", .{});

    // --- Worker: consume and ack ---
    var worker = try client_mod.Client.connect(alloc, io, sock_path, "agent-7");
    defer worker.deinit();
    std.debug.print("[worker] connected\n", .{});

    var reg_reply = try worker.register(12345, &.{"shell.exec"}, 5000);
    defer reg_reply.deinit();
    std.debug.print("[worker] registered, reply type={s}\n", .{reg_reply.envelope.primitive.wireName()});

    _ = try worker.consume("task.dispatch", "workers", 30, 5);
    std.debug.print("[worker] consuming task.dispatch...\n", .{});

    var delivery: ?proto.Message = null;
    defer if (delivery) |*d| d.deinit();
    const deadline = proto.nowMs() + 5000;
    while (proto.nowMs() < deadline) {
        var msg = try worker.recv();
        if (msg.envelope.primitive == .queue_deliver) {
            delivery = msg;
            break;
        }
        msg.deinit();
    }

    if (delivery) |*d| {
        const mid_el = d.root.child("message_id") orelse {
            std.debug.print("DEMO FAIL: no message_id in deliver\n", .{});
            std.process.exit(1);
        };
        const mid_t = try mid_el.textContent(alloc);
        defer alloc.free(mid_t);
        const dlv_el = d.root.child("delivery_id").?;
        const dlv_t = try dlv_el.textContent(alloc);
        defer alloc.free(dlv_t);
        std.debug.print("[worker] delivery: message_id={s} delivery_id={s}\n", .{ mid_t, dlv_t });

        _ = try worker.ack("task.dispatch", "workers", dlv_t, false);
        std.debug.print("[worker] acked {s}\n", .{dlv_t});
        std.debug.print("DEMO OK: task exchanged via agent-sock\n", .{});
    } else {
        std.debug.print("DEMO FAIL: no delivery received\n", .{});
        std.process.exit(1);
    }
}
