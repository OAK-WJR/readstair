#!/bin/bash
# Maintainers only: the package check before an upload. Any FAIL means: do not upload.
#   check-package.sh ARCHIVE OUT CLEAN   export ARCHIVE the way an App Store upload signs it (into the new folder OUT), then check
#                                        the app against CLEAN, the export (worktree or release repository) it was archived from
#   check-package.sh --app APP CLEAN     only the checks that need no signing export (for a simulator build; no entitlements)
# The export needs the network and the signing account. It never changes the version or the build number.
set -uo pipefail
export LC_ALL=C
users=/Users   # home folders; kept in a variable so the privacy check does not take the pattern for a path
status=0
pass() { echo "PASS: $*"; }
failed() { echo "FAIL: $*"; status=1; }
usage() { echo "usage: check-package.sh ARCHIVE OUT CLEAN | --app APP CLEAN" >&2; exit 2; }

if [ "${1:-}" = --app ]; then
  [ $# = 3 ] || usage
  app=$2 clean=$3 archive= ent=
else
  [ $# = 3 ] || usage
  archive=$1 out=$2 clean=$3
  [ -d "$archive" ] || { echo "no archive at $archive" >&2; exit 2; }
  [ ! -e "$out" ] || { echo "$out already exists" >&2; exit 2; }
  mkdir -p "$out"
  cat > "$out/export.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>export</string>
  <key>signingStyle</key><string>automatic</string>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict></plist>
EOF
  xcodebuild -exportArchive -archivePath "$archive" -exportPath "$out/export" -exportOptionsPlist "$out/export.plist" \
    -allowProvisioningUpdates > "$out/export.log" 2>&1 || { echo "FAIL: the export did not finish (see export.log)"; exit 1; }
  (cd "$out/export" && unzip -q ReadStair.ipa) || { echo "FAIL: no ReadStair.ipa"; exit 1; }
  app=$out/export/Payload/ReadStair.app
  # The entitlements hold the Team ID: they stay in OUT and are never printed whole
  ent=$out/entitlements.plist
  codesign -d --entitlements - --xml "$app" > "$ent" 2>/dev/null || failed "cannot read the entitlements"
fi
[ -d "$app" ] || { echo "no app at $app" >&2; exit 2; }
[ -d "$clean/.git" ] || [ -f "$clean/.git" ] || { echo "$clean is not a git checkout" >&2; exit 2; }
key() { /usr/libexec/PlistBuddy -c "Print :$1" "$2" 2>/dev/null; }
setting() { sed -n "s/^$1 = //p" "$clean/Config/Shared.xcconfig"; }

# Signing: production push, CloudKit and the app's container (only an exported package has these)
if [ -n "$ent" ]; then
  [ "$(key aps-environment "$ent")" = production ] && pass "aps-environment production" || failed "aps-environment is not production"
  key com.apple.developer.icloud-services "$ent" | grep -qx ' *CloudKit' && pass "CloudKit" || failed "no CloudKit in icloud-services"
  key com.apple.developer.icloud-container-identifiers "$ent" | grep -qx ' *iCloud.app.readstair' && pass "container iCloud.app.readstair" || failed "the iCloud container is not iCloud.app.readstair"
  environment=$(key com.apple.developer.icloud-container-environment "$ent")
  case "$environment" in ""|*Production*) pass "icloud-container-environment ${environment:-absent}";; *) failed "icloud-container-environment is $environment";; esac
fi

# Info.plist: background mode, the version and build this tree says
modes=$(plutil -extract UIBackgroundModes json -o - "$app/Info.plist" 2>/dev/null)
if [ -n "$ent" ]; then
  [ "$modes" = '["remote-notification"]' ] && pass "UIBackgroundModes remote-notification" || failed "UIBackgroundModes is ${modes:-absent}"
fi
version=$(plutil -extract CFBundleShortVersionString raw -o - "$app/Info.plist" 2>/dev/null)
build=$(plutil -extract CFBundleVersion raw -o - "$app/Info.plist" 2>/dev/null)
[ "$version" = "$(setting MARKETING_VERSION)" ] && pass "version $version" || failed "version $version is not the tree's $(setting MARKETING_VERSION)"
[ "$build" = "$(setting CURRENT_PROJECT_VERSION)" ] && pass "build $build" || failed "build $build is not the tree's $(setting CURRENT_PROJECT_VERSION)"
[ "$(plutil -extract CFBundleIdentifier raw -o - "$app/Info.plist")" = app.readstair ] && pass "bundle ID app.readstair" || failed "bundle ID is not app.readstair"

