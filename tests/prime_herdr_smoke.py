#!/usr/bin/env python3
"""Exercise patched Herdr and real Prime with an isolated local model provider."""

import argparse
import json
import os
import socket
import subprocess
import tempfile
import threading
import time
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument(
    "--herdr", required=True, help="absolute path to the patched Herdr binary"
)
parser.add_argument(
    "--prime-agent", required=True, help="absolute path to the real Prime Agent binary"
)
args = parser.parse_args()
base = Path(tempfile.mkdtemp(prefix="herdr-prime-smoke-"))
print(f"evidence: {base}", flush=True)
herdr = str(Path(args.herdr).resolve())
prime = str(Path(args.prime_agent).resolve())
repository = Path(__file__).resolve().parents[1]
adapter = repository / "config/pstack/skills/pstack-pair/scripts/prime-agent.sh"
name = "prime-smoke-" + str(os.getpid())
mode = "ok"


class Provider(BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        if mode == "error":
            self.send_response(401)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(
                json.dumps(
                    {
                        "error": {
                            "message": "smoke provider denied request",
                            "type": "authentication_error",
                        }
                    }
                ).encode()
            )
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        time.sleep(1)
        for chunk in [
            {
                "id": "smoke",
                "object": "chat.completion.chunk",
                "model": "smoke",
                "choices": [
                    {
                        "index": 0,
                        "delta": {"role": "assistant", "content": "OK"},
                        "finish_reason": None,
                    }
                ],
            },
            {
                "id": "smoke",
                "object": "chat.completion.chunk",
                "model": "smoke",
                "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
                "usage": {
                    "prompt_tokens": 1,
                    "completion_tokens": 1,
                    "total_tokens": 2,
                },
            },
        ]:
            self.wfile.write(("data: " + json.dumps(chunk) + "\n\n").encode())
            self.wfile.flush()
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()

    def log_message(self, *args):
        pass


provider = ThreadingHTTPServer(("127.0.0.1", 0), Provider)
threading.Thread(target=provider.serve_forever, daemon=True).start()
for directory in ["home", "config", "state", "agent", "bin", "cwd"]:
    (base / directory).mkdir()
(base / "bin/herdr").symlink_to(herdr)
(base / "bin/prime-agent").symlink_to(prime)
(base / "home/.agents").mkdir()
(base / "home/.agents/skills").symlink_to(repository / "config/pstack/skills")
config = base / "herdr.toml"
config.write_text(
    'onboarding = false\n[experimental]\nallow_nested = true\n[terminal]\ndefault_shell = "/bin/bash"\n[server]\nheadless_cols = 160\nheadless_rows = 50\n'
)
(base / "agent/settings.json").write_text(
    json.dumps(
        {
            "onboardingShown": True,
            "onboardingCompleted": True,
            "agentTraces": {"enabled": False},
            "telemetry": {"enabled": False},
        }
    )
)
(base / "agent/models.json").write_text(
    json.dumps(
        {
            "providers": {
                "mock": {
                    "baseUrl": f"http://127.0.0.1:{provider.server_port}/v1",
                    "apiKey": "local-smoke",
                    "api": "openai-completions",
                    "models": [{"id": "smoke", "name": "Smoke"}],
                }
            }
        }
    )
)
env = {k: v for k, v in os.environ.items() if not k.startswith("HERDR_")}
env.update(
    HERDR_ENV="1",
    HERDR_SESSION=name,
    HERDR_CONFIG_PATH=str(config),
    HOME=str(base / "home"),
    XDG_CONFIG_HOME=str(base / "config"),
    XDG_STATE_HOME=str(base / "state"),
    PRIME_AGENT_CODING_AGENT_DIR=str(base / "agent"),
    PATH=f"{base}/bin:" + os.environ["PATH"],
    SHELL="/bin/bash",
)
log = (base / "commands.jsonl").open("w")


def call(binary, args, timeout=45, check=True):
    result = subprocess.run(
        [binary, *args],
        env=env,
        cwd=base / "cwd",
        capture_output=True,
        text=True,
        timeout=timeout,
        check=False,
    )
    log.write(
        json.dumps(
            {
                "args": args,
                "code": result.returncode,
                "out": result.stdout,
                "err": result.stderr,
            }
        )
        + "\n"
    )
    log.flush()
    if check and result.returncode:
        raise RuntimeError(f"{args}: {result.stderr}")
    return result


def h(*args, check=True):
    return call(herdr, list(args), check=check)


def p(*args):
    return call(prime, list(args))


def agent():
    return json.loads(h("agent", "get", "prime-test").stdout)["result"]["agent"]


server = None
active_id = None
try:
    h("config", "check")
    server = subprocess.Popen(
        [herdr, "server"],
        env=env,
        cwd=base / "cwd",
        stdout=(base / "server.log").open("w"),
        stderr=subprocess.STDOUT,
    )
    for _ in range(100):
        result = h("pane", "list", check=False)
        if result.returncode == 0:
            break
        if server.poll() is not None:
            raise RuntimeError((base / "server.log").read_text())
        time.sleep(0.1)
    else:
        raise RuntimeError("server did not start")
    panes = json.loads(result.stdout)["result"]["panes"]
    if panes:
        pane = panes[0]["pane_id"]
    else:
        pane = json.loads(
            h("workspace", "create", "--cwd", str(base / "cwd"), "--no-focus").stdout
        )["result"]["root_pane"]["pane_id"]
    print(f"named session {name}, pane {pane}", flush=True)
    h("pane", "process-info", "--pane", pane)
    call(
        "/bin/bash",
        [
            "-c",
            'set -euo pipefail; source "$1"; shift; preflight_prime "$@"',
            "smoke",
            str(adapter),
            "--offline",
            "--model",
            "mock/smoke",
        ],
    )
    print("native adapter preflight against the local provider: PASS", flush=True)
    start_args = [
        "agent",
        "start",
        "prime-test",
        "--kind",
        "prime-agent",
        "--pane",
        pane,
        "--timeout",
        "30000",
        "--",
        "--offline",
        "--model",
        "mock/smoke",
        "--daemon-socket",
        str(base / "prime.sock"),
        "--session-dir",
        str(base / "sessions"),
    ]
    h(*start_args)
    initial = agent()
    assert initial["agent"] == "prime-agent", initial
    session = initial["agent_session"]
    assert session["kind"] == "path", session
    rows = json.loads(p("list", "--json", "--socket", str(base / "prime.sock")).stdout)[
        "sessions"
    ]
    matching = [s for s in rows if s["sessionFile"] == session["value"]]
    assert len(matching) == 1, rows
    active_id = matching[0]["activeSessionId"]
    print("initial idle, built-in session path and exact daemon id: PASS", flush=True)
    h(
        "agent",
        "prompt",
        "prime-test",
        "Reply OK",
        "--wait",
        "--until",
        "working",
        "--timeout",
        "15000",
    )
    assert agent()["agent_status"] == "working"
    h(
        "agent",
        "wait",
        "prime-test",
        "--until",
        "idle",
        "--until",
        "done",
        "--timeout",
        "15000",
    )
    print("real prompt working -> idle: PASS", flush=True)
    h(
        "agent",
        "prompt",
        "prime-test",
        "Another local turn",
        "--wait",
        "--until",
        "working",
        "--timeout",
        "15000",
    )
    receipt = json.loads(
        p(
            "send",
            "--json",
            active_id,
            "Read this between tool calls",
            "--socket",
            str(base / "prime.sock"),
        ).stdout
    )
    assert receipt["deliveryMode"] == "steer", receipt
    assert receipt["target"]["activeSessionId"] == active_id, receipt
    assert receipt["deliveryStatus"] in {"queued", "delivered"}, receipt
    h(
        "agent",
        "wait",
        "prime-test",
        "--until",
        "idle",
        "--until",
        "done",
        "--timeout",
        "15000",
    )
    print("native steer to owned session during a real turn: PASS", flush=True)
    mode = "error"
    h(
        "agent",
        "prompt",
        "prime-test",
        "Probe local provider error",
        "--wait",
        "--until",
        "blocked",
        "--timeout",
        "15000",
    )
    assert agent()["agent_status"] == "blocked"
    print("provider error -> blocked after retry grace: PASS", flush=True)
    # Exercise the deployed adapter against real daemon and pane information.
    store = base / "store"
    store.mkdir()
    (store / "pair.json").write_text(
        json.dumps(
            {
                "sidekick": {
                    "name": "prime-test",
                    "kind": "prime-agent",
                    "pane_id": pane,
                    "start_args": ["--daemon-socket", str(base / "prime.sock")],
                    "session": session,
                }
            }
        )
    )
    script = """set -euo pipefail
field() { jq -r "$2" "$1/pair.json"; }
json_update() { local store="$1"; shift; jq "$@" "$store/pair.json" >"$store/new"; mv "$store/new" "$store/pair.json"; }
agent_status() { herdr agent get "$1" 2>/dev/null | jq -r '.result.agent.agent_status' || printf absent; }
source "$2"
stop_prime_role "$1" sidekick
"""
    call(
        "/bin/bash",
        [
            "-c",
            script,
            "smoke",
            str(store),
            str(adapter),
        ],
    )
    assert not any(
        s["activeSessionId"] == active_id
        for s in json.loads(
            p("list", "--json", "--socket", str(base / "prime.sock")).stdout
        )["sessions"]
    )
    assert Path(session["value"]).is_file()
    print(
        "adapter stops exact worker, releases pane to shell, preserves transcript: PASS",
        flush=True,
    )
    # Rotation must also work with an old reporter claim on this same pane.
    h(*start_args)
    fresh = agent()["agent_session"]
    assert fresh["kind"] == "path" and fresh != session, fresh
    call(
        "/bin/bash",
        [
            "-c",
            script,
            "smoke",
            str(store),
            str(adapter),
        ],
    )
    assert Path(fresh["value"]).is_file()
    assert not json.loads(
        p("list", "--json", "--socket", str(base / "prime.sock")).stdout
    )["sessions"]
    print("fresh session in the same pane and idle cleanup: PASS", flush=True)
except Exception:
    traceback.print_exc()
    raise
finally:
    if (base / "prime.sock").exists():
        try:
            rows = json.loads(
                p("list", "--json", "--socket", str(base / "prime.sock")).stdout
            )["sessions"]
            for row in rows:
                assert Path(row["sessionFile"]).is_relative_to(base), row["sessionFile"]
                p(
                    "stop",
                    row["activeSessionId"],
                    "--json",
                    "--socket",
                    str(base / "prime.sock"),
                )
        except (
            RuntimeError,
            ValueError,
            KeyError,
            AssertionError,
            subprocess.SubprocessError,
        ):
            traceback.print_exc()
    # Only this newly created named session is addressed.
    h("session", "stop", name, check=False)
    h("session", "delete", name, check=False)
    if server:
        try:
            server.wait(timeout=10)
        except subprocess.TimeoutExpired:
            server.terminate()
            server.wait(timeout=5)
    # Do not invoke global shutdown; it can discover other daemons on the host.
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.settimeout(3)
            client.connect(str(base / "prime.sock"))
            reader = client.makefile("r")
            hello = json.loads(reader.readline())
            request = {
                "type": "command",
                "id": "smoke-cleanup",
                "protocol": hello["protocol"],
                "clientId": "smoke-cleanup-client",
                "command": {"id": "smoke-cleanup", "type": "shutdown", "force": False},
            }
            client.sendall((json.dumps(request) + "\n").encode())
            reader.readline()
    except OSError:
        pass
    for _ in range(50):
        if not (base / "prime.sock").exists():
            break
        time.sleep(0.1)
    assert not (base / "prime.sock").exists(), "test daemon did not stop"
    provider.shutdown()
    log.close()
    print("test-session cleanup complete", flush=True)
