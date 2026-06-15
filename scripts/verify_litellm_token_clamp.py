#!/usr/bin/env python3

from __future__ import annotations

import argparse
import contextlib
import dataclasses
import http.server
import importlib.util
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any


MASTER_KEY = "test-master-key"
MODEL_NAME = "probe-model"
BACKEND_MODEL = "openai/mock-backend"
COST_INPUT_CAP = 16
COST_TOTAL_CAP = 64


@dataclasses.dataclass
class MockRecord:
    path: str
    body: dict[str, Any]
    status: int


class MockState:
    def __init__(self, output_cap: int):
        self.output_cap = output_cap
        self.records: list[MockRecord] = []
        self.lock = threading.Lock()

    def append(self, record: MockRecord) -> None:
        with self.lock:
            self.records.append(record)

    def snapshot(self) -> list[MockRecord]:
        with self.lock:
            return list(self.records)


def find_free_port() -> int:
    with contextlib.closing(socket.socket(socket.AF_INET, socket.SOCK_STREAM)) as sock:
        sock.bind(("127.0.0.1", 0))
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        return int(sock.getsockname()[1])


def make_mock_handler(state: MockState) -> type[http.server.BaseHTTPRequestHandler]:
    class Handler(http.server.BaseHTTPRequestHandler):
        server_version = "TokenClampMock/1.0"

        def log_message(self, fmt: str, *args: Any) -> None:
            return

        def _send_json(self, status: int, payload: dict[str, Any]) -> None:
            encoded = json.dumps(payload).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)

        def do_GET(self) -> None:
            if self.path.endswith("/models"):
                self._send_json(
                    200,
                    {
                        "object": "list",
                        "data": [{"id": "mock-backend", "object": "model"}],
                    },
                )
                return
            self._send_json(404, {"error": {"message": "not found"}})

        def do_POST(self) -> None:
            length = int(self.headers.get("Content-Length") or "0")
            raw = self.rfile.read(length)
            try:
                body = json.loads(raw.decode("utf-8") or "{}")
            except json.JSONDecodeError:
                body = {}

            requested_values = []
            for key in ("max_tokens", "max_completion_tokens"):
                value = body.get(key)
                if isinstance(value, int):
                    requested_values.append((key, value))

            over_cap = [(key, value) for key, value in requested_values if value > state.output_cap]
            if over_cap:
                status = 400
                payload = {
                    "error": {
                        "message": f"mock provider rejected output reservation over {state.output_cap}: {over_cap}",
                        "type": "invalid_request_error",
                    }
                }
            else:
                status = 200
                payload = {
                    "id": "chatcmpl-token-clamp-probe",
                    "object": "chat.completion",
                    "created": 0,
                    "model": body.get("model", "mock-backend"),
                    "choices": [
                        {
                            "index": 0,
                            "finish_reason": "stop",
                            "message": {"role": "assistant", "content": "OK"},
                        }
                    ],
                    "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2},
                }

            state.append(MockRecord(path=self.path, body=body, status=status))
            self._send_json(status, payload)

    return Handler


@contextlib.contextmanager
def run_mock_provider(output_cap: int):
    state = MockState(output_cap=output_cap)
    port = find_free_port()
    server = http.server.ThreadingHTTPServer(("127.0.0.1", port), make_mock_handler(state))
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{port}/v1", state
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


