#!/bin/bash
set -Eeuo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_path="$script_directory/../EarnedIt.xcodeproj"

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
  echo "Release application must declare iPhone device family 1 first." >&2
  exit 1
fi

second_family="$(/usr/libexec/PlistBuddy -c 'Print :UIDeviceFamily:1' "$info_plist")"
if [[ "$second_family" != "2" ]]; then
  echo "Release application must declare iPad device family 2 second." >&2
  exit 1
fi

if /usr/libexec/PlistBuddy -c 'Print :UIDeviceFamily:2' "$info_plist" >/dev/null 2>&1; then
  echo "Release application unexpectedly declares a third device family." >&2
  exit 1
fi

marketing_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist")"
build_number="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info_plist")"
release_settings="$(
  xcodebuild \
    -project "$project_path" \
    -target EarnedIt \
    -configuration Release \
    -showBuildSettings 2>/dev/null
)"
expected_marketing_version="$(awk '$1 == "MARKETING_VERSION" { print $3; exit }' <<< "$release_settings")"
expected_build_number="$(awk '$1 == "CURRENT_PROJECT_VERSION" { print $3; exit }' <<< "$release_settings")"
if [[ -z "$expected_marketing_version" ]]; then
  echo "Could not resolve the Release MARKETING_VERSION from $project_path." >&2
  exit 1
fi
if [[ "$marketing_version" != "$expected_marketing_version" ]]; then
  echo "Release application marketing version must be $expected_marketing_version." >&2
  exit 1
fi
if [[ -z "$expected_build_number" || "$build_number" != "$expected_build_number" ]]; then
  echo "Release application build number must match the project ($expected_build_number)." >&2
  exit 1
fi

required_ipad_orientations=(
  UIInterfaceOrientationPortrait
  UIInterfaceOrientationPortraitUpsideDown
  UIInterfaceOrientationLandscapeLeft
  UIInterfaceOrientationLandscapeRight
)

for orientation in "${required_ipad_orientations[@]}"; do
  if ! /usr/libexec/PlistBuddy -c 'Print :UISupportedInterfaceOrientations~ipad' "$info_plist" | grep -Fxq "    $orientation"; then
    echo "Release application is missing required iPad orientation $orientation." >&2
    exit 1
  fi
done

echo "Release metadata passed: Earned It $marketing_version build $build_number supports iPhone and iPad multitasking orientations."