# Privacy manifest: exactly one, with exactly the two required-reason entries
manifests=$(find "$app" -name '*.xcprivacy')
count=$(printf '%s' "$manifests" | grep -c . || true)
if [ "$count" = 1 ]; then
  reasons=$(plutil -p "$manifests" | grep -oE 'NSPrivacyAccessedAPICategory[A-Za-z]+|"[A-Z0-9]{4}\.[0-9]"' | tr -d '"' | sort | tr '\n' ' ')
  [ "$reasons" = "CA92.1 E174.1 NSPrivacyAccessedAPICategoryDiskSpace NSPrivacyAccessedAPICategoryUserDefaults " ] && pass "privacy manifest: DiskSpace E174.1, UserDefaults CA92.1" || failed "privacy manifest reasons: $reasons"
  plutil -p "$manifests" | grep -q '"NSPrivacyTracking" => false' && pass "no tracking" || failed "NSPrivacyTracking is not false"
  for k in NSPrivacyCollectedDataTypes NSPrivacyTrackingDomains; do
    [ "$(plutil -extract "$k" json -o - "$manifests" 2>/dev/null)" = '[]' ] && pass "$k is empty" || failed "$k is not an empty list"
  done
else
  failed "$count privacy manifests"
fi

# The sample book at the bundle root, one chapter and its cover; the whole-book test fixture stays out
if [ -f "$app/alice.epub" ]; then
  chapters=$(unzip -Z1 "$app/alice.epub" | grep -c '^OEBPS/text/chapter-' || true)
  cover=$(unzip -Z1 "$app/alice.epub" | grep -c '^OEBPS/images/cover.jpg$' || true)
  [ "$chapters" = 1 ] && [ "$cover" = 1 ] && pass "alice.epub: 1 chapter, the cover, $(stat -f%z "$app/alice.epub") bytes" || failed "alice.epub has $chapters chapters and $cover covers"
else
  failed "no alice.epub at the bundle root"
fi
[ -z "$(find "$app" -name 'alice-whole.epub')" ] && pass "no alice-whole.epub" || failed "the whole-book test fixture is in the app"

# The executable: no DEBUG-only hooks, no computer paths
# (a Debug build keeps its code in ReadStair.debug.dylib next to a stub executable, so that file is read too, and must not ship)
bin=$app/ReadStair
strings_of=$(strings -a "$bin" 2>/dev/null) || failed "cannot read the executable"
if [ -f "$app/ReadStair.debug.dylib" ]; then
  failed "ReadStair.debug.dylib is in the app (a Debug build)"
  strings_of+=$'\n'$(strings -a "$app/ReadStair.debug.dylib" 2>/dev/null)
fi
hooks='ReadStair(DataRoot|SeedPages|SeedFile|Recognizer|CloudLevel|SyncSelfTest|HoldsUndo|SampleBook|AppleIntelligence|ResetAppleIntelligenceHint)|I-SYNC|SyncSelfTest|applyCloudLevelForTesting'
found=$(grep -cE "$hooks" <<< "$strings_of" || true)
[ "$found" = 0 ] && pass "no DEBUG hooks" || failed "$found strings of DEBUG hooks"
paths=$(grep -c "$users/" <<< "$strings_of" || true)
[ "$paths" = 0 ] && pass "no home-folder paths in the executable" || failed "$paths strings with home-folder paths in the executable"

# The archive's debug symbols point only into the clean folder
if [ -n "$archive" ]; then
  dwarf=$(find "$archive/dSYMs" -path '*ReadStair.app.dSYM/Contents/Resources/DWARF/ReadStair' | head -1)
  if [ -n "$dwarf" ]; then
    root=$(cd "$clean" && pwd -P)
    # Xcode's own DerivedData paths (generated sources, SDK caches) are expected; every source path must be in the export
    outside=$(strings -a "$dwarf" | grep -E "^$users/" | grep -vE "^$users/[^/]+/Library/Developer/Xcode/DerivedData/" \
      | grep -vF "$root/" | grep -vF "$(cd "$clean" && pwd)/" | grep -c . || true)
    [ "$outside" = 0 ] && pass "dSYM source paths are all in the clean folder" || failed "$outside dSYM paths outside the clean folder"
  else
    failed "no dSYM for ReadStair in the archive"
  fi
fi

# The export is still exactly what was tested: the release test ended with no changes, and archiving must not add any
[ -z "$(git -C "$clean" status --porcelain)" ] && pass "the export has no changes" || failed "the export has changes"

[ $status = 0 ] && echo "Package: PASS" || echo "Package: FAIL"
exit $status