def write_callback(tmpdir: Path, cap: int) -> None:
    (tmpdir / "custom_callbacks.py").write_text(
        f"""
import json
import os
from pathlib import Path

from litellm.integrations.custom_logger import CustomLogger

OUTPUT_CAP = {cap}
COST_INPUT_CAP = {COST_INPUT_CAP}
COST_TOTAL_CAP = {COST_TOTAL_CAP}
MARKER_PATH = os.environ.get("TOKEN_CLAMP_MARKER")


def mark(event, payload=None):
    if not MARKER_PATH:
        return
    with Path(MARKER_PATH).open("a", encoding="utf-8") as handle:
        handle.write(json.dumps({{"event": event, "payload": payload or {{}}}}, default=str) + "\\n")


mark("import")


def iter_text(value):
    if value is None:
        return []
    if isinstance(value, str):
        return [value]
    if isinstance(value, list):
        out = []
        for item in value:
            out.extend(iter_text(item))
        return out
    if isinstance(value, dict):
        if "content" in value:
            return iter_text(value.get("content"))
        if "text" in value:
            return iter_text(value.get("text"))
        out = []
        for item in value.values():
            out.extend(iter_text(item))
        return out
    return [str(value)]


def estimate_input(data):
    text = "\\n".join(
        part
        for key in ("messages", "input", "prompt", "system", "tools", "functions")
        for part in iter_text(data.get(key))
    )
    return max((len(text) + 3) // 4, len(text.split())) if text else 0


class OutputClamp(CustomLogger):
    def __init__(self):
        mark("init")

    async def async_pre_call_hook(self, user_api_key_dict, cache, data, call_type):
        mark("async_pre_call_hook", {{"call_type": call_type, "before": dict(data)}})
        if call_type not in ("completion", "text_completion"):
            return data

        seen_token_key = False
        for key in ("max_tokens", "max_completion_tokens"):
            value = data.get(key)
            if value is None:
                continue
            seen_token_key = True
            try:
                value = int(value)
            except Exception:
                data[key] = OUTPUT_CAP
                continue
            if value > OUTPUT_CAP:
                data[key] = OUTPUT_CAP

        if not seen_token_key:
            data["max_tokens"] = OUTPUT_CAP

        mark("async_pre_call_hook", {{"call_type": call_type, "after": dict(data)}})
        return data

    async def async_pre_call_deployment_hook(self, kwargs, call_type):
        mark("async_pre_call_deployment_hook", {{"call_type": str(call_type), "before": dict(kwargs)}})
        for key in ("max_tokens", "max_completion_tokens"):
            value = kwargs.get(key)
            if value is None:
                continue
            try:
                value = int(value)
            except Exception:
                kwargs[key] = OUTPUT_CAP
                continue
            if value > OUTPUT_CAP:
                kwargs[key] = OUTPUT_CAP
        estimated_input = estimate_input(kwargs)
        requested_output = max([
            value for value in (kwargs.get("max_tokens"), kwargs.get("max_completion_tokens"))
            if isinstance(value, int)
        ] or [0])
        if estimated_input > COST_INPUT_CAP or estimated_input + requested_output > COST_TOTAL_CAP:
            raise ValueError(
                "test cost guardrail rejected request before provider dispatch: "
                f"input={{estimated_input}} total={{estimated_input + requested_output}}"
            )
        mark("async_pre_call_deployment_hook", {{"call_type": str(call_type), "after": dict(kwargs)}})
        return kwargs


proxy_handler_instance = OutputClamp()
""".lstrip(),
        encoding="utf-8",
    )


def materialize_callback_module(tmpdir: Path, callback_module: str, output_cap: int) -> None:
    module_name = ".".join(callback_module.split(".")[:-1])
    if module_name == "custom_callbacks":
        write_callback(tmpdir, output_cap)
        return

    spec = importlib.util.find_spec(module_name)
    if spec is None or spec.origin is None:
        raise RuntimeError(f"Cannot locate callback module source: {module_name}")
    source = Path(spec.origin)
    if not source.is_file():
        raise RuntimeError(f"Callback module source is not a file: {source}")

    dest = tmpdir / Path(*module_name.split(".")).with_suffix(".py")
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, dest)

    package_parts = module_name.split(".")[:-1]
    package_dir = tmpdir
    for part in package_parts:
        package_dir = package_dir / part
        package_dir.mkdir(exist_ok=True)
        init_file = package_dir / "__init__.py"
        init_file.touch(exist_ok=True)


def write_config(
    tmpdir: Path,
    upstream_base_url: str,
    *,
    output_cap: int,
    callback: bool,
    callback_module: str,
    modify_params: bool,
) -> Path:
    callbacks_line = f"  callbacks: [{callback_module}]\n" if callback else ""
    modify_line = "  modify_params: true\n" if modify_params else ""
    config = f"""
model_list:
  - model_name: {MODEL_NAME}
    litellm_params:
      model: {BACKEND_MODEL}
      api_base: {upstream_base_url}
      api_key: test-upstream-key
      max_tokens: {output_cap}
    model_info:
      max_input_tokens: 4096
      max_output_tokens: {output_cap}

general_settings:
  master_key: {MASTER_KEY}

x-gateway-output-clamp:
  enabled: true
  default: {output_cap}
  tokenizer_headroom: 1
  minimum_input: 1

x-gateway-cost-guardrail:
  enabled: true
  max_estimated_input_tokens: {COST_INPUT_CAP}
  max_estimated_total_tokens: {COST_TOTAL_CAP}
  chars_per_token: 4

litellm_settings:
  drop_params: true
{modify_line}{callbacks_line}
router_settings:
  enable_pre_call_checks: true
""".lstrip()
    path = tmpdir / "litellm_config.yaml"
    path.write_text(config, encoding="utf-8")
    if callback:
        materialize_callback_module(tmpdir, callback_module, output_cap)
    return path


