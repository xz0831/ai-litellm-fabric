import sys

USAGE = "fabric — ai-litellm control-plane TUI\n\nUsage: fabric            launch the dashboard\n       fabric --help     show this help\n"


def main() -> int:
    if "--help" in sys.argv[1:] or "-h" in sys.argv[1:]:
        print(USAGE)
        return 0
    try:
        from .app import FabricApp
    except ModuleNotFoundError as e:
        if "textual" in str(e):
            print("fabric requires Textual: python3 -m pip install textual", file=sys.stderr)
            return 1
        raise
    app = FabricApp()
    result = app.run()
    if isinstance(result, tuple) and result and result[0] == "launch":
        import os
        harness = result[1][0]
        os.execvp("ai-litellm", ["ai-litellm", "harness", "launch", harness])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
