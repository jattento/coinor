#!/bin/zsh -f

setopt NO_BEEP

if [[ -n "${COINOR_SPIKE_EVENT_LOG:-}" ]]; then
  printf 'command_started pid=%s cwd=%s term=%s terminfo=%s\n' \
    "$$" "$PWD" "${TERM:-}" "${TERMINFO:-}" >> "$COINOR_SPIKE_EVENT_LOG"
fi

printf '\033[1;32mCoinor GhosttyKit spike\033[0m\n'
printf 'Renderer: embedded Ghostty v1.3.1\n'
printf 'Command: /bin/zsh (absolute)\n'
printf 'Working directory: %s\n' "$PWD"
printf 'TERM=%s\n' "${TERM:-unset}"
printf 'TERMINFO=%s\n' "${TERMINFO:-unset}"
for line in {1..48}; do
  printf 'scrollback sample %02d\n' "$line"
done
printf '\nType here. This is a real interactive PTY.\n\n'

exec /bin/zsh -f
