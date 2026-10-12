"""事件总线：复用 sock 连接、CloudEvents 兼容信封、通配订阅、cursor+ack。

DESIGN.md §2.5（event 载荷）、§3.3。SOTA：CloudEvents 1.0 信封兼容。
"""
from __future__ import annotations

import asyncio
import json
import time
import uuid

from .client import Client

EVENTS_QUEUE = "events"


def _match(filter_pat: str, subject: str) -> bool:
    """通配：* 单段，> 后缀。"""
    fp, sp = filter_pat.split("."), subject.split(".")
    i = j = 0
    while i < len(fp) and j < len(sp):
        if fp[i] == ">":
            return True
        if fp[i] != "*" and fp[i] != sp[j]:
            return False
        i += 1
        j += 1
    if i < len(fp):
        return all(p == ">" for p in fp[i:])
    return j == len(sp)


def cloudevent(subject: str, data: dict, source: str = "agent-sock",
               event_id: str | None = None) -> dict:
    """CloudEvents 1.0 兼容信封。"""
    return {
        "specversion": "1.0",
        "id": event_id or str(uuid.uuid4()),
        "source": source,
        "type": subject,
        "time": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "datacontenttype": "application/json",
        "data": data,
    }


class EventBus:
    """基于 client 的事件发布/订阅。"""

    def __init__(self, client: Client):
        self.client = client
        self._filters: list[tuple[str, object]] = []  # (pattern, handler)
        client.on_deliver(self._on_deliver)

    async def subscribe(self, pattern: str, handler) -> None:
        """pattern 如 task.* 或 >。"""
        self._filters.append((pattern, handler))
        await self.client.consume(EVENTS_QUEUE, filter=pattern)

    async def publish(self, subject: str, data: dict,
                      source: str = "agent-sock") -> int:
        ce = cloudevent(subject, data, source)
        payload = json.dumps(ce)
        return await self.client.publish(EVENTS_QUEUE, ce["id"], payload)

    async def _on_deliver(self, msg):
        body = msg.body
        if body.get("queue") != EVENTS_QUEUE:
            return
        try:
            ce = json.loads(body.get("payload", "{}"))
        except (json.JSONDecodeError, TypeError):
            return
        subject = ce.get("type", "")
        for pattern, handler in self._filters:
            if _match(pattern, subject):
                try:
                    if asyncio.iscoroutinefunction(handler):
                        await handler(ce)
                    else:
                        handler(ce)
                except Exception:
                    pass
        # cursor+ack：消费完确认
        try:
            await self.client.ack(EVENTS_QUEUE,
                                  body.get("group", ""),
                                  body.get("delivery_id", ""))
        except Exception:
            pass

    async def tail(self, pattern: str = ">", since: int | None = None,
                   handler=None, duration: float = 0) -> None:
        """订阅并（可选）限时收听。"""
        if handler:
            await self.subscribe(pattern, handler)
        else:
            await self.client.consume(EVENTS_QUEUE, filter=pattern,
                                      since=since)
        if duration > 0:
            await asyncio.sleep(duration)