def request_json(url: str, payload: dict[str, Any], timeout: float = 20.0) -> tuple[int, dict[str, Any]]:
    encoded = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=encoded,
        headers={
            "Authorization": f"Bearer {MASTER_KEY}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return int(resp.status), json.loads(resp.read().decode("utf-8") or "{}")
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8")
        try:
            parsed = json.loads(body or "{}")
        except json.JSONDecodeError:
            parsed = {"raw": body}
        return int(exc.code), parsed


def wait_for_proxy(port: int, timeout: float) -> None:
    deadline = time.monotonic() + timeout
    last_error: Exception | None = None
    url = f"http://127.0.0.1:{port}/v1/models"
    while time.monotonic() < deadline:
        req = urllib.request.Request(url, headers={"Authorization": f"Bearer {MASTER_KEY}"})
        try:
            with urllib.request.urlopen(req, timeout=2) as resp:
                if 200 <= int(resp.status) < 500:
                    return
        except Exception as exc:  # noqa: BLE001 - diagnostic loop
            last_error = exc
            time.sleep(0.25)
    raise RuntimeError(f"LiteLLM proxy did not become ready: {last_error}")


@contextlib.contextmanager
def run_litellm_proxy(
    *,
    litellm_bin: str,
    config_path: Path,
    cwd: Path,
    timeout: float,
):
    port = find_free_port()
    log_path = cwd / "litellm.log"
    env = os.environ.copy()
    env["PYTHONPATH"] = str(cwd) + os.pathsep + env.get("PYTHONPATH", "")
    env["AI_LITELLM_CONFIG"] = str(config_path)
    env["NO_PROXY"] = "127.0.0.1,localhost"
    env["LITELLM_TELEMETRY"] = "False"
    env["TOKEN_CLAMP_MARKER"] = str(cwd / "callback-marker.jsonl")
    cmd = [
        litellm_bin,
        "--config",
        str(config_path),
        "--host",
        "127.0.0.1",
        "--port",
        str(port),
        "--telemetry",
        "False",
    ]
    with log_path.open("wb") as log:
        proc = subprocess.Popen(cmd, cwd=str(cwd), env=env, stdout=log, stderr=subprocess.STDOUT)
    try:
        wait_for_proxy(port, timeout)
        yield port, log_path
    except Exception:
        with contextlib.suppress(Exception):
            sys.stderr.write(log_path.read_text(encoding="utf-8", errors="replace")[-8000:])
        raise
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=10)


def run_case(
    *,
    name: str,
    litellm_bin: str,
    upstream_base_url: str,
    state: MockState,
    output_cap: int,
    callback: bool,
    callback_module: str,
    modify_params: bool,
    request_overrides: dict[str, Any],
    timeout: float,
    keep_temp: bool,
) -> dict[str, Any]:
    if keep_temp:
        tmp = Path(tempfile.mkdtemp(prefix=f"litellm-clamp-{name}-"))
        cleanup_context = contextlib.nullcontext()
    else:
        temp_context = tempfile.TemporaryDirectory(prefix=f"litellm-clamp-{name}-")
        tmp = Path(temp_context.name)
        cleanup_context = temp_context

    with cleanup_context:
        config_path = write_config(
            tmp,
            upstream_base_url,
            output_cap=output_cap,
            callback=callback,
            callback_module=callback_module,
            modify_params=modify_params,
        )
        before = len(state.snapshot())
        with run_litellm_proxy(
            litellm_bin=litellm_bin,
            config_path=config_path,
            cwd=tmp,
            timeout=timeout,
        ) as (proxy_port, log_path):
            payload: dict[str, Any] = {
                "model": MODEL_NAME,
                "messages": [{"role": "user", "content": "ping"}],
            }
            payload.update(request_overrides)
            status, response = request_json(
                f"http://127.0.0.1:{proxy_port}/v1/chat/completions",
                payload,
                timeout=timeout,
            )
        records = state.snapshot()[before:]
        upstream_body = records[-1].body if records else None
        upstream_status = records[-1].status if records else None
        marker_path = tmp / "callback-marker.jsonl"
        marker_events = []
        if marker_path.exists():
            for line in marker_path.read_text(encoding="utf-8").splitlines():
                try:
                    marker_events.append(json.loads(line).get("event", "unknown"))
                except json.JSONDecodeError:
                    marker_events.append("unparseable")
        return {
            "name": name,
            "callback": callback,
            "modify_params": modify_params,
            "client_status": status,
            "upstream_status": upstream_status,
            "upstream_body": upstream_body,
            "response_error": response.get("error"),
            "callback_marker_events": marker_events,
            "tempdir": str(tmp) if keep_temp else None,
            "log_path": str(log_path) if keep_temp else None,
        }


