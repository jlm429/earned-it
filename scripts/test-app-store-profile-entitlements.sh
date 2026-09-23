#!/bin/bash
set -Eeuo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
validator="$script_directory/validate-app-store-profile-entitlements.sh"
temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/earned-it-profile-test.XXXXXX")"
trap 'rm -rf "$temporary_directory"' EXIT

create_profile() {
  local path="$1"

  /usr/libexec/PlistBuddy -c 'Clear dict' "$path" >/dev/null
  /usr/libexec/PlistBuddy -c 'Add :Entitlements dict' "$path"
  /usr/libexec/PlistBuddy \
    -c 'Add :Entitlements:com.apple.developer.icloud-container-environment array' \
    "$path"
  /usr/libexec/PlistBuddy \
    -c 'Add :Entitlements:com.apple.developer.icloud-container-environment:0 string Production' \
    "$path"
  /usr/libexec/PlistBuddy \
    -c 'Add :Entitlements:com.apple.developer.icloud-container-environment:1 string Development' \
    "$path"
  /usr/libexec/PlistBuddy \
    -c 'Add :Entitlements:com.apple.developer.icloud-container-identifiers array' \
    "$path"
  /usr/libexec/PlistBuddy \
    -c 'Add :Entitlements:com.apple.developer.icloud-container-identifiers:0 string iCloud.com.jlm429.EarnedIt' \
    "$path"
  /usr/libexec/PlistBuddy \
    -c 'Add :Entitlements:com.apple.developer.icloud-services string *' \
    "$path"
  /usr/libexec/PlistBuddy \
    -c 'Add :Entitlements:com.apple.developer.icloud-extended-share-access array' \
    "$path"
  /usr/libexec/PlistBuddy \
    -c 'Add :Entitlements:com.apple.developer.icloud-extended-share-access:0 string InProcessShareAccessRequests' \
    "$path"
  /usr/libexec/PlistBuddy \
    -c 'Add :Entitlements:com.apple.developer.icloud-extended-share-access:1 string InProcessShareOwnerParticipantInfo' \
    "$path"
  /usr/libexec/PlistBuddy \
    -c 'Add :Entitlements:com.apple.developer.icloud-extended-share-access:2 string InProcessOneTimeLinks' \
    "$path"
}

expect_rejection() {
  local profile="$1"
  local description="$2"

  if "$validator" "$profile" >/dev/null 2>&1; then
    echo "Validator accepted a profile without $description." >&2
    exit 1
  fi
}

issued_profile="$temporary_directory/issued.plist"
create_profile "$issued_profile"
"$validator" "$issued_profile" >/dev/null

explicit_service_profile="$temporary_directory/explicit-service.plist"
create_profile "$explicit_service_profile"
/usr/libexec/PlistBuddy \
  -c 'Delete :Entitlements:com.apple.developer.icloud-services' \
  "$explicit_service_profile"
/usr/libexec/PlistBuddy \
  -c 'Add :Entitlements:com.apple.developer.icloud-services array' \
  "$explicit_service_profile"
/usr/libexec/PlistBuddy \
  -c 'Add :Entitlements:com.apple.developer.icloud-services:0 string CloudKit' \
  "$explicit_service_profile"
"$validator" "$explicit_service_profile" >/dev/null

development_only_profile="$temporary_directory/development-only.plist"
create_profile "$development_only_profile"
/usr/libexec/PlistBuddy \
  -c 'Delete :Entitlements:com.apple.developer.icloud-container-environment:0' \
  "$development_only_profile"
expect_rejection "$development_only_profile" "Production iCloud authorization"

wrong_container_profile="$temporary_directory/wrong-container.plist"
create_profile "$wrong_container_profile"
/usr/libexec/PlistBuddy \
  -c 'Set :Entitlements:com.apple.developer.icloud-container-identifiers:0 iCloud.com.example.Other' \
  "$wrong_container_profile"
expect_rejection "$wrong_container_profile" "the Earned It iCloud container"

documents_only_profile="$temporary_directory/documents-only.plist"
create_profile "$documents_only_profile"
/usr/libexec/PlistBuddy \
  -c 'Set :Entitlements:com.apple.developer.icloud-services CloudDocuments' \
  "$documents_only_profile"
expect_rejection "$documents_only_profile" "CloudKit authorization"

no_one_time_links_profile="$temporary_directory/no-one-time-links.plist"
create_profile "$no_one_time_links_profile"
/usr/libexec/PlistBuddy \
  -c 'Delete :Entitlements:com.apple.developer.icloud-extended-share-access:2' \
  "$no_one_time_links_profile"
expect_rejection "$no_one_time_links_profile" "CloudKit one-time-link authorization"

echo "App Store profile entitlement semantics passed."
