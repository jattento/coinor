#!/bin/sh
set -u

if [ -z "${CONAN_CODE_CONTROL_CLIENT:-}" ] ||
   [ ! -x "$CONAN_CODE_CONTROL_CLIENT" ]; then
  echo "conan-code-long-running: not running inside Conan Code" >&2
  exit 1
fi

exec "$CONAN_CODE_CONTROL_CLIENT" "$@"
