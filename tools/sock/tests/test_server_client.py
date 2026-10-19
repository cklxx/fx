"""server+client 集成测试：真实 Unix socket 回环。"""
import asyncio
import os
import shutil
import tempfile
import unittest

from agent_sock.server import Server
from agent_sock.client import Client, ClientError


class TestServerClient(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.tmp = tempfile.mkdtemp()
        self.sock = os.path.join(self.tmp, "test.sock")
        self.srv = Server(sock_path=self.sock, data_dir=self.tmp)
        self.srv_task = asyncio.ensure_future(self.srv.serve())
        await asyncio.sleep(0.2)  # 等 server 就绪

    async def asyncTearDown(self):
        self.srv._running = False
        self.srv_task.cancel()
        try:
            await self.srv_task
        except (asyncio.CancelledError, Exception):
            pass
        shutil.rmtree(self.tmp, ignore_errors=True)

    async def _client(self, aid="agent-1"):
        c = Client(agent_id=aid, sock_path=self.sock)
        await c.connect()
        self.addAsyncCleanup(c.close)
        return c

    async def test_register_and_card(self):
        c = await self._client("agent-1")
        card = await c.card("agent-1")
        self.assertEqual(card.get("agent_id"), "agent-1")

    async def test_publish_consume_deliver_ack(self):
        pub = await self._client("pub")
        sub = await self._client("sub")
        await pub.declare("tq", "workqueue")
        await sub.consume("tq", group="g")
        # 先注册 handler 再 publish：投递可能在 publish 应答之前到达，
        # 没有 handler 时客户端丢弃它（以前这里有竞态）。
        got = []
        async def h(msg):
            got.append(msg)
        sub.on_deliver(h)
        mid = await pub.publish("tq", "m1", "<task>hello</task>")
        self.assertGreater(mid, 0)
        # 等投递
        await asyncio.sleep(0.5)
        self.assertEqual(len(got), 1)
        d = got[0]
        self.assertEqual(d.body["message_id"], "m1")
        # in_reply_to 关联：publish 的应答已在 publish() 内校验
        r = await sub.ack("tq", "g", d.body["delivery_id"])
        self.assertEqual(r, "acked")

    async def test_request_reply_correlation(self):
        """R-01：in_reply_to 关联。流水线发两个请求，应答各自归位。"""
        c = await self._client("agent-1")
        r1, r2 = await asyncio.gather(c.card("agent-1"), c.card("agent-1"))
        self.assertEqual(r1["agent_id"], "agent-1")
        self.assertEqual(r2["agent_id"], "agent-1")

    async def test_cancel_filters_delivery(self):
        """R-05 端到端：cancel 后任务不投递。"""
        pub = await self._client("pub")
        sub = await self._client("sub")
        await pub.declare("tq2", "workqueue")
        await pub.publish("tq2", "task-x", "<task>rm -rf /</task>")
        await pub.cancel_task("task-x", queue="tq2")
        await sub.consume("tq2", group="g")
        got = []
        sub.on_deliver(lambda m: got.append(m))
        await asyncio.sleep(0.5)
        # cancel 的 control 消息本身会投递，但 task-x 不应投递
        task_deliveries = [m for m in got
                           if m.body.get("message_id") == "task-x"]
        self.assertEqual(task_deliveries, [])

    async def test_undeclared_queue_error(self):
        c = await self._client("agent-1")
        with self.assertRaises(ClientError) as ctx:
            await c.publish("nope", "m1", "x")
        self.assertEqual(ctx.exception.code, "AEVT-4006")


if __name__ == "__main__":
    unittest.main()
