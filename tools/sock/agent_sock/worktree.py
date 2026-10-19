"""每次认领一个独立 git worktree + merge gate。DESIGN.md §11.6。

fencing token 只能挡住发到 server 的请求。worker 直接改文件不经过 server，
所以 token 挡不住。解决办法：
  1. 每次认领用一个独立 worktree（路径 = claim 返回的 workdir，
     分支 = task/<task_id>-t<token>）。不同认领从不写同一个目录。
  2. 只有 merge gate 能把结果合并进主线。merge gate 先问 server：
     任务是 completed，而且 completed_token == 本分支的 token。
     否则拒绝合并（MergeRejected）。

server 不碰 git。这个模块只在 client 侧运行。
"""
from __future__ import annotations

import os
import subprocess


class MergeRejected(Exception):
    pass


def branch_name(task_id: str, token: int) -> str:
    return f"task/{task_id}-t{token}"


def _git(repo: str, *args: str) -> str:
    r = subprocess.run(["git", "-C", repo, *args], capture_output=True,
                       text=True)
    if r.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)} failed: {r.stderr.strip()}")
    return r.stdout.strip()


def prepare(repo: str, claim: dict, base: str = "HEAD") -> str:
    """按 claim 结果建 worktree。claim 需含 task_id/token/workdir。
    返回 worktree 路径。"""
    workdir = claim.get("workdir") or ""
    if not workdir:
        raise ValueError("claim has no workdir; pass workroot to task_claim")
    os.makedirs(os.path.dirname(workdir), exist_ok=True)
    _git(repo, "worktree", "add", "-b",
         branch_name(claim["task_id"], claim["token"]), workdir, base)
    return workdir


def check_gate(task: dict, token: int) -> None:
    """纯函数：按 task.get 的结果判定能否合并。不能则抛 MergeRejected。"""
    if task.get("state") != "completed":
        raise MergeRejected(
            f"task {task.get('task_id')} is {task.get('state')}, not completed")
    if int(task.get("completed_token", 0)) != int(token):
        raise MergeRejected(
            f"task {task.get('task_id')} completed by token "
            f"{task.get('completed_token')}, not {token}")


async def merge_gate(client, repo: str, task_id: str, token: int,
                     into: str = "", remove: bool = True) -> str:
    """server 确认 token 有效后才合并 task/<id>-t<token> 分支。
    返回合并后的 HEAD。into 为空时合并进 repo 当前分支。"""
    task = await client.task_get(task_id)
    check_gate(task, token)
    br = branch_name(task_id, token)
    if into:
        _git(repo, "checkout", into)
    _git(repo, "merge", "--no-ff", "-m", f"merge {br} (fenced)", br)
    if remove and task.get("workdir"):
        cleanup(repo, task["workdir"])
    return _git(repo, "rev-parse", "HEAD")


def cleanup(repo: str, workdir: str) -> None:
    """删除 worktree（分支保留，便于审计）。"""
    if os.path.isdir(workdir):
        _git(repo, "worktree", "remove", "--force", workdir)
