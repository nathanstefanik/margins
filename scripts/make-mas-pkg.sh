#!/bin/sh
# Build the Mac App Store package: universal app, sandboxed entitlements,
# Apple Distribution signing, embedded App Store profile, installer pkg.
#
# Usage:
#   MAC_APP_IDENTITY="Apple Distribution: NAME (TEAMID)" \
#   MAC_INSTALLER_IDENTITY="3rd Party Mac Developer Installer: NAME (TEAMID)" \
#   MARGINS_PROFILE=/path/to/Margins.provisionprofile \
#   scripts/make-mas-pkg.sh
#
# Optional:
#   MARGINS_KEYCHAIN           keychain holding the two identities; it is
#                              prepended to the user keychain search list
#                              for the run (codesign does not honor
#                              --keychain for identity lookup) and the
#                              original list is restored on exit
#   MARGINS_KEYCHAIN_PASSWORD  unlock the keychain first (omit if unlocked)
#   MARGINS_BUILD_NUMBER       CFBundleVersion (default 1)
#   MARGINS_MAS_OUTPUT         pkg path (default build/Margins-vX.Y.Z-mas.pkg)
#
# The app bundle is assembled by make-app.sh, then re-signed here with the
# sandbox/iCloud entitlements and the distribution profile; `productbuild`
# signs the installer.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

: "${MAC_APP_IDENTITY:?set MAC_APP_IDENTITY to the Apple Distribution identity}"
: "${MAC_INSTALLER_IDENTITY:?set MAC_INSTALLER_IDENTITY to the installer identity}"

profile=${MARGINS_PROFILE:-}
if [ -n "$profile" ] && [ ! -f "$profile" ]; then
  echo "provisioning profile not found at $profile" >&2
  exit 1
fi

entitlements="$root/apple/macos/Margins.entitlements"
[ -f "$entitlements" ] || { echo "missing $entitlements" >&2; exit 1; }

original_keychains=""
if [ -n "${MARGINS_KEYCHAIN:-}" ]; then
  original_keychains=$(
    security list-keychains -d user | sed -e 's/^[[:space:]]*//' -e 's/^"//' -e 's/"$//' | tr '\n' ' '
  )
  if [ -n "${MARGINS_KEYCHAIN_PASSWORD:-}" ]; then
    security unlock-keychain -p "$MARGINS_KEYCHAIN_PASSWORD" "$MARGINS_KEYCHAIN"
  fi
  # shellcheck disable=SC2086
  security list-keychains -d user -s "$MARGINS_KEYCHAIN" $original_keychains
  # shellcheck disable=SC2086
  trap 'security list-keychains -d user -s $original_keychains' EXIT INT TERM
fi

UNIVERSAL=1 MARGINS_BUILD_NUMBER="${MARGINS_BUILD_NUMBER:-1}" ./scripts/make-app.sh

app="$root/build/Margins.app"
version=$(tr -d '[:space:]' < "$root/apple/VERSION")
out=${MARGINS_MAS_OUTPUT:-"$root/build/Margins-v${version}-mas.pkg"}

app_entitlements="$entitlements"
if [ -n "$profile" ]; then
  cp "$profile" "$app/Contents/embedded.provisionprofile"
  # Xcode-signed apps carry the team/application identifiers and the
  # CloudKit environment in their signature; derive them from the profile
  # so the committed entitlements template stays team-neutral.
  profile_plist=$(mktemp)
  security cms -D -i "$profile" > "$profile_plist"
  team_id=$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.team-identifier' "$profile_plist")
  rm -f "$profile_plist"
  [ -n "$team_id" ] || { echo "no team identifier in $profile" >&2; exit 1; }
  bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")
  app_entitlements=$(mktemp)
  cp "$entitlements" "$app_entitlements"
  add_or_set() {
    /usr/libexec/PlistBuddy -c "Add :$1 string $2" "$app_entitlements" 2>/dev/null \
      || /usr/libexec/PlistBuddy -c "Set :$1 $2" "$app_entitlements"
  }
  add_or_set com.apple.developer.team-identifier "$team_id"
  add_or_set com.apple.application-identifier "$team_id.$bundle_id"
  add_or_set com.apple.developer.icloud-container-environment Production
else
  echo "warning: no MARGINS_PROFILE set; the pkg will not validate for the Mac App Store" >&2
fi

# Export-compliance answer, same as the iOS Info.plist.
/usr/libexec/PlistBuddy -c "Add :ITSAppUsesNonExemptEncryption bool false" \
  "$app/Contents/Info.plist" 2>/dev/null || true

codesign --force --timestamp --generate-entitlement-der \
  --sign "$MAC_APP_IDENTITY" --entitlements "$app_entitlements" "$app"

codesign --verify --deep --strict --verbose=2 "$app"
echo "signed entitlements:"
codesign -d --entitlements - "$app" 2>/dev/null

rm -f "$out"
productbuild --component "$app" /Applications --sign "$MAC_INSTALLER_IDENTITY" "$out"

echo "assembled $out"
