#!/bin/bash
set -Eeuo pipefail

run_number="${1:-${GITHUB_RUN_NUMBER:-}}"
run_attempt="${2:-${GITHUB_RUN_ATTEMPT:-}}"

if [[ ! "$run_number" =~ ^[1-9][0-9]*$ ]] || [[ ! "$run_attempt" =~ ^[1-9][0-9]*$ ]]; then
  echo "GITHUB_RUN_NUMBER and GITHUB_RUN_ATTEMPT must be positive integers." >&2
  exit 1
fi

if (( run_attempt != 1 )); then
  echo "Reruns are not uploaded because they would reuse a build number. Start a new Archive and Upload run." >&2
  exit 1
fi

if (( ${#run_number} > 4 )) || (( run_number > 9985 )); then
  echo "The generated build number exceeds Apple's four-digit major build component." >&2
  exit 1
fi

build_number=$((14 + run_number))
printf '%s\n' "$build_number"
