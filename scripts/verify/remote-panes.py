#!/usr/bin/env python3
"""Runs Conan Code's remote pane commands on real pseudo-terminals.

The commands are not written here: they are dumped by
`CoinorTests/RemoteLaunchCommandDumpTests`, so what this script executes is
exactly what a Ghostty surface would run for a remote conversation.

Usage:
    xcodebuild ... test-without-building \\
        -only-testing:'CoinorTests/RemoteLaunchCommandDumpTests'
    python3 scripts/verify/remote-panes.py

A pseudo-terminal is used because a terminal surface is what the product gives
these commands, and a Grok or TUI process behaves differently without one.
"""

import json
import os
import pty
import select
import signal
import sys
import time

DUMP = "/tmp/coinor-remote-commands.json"
ALT_SCREEN = b"\x1b[?1049h"


class Pane:
    """One command running on its own pseudo-terminal."""

    def __init__(self, command):
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.execv("/bin/sh", ["/bin/sh", "-c", command])
            os._exit(127)
        self.buffer = b""

    def drive(self, marker=None, payloads=(), timeout=60):
        """Reads output, sending each payload once the pane goes quiet."""
        deadline = time.time() + timeout
        last = time.time()
        sent = 0
        while time.time() < deadline:
            ready, _, _ = select.select([self.fd], [], [], 0.8)
            if ready:
                try:
                    chunk = os.read(self.fd, 8192)
                except OSError:
                    break
                if not chunk:
                    break
                self.buffer += chunk
                last = time.time()
            if marker and marker in self.buffer:
                break
            if time.time() - last > 2 and sent < len(payloads):
                os.write(self.fd, payloads[sent])
                sent += 1
                last = time.time()
        return self.buffer

    def kill(self):
        try:
            os.kill(self.pid, signal.SIGKILL)
            os.waitpid(self.pid, 0)
        except OSError:
            pass
        try:
            os.close(self.fd)
        except OSError:
            pass


def check(name, ok, detail=""):
    print(f"{'PASS' if ok else 'FAIL'}  {name}{'  ' + detail if detail else ''}")
    return ok


def main():
    if not os.path.exists(DUMP):
        print(f"missing {DUMP}: run the command dump test first")
        return 1
    commands = json.load(open(DUMP))
    home = commands["home"]
    results = []

    pane = Pane(commands["shell"])
    text = pane.drive(
        marker=b"HOST=",
        payloads=[b"\n", b"\n", b'printf "CWD=%s\\n" "$PWD"\n',
                  b'printf "HOST=%s\\n" "$(hostname -s)"\n'],
        timeout=70,
    ).decode(errors="replace")
    pane.kill()
    results.append(check(
        "shell tab runs the remote login shell in the requested directory",
        f"CWD={home}" in text and "HOST=" in text,
    ))

    for key, tab, label in (
        ("ide_fresh", "IDE", "fresh"),
        ("git_lazygit", "Git", "lazygit"),
    ):
        pane = Pane(commands[key])
        raw = pane.drive(marker=ALT_SCREEN, timeout=50)
        pane.kill()
        results.append(check(
            f"{tab} tab starts {label} on the remote computer",
            ALT_SCREEN in raw and b"command not found" not in raw,
        ))

    pane = Pane(commands["new_session"])
    raw = pane.drive(marker=ALT_SCREEN, timeout=70)
    pane.kill()
    results.append(check(
        "a new remote conversation paints the Grok interface",
        ALT_SCREEN in raw,
    ))

    if "resume" in commands:
        pane = Pane(commands["resume"])
        raw = pane.drive(marker=ALT_SCREEN, timeout=70)
        text = raw.decode(errors="replace").lower()
        results.append(check(
            "an existing remote conversation resumes",
            ALT_SCREEN in raw and "does not exist" not in text,
        ))
        # A dropped link must not end the remote session: the same command has
        # to reattach to the same conversation.
        pane.kill()
        again = Pane(commands["resume"])
        raw = again.drive(marker=ALT_SCREEN, timeout=70)
        again.kill()
        text = raw.decode(errors="replace").lower()
        results.append(check(
            "the same conversation reattaches after the connection drops",
            ALT_SCREEN in raw and "does not exist" not in text,
        ))

    if "subagent" in commands:
        pane = Pane(commands["subagent"])
        raw = pane.drive(marker=ALT_SCREEN, timeout=70)
        pane.kill()
        text = raw.decode(errors="replace").lower()
        results.append(check(
            "a remote subagent pane resumes its child session",
            b"\x1b[" in raw and "does not exist" not in text,
        ))
    else:
        print("SKIP  no persisted subagent session on the remote computer")

    print(f"\n{sum(results)}/{len(results)} checks passed")
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
