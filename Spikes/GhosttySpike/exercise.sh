#!/bin/bash

set -euo pipefail

SPIKE_ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$SPIKE_ROOT/.build/app/CoinorGhosttySpike.app"
EVENT_LOG="$SPIKE_ROOT/.build/runtime-events.log"
OPEN_LOG="$SPIKE_ROOT/.build/open.log"
COMPACT_SCREENSHOT="$SPIKE_ROOT/.build/ghostty-spike-compact.png"
WIDE_SCREENSHOT="$SPIKE_ROOT/.build/ghostty-spike-wide.png"
COMPACT_IMAGE_REPORT="$SPIKE_ROOT/.build/image-report-compact.txt"
WIDE_IMAGE_REPORT="$SPIKE_ROOT/.build/image-report-wide.txt"
KEYBOARD_MARKER="$SPIKE_ROOT/.build/keyboard-marker.txt"
CLIPBOARD_MARKER="$SPIKE_ROOT/.build/clipboard-marker.txt"

wait_for_event() {
  local pattern="$1"
  for _ in {1..160}; do
    if [[ -f "$EVENT_LOG" ]] && grep -q "$pattern" "$EVENT_LOG"; then
      return 0
    fi
    if ! kill -0 "$open_pid" 2>/dev/null; then
      break
    fi
    sleep 0.1
  done
  printf 'timed out waiting for runtime event: %s\n' "$pattern" >&2
  return 1
}

"$SPIKE_ROOT/build.sh"

rm -f \
  "$EVENT_LOG" \
  "$OPEN_LOG" \
  "$COMPACT_SCREENSHOT" \
  "$WIDE_SCREENSHOT" \
  "$COMPACT_IMAGE_REPORT" \
  "$WIDE_IMAGE_REPORT" \
  "$KEYBOARD_MARKER" \
  "$CLIPBOARD_MARKER"

open -n -W "$APP" --args \
  --automation \
  --event-log "$EVENT_LOG" \
  --cwd "$SPIKE_ROOT" \
  --exit-after 11 \
  >"$OPEN_LOG" 2>&1 &
open_pid=$!

window_id=""
for _ in {1..80}; do
  if [[ -f "$EVENT_LOG" ]]; then
    window_id="$(awk -F= '/window_id=/ {print $2; exit}' "$EVENT_LOG" | tr -d '[:space:]')"
  fi
  [[ -n "$window_id" ]] && break
  sleep 0.1
done

[[ -n "$window_id" ]] || {
  printf 'failed to discover the spike window id\n' >&2
  exit 1
}

wait_for_event 'window_content_size_compact=620x380'
sleep 0.2
screencapture -x -l "$window_id" "$COMPACT_SCREENSHOT" \
  2>"$SPIKE_ROOT/.build/screencapture-compact.err"
"$SPIKE_ROOT/.build/app/image-probe" "$COMPACT_SCREENSHOT" |
  tee "$COMPACT_IMAGE_REPORT"

wait_for_event 'window_content_size_wide=1080x700'
sleep 0.2
screencapture -x -l "$window_id" "$WIDE_SCREENSHOT" \
  2>"$SPIKE_ROOT/.build/screencapture-wide.err"
"$SPIKE_ROOT/.build/app/image-probe" "$WIDE_SCREENSHOT" |
  tee "$WIDE_IMAGE_REPORT"

wait "$open_pid"

grep -q 'surface_created' "$EVENT_LOG"
grep -q 'automation_keyboard_events=' "$EVENT_LOG"
grep -q 'automation_binding_action=scroll_page_up handled=true' "$EVENT_LOG"
grep -q 'automation_binding_action=scroll_page_down handled=true' "$EVENT_LOG"
grep -q 'automation_binding_action=select_all handled=true' "$EVENT_LOG"
grep -q 'automation_binding_action=copy_to_clipboard handled=true' "$EVENT_LOG"
grep -q 'clipboard_write bytes=' "$EVENT_LOG"
grep -q 'clipboard_copy_contains_marker=true' "$EVENT_LOG"
grep -q 'automation_binding_action=paste_from_clipboard handled=true' "$EVENT_LOG"
grep -q 'clipboard_read bytes=' "$EVENT_LOG"
grep -q 'automation_resize=compact' "$EVENT_LOG"
grep -q 'automation_resize=wide' "$EVENT_LOG"
grep -q 'window_content_size_compact=620x380' "$EVENT_LOG"
grep -q 'window_content_size_wide=1080x700' "$EVENT_LOG"
grep -q 'surface_size_pixels=620x380' "$EVENT_LOG"
grep -q 'surface_size_pixels=1080x700' "$EVENT_LOG"
grep -q 'surface_recreate generation=1' "$EVENT_LOG"
grep -q 'visible_text=.*scrollback sample' "$EVENT_LOG"
grep -q 'visible_text_after_recreate=.*scrollback sample' "$EVENT_LOG"
grep -q 'visible_window_count_after_suppressed_actions=1' "$EVENT_LOG"
grep -q 'automation_url_action handled=true' "$EVENT_LOG"
grep -q 'url_open_intercepted=coinor-spike://phase0' "$EVENT_LOG"
grep -q 'automation_close_action handled=true' "$EVENT_LOG"
grep -q 'automation_host_close_received' "$EVENT_LOG"
grep -q 'surface_occlusion_visible=false' "$EVENT_LOG"
grep -q 'automation_backing_transition' "$EVENT_LOG"
grep -q 'workspace_wake' "$EVENT_LOG"
grep -q 'surface_destroyed' "$EVENT_LOG"
grep -q 'runtime_destroyed' "$EVENT_LOG"
grep -q 'app_terminated' "$EVENT_LOG"
grep -q '^ok$' "$KEYBOARD_MARKER"
grep -q '^clipboard$' "$CLIPBOARD_MARKER"

surface_count="$(grep -c 'surface_created' "$EVENT_LOG")"
destroy_count="$(grep -c 'surface_destroyed' "$EVENT_LOG")"
[[ "$surface_count" == "4" ]]
[[ "$destroy_count" == "4" ]]

while read -r pid; do
  if kill -0 "$pid" 2>/dev/null; then
    printf 'terminal child still alive after shutdown: %s\n' "$pid" >&2
    exit 1
  fi
done < <(awk -F'[ =]' '/command_started/ {for (i=1; i<=NF; i++) if ($i == "pid") print $(i+1)}' "$EVENT_LOG")

compact_width="$(awk -F= '$1 == "width" {print $2}' "$COMPACT_IMAGE_REPORT")"
compact_height="$(awk -F= '$1 == "height" {print $2}' "$COMPACT_IMAGE_REPORT")"
wide_width="$(awk -F= '$1 == "width" {print $2}' "$WIDE_IMAGE_REPORT")"
wide_height="$(awk -F= '$1 == "height" {print $2}' "$WIDE_IMAGE_REPORT")"
(( compact_width < wide_width ))
(( compact_height < wide_height ))

printf 'runtime_exercise=passed\n'
printf 'surface_create_count=%s\n' "$surface_count"
printf 'surface_destroy_count=%s\n' "$destroy_count"
printf 'screenshot_probe=passed\n'
printf 'compact_screenshot=%sx%s\n' "$compact_width" "$compact_height"
printf 'wide_screenshot=%sx%s\n' "$wide_width" "$wide_height"
