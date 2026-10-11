#!/bin/bash
set -Eeuo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
run_attempt="${1:-${GITHUB_RUN_ATTEMPT:-1}}"

if (( $# > 1 )) || [[ ! "$run_attempt" =~ ^[1-9][0-9]*$ ]]; then
  echo "GITHUB_RUN_ATTEMPT must be a positive integer." >&2
  exit 1
fi

if [[ "$run_attempt" != "1" ]]; then
  echo "Reruns are not uploaded because they would reuse a build number. Update the project build number before another upload." >&2
  exit 1
fi

build_number="$(
  xcodebuild -project "$script_directory/../EarnedIt.xcodeproj" \
    -target EarnedIt -configuration Release -showBuildSettings 2>/dev/null \
    | awk '$1 == "CURRENT_PROJECT_VERSION" { print $3 }'
)"
if [[ ! "$build_number" =~ ^[1-9][0-9]{0,3}$ ]]; then
  echo "The project build number must be a positive integer of at most four digits." >&2
  exit 1
fi

printf '%s\n' "$build_number"
