#!/usr/bin/env python3
"""Phase 0 spike for Coinor's shared Grok session architecture."""

from __future__ import annotations

import argparse
import codecs
import fcntl
import hashlib
import json
import os
from pathlib import Path
import pty
import re
import select
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time
import uuid
from typing import Any, Callable
import unicodedata


DEFAULT_TIMEOUT = 180.0
READ_SIZE = 64 * 1024
MAX_FRAME_SIZE = 64 * 1024 * 1024


class SpikeFailure(RuntimeError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SpikeFailure(message)


def sha256_file(path: Path) -> str | None:
    if not path.exists():
        return None
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(READ_SIZE), b""):
            digest.update(chunk)
    return digest.hexdigest()


def run_checked(
    command: list[str],
    *,
    cwd: Path,
    env: dict[str, str],
    timeout: float = 30.0,
) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        command,
        cwd=cwd,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout,
        check=False,
    )
    if result.returncode != 0:
        raise SpikeFailure(
            f"Command failed ({result.returncode}): {command!r}\n"
            f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        )
    return result


def wait_until(
    predicate: Callable[[], bool],
    *,
    timeout: float,
    description: str,
    interval: float = 0.1,
) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(interval)
    raise SpikeFailure(f"Timed out waiting for {description}")


def inner_params(message: dict[str, Any]) -> dict[str, Any]:
    params = message.get("params")
    if not isinstance(params, dict):
        return {}
    nested = params.get("params")
    if isinstance(nested, dict) and isinstance(params.get("method"), str):
        return nested
    return params


def session_update(message: dict[str, Any]) -> dict[str, Any]:
    update = inner_params(message).get("update")
    return update if isinstance(update, dict) else {}


def session_id_of(message: dict[str, Any]) -> str | None:
    value = inner_params(message).get("sessionId")
    if not isinstance(value, str):
        value = inner_params(message).get("session_id")
    return value if isinstance(value, str) else None


def message_is_replay(message: dict[str, Any]) -> bool:
    meta = inner_params(message).get("_meta")
    return isinstance(meta, dict) and meta.get("isReplay") is True


def update_kind(message: dict[str, Any]) -> str | None:
    update = session_update(message)
    value = update.get("sessionUpdate") or update.get("session_update")
    return value if isinstance(value, str) else None


def content_text(value: Any) -> str:
    if isinstance(value, str):
        return value
    if isinstance(value, list):
        return "".join(content_text(item) for item in value)
    if not isinstance(value, dict):
        return ""
    if value.get("type") == "text" and isinstance(value.get("text"), str):
        return value["text"]
    return "".join(
        content_text(item)
        for key, item in value.items()
        if key not in {"type", "_meta", "sessionUpdate", "session_update"}
    )


def agent_text(
    messages: list[dict[str, Any]],
    *,
    session_id: str,
    replay: bool | None,
) -> str:
    chunks: list[str] = []
    for message in messages:
        if session_id_of(message) != session_id:
            continue
        if update_kind(message) != "agent_message_chunk":
            continue
        if replay is not None and message_is_replay(message) != replay:
            continue
        chunks.append(content_text(session_update(message).get("content")))
    return "".join(chunks)


def extract_spawned_child(messages: list[dict[str, Any]], root_id: str) -> str | None:
    for message in messages:
        if session_id_of(message) != root_id:
            continue
        update = session_update(message)
        kind = update.get("sessionUpdate") or update.get("session_update")
        if kind != "subagent_spawned":
            continue
        child = update.get("child_session_id") or update.get("childSessionId")
        if isinstance(child, str) and child:
            return child
    return None


def error_text(response: dict[str, Any]) -> str:
    error = response.get("error")
    if error is None:
        return ""
    return json.dumps(error, ensure_ascii=True, sort_keys=True)


