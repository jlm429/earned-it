#!/bin/bash
set -Eeuo pipefail

target="${1:-}"
if [[ -z "$target" ]]; then
  echo "Usage: $0 <release-app-or-xcarchive>" >&2
  exit 1
fi

if [[ "$target" == *.xcarchive ]]; then
  archive_info="$target/Info.plist"
  if [[ ! -f "$archive_info" ]]; then
    echo "Archive Info.plist not found: $archive_info" >&2
    exit 1
  fi
  application_path="$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:ApplicationPath' "$archive_info")"
  target="$target/Products/$application_path"
fi

info_plist="$target/Info.plist"
if [[ ! -f "$info_plist" ]]; then
  echo "Application Info.plist not found: $info_plist" >&2
  exit 1
fi

first_family="$(/usr/libexec/PlistBuddy -c 'Print :UIDeviceFamily:0' "$info_plist")"
if [[ "$first_family" != "1" ]]; then
  echo "Release application must declare iPhone device family 1 only." >&2
  exit 1
fi

if /usr/libexec/PlistBuddy -c 'Print :UIDeviceFamily:1' "$info_plist" >/dev/null 2>&1; then
  echo "Release application unexpectedly declares another device family." >&2
  exit 1
fi

marketing_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist")"
if [[ "$marketing_version" != "1.0.1" ]]; then
  echo "Release application marketing version must be 1.0.1." >&2
  exit 1
fi

echo "Release metadata passed: Earned It $marketing_version supports iPhone only."
