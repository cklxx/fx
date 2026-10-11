"""CLI: python3 -m tmux_compile <dsl.yaml> -o <product.sh> [--param K=V ...]."""

import argparse
import sys

from .compiler import compile_dsl, CompileError, EXIT_COMPILE_ERROR


def main(argv):
    p = argparse.ArgumentParser(
        prog="tmux_compile",
        description="Compile a YAML tmux interaction sequence into a bash product.",
    )
    p.add_argument("dsl", help="input YAML file")
    p.add_argument("-o", "--output", required=True, help="output bash file")
    p.add_argument(
        "--param",
        action="append",
        default=[],
        metavar="K=V",
        help="value for a {{param}} declared in the DSL (repeatable)",
    )
    args = p.parse_args(argv)
    params = {}
    for pv in args.param:
        if "=" not in pv:
            print(
                "COMPILE-ERROR bad --param '%s' (want K=V)" % pv, file=sys.stderr
            )
            return 2
        k, v = pv.split("=", 1)
        params[k] = v
    try:
        n = compile_dsl(args.dsl, args.output, params=params or None)
    except CompileError as e:
        loc = "%s:%s" % (args.dsl, e.line) if e.line else args.dsl
        print("COMPILE-ERROR %s: %s" % (loc, e.message), file=sys.stderr)
        return EXIT_COMPILE_ERROR
    except OSError as e:
        print("COMPILE-ERROR %s: %s" % (args.dsl, e), file=sys.stderr)
        return EXIT_COMPILE_ERROR
    print("compiled %s -> %s (%d steps)" % (args.dsl, args.output, n))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