class LeaderAcpClient:
    """ACP client speaking Grok's public leader framing over a Unix socket."""

    def __init__(
        self,
        *,
        name: str,
        socket_path: Path,
        allowed_root: Path,
        answer_interactions: bool,
    ) -> None:
        self.name = name
        self.allowed_root = allowed_root.resolve()
        self.answer_interactions = answer_interactions
        self.socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.socket.settimeout(1.0)
        self._connect(socket_path)
        self.socket.settimeout(None)
        self.send_lock = threading.Lock()
        self.condition = threading.Condition()
        self.responses: dict[str, dict[str, Any]] = {}
        self.messages: list[dict[str, Any]] = []
        self.reverse_requests: list[dict[str, Any]] = []
        self.unexpected_reverse_requests: list[dict[str, Any]] = []
        self.next_id = 0
        self.running = True
        self.client_id: int | None = None

        self._send_outer(
            {
                "type": "register",
                "client_type": f"coinor-phase0-{name}",
                "mode": "stdio",
                "capabilities": {
                    "yolo_mode": False,
                    "auto_mode": False,
                    "default_model": None,
                    "client_version": "coinor-phase0",
                    "code_nav_enabled": False,
                    "terminal": False,
                    "fs_read": True,
                    "fs_write": True,
                },
            }
        )
        registration = self._read_outer()
        require(
            registration.get("type") == "registered",
            f"{name}: leader registration failed: {registration}",
        )
        self.client_id = registration.get("client_id")
        require(isinstance(self.client_id, int), f"{name}: missing leader client id")
        if registration.get("ready", True) is False:
            while True:
                ready = self._read_outer()
                if ready.get("type") == "leader_ready":
                    break
                if ready.get("type") == "error":
                    raise SpikeFailure(f"{name}: leader readiness failed: {ready}")

        self.reader = threading.Thread(
            target=self._reader_loop,
            name=f"leader-acp-{name}",
            daemon=True,
        )
        self.reader.start()

    def _connect(self, socket_path: Path) -> None:
        deadline = time.monotonic() + 30.0
        last_error: OSError | None = None
        while time.monotonic() < deadline:
            try:
                self.socket.connect(str(socket_path))
                return
            except OSError as error:
                last_error = error
                time.sleep(0.1)
        raise SpikeFailure(f"{self.name}: cannot connect to {socket_path}: {last_error}")

    def _send_outer(self, message: dict[str, Any]) -> None:
        data = json.dumps(message, separators=(",", ":"), ensure_ascii=True).encode()
        require(len(data) <= MAX_FRAME_SIZE, f"{self.name}: leader frame too large")
        frame = struct.pack(">I", len(data)) + data
        with self.send_lock:
            self.socket.sendall(frame)

    def _read_exact(self, size: int) -> bytes:
        chunks: list[bytes] = []
        remaining = size
        while remaining:
            chunk = self.socket.recv(remaining)
            if not chunk:
                raise EOFError(f"{self.name}: leader socket closed")
            chunks.append(chunk)
            remaining -= len(chunk)
        return b"".join(chunks)

    def _read_outer(self) -> dict[str, Any]:
        size = struct.unpack(">I", self._read_exact(4))[0]
        require(size <= MAX_FRAME_SIZE, f"{self.name}: oversized leader frame {size}")
        return json.loads(self._read_exact(size))

    def _send_inner(self, message: dict[str, Any]) -> None:
        self._send_outer(
            {
                "type": "acp",
                "payload": json.dumps(
                    message,
                    separators=(",", ":"),
                    ensure_ascii=True,
                ),
            }
        )

    def _reader_loop(self) -> None:
        try:
            while self.running:
                outer = self._read_outer()
                if outer.get("type") != "acp":
                    continue
                message = json.loads(outer["payload"])
                with self.condition:
                    self.messages.append(message)
                    if "id" in message and "method" not in message:
                        self.responses[str(message["id"])] = message
                        self.condition.notify_all()
                        continue
                    self.condition.notify_all()
                if "id" in message and "method" in message:
                    self._handle_reverse_request(message)
        except (EOFError, OSError):
            if self.running:
                with self.condition:
                    self.condition.notify_all()
        except Exception as error:
            if self.running:
                with self.condition:
                    self.unexpected_reverse_requests.append(
                        {"readerError": repr(error)}
                    )
                    self.condition.notify_all()

    def _handle_reverse_request(self, message: dict[str, Any]) -> None:
        self.reverse_requests.append(message)
        method = message.get("method")
        params = inner_params(message)

        if method == "fs/read_text_file":
            try:
                requested = Path(params["path"]).resolve(strict=True)
                requested.relative_to(self.allowed_root)
                content = requested.read_text(encoding="utf-8")
            except Exception as error:
                self._send_inner(
                    {
                        "jsonrpc": "2.0",
                        "id": message["id"],
                        "error": {"code": -32000, "message": str(error)},
                    }
                )
            else:
                self._send_inner(
                    {
                        "jsonrpc": "2.0",
                        "id": message["id"],
                        "result": {"content": content},
                    }
                )
            return

        if method == "session/request_permission":
            if not self.answer_interactions:
                return
            options = params.get("options")
            if not isinstance(options, list):
                options = []
            selected = next(
                (
                    option.get("optionId")
                    for option in options
                    if option.get("kind") == "allow_once"
                ),
                None,
            )
            outcome: dict[str, Any]
            if isinstance(selected, str):
                outcome = {"outcome": "selected", "optionId": selected}
            else:
                outcome = {"outcome": "cancelled"}
            self._send_inner(
                {
                    "jsonrpc": "2.0",
                    "id": message["id"],
                    "result": {"outcome": outcome},
                }
            )
            return

        self.unexpected_reverse_requests.append(message)
        self._send_inner(
            {
                "jsonrpc": "2.0",
                "id": message["id"],
                "error": {
                    "code": -32601,
                    "message": f"Coinor spike does not serve {method}",
                },
            }
        )

    def request(
        self,
        method: str,
        params: dict[str, Any],
        *,
        timeout: float = DEFAULT_TIMEOUT,
    ) -> dict[str, Any]:
        with self.condition:
            self.next_id += 1
            request_id = f"{self.name}-{self.next_id}"
            self._send_inner(
                {
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "method": method,
                    "params": params,
                }
            )
            deadline = time.monotonic() + timeout
            while request_id not in self.responses:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise SpikeFailure(f"{self.name}: timeout waiting for {method}")
                self.condition.wait(remaining)
            return self.responses.pop(request_id)

    def snapshot_messages(self) -> list[dict[str, Any]]:
        with self.condition:
            return list(self.messages)

    def close(self) -> None:
        if not self.running:
            return
        self.running = False
        try:
            self._send_outer({"type": "disconnect"})
        except OSError:
            pass
        try:
            self.socket.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        self.socket.close()
        self.reader.join(timeout=2.0)


ANSI_CSI = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
ANSI_OSC = re.compile(r"\x1b\].*?(?:\x07|\x1b\\)", re.DOTALL)


