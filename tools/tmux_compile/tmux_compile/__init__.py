"""tmux_compile: compile YAML tmux interaction sequences into bash products."""

__version__ = "0.2.0"

from .compiler import compile_dsl, CompileError  # noqa: F401
