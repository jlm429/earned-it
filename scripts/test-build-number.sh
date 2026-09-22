#!/bin/bash
set -Eeuo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
generator="$script_directory/build-number.sh"

first="$($generator 1 1)"
second="$($generator 2 1)"
later="$($generator 125 1)"

[[ "$first" == "15" ]]
[[ "$first" =~ ^[1-9][0-9]{0,3}$ ]]
(( first > 14 ))
(( second > first ))
(( later > second ))

if "$generator" 1 2 >/dev/null 2>&1; then
  echo "A rerun unexpectedly produced a colliding build number." >&2
  exit 1
fi

if "$generator" 9986 1 >/dev/null 2>&1; then
  echo "An Apple-invalid build number was unexpectedly accepted." >&2
  exit 1
fi

if "$generator" 999999999999999999999999999 1 >/dev/null 2>&1; then
  echo "An overflowing build number was unexpectedly accepted." >&2
  exit 1
fi

echo "Build-number semantics passed."
