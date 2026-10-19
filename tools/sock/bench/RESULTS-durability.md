# 持久化改动：fsync 代价测量（2026-10-19）

机器：开发 box，ext4 on /dev/vdb（virtio）。原始 fsync：p50 0.083 ms，p99 0.994 ms（500 次，每次 201 字节）。
负载：publish 200 字节载荷。seq = 1 个客户端串行 500 次。conc16 = 16 个客户端并发，每个 200 次。
客户端：Python `agent_sock.client`（两个 server 用同一个客户端）。每组跑 3 次。

## Python server（`python bench_publish_py.py <pkgroot> [--no-fsync]`）

| 版本 | p50 ms | p99 ms | seq ops/s | conc16 ops/s |
|---|---|---|---|---|
| main（不 fsync，每 10 ms 重写 state.json） | 0.27–0.30 | 0.91–1.02 | 2590–3008 | 1704–1847 |
| 本分支 `--no-fsync`（只用于对照） | 0.25–0.29 | 0.65–0.73 | 3225–3594 | 2225–2928 |
| 本分支（fsync 后回复，组提交） | 0.55–0.82 | 2.03–3.72 | 1186–1406 | 1907–2128 |

结论：串行 publish 每次多一次 fsync，p50 增加约 0.3–0.5 ms。并发时组提交把多次写入合成一次 fsync，吞吐和 main 相同或更高（main 的 state.json 定时重写也有代价）。

## Zig server（ReleaseFast，`python bench_publish_zig.py <asock-server> <pkgroot> [--no-fsync]`）

| 版本 | p50 ms | p99 ms | seq ops/s | conc16 ops/s |
|---|---|---|---|---|
| main（每条记录 fsync，持引擎自旋锁） | 0.21–0.22 | 1.36–1.62 | 3221–3815 | 591–631 |
| 本分支 `--no-fsync`（只用于对照） | 0.11–0.12 | 0.27–0.56 | 7471–8320 | 11733–15448 |
| 本分支（组提交，fsync 在锁外） | 0.20–0.23 | 0.83–1.47 | 1274–3873 | 10039–13254 |

结论：串行延迟和 main 相同（都是每次一次 fsync）。并发吞吐从约 600 ops/s 升到约 10000–13000 ops/s（约 17–22 倍），原因是 main 在自旋锁内 fsync，所有连接线程排队。

Debug 构建（`zig build` 缺省）的并发吞吐约 350–460 ops/s，三个版本相同；瓶颈在 Debug 分配器，不在 fsync。
