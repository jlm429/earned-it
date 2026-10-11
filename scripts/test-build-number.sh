#!/bin/bash
set -Eeuo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
generator="$script_directory/build-number.sh"

first="$(GITHUB_RUN_NUMBER=1 GITHUB_RUN_ATTEMPT=1 "$generator")"
later="$(GITHUB_RUN_NUMBER=125 GITHUB_RUN_ATTEMPT=1 "$generator")"

[[ "$first" =~ ^[1-9][0-9]{0,3}$ ]]
[[ "$later" == "$first" ]]
[[ "$("$generator" 1)" == "$first" ]]

if GITHUB_RUN_ATTEMPT=2 "$generator" >/dev/null 2>&1; then
  echo "A rerun unexpectedly produced a colliding build number." >&2
  exit 1
fi

for attempt in 0 invalid 999999999999999999999999999; do
  if "$generator" "$attempt" >/dev/null 2>&1; then
    echo "An invalid upload attempt was unexpectedly accepted." >&2
    exit 1
  fi
done

echo "Build-number semantics passed."
