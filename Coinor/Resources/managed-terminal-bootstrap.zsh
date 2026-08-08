function __conan_code_run() {
  emulate -L zsh
  setopt localoptions noerrexit

  local __conan_code_command_id="$1"
  local __conan_code_command
  local __conan_code_exit_code

  __conan_code_command="$("$CONAN_CODE_CONTROL_CLIENT" fetch-command \
    --tab "$CONAN_CODE_TAB_ID" \
    --capability "$CONAN_CODE_TAB_CAPABILITY" \
    --command-id "$__conan_code_command_id")" || return $?

  {
    eval "$__conan_code_command"
    __conan_code_exit_code=$?
  } always {
    __conan_code_exit_code=${__conan_code_exit_code:-$?}
    "$CONAN_CODE_CONTROL_CLIENT" command-finished \
      --tab "$CONAN_CODE_TAB_ID" \
      --capability "$CONAN_CODE_TAB_CAPABILITY" \
      --command-id "$__conan_code_command_id" \
      --exit-code "$__conan_code_exit_code" >/dev/null 2>&1 || true
  }
  return "$__conan_code_exit_code"
}

"$CONAN_CODE_CONTROL_CLIENT" shell-ready \
  --tab "$CONAN_CODE_TAB_ID" \
  --capability "$CONAN_CODE_TAB_CAPABILITY" >/dev/null
