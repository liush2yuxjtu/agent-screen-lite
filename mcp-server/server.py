#!/usr/bin/env python3
"""stdio MCP server for the local AgentScreenLite macOS helper.

No third-party Python dependency is required. The native helper owns the
private CGVirtualDisplay object and the Accessibility window checkpoints;
this process only exposes a small MCP surface and forwards JSON requests over
its user-only Unix socket.
"""
from __future__ import annotations

import json
import os
import socket
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

VERSION = "0.1.0"
ROOT = Path(os.environ.get("AGENT_SCREEN_ROOT", Path(__file__).resolve().parents[1]))
BINARY = Path(os.environ.get("AGENT_SCREEN_BINARY", ROOT / "dist" / "AgentScreenLite"))
SOCKET_PATH = Path(os.environ.get(
    "AGENT_SCREEN_SOCKET",
    Path.home() / "Library" / "Application Support" / "agent-screen-lite" / "control.sock",
))
_daemon: subprocess.Popen[bytes] | None = None

TOOLS = [
    {
        "name": "screen_status",
        "description": "Read virtual displays, online displays, Accessibility readiness, and whether a second display is available for safe window isolation.",
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
    },
    {
        "name": "screen_create",
        "description": "Create or reuse a named macOS virtual work screen. This does not move apps.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "name": {"type": "string", "minLength": 1, "maxLength": 80},
                "width": {"type": "integer", "minimum": 320, "maximum": 8192},
                "height": {"type": "integer", "minimum": 240, "maximum": 8192},
                "hi_dpi": {"type": "boolean"},
            },
            "required": ["name"],
            "additionalProperties": False,
        },
    },
    {
        "name": "screen_move_app",
        "description": "Move an already running app's ordinary windows from one source display into a named virtual screen. Defaults to physical displays only when source_display_id is omitted.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "screen": {"type": "string"},
                "display_id": {"type": "integer", "minimum": 1},
                "bundle_id": {"type": "string"},
                "app_path": {"type": "string"},
                "source_display_id": {"type": "integer", "minimum": 0},
            },
            "anyOf": [{"required": ["bundle_id"]}, {"required": ["app_path"]}],
            "additionalProperties": False,
        },
    },
    {
        "name": "screen_restore",
        "description": "Restore one app or all tracked app windows from a virtual screen to their recorded physical placement.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "screen": {"type": "string"},
                "display_id": {"type": "integer", "minimum": 1},
                "bundle_id": {"type": "string"},
            },
            "required": ["screen"],
            "additionalProperties": False,
        },
    },
    {
        "name": "screen_verify",
        "description": "Verify that a virtual screen is online and capturable; reports permissions and writes a local PNG evidence file. It does not claim keyboard or mouse isolation.",
        "inputSchema": {
            "type": "object",
            "properties": {"screen": {"type": "string"}, "display_id": {"type": "integer", "minimum": 1}},
            "required": ["screen"],
            "additionalProperties": False,
        },
    },
    {
        "name": "screen_capture",
        "description": "Capture one virtual display to a local PNG for visual inspection.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "screen": {"type": "string"},
                "display_id": {"type": "integer", "minimum": 1},
                "path": {"type": "string"},
            },
            "required": ["screen"],
            "additionalProperties": False,
        },
    },
    {
        "name": "screen_destroy",
        "description": "Restore tracked windows and remove a virtual screen. Refuses to destroy when restoration cannot be verified.",
        "inputSchema": {
            "type": "object",
            "properties": {"screen": {"type": "string"}, "display_id": {"type": "integer", "minimum": 1}},
            "required": ["screen"],
            "additionalProperties": False,
        },
    },
]


def _json_line(obj: Any) -> bytes:
    return (json.dumps(obj, ensure_ascii=False, separators=(",", ":")) + "\n").encode()