class AnsiScreen:
    """Small VT screen model covering the cursor operations ratatui emits."""

    def __init__(self, rows: int, columns: int) -> None:
        self.rows = rows
        self.columns = columns
        self.grid = [[" "] * columns for _ in range(rows)]
        self.row = 0
        self.column = 0
        self.saved_cursor = (0, 0)
        self.state = "normal"
        self.csi = ""

    def feed(self, text: str) -> None:
        for character in text:
            if self.state == "normal":
                self._normal(character)
            elif self.state == "escape":
                if character == "[":
                    self.state = "csi"
                    self.csi = ""
                elif character == "]":
                    self.state = "osc"
                else:
                    self.state = "normal"
            elif self.state == "csi":
                self.csi += character
                if "@" <= character <= "~":
                    self._apply_csi(self.csi)
                    self.state = "normal"
                    self.csi = ""
            elif self.state == "osc":
                if character == "\x07":
                    self.state = "normal"
                elif character == "\x1b":
                    self.state = "osc_escape"
            elif self.state == "osc_escape":
                self.state = "normal" if character == "\\" else "osc"

    def _normal(self, character: str) -> None:
        if character == "\x1b":
            self.state = "escape"
            return
        if character == "\r":
            self.column = 0
            return
        if character == "\n":
            self.row += 1
            if self.row >= self.rows:
                self.grid.pop(0)
                self.grid.append([" "] * self.columns)
                self.row = self.rows - 1
            return
        if character == "\b":
            self.column = max(0, self.column - 1)
            return
        if character == "\t":
            self.column = min(self.columns - 1, ((self.column // 8) + 1) * 8)
            return
        if ord(character) < 32 or character == "\x7f":
            return
        if self.column >= self.columns:
            self.column = 0
            self.row += 1
        if self.row >= self.rows:
            self.grid.pop(0)
            self.grid.append([" "] * self.columns)
            self.row = self.rows - 1
        self.grid[self.row][self.column] = character
        width = 2 if unicodedata.east_asian_width(character) in {"W", "F"} else 1
        if unicodedata.combining(character):
            width = 0
        self.column += width

    @staticmethod
    def _parameters(raw: str) -> list[int]:
        body = raw[:-1].lstrip("?><!")
        if not body:
            return []
        values = []
        for item in body.split(";"):
            try:
                values.append(int(item) if item else 0)
            except ValueError:
                values.append(0)
        return values

    def _apply_csi(self, raw: str) -> None:
        command = raw[-1]
        values = self._parameters(raw)
        first = values[0] if values and values[0] else 1
        second = values[1] if len(values) > 1 and values[1] else 1

        if command in {"H", "f"}:
            self.row = min(self.rows - 1, max(0, first - 1))
            self.column = min(self.columns - 1, max(0, second - 1))
        elif command == "A":
            self.row = max(0, self.row - first)
        elif command == "B":
            self.row = min(self.rows - 1, self.row + first)
        elif command == "C":
            self.column = min(self.columns - 1, self.column + first)
        elif command == "D":
            self.column = max(0, self.column - first)
        elif command == "E":
            self.row = min(self.rows - 1, self.row + first)
            self.column = 0
        elif command == "F":
            self.row = max(0, self.row - first)
            self.column = 0
        elif command == "G":
            self.column = min(self.columns - 1, max(0, first - 1))
        elif command == "d":
            self.row = min(self.rows - 1, max(0, first - 1))
        elif command == "J":
            self._erase_display(values[0] if values else 0)
        elif command == "K":
            self._erase_line(values[0] if values else 0)
        elif command == "X":
            for index in range(self.column, min(self.columns, self.column + first)):
                self.grid[self.row][index] = " "
        elif command == "P":
            line = self.grid[self.row]
            del line[self.column : min(self.columns, self.column + first)]
            line.extend([" "] * (self.columns - len(line)))
        elif command == "@":
            line = self.grid[self.row]
            line[self.column : self.column] = [" "] * first
            del line[self.columns :]
        elif command == "S":
            for _ in range(min(first, self.rows)):
                self.grid.pop(0)
                self.grid.append([" "] * self.columns)
        elif command == "T":
            for _ in range(min(first, self.rows)):
                self.grid.pop()
                self.grid.insert(0, [" "] * self.columns)
        elif command == "s":
            self.saved_cursor = (self.row, self.column)
        elif command == "u":
            self.row, self.column = self.saved_cursor

    def _erase_display(self, mode: int) -> None:
        if mode == 2 or mode == 3:
            self.grid = [[" "] * self.columns for _ in range(self.rows)]
            return
        if mode == 1:
            for row in range(0, self.row):
                self.grid[row] = [" "] * self.columns
            for column in range(0, self.column + 1):
                self.grid[self.row][column] = " "
            return
        for column in range(self.column, self.columns):
            self.grid[self.row][column] = " "
        for row in range(self.row + 1, self.rows):
            self.grid[row] = [" "] * self.columns

    def _erase_line(self, mode: int) -> None:
        if mode == 2:
            self.grid[self.row] = [" "] * self.columns
        elif mode == 1:
            for column in range(0, self.column + 1):
                self.grid[self.row][column] = " "
        else:
            for column in range(self.column, self.columns):
                self.grid[self.row][column] = " "

    def text(self) -> str:
        return "\n".join("".join(row).rstrip() for row in self.grid)


class TuiProcess:
    def __init__(
        self,
        *,
        command: list[str],
        cwd: Path,
        env: dict[str, str],
    ) -> None:
        master_fd, slave_fd = pty.openpty()
        fcntl.ioctl(
            slave_fd,
            termios.TIOCSWINSZ,
            struct.pack("HHHH", 55, 160, 0, 0),
        )
        self.master_fd = master_fd
        self.output = bytearray()
        self.output_lock = threading.Lock()
        self.screen = AnsiScreen(55, 160)
        self.decoder = codecs.getincrementaldecoder("utf-8")(errors="replace")
        self.running = True
        self.command = command
        self.process = subprocess.Popen(
            command,
            cwd=cwd,
            env=env,
            stdin=slave_fd,
            stdout=slave_fd,
            stderr=slave_fd,
            start_new_session=True,
            close_fds=True,
        )
        os.close(slave_fd)
        os.set_blocking(master_fd, False)
        self.reader = threading.Thread(
            target=self._reader_loop,
            name=f"tui-{self.process.pid}",
            daemon=True,
        )
        self.reader.start()

    def _reader_loop(self) -> None:
        while self.running:
            ready, _, _ = select.select([self.master_fd], [], [], 0.2)
            if not ready:
                if self.process.poll() is not None:
                    break
                continue
            try:
                chunk = os.read(self.master_fd, READ_SIZE)
            except BlockingIOError:
                continue
            except OSError:
                break
            if not chunk:
                break
            with self.output_lock:
                self.output.extend(chunk)
                self.screen.feed(self.decoder.decode(chunk))

    def text(self) -> str:
        with self.output_lock:
            decoded = bytes(self.output).decode("utf-8", errors="replace")
        decoded = ANSI_OSC.sub("", decoded)
        decoded = ANSI_CSI.sub("", decoded)
        return decoded.replace("\r", "")

    def wait_for_text(self, text: str, *, timeout: float) -> bool:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if text in self.screen_text():
                return True
            if self.process.poll() is not None:
                return text in self.screen_text()
            time.sleep(0.1)
        return text in self.screen_text()

    def screen_text(self) -> str:
        with self.output_lock:
            return self.screen.text()

    def close(self) -> None:
        if not self.running:
            return
        self.running = False
        if self.process.poll() is None:
            try:
                self.process.terminate()
            except (OSError, ProcessLookupError):
                pass
            try:
                self.process.wait(timeout=5.0)
            except subprocess.TimeoutExpired:
                try:
                    self.process.kill()
                except (OSError, ProcessLookupError):
                    pass
                try:
                    self.process.wait(timeout=5.0)
                except subprocess.TimeoutExpired:
                    pass
        try:
            os.close(self.master_fd)
        except OSError:
            pass
        self.reader.join(timeout=2.0)


def initialize_client(client: LeaderAcpClient) -> str:
    response = client.request(
        "initialize",
        {
            "protocolVersion": 1,
            "clientCapabilities": {
                "fs": {"readTextFile": True, "writeTextFile": True},
                "terminal": False,
            },
            "_meta": {
                "startupHints": {
                    "nonInteractive": True,
                    "skipGitStatus": True,
                    "skipProjectLayout": True,
                },
                "clientType": "coinor-phase0",
                "clientVersion": "0",
            },
        },
    )
    require("error" not in response, f"{client.name}: initialize failed: {response}")
    methods = [
        method.get("id")
        for method in response.get("result", {}).get("authMethods", [])
        if isinstance(method, dict) and isinstance(method.get("id"), str)
    ]
    require(methods, f"{client.name}: initialize returned no auth methods")
    auth_method = next(
        (candidate for candidate in ("cached_token", "grok.com", "xai.api_key") if candidate in methods),
        methods[0],
    )
    auth = client.request(
        "authenticate",
        {"methodId": auth_method, "_meta": {"headless": True}},
    )
    require("error" not in auth, f"{client.name}: authenticate failed: {auth}")
    return auth_method


def load_session_with_retry(
    client: LeaderAcpClient,
    *,
    session_id: str,
    cwd: Path,
    timeout: float,
) -> int:
    deadline = time.monotonic() + timeout
    attempts = 0
    while time.monotonic() < deadline:
        attempts += 1
        response = client.request(
            "session/load",
            {"sessionId": session_id, "cwd": str(cwd), "mcpServers": []},
            timeout=min(DEFAULT_TIMEOUT, max(10.0, deadline - time.monotonic())),
        )
        if "error" not in response:
            return attempts
        text = error_text(response).lower()
        if "session does not exist" not in text and "no such file" not in text:
            raise SpikeFailure(
                f"{client.name}: session/load failed unexpectedly: {response}"
            )
        time.sleep(0.35)
    raise SpikeFailure(
        f"{client.name}: session/load never found {session_id} within {timeout:.1f}s"
    )


def start_resume_tui_with_retry(
    *,
    grok: Path,
    leader_socket: Path,
    session_id: str,
    unrelated_cwd: Path,
    env: dict[str, str],
    expected_replay: str | None,
    timeout: float,
) -> tuple[TuiProcess, int]:
    deadline = time.monotonic() + timeout
    attempts = 0
    last_output = ""
    while time.monotonic() < deadline:
        attempts += 1
        command = [
            str(grok),
            "--leader-socket",
            str(leader_socket),
            "--leader",
            "--cwd",
            str(unrelated_cwd),
            "--resume",
            session_id,
            "--no-alt-screen",
        ]
        tui = TuiProcess(command=command, cwd=unrelated_cwd, env=env)
        settle_deadline = min(deadline, time.monotonic() + 12.0)
        while time.monotonic() < settle_deadline:
            output = tui.text()
            screen = tui.screen_text()
            last_output = output
            if "Session does not exist" in output:
                break
            if expected_replay is not None and expected_replay in screen:
                return tui, attempts
            if (
                expected_replay is None
                and tui.process.poll() is None
                and time.monotonic() + 9.0 >= settle_deadline
            ):
                return tui, attempts
            if tui.process.poll() is not None:
                break
            time.sleep(0.1)

        if (
            expected_replay is not None
            and tui.process.poll() is None
            and tui.wait_for_text(
                expected_replay,
                timeout=max(0.0, deadline - time.monotonic()),
            )
        ):
            return tui, attempts
        tui.close()
        time.sleep(0.35)

    raise SpikeFailure(
        f"TUI exact resume failed for {session_id} after {attempts} attempts.\n"
        f"Last output:\n{last_output[-4000:]}"
    )


def find_summary(grok_home: Path, session_id: str) -> Path:
    matches = list((grok_home / "sessions").glob(f"*/{session_id}/summary.json"))
    require(
        len(matches) == 1,
        f"Expected one summary for {session_id}, found {len(matches)}: {matches}",
    )
    return matches[0]


def process_exists(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def close_bridge(process: subprocess.Popen[bytes]) -> None:
    if process.stdin is not None:
        try:
            process.stdin.close()
        except OSError:
            pass
    try:
        process.wait(timeout=8.0)
    except subprocess.TimeoutExpired:
        process.terminate()
        try:
            process.wait(timeout=4.0)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=4.0)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--grok",
        default=str(Path.home() / "bin" / "grok"),
        help="Absolute custom Grok executable path",
    )
    parser.add_argument(
        "--auth-file",
        default=str(Path.home() / ".grok" / "auth.json"),
        help="Credential file copied into the isolated temporary GROK_HOME",
    )
    parser.add_argument(
        "--keep-temp",
        action="store_true",
        help="Keep the isolated temporary directory for diagnosis",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    grok = Path(os.path.abspath(os.path.expanduser(args.grok)))
    auth_file = Path(args.auth_file).expanduser().resolve()
    real_config = Path.home() / ".grok" / "config.toml"
    config_hash_before = sha256_file(real_config)
    temp_root = Path(tempfile.mkdtemp(prefix="coinor-grok-", dir="/tmp"))
    bridges: list[subprocess.Popen[bytes]] = []
    bridge_logs: list[Any] = []
    clients: list[LeaderAcpClient] = []
    tuis: list[TuiProcess] = []
    leader_pid: int | None = None
    report: dict[str, Any] = {
        "status": "failed",
        "temporaryRoot": str(temp_root),
        "grok": str(grok),
    }

    try:
        require(grok.is_absolute() and grok.exists(), f"Grok binary not found: {grok}")
        require(os.access(grok, os.X_OK), f"Grok binary is not executable: {grok}")
        require(auth_file.exists(), f"Auth file not found: {auth_file}")

        home = temp_root / "home"
        grok_home = temp_root / "grok-home"
        repo = temp_root / "root-repo"
        unrelated_repo = temp_root / "unrelated-repo"
        home.mkdir()
        grok_home.mkdir()
        repo.mkdir()
        unrelated_repo.mkdir()
        shutil.copy2(auth_file, grok_home / "auth.json")
        os.chmod(grok_home / "auth.json", 0o600)

        child_env = os.environ.copy()
        child_env.update(
            {
                "HOME": str(home),
                "GROK_HOME": str(grok_home),
                "GROK_SANDBOX": "off",
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "TERM": "xterm-256color",
                "COLORTERM": "truecolor",
            }
        )
        for key in list(child_env):
            if key.startswith("HERDR_") or key in {
                "GROK_AUTH_PATH",
                "GROK_LEADER_SOCKET",
                "GRK_REBUILD",
            }:
                child_env.pop(key, None)

        require(
            shutil.which("herdr", path=child_env["PATH"]) is None,
            "Herdr unexpectedly resolves in the isolated child PATH",
        )
        require(
            not (grok_home / "config.toml").exists(),
            "The isolated GROK_HOME must not contain global leader configuration",
        )
        require(
            not (grok_home / "hooks").exists(),
            "The isolated GROK_HOME must not contain hooks",
        )

        version = run_checked([str(grok), "--version"], cwd=repo, env=child_env)
        version_text = version.stdout.strip()
        require(version_text.startswith("grok "), f"Unexpected Grok version: {version_text!r}")

        for target in (repo, unrelated_repo):
            run_checked(["/usr/bin/git", "init", "-q", str(target)], cwd=temp_root, env=child_env)
            run_checked(
                ["/usr/bin/git", "-C", str(target), "config", "user.name", "Coinor Phase 0"],
                cwd=temp_root,
                env=child_env,
            )
            run_checked(
                [
                    "/usr/bin/git",
                    "-C",
                    str(target),
                    "config",
                    "user.email",
                    "coinor-phase0@example.invalid",
                ],
                cwd=temp_root,
                env=child_env,
            )

        leader_socket = grok_home / "leader-coinor-phase0.sock"
        leader_lock = leader_socket.with_suffix(".lock")
        bridge_command = [
            str(grok),
            "--leader-socket",
            str(leader_socket),
            "agent",
            "--leader",
            "stdio",
        ]

        start_gate = threading.Barrier(3)
        bridge_slots: list[subprocess.Popen[bytes] | None] = [None, None]

        def start_bridge(index: int) -> None:
            log = (temp_root / f"bridge-{index}.log").open("wb", buffering=0)
            bridge_logs.append(log)
            start_gate.wait()
            bridge_slots[index] = subprocess.Popen(
                bridge_command,
                cwd=repo,
                env=child_env,
                stdin=subprocess.PIPE,
                stdout=log,
                stderr=log,
            )

        bridge_threads = [
            threading.Thread(target=start_bridge, args=(index,), daemon=True)
            for index in range(2)
        ]
        for thread in bridge_threads:
            thread.start()
        start_gate.wait()
        for thread in bridge_threads:
            thread.join()
        bridges = [process for process in bridge_slots if process is not None]
        require(len(bridges) == 2, "Failed to start both concurrent Grok bridge clients")

        try:
            wait_until(
                lambda: leader_socket.exists() and leader_lock.exists(),
                timeout=45.0,
                description="private leader socket and lock",
            )
        except SpikeFailure as error:
            diagnostics = []
            for index in range(2):
                path = temp_root / f"bridge-{index}.log"
                if path.exists():
                    diagnostics.append(
                        f"bridge-{index}.log:\n"
                        f"{path.read_text(encoding='utf-8', errors='replace')[-4000:]}"
                    )
            raise SpikeFailure(f"{error}\n" + "\n".join(diagnostics)) from error
        leader_pid = int(leader_lock.read_text(encoding="utf-8").strip())
        require(process_exists(leader_pid), f"Leader PID {leader_pid} is not alive")
        require(
            all(process.poll() is None for process in bridges),
            "A concurrent bridge exited instead of converging on the private leader",
        )
        time.sleep(1.0)
        require(
            int(leader_lock.read_text(encoding="utf-8").strip()) == leader_pid,
            "Leader lock PID changed after concurrent client convergence",
        )

        driver = LeaderAcpClient(
            name="driver",
            socket_path=leader_socket,
            allowed_root=temp_root,
            answer_interactions=True,
        )
        observer = LeaderAcpClient(
            name="observer",
            socket_path=leader_socket,
            allowed_root=temp_root,
            answer_interactions=False,
        )
        clients.extend([driver, observer])
        driver_auth = initialize_client(driver)
        observer_auth = initialize_client(observer)

        root_id = str(uuid.uuid4())
        new_response = driver.request(
            "session/new",
            {
                "cwd": str(repo),
                "mcpServers": [],
                "_meta": {"sessionId": root_id},
            },
        )
        require("error" not in new_response, f"session/new failed: {new_response}")
        require(
            new_response.get("result", {}).get("sessionId") == root_id,
            "Grok did not preserve the client-generated root UUID",
        )

        replay_suffix = uuid.uuid4().hex
        replay_marker = f"COINOR_REPLAY_{replay_suffix}"
        first_prompt = driver.request(
            "session/prompt",
            {
                "sessionId": root_id,
                "prompt": [
                    {
                        "type": "text",
                        "text": (
                            "Reply with exactly the concatenation of "
                            f"`COINOR_REPLAY_` and `{replay_suffix}`, with no "
                            "backticks, spaces, or other text. Do not use tools."
                        ),
                    }
                ],
            },
        )
        require("error" not in first_prompt, f"Initial prompt failed: {first_prompt}")
        require(
            replay_marker
            in agent_text(
                driver.snapshot_messages(),
                session_id=root_id,
                replay=False,
            ),
            "Driver did not receive the initial live marker",
        )

        root_load_attempts = load_session_with_retry(
            observer,
            session_id=root_id,
            cwd=repo,
            timeout=30.0,
        )
        wait_until(
            lambda: replay_marker
            in agent_text(
                observer.snapshot_messages(),
                session_id=root_id,
                replay=True,
            ),
            timeout=30.0,
            description="observer replay notification",
        )

        root_tui, root_tui_attempts = start_resume_tui_with_retry(
            grok=grok,
            leader_socket=leader_socket,
            session_id=root_id,
            unrelated_cwd=unrelated_repo,
            env=child_env,
            expected_replay=replay_marker,
            timeout=75.0,
        )
        tuis.append(root_tui)
        require(
            unrelated_repo.resolve() != repo.resolve()
            and replay_marker in root_tui.screen_text(),
            "Root TUI did not prove exact session resolution from an unrelated cwd",
        )

        live_suffix = uuid.uuid4().hex
        live_marker = f"COINOR_LIVE_STREAM_{live_suffix}"
        live_prompt = driver.request(
            "session/prompt",
            {
                "sessionId": root_id,
                "prompt": [
                    {
                        "type": "text",
                        "text": (
                            "Reply with exactly the concatenation of "
                            f"`COINOR_LIVE_STREAM_` and `{live_suffix}`, with no "
                            "backticks, spaces, or other text. Do not use tools."
                        ),
                    }
                ],
            },
        )
        require("error" not in live_prompt, f"Live prompt failed: {live_prompt}")
        wait_until(
            lambda: live_marker
            in agent_text(
                observer.snapshot_messages(),
                session_id=root_id,
                replay=False,
            ),
            timeout=30.0,
            description="observer live root update",
        )
        if not root_tui.wait_for_text(live_marker, timeout=45.0):
            raise SpikeFailure(
                "Root TUI did not render the live assistant update. "
                f"poll={root_tui.process.poll()} command={root_tui.command!r}\n"
                f"Captured screen:\n{root_tui.screen_text()}\n"
                f"Captured PTY text tail:\n{root_tui.text()[-8000:]}"
            )

        driver_marker = f"COINOR_DRIVER_REQUEST_{uuid.uuid4().hex}"
        root_marker_file = repo / "root-driver-marker.txt"
        root_marker_file.write_text(driver_marker, encoding="utf-8")
        observer_fs_before = len(
            [
                item
                for item in observer.reverse_requests
                if item.get("method") == "fs/read_text_file"
            ]
        )
        driver_prompt = driver.request(
            "session/prompt",
            {
                "sessionId": root_id,
                "prompt": [
                    {
                        "type": "text",
                        "text": (
                            "You must use read_file, not bash or terminal, to read "
                            f"{root_marker_file}. Reply with exactly its contents. "
                            "Do not modify anything."
                        ),
                    }
                ],
            },
        )
        require("error" not in driver_prompt, f"Driver request prompt failed: {driver_prompt}")

        driver_root_reads = [
            item
            for item in driver.reverse_requests
            if item.get("method") == "fs/read_text_file"
            and session_id_of(item) == root_id
            and inner_params(item).get("path") == str(root_marker_file.resolve())
        ]
        observer_root_reads = [
            item
            for item in observer.reverse_requests
            if item.get("method") == "fs/read_text_file"
            and session_id_of(item) == root_id
        ]
        require(
            len(driver_root_reads) == 1,
            f"Expected one driver-only root fs request, got {len(driver_root_reads)}",
        )
        require(
            len(observer_root_reads) == observer_fs_before,
            "Observer received a driver-only root reverse request",
        )

        child_marker = f"COINOR_CHILD_LIVE_{uuid.uuid4().hex}"
        root_child_marker = f"COINOR_ROOT_AFTER_CHILD_{uuid.uuid4().hex}"
        child_marker_file = repo / "child-marker.txt"
        root_child_marker_file = repo / "root-after-child-marker.txt"
        child_marker_file.write_text(child_marker, encoding="utf-8")
        root_child_marker_file.write_text(root_child_marker, encoding="utf-8")
        subagent_result: dict[str, Any] = {}

        def run_subagent_prompt() -> None:
            try:
                subagent_result["response"] = driver.request(
                    "session/prompt",
                    {
                        "sessionId": root_id,
                        "prompt": [
                            {
                                "type": "text",
                                "text": (
                                    "This is a read-only protocol test. Use the task "
                                    "tool exactly once to launch a general-purpose "
                                    "subagent. Give it this exact task: First run "
                                    "`/bin/sleep 15` using bash. Then use read_file, "
                                    f"not bash, to read {child_marker_file}. Return "
                                    "exactly the file contents and do not modify "
                                    "anything. Wait for that subagent to finish. "
                                    "Then use read_file, not bash, to read "
                                    f"{root_child_marker_file} and reply with "
                                    "exactly that file's contents. Do not perform "
                                    "the delegated work yourself."
                                ),
                            }
                        ],
                    },
                    timeout=300.0,
                )
            except Exception as error:
                subagent_result["error"] = error

        prompt_thread = threading.Thread(
            target=run_subagent_prompt,
            name="subagent-prompt",
            daemon=True,
        )
        prompt_thread.start()
        wait_until(
            lambda: extract_spawned_child(driver.snapshot_messages(), root_id) is not None,
            timeout=120.0,
            description="native subagent_spawned notification",
        )
        child_id = extract_spawned_child(driver.snapshot_messages(), root_id)
        require(child_id is not None, "Subagent notification omitted child session ID")

        child_observer = LeaderAcpClient(
            name="child-observer",
            socket_path=leader_socket,
            allowed_root=temp_root,
            answer_interactions=False,
        )
        clients.append(child_observer)
        child_auth = initialize_client(child_observer)
        child_load_attempts = load_session_with_retry(
            child_observer,
            session_id=child_id,
            cwd=repo,
            timeout=45.0,
        )

        child_tui, child_tui_attempts = start_resume_tui_with_retry(
            grok=grok,
            leader_socket=leader_socket,
            session_id=child_id,
            unrelated_cwd=unrelated_repo,
            env=child_env,
            expected_replay="First run",
            timeout=75.0,
        )
        tuis.append(child_tui)
        require(
            unrelated_repo.resolve() != repo.resolve()
            and "First run" in child_tui.screen_text(),
            "Live hidden child TUI did not load the explicit child UUID from an unrelated cwd",
        )
        require(
            prompt_thread.is_alive(),
            "The native subagent finished before live child TUI verification completed",
        )

        prompt_thread.join(timeout=300.0)
        require(not prompt_thread.is_alive(), "Subagent prompt did not finish")
        if "error" in subagent_result:
            raise SpikeFailure(f"Subagent prompt raised: {subagent_result['error']!r}")
        subagent_prompt_response = subagent_result.get("response", {})
        require(
            "error" not in subagent_prompt_response,
            f"Subagent prompt failed: {subagent_prompt_response}",
        )

        wait_until(
            lambda: child_marker
            in agent_text(
                child_observer.snapshot_messages(),
                session_id=child_id,
                replay=False,
            ),
            timeout=60.0,
            description="live child observer update",
        )
        if not child_tui.wait_for_text(child_marker, timeout=60.0):
            raise SpikeFailure(
                "Live hidden child TUI did not render the child assistant update. "
                f"poll={child_tui.process.poll()} command={child_tui.command!r}\n"
                f"Captured screen:\n{child_tui.screen_text()}\n"
                f"Captured PTY text tail:\n{child_tui.text()[-8000:]}"
            )
        wait_until(
            lambda: root_child_marker
            in agent_text(
                observer.snapshot_messages(),
                session_id=root_id,
                replay=False,
            ),
            timeout=60.0,
            description="root observer update after child completion",
        )

        driver_child_reads = [
            item
            for item in driver.reverse_requests
            if item.get("method") == "fs/read_text_file"
            and session_id_of(item) == child_id
            and inner_params(item).get("path") == str(child_marker_file.resolve())
        ]
        observer_child_reads = [
            item
            for client in (observer, child_observer)
            for item in client.reverse_requests
            if item.get("method") == "fs/read_text_file"
            and session_id_of(item) == child_id
        ]
        require(
            len(driver_child_reads) == 1,
            f"Expected one inherited driver-only child fs request, got {len(driver_child_reads)}",
        )
        require(
            not observer_child_reads,
            "An observer received a driver-only child reverse request",
        )
        driver_post_child_reads = [
            item
            for item in driver.reverse_requests
            if item.get("method") == "fs/read_text_file"
            and session_id_of(item) == root_id
            and inner_params(item).get("path")
            == str(root_child_marker_file.resolve())
        ]
        require(
            len(driver_post_child_reads) == 1,
            "The original root driver did not receive the post-child reverse request",
        )

        child_summary_path = find_summary(grok_home, child_id)
        child_summary = json.loads(child_summary_path.read_text(encoding="utf-8"))
        child_kind = child_summary.get("session_kind") or child_summary.get("sessionKind")
        require(
            isinstance(child_kind, str) and child_kind.startswith("subagent"),
            f"Child session is not marked hidden/subagent: {child_kind!r}",
        )

        root_summary_path = find_summary(grok_home, root_id)
        require(root_summary_path.exists(), "Root summary was not persisted")
        require(
            int(leader_lock.read_text(encoding="utf-8").strip()) == leader_pid,
            "Leader PID changed while root and child clients were attached",
        )
        require(
            not driver.unexpected_reverse_requests,
            f"Driver received unexpected reverse requests: {driver.unexpected_reverse_requests}",
        )
        require(
            not observer.unexpected_reverse_requests,
            f"Observer received unexpected reverse requests: {observer.unexpected_reverse_requests}",
        )
        require(
            not child_observer.unexpected_reverse_requests,
            "Child observer received unexpected reverse requests: "
            f"{child_observer.unexpected_reverse_requests}",
        )

        config_hash_after = sha256_file(real_config)
        require(
            config_hash_after == config_hash_before,
            "The real ~/.grok/config.toml changed during the isolated spike",
        )

        report.update(
            {
                "status": "passed",
                "grokVersion": version_text,
                "leaderPid": leader_pid,
                "leaderSocket": str(leader_socket),
                "bridgePids": [process.pid for process in bridges],
                "driverClientId": driver.client_id,
                "observerClientId": observer.client_id,
                "childObserverClientId": child_observer.client_id,
                "rootSessionId": root_id,
                "childSessionId": child_id,
                "childSessionKind": child_kind,
                "authMethods": {
                    "driver": driver_auth,
                    "observer": observer_auth,
                    "childObserver": child_auth,
                },
                "attempts": {
                    "rootAcpLoad": root_load_attempts,
                    "rootTuiResume": root_tui_attempts,
                    "childAcpLoad": child_load_attempts,
                    "childTuiResume": child_tui_attempts,
                },
                "childTuiAttachedWhilePromptActive": True,
                "markers": {
                    "replay": replay_marker,
                    "live": live_marker,
                    "child": child_marker,
                    "rootAfterChild": root_child_marker,
                },
                "driverOnlyRequests": {
                    "root": len(driver_root_reads) + len(driver_post_child_reads),
                    "child": len(driver_child_reads),
                    "observer": len(observer_child_reads),
                },
                "isolation": {
                    "temporaryGrokHome": str(grok_home),
                    "globalConfigSha256Before": config_hash_before,
                    "globalConfigSha256After": config_hash_after,
                    "globalUseLeaderRequired": False,
                    "herdrAvailableOnChildPath": False,
                    "globalHooksLoaded": False,
                },
            }
        )
        print("PASS private leader convergence")
        print("PASS client-generated root UUID")
        print("PASS ACP replay and live fan-out")
        print("PASS exact root TUI resume from unrelated cwd")
        print("PASS root driver preservation")
        print("PASS native hidden subagent discovery")
        print("PASS live hidden child TUI resume from unrelated cwd")
        print("PASS inherited child driver preservation")
        print("PASS no Herdr or global use_leader dependency")
        print("RESULT " + json.dumps(report, sort_keys=True))
        return 0
    except Exception as error:
        report["error"] = str(error)
        print("FAIL " + json.dumps(report, sort_keys=True), file=sys.stderr)
        return 1
    finally:
        for tui in reversed(tuis):
            tui.close()
        for client in reversed(clients):
            client.close()
        for process in bridges:
            close_bridge(process)
        for handle in bridge_logs:
            try:
                handle.close()
            except OSError:
                pass
        if leader_pid is not None:
            deadline = time.monotonic() + 12.0
            while process_exists(leader_pid) and time.monotonic() < deadline:
                time.sleep(0.2)
            if process_exists(leader_pid):
                try:
                    os.kill(leader_pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
        if args.keep_temp:
            print(f"Kept temporary artifacts at {temp_root}", file=sys.stderr)
        else:
            shutil.rmtree(temp_root, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
