#!/bin/bash
set -Eeuo pipefail

profile_plist="${1:-}"
if [[ -z "$profile_plist" || ! -f "$profile_plist" ]]; then
  echo "Usage: $0 <decoded-provisioning-profile-plist>" >&2
  exit 1
fi

entitlement_allows() {
  local key="$1"
  local required_value="$2"
  local allow_wildcard="${3:-false}"
  local output
  local value

  if ! output="$(
    /usr/libexec/PlistBuddy \
      -c "Print :Entitlements:${key}" \
      "$profile_plist" 2>/dev/null
  )"; then
    return 1
  fi

  while IFS= read -r value; do
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    if [[ "$value" == "$required_value" ]] ||
       [[ "$allow_wildcard" == "true" && "$value" == "*" ]]; then
      return 0
    fi
  done <<< "$output"

  return 1
}

if ! entitlement_allows \
  "com.apple.developer.icloud-container-environment" \
  "Production"; then
  echo "The App Store profile does not authorize the Production iCloud environment." >&2
  exit 1
fi

if ! entitlement_allows \
  "com.apple.developer.icloud-container-identifiers" \
  "iCloud.com.jlm429.EarnedIt"; then
  echo "The App Store profile does not authorize the Earned It iCloud container." >&2
  exit 1
fi

if ! entitlement_allows \
  "com.apple.developer.icloud-services" \
  "CloudKit" \
  true; then
  echo "The App Store profile does not authorize the CloudKit service." >&2
  exit 1
fi

if ! entitlement_allows \
  "com.apple.developer.icloud-extended-share-access" \
  "InProcessOneTimeLinks"; then
  echo "The App Store profile does not authorize CloudKit one-time links." >&2
  exit 1
fi

echo "Validated production CloudKit and one-time-link profile authorization."