def _raw_call(method: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
    global _daemon
    params = params or {}
    for attempt in range(2):
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                client.settimeout(45)
                client.connect(str(SOCKET_PATH))
                client.sendall(_json_line({"method": method, "params": params}))
                data = bytearray()
                while not data.endswith(b"\n"):
                    chunk = client.recv(65536)
                    if not chunk:
                        raise RuntimeError("AgentScreenLite closed the control socket")
                    data.extend(chunk)
                result = json.loads(bytes(data))
                if not isinstance(result, dict):
                    raise RuntimeError("AgentScreenLite returned a non-object")
                return result
        except (FileNotFoundError, ConnectionRefusedError, TimeoutError, socket.timeout, RuntimeError, OSError) as exc:
            if attempt == 1:
                raise RuntimeError(f"AgentScreenLite unavailable: {exc}") from exc
            _start_daemon()
    raise AssertionError("unreachable")


def _start_daemon() -> None:
    global _daemon
    if _daemon is not None and _daemon.poll() is None:
        return
    if not BINARY.exists():
        raise RuntimeError(f"native helper is missing: {BINARY}")
    BINARY.parent.mkdir(parents=True, exist_ok=True)
    log_path = Path.home() / "Library" / "Logs" / "agent-screen-lite.log"
    log_path.parent.mkdir(parents=True, exist_ok=True)
    log = open(log_path, "ab", buffering=0)
    _daemon = subprocess.Popen(
        [str(BINARY), "--daemon"],
        stdin=subprocess.DEVNULL,
        stdout=log,
        stderr=log,
        start_new_session=True,
        env={**os.environ, "AGENT_SCREEN_SOCKET": str(SOCKET_PATH)},
    )
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        if SOCKET_PATH.exists():
            try:
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as probe:
                    probe.settimeout(0.3)
                    probe.connect(str(SOCKET_PATH))
                    return
            except OSError:
                pass
        if _daemon.poll() is not None:
            break
        time.sleep(0.1)
    detail = ""
    try:
        detail = log_path.read_text(errors="replace")[-1000:]
    except OSError:
        pass
    raise RuntimeError(f"AgentScreenLite failed to start; see {log_path}\n{detail}")


def _tool_call(name: str, args: dict[str, Any]) -> dict[str, Any]:
    mapping = {
        "screen_status": "status",
        "screen_create": "create",
        "screen_move_app": "move_app",
        "screen_restore": "restore",
        "screen_verify": "verify",
        "screen_capture": "capture",
        "screen_destroy": "destroy",
    }
    if name not in mapping:
        raise ValueError(f"unknown tool: {name}")
    response = _raw_call(mapping[name], args)
    if not response.get("ok"):
        raise RuntimeError(response.get("error", {}).get("message", "native helper error"))
    return response.get("result", {})


def _send(message: dict[str, Any]) -> None:
    sys.stdout.write(json.dumps(message, ensure_ascii=False, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def _handle(message: dict[str, Any]) -> None:
    msg_id = message.get("id")
    method = message.get("method")
    if not method:
        return
    if method == "notifications/initialized":
        return
    if method == "initialize":
        params = message.get("params") or {}
        _send({"jsonrpc": "2.0", "id": msg_id, "result": {
            "protocolVersion": params.get("protocolVersion", "2025-06-18"),
            "capabilities": {"tools": {"listChanged": False}},
            "serverInfo": {"name": "agent-screen-lite", "version": VERSION},
            "instructions": "Use screen_create, screen_move_app, screen_verify, screen_restore, and screen_destroy as a reversible work-screen lifecycle. A virtual display shares the login session's focus, keyboard, and pointer; it is not input isolation.",
        }})
        return
    if method == "ping":
        _send({"jsonrpc": "2.0", "id": msg_id, "result": {}})
        return
    if method == "tools/list":
        _send({"jsonrpc": "2.0", "id": msg_id, "result": {"tools": TOOLS}})
        return
    if method == "tools/call":
        params = message.get("params") or {}
        name = params.get("name")
        args = params.get("arguments") or {}
        try:
            result = _tool_call(name, args)
            _send({"jsonrpc": "2.0", "id": msg_id, "result": {
                "content": [{"type": "text", "text": json.dumps(result, ensure_ascii=False, indent=2)}],
                "structuredContent": result,
            }})
        except Exception as exc:  # MCP errors are returned to the caller, not logged as protocol output.
            _send({"jsonrpc": "2.0", "id": msg_id, "result": {
                "isError": True,
                "content": [{"type": "text", "text": str(exc)}],
            }})
        return
    if msg_id is not None:
        _send({"jsonrpc": "2.0", "id": msg_id, "error": {"code": -32601, "message": f"Method not found: {method}"}})


def main() -> int:
    for line in sys.stdin:
        try:
            message = json.loads(line)
            if isinstance(message, dict):
                _handle(message)
        except Exception as exc:
            _send({"jsonrpc": "2.0", "id": None, "error": {"code": -32603, "message": str(exc)}})
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
