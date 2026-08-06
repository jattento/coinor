# Shared Grok session spike results

Date: 2026-08-06

Status: **PASS**

Binary under test:

```text
/Users/jattentokeyway/bin/grok
grok 0.2.117 (29189e7)
```

## Commands

Run from `/Users/jattentokeyway/projects/github.com/jattento/coinor`:

```sh
python3 -m py_compile Spikes/GrokSharedSession/run_spike.py
python3 Spikes/GrokSharedSession/run_spike.py
git diff --check -- Spikes/GrokSharedSession
```

The passing run created two concurrent bridge clients with this concrete
command:

```sh
/Users/jattentokeyway/bin/grok \
  --leader-socket /tmp/coinor-grok-mahg98zk/grok-home/leader-coinor-phase0.sock \
  agent --leader stdio
```

The root and hidden-child TUI checks used:

```sh
/Users/jattentokeyway/bin/grok \
  --leader-socket /tmp/coinor-grok-mahg98zk/grok-home/leader-coinor-phase0.sock \
  --leader \
  --cwd /tmp/coinor-grok-mahg98zk/unrelated-repo \
  --resume 5aec106f-0b25-49f5-b2cc-4f266a2d4ada \
  --no-alt-screen

/Users/jattentokeyway/bin/grok \
  --leader-socket /tmp/coinor-grok-mahg98zk/grok-home/leader-coinor-phase0.sock \
  --leader \
  --cwd /tmp/coinor-grok-mahg98zk/unrelated-repo \
  --resume 019fd978-a961-7cd1-b23c-0eb4a271aaad \
  --no-alt-screen
```

## Direct evidence

| Invariant | Observed result |
| --- | --- |
| Private leader convergence | Concurrent bridge PIDs `83370` and `83369` stayed alive and converged on one private socket and leader PID `83398`. |
| Client-generated root UUID | `session/new` preserved root UUID `5aec106f-0b25-49f5-b2cc-4f266a2d4ada`. |
| Replay and live fan-out | The observer received the replay marker with `_meta.isReplay=true`, then the later live marker with `_meta.isReplay=false`. The attached root TUI rendered both. |
| Exact real-TUI resume | The real Grok TUI loaded the root UUID from an unrelated repository in one attempt and rendered the persisted marker. |
| Original driver preservation | Driver client `3` received both root `fs/read_text_file` reverse requests. Observer client `4` received none. |
| Explicit hidden-child load | Native `subagent_spawned` produced child UUID `019fd978-a961-7cd1-b23c-0eb4a271aaad`; its persisted `session_kind` was `subagent`. ACP loaded it explicitly while live in one attempt. |
| Live hidden-child real-TUI resume | A real Grok TUI explicitly resumed that child UUID from the unrelated repository while the native subagent prompt thread was still active, then rendered the child marker in one attempt. |
| Child driver inheritance | The child filesystem reverse request went to original root driver client `3`; root observer `4` and child observer `6` received zero such requests. |
| No global leader or Herdr | The isolated `GROK_HOME` had no config or hooks, `herdr` was absent from the child `PATH`, and the real config hash was identical before and after. |
| Cleanup | `/tmp/coinor-grok-mahg98zk` was removed and leader PID `83398` no longer existed after the harness returned. |

Real config SHA-256 before and after:

```text
a33ab461777d94cd9a5d40f2fc1c0323adbd11b2bd5f89a29e228fbe51c77300
```

## Exact result

```text
PASS private leader convergence
PASS client-generated root UUID
PASS ACP replay and live fan-out
PASS exact root TUI resume from unrelated cwd
PASS root driver preservation
PASS native hidden subagent discovery
PASS live hidden child TUI resume from unrelated cwd
PASS inherited child driver preservation
PASS no Herdr or global use_leader dependency
RESULT {"attempts": {"childAcpLoad": 1, "childTuiResume": 1, "rootAcpLoad": 1, "rootTuiResume": 1}, "authMethods": {"childObserver": "cached_token", "driver": "cached_token", "observer": "cached_token"}, "bridgePids": [83370, 83369], "childObserverClientId": 6, "childSessionId": "019fd978-a961-7cd1-b23c-0eb4a271aaad", "childSessionKind": "subagent", "childTuiAttachedWhilePromptActive": true, "driverClientId": 3, "driverOnlyRequests": {"child": 1, "observer": 0, "root": 2}, "grok": "/Users/jattentokeyway/bin/grok", "grokVersion": "grok 0.2.117 (29189e7)", "isolation": {"globalConfigSha256After": "a33ab461777d94cd9a5d40f2fc1c0323adbd11b2bd5f89a29e228fbe51c77300", "globalConfigSha256Before": "a33ab461777d94cd9a5d40f2fc1c0323adbd11b2bd5f89a29e228fbe51c77300", "globalHooksLoaded": false, "globalUseLeaderRequired": false, "herdrAvailableOnChildPath": false, "temporaryGrokHome": "/tmp/coinor-grok-mahg98zk/grok-home"}, "leaderPid": 83398, "leaderSocket": "/tmp/coinor-grok-mahg98zk/grok-home/leader-coinor-phase0.sock", "markers": {"child": "COINOR_CHILD_LIVE_37bae4c095e74c1d9465a1acd9cda52b", "live": "COINOR_LIVE_STREAM_ca217a03e05e4608a1e57204cc7e3a34", "replay": "COINOR_REPLAY_f0042a130f2f45bbb8306d83d4448590", "rootAfterChild": "COINOR_ROOT_AFTER_CHILD_98aec0ffceb64f578b569e325fb8df25"}, "observerClientId": 4, "rootSessionId": "5aec106f-0b25-49f5-b2cc-4f266a2d4ada", "status": "passed", "temporaryRoot": "/tmp/coinor-grok-mahg98zk"}
```

## Limitations

- Direct ACP assertions use Grok's public framed leader protocol. The two
  convergence clients and both resume checks are real custom-Grok processes.
  This is necessary because `grok agent --leader stdio` advertises filesystem
  capabilities as disabled, while driver preservation needs a deterministic
  driver-only reverse request.
- Live child fan-out is proven through both an ACP observer and a real TUI
  attached before the native subagent prompt completed. The child sleeps for
  15 seconds before emitting its marker, giving the TUI a deterministic live
  attachment window.
- The ANSI screen model implements only the cursor, erase, insert, delete,
  scroll, and save/restore operations emitted by the current Grok/Ratatui
  screen. It is deliberately not a general terminal emulator.
- The prompts are constrained read-only tests. They only return random markers,
  read files created under the temporary repository, and run `/bin/sleep 15`.
  No existing session is resumed or modified.
- Authentication is copied into the temporary `GROK_HOME`; credential contents
  are never printed. All temporary artifacts are removed unless `--keep-temp`
  is explicitly supplied.
