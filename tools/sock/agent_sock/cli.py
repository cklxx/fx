"""asock CLI。DESIGN.md §7。"""
from __future__ import annotations

import argparse
import asyncio
import json
import os
import sys
import time

from .client import Client
from .server import Server, DEFAULT_SOCK


def _client(agent_id: str, sock: str) -> Client:
    return Client(agent_id=agent_id, sock_path=sock)


def cmd_serve(args):
    srv = Server(sock_path=args.sock, data_dir=args.data_dir)
    print(f"serving on {args.sock}", flush=True)
    asyncio.run(srv.serve())


def cmd_declare(args):
    async def go():
        c = _client("cli", args.sock)
        await c.connect()
        try:
            await c.declare(args.queue, args.semantics,
                            max_depth=args.max_depth, overflow=args.overflow)
            print(json.dumps({"ok": True, "queue": args.queue}))
        finally:
            await c.close()
    asyncio.run(go())


def cmd_publish(args):
    async def go():
        c = _client("cli", args.sock)
        await c.connect()
        try:
            payload = args.payload
            if args.file:
                with open(args.file) as f:
                    payload = f.read()
            mid = await c.publish(args.queue, args.message_id, payload)
            print(json.dumps({"ok": True, "mid": mid}))
        finally:
            await c.close()
    asyncio.run(go())


def cmd_depth(args):
    # 直连 server 数据目录读 depth（本地运维命令）
    data_dir = args.data_dir or os.path.expanduser("~/.agent-sock")
    from .queue import Queue, QueueDeclare
    qdir = os.path.join(data_dir, "queues", args.queue)
    if not os.path.isdir(qdir):
        print(json.dumps({"queue": args.queue, "depth": 0,
                          "error": "not found"}))
        return
    q = Queue(QueueDeclare(name=args.queue, semantics="workqueue"), qdir,
              read_only=True)
    print(json.dumps({"queue": args.queue, "depth": q.depth()}))


def cmd_dlq(args):
    """列出死信。只读打开日志，server 运行中也可用。"""
    data_dir = args.data_dir or os.path.expanduser("~/.agent-sock")
    from .queue import Queue, QueueDeclare
    qdir = os.path.join(data_dir, "queues", args.queue)
    if not os.path.isdir(qdir):
        print(json.dumps({"queue": args.queue, "dead": [],
                          "error": "not found"}))
        return
    q = Queue(QueueDeclare(name=args.queue, semantics="workqueue"), qdir,
              read_only=True)
    print(json.dumps({"queue": args.queue, "dead": q.dead_letters()},
                     indent=2))


def cmd_replay_dlq(args):
    """死信重放（离线）：先停 server，再运行；重启后生效。"""
    data_dir = args.data_dir or os.path.expanduser("~/.agent-sock")
    from .queue import Queue, QueueDeclare
    qdir = os.path.join(data_dir, "queues", args.queue)
    q = Queue(QueueDeclare(name=args.queue, semantics="workqueue"), qdir)
    n = q.replay_dead()
    q.log.close()
    print(json.dumps({"queue": args.queue, "replayed": n}))


def cmd_submit(args):
    async def go():
        c = _client("cli", args.sock)
        await c.connect()
        try:
            with open(args.file) as f:
                spec = f.read()
            task_id = args.task_id or f"task-{int(time.time())}"
            mid = await c.submit_task(task_id, spec,
                                      queue=args.queue,
                                      timeout_s=args.timeout)
            print(json.dumps({"ok": True, "task_id": task_id, "mid": mid}))
        finally:
            await c.close()
    asyncio.run(go())


def cmd_cancel(args):
    async def go():
        c = _client("cli", args.sock)
        await c.connect()
        try:
            await c.cancel_task(args.task_id, queue=args.queue)
            print(json.dumps({"ok": True, "cancelled": args.task_id}))
        finally:
            await c.close()
    asyncio.run(go())