def token_values(body: dict[str, Any] | None) -> dict[str, int]:
    if not body:
        return {}
    values: dict[str, int] = {}
    for key in ("max_tokens", "max_completion_tokens"):
        value = body.get(key)
        if isinstance(value, int):
            values[key] = value
    return values


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Verify whether LiteLLM config-only settings clamp provider output token reservations.",
    )
    parser.add_argument("--litellm-bin", default=os.environ.get("LITELLM_BIN") or shutil.which("litellm"))
    parser.add_argument("--output-cap", type=int, default=8)
    parser.add_argument(
        "--callback-module",
        default="custom_callbacks.proxy_handler_instance",
        help="Callback object path to test for callback cases.",
    )
    parser.add_argument("--timeout", type=float, default=45.0)
    parser.add_argument("--keep-temp", action="store_true")
    parser.add_argument("--json", action="store_true", dest="json_output")
    args = parser.parse_args()

    if not args.litellm_bin:
        print("litellm executable not found. Set LITELLM_BIN or install litellm.", file=sys.stderr)
        return 2

    with run_mock_provider(output_cap=args.output_cap) as (upstream_base_url, state):
        cases = [
            {
                "name": "config_default_injection",
                "callback": False,
                "modify_params": False,
                "request_overrides": {},
            },
            {
                "name": "config_client_max_tokens_override",
                "callback": False,
                "modify_params": False,
                "request_overrides": {"max_tokens": args.output_cap * 4},
            },
            {
                "name": "config_modify_params_client_override",
                "callback": False,
                "modify_params": True,
                "request_overrides": {"max_tokens": args.output_cap * 4},
            },
            {
                "name": "config_modify_params_completion_override",
                "callback": False,
                "modify_params": True,
                "request_overrides": {"max_completion_tokens": args.output_cap * 4},
            },
            {
                "name": "hook_client_max_tokens_clamp",
                "callback": True,
                "modify_params": False,
                "request_overrides": {"max_tokens": args.output_cap * 4},
            },
            {
                "name": "hook_client_max_completion_tokens_clamp",
                "callback": True,
                "modify_params": False,
                "request_overrides": {"max_completion_tokens": args.output_cap * 4},
            },
            {
                "name": "hook_cost_guardrail_rejects_before_provider",
                "callback": True,
                "modify_params": False,
                "request_overrides": {
                    "messages": [
                        {
                            "role": "user",
                            "content": " ".join(f"word{i}" for i in range(COST_INPUT_CAP + 8)),
                        }
                    ],
                    "max_tokens": 1,
                },
            },
            {
                # Regression guard: agentic prompts carry their bulk in the tool
                # catalog, not the conversation. With tiny messages but a large
                # tools payload the guardrail must still reject — otherwise a big
                # tool catalog slips past the estimate to a billable backend.
                "name": "hook_cost_guardrail_counts_tools",
                "callback": True,
                "modify_params": False,
                "request_overrides": {
                    "messages": [{"role": "user", "content": "hi"}],
                    "tools": [
                        {
                            "type": "function",
                            "function": {
                                "name": "bulky_tool",
                                "description": " ".join(
                                    f"tok{i}" for i in range(COST_INPUT_CAP + 8)
                                ),
                                "parameters": {"type": "object", "properties": {}},
                            },
                        }
                    ],
                    "max_tokens": 1,
                },
            },
        ]
        results = [
            run_case(
                litellm_bin=args.litellm_bin,
                upstream_base_url=upstream_base_url,
                state=state,
                output_cap=args.output_cap,
                callback_module=args.callback_module,
                timeout=args.timeout,
                keep_temp=args.keep_temp,
                **case,
            )
            for case in cases
        ]

    for result in results:
        result["upstream_token_values"] = token_values(result["upstream_body"])

    config_override = next(r for r in results if r["name"] == "config_client_max_tokens_override")
    config_modify = next(r for r in results if r["name"] == "config_modify_params_client_override")
    config_modify_completion = next(
        r for r in results if r["name"] == "config_modify_params_completion_override"
    )
    hook_max = next(r for r in results if r["name"] == "hook_client_max_tokens_clamp")
    hook_completion = next(r for r in results if r["name"] == "hook_client_max_completion_tokens_clamp")
    hook_cost = next(r for r in results if r["name"] == "hook_cost_guardrail_rejects_before_provider")
    hook_cost_tools = next(r for r in results if r["name"] == "hook_cost_guardrail_counts_tools")

    def max_seen(result: dict[str, Any]) -> int:
        values = result["upstream_token_values"].values()
        return max(values) if values else 0

    plain_config_enforced = (
        config_override["upstream_status"] == 200
        and max_seen(config_override) <= args.output_cap
    )
    modify_params_enforced = (
        config_modify["upstream_status"] == 200
        and max_seen(config_modify) <= args.output_cap
        and config_modify_completion["upstream_status"] == 200
        and max_seen(config_modify_completion) <= args.output_cap
    )
    hook_enforced = (
        hook_max["upstream_status"] == 200
        and max_seen(hook_max) <= args.output_cap
        and hook_completion["upstream_status"] == 200
        and max_seen(hook_completion) <= args.output_cap
    )
    hook_cost_guardrail_enforced = (
        hook_cost["client_status"] >= 400
        and hook_cost["upstream_status"] is None
    )
    hook_cost_guardrail_counts_tools = (
        hook_cost_tools["client_status"] >= 400
        and hook_cost_tools["upstream_status"] is None
    )
    if modify_params_enforced:
        recommended_policy = "litellm_settings.modify_params"
    elif hook_enforced:
        recommended_policy = "async_pre_call_deployment_hook"
    else:
        recommended_policy = "no verified gateway clamp"

    verdict = {
        "litellm_bin": args.litellm_bin,
        "output_cap": args.output_cap,
        "callback_module": args.callback_module,
        "plain_config_enforced_client_output_cap": plain_config_enforced,
        "modify_params_enforced_client_output_cap": modify_params_enforced,
        "hook_enforced_client_output_cap": hook_enforced,
        "hook_enforced_cost_guardrail": hook_cost_guardrail_enforced,
        "hook_enforced_cost_guardrail_tools": hook_cost_guardrail_counts_tools,
        "recommended_policy": recommended_policy,
        "results": results,
    }

    if args.json_output:
        print(json.dumps(verdict, indent=2, sort_keys=True))
    else:
        print(f"litellm_bin: {args.litellm_bin}")
        print(f"output_cap: {args.output_cap}")
        for result in results:
            values = result["upstream_token_values"]
            print(
                f"{result['name']}: client_status={result['client_status']} "
                f"upstream_status={result['upstream_status']} upstream_tokens={values}"
            )
        print(f"plain_config_enforced_client_output_cap: {str(plain_config_enforced).lower()}")
        print(f"modify_params_enforced_client_output_cap: {str(modify_params_enforced).lower()}")
        print(f"hook_enforced_client_output_cap: {str(hook_enforced).lower()}")
        print(f"hook_enforced_cost_guardrail: {str(hook_cost_guardrail_enforced).lower()}")
        print(
            "hook_enforced_cost_guardrail_tools: "
            f"{str(hook_cost_guardrail_counts_tools).lower()}"
        )
        print(f"recommended_policy: {verdict['recommended_policy']}")

    return (
        0
        if (modify_params_enforced or hook_enforced)
        and hook_cost_guardrail_enforced
        and hook_cost_guardrail_counts_tools
        else 1
    )


if __name__ == "__main__":
    raise SystemExit(main())
