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

  /usr/bin/python3 - "$profile_plist" "$key" "$required_value" "$allow_wildcard" <<'PY'
import plistlib
import sys

profile_path, key, required_value, allow_wildcard = sys.argv[1:]

try:
    with open(profile_path, "rb") as profile_file:
        value = plistlib.load(profile_file)["Entitlements"][key]
except (KeyError, OSError, plistlib.InvalidFileException):
    sys.exit(1)

if isinstance(value, str):
    values = [value]
elif isinstance(value, list) and all(isinstance(item, str) for item in value):
    values = value
else:
    sys.exit(1)

authorized_values = {required_value}
if allow_wildcard == "true":
    authorized_values.add("*")

sys.exit(0 if authorized_values.intersection(values) else 1)
PY
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
