"""tools/retry: post-execution validation + retry for tool calls.

Prototype for the fx heterogeneous-decomposition project: give the agent
a way to check a tool's result against expectations and retry transient
failures instead of hard-failing.
"""

from .engine import run_with_retry, RunResult, Attempt, RetryPolicy
from .validators import ConfigError, CheckResult, ExecResult

__version__ = "0.1.0"

__all__ = [
    "run_with_retry",
    "RunResult",
    "Attempt",
    "RetryPolicy",
    "ConfigError",
    "CheckResult",
    "ExecResult",
    "__version__",
]