def cmd_tail(args):
    """订阅 events 并打印。"""
    from .eventbus import EventBus

    async def go():
        c = _client("cli", args.sock)
        await c.connect()
        bus = EventBus(c)

        def show(ce):
            print(json.dumps({"type": ce.get("type"),
                              "data": ce.get("data")}))
            sys.stdout.flush()

        await bus.tail(pattern=args.pattern, duration=args.duration or 0,
                       handler=show)
        if not args.duration:
            await asyncio.sleep(3600 * 24)
        await c.close()

    asyncio.run(go())


def cmd_compile(args):
    from .pipeline import compile_file
    out = compile_file(args.file, target=args.target)
    if args.output:
        with open(args.output, "w") as f:
            f.write(out)
    else:
        print(out)


def cmd_tmux_compile(args):
    """Compile a tmux_interaction YAML and run it on an agent's pane."""
    from .tmux_tool import TmuxTool
    from .tmux_compile import compile_and_run
    from . import errors as _errors

    tool = TmuxTool()
    params = {}
    for pv in args.param or []:
        if "=" not in pv:
            print(json.dumps({"ok": False,
                              "error": f"bad --param '{pv}' (want K=V)"}))
            return
        k, v = pv.split("=", 1)
        params[k] = v
    try:
        res = compile_and_run(tool, args.agent, args.file,
                              params=params or None,
                              target=args.target,
                              timeout_s=args.timeout)
    except Exception as e:  # ErrorPacket from errors.make
        pkt = e.to_dict() if hasattr(e, "to_dict") else {"error": str(e)}
        print(json.dumps({"ok": False, **pkt}, indent=2))
        return
    print(json.dumps(res, indent=2))


def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(prog="asock")
    ap.add_argument("--sock", default=DEFAULT_SOCK)
    ap.add_argument("--data-dir", default=None)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("serve"); p.set_defaults(fn=cmd_serve)

    p = sub.add_parser("declare")
    p.add_argument("queue"); p.add_argument("semantics",
                                            choices=["workqueue", "topic"])
    p.add_argument("--max-depth", type=int, default=10000)
    p.add_argument("--overflow", default="block",
                   choices=["block", "drop_oldest"])
    p.set_defaults(fn=cmd_declare)

    p = sub.add_parser("publish")
    p.add_argument("queue"); p.add_argument("message_id")
    p.add_argument("--payload", default=""); p.add_argument("--file")
    p.set_defaults(fn=cmd_publish)

    p = sub.add_parser("depth"); p.add_argument("queue")
    p.set_defaults(fn=cmd_depth)

    p = sub.add_parser("dlq"); p.add_argument("queue")
    p.set_defaults(fn=cmd_dlq)

    p = sub.add_parser("replay-dlq"); p.add_argument("queue")
    p.set_defaults(fn=cmd_replay_dlq)

    p = sub.add_parser("submit")
    p.add_argument("--file", required=True); p.add_argument("--task-id")
    p.add_argument("--queue", default="task.dispatch")
    p.add_argument("--timeout", type=int, default=600)
    p.set_defaults(fn=cmd_submit)

    p = sub.add_parser("cancel")
    p.add_argument("task_id"); p.add_argument("--queue",
                                              default="task.dispatch")
    p.set_defaults(fn=cmd_cancel)

    p = sub.add_parser("tail")
    p.add_argument("--pattern", default=">")
    p.add_argument("--duration", type=float, default=0)
    p.set_defaults(fn=cmd_tail)

    p = sub.add_parser("compile")
    p.add_argument("--file", required=True)
    p.add_argument("--target", default="bash", choices=["bash", "xml"])
    p.add_argument("--output")
    p.set_defaults(fn=cmd_compile)

    p = sub.add_parser("tmux-compile")
    p.add_argument("--file", required=True,
                   help="tmux_compile YAML DSL file")
    p.add_argument("--agent", required=True,
                   help="agent id (tmux session asock-<id>)")
    p.add_argument("--param", action="append", default=[],
                   help="K=V for a {{param}} in the DSL (repeatable)")
    p.add_argument("--target", default=None,
                   help="tmux pane address (default <session>:0.0)")
    p.add_argument("--timeout", type=float, default=3600)
    p.set_defaults(fn=cmd_tmux_compile)

    return ap


def main(argv=None):
    ap = build_parser()
    args = ap.parse_args(argv)
    args.fn(args)


if __name__ == "__main__":
    main()
