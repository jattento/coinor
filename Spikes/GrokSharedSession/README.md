# Grok shared-session spike

This harness validates Coinor's private-leader design against the real custom
Grok binary using only Python's standard library and macOS system tools.

It creates an isolated temporary `HOME`, `GROK_HOME`, Git repository, leader
socket, root session, and hidden child session. The real user configuration,
hooks, and session store are not loaded.

Run:

```sh
python3 Spikes/GrokSharedSession/run_spike.py
```

Override the binary or credential source when needed:

```sh
python3 Spikes/GrokSharedSession/run_spike.py \
  --grok /absolute/path/to/grok \
  --auth-file /absolute/path/to/auth.json
```

`--keep-temp` retains the isolated directory after the run for diagnosis.
Without it, every process and temporary artifact owned by the harness is
cleaned up.

The harness uses two concurrent real `grok agent --leader stdio` processes to
exercise private leader convergence. It then speaks Grok's framed leader
protocol directly for deterministic ACP assertions, including a driver-only
filesystem reverse request. Real Grok TUIs attach with `--resume` to prove
exact root and hidden-child loading from an unrelated working directory.

The PTY capture includes a deliberately small ANSI screen model covering only
the operations emitted by the current Grok/Ratatui TUI. It exists to make
marker assertions reproducible; it is not intended to become a terminal
emulator. See `RESULTS.md` for the passing command, direct evidence, and other
limitations.
