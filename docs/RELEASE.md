# Release checklist

Use this checklist to prepare a reproducible Hygieia macOS release. A checked
build is not a claim that signing, notarization, native file actions, or owner
acceptance succeeded unless their separate evidence is attached to the release.

## 1. Establish the release state

1. Start from a clean, reviewed commit on the intended release branch.
2. Confirm the release metadata:

   ```bash
   xcodebuild -project Hygieia.xcodeproj -scheme Hygieia -configuration Release -showBuildSettings | \
     rg 'MARKETING_VERSION|CURRENT_PROJECT_VERSION|PRODUCT_BUNDLE_IDENTIFIER|INFOPLIST_KEY_LSApplicationCategoryType|ENABLE_HARDENED_RUNTIME'
   ```

   Expected for `0.2.0`: `MARKETING_VERSION = 0.2.0`,
   `CURRENT_PROJECT_VERSION = 1`, and
   `PRODUCT_BUNDLE_IDENTIFIER = com.gollardo.Hygieia`. Do not change the bundle
   identifier once it is registered in Apple Developer.
3. Update [CHANGELOG.md](../CHANGELOG.md), release notes, and any affected
   user-facing documentation.

## 2. Verify source and build

Run these commands from the repository root using a full Xcode installation:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project Hygieia.xcodeproj \
  -scheme Hygieia \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  build
```

Record the Xcode version, commit SHA, command output, and any skipped tests.
Inspect the built app's Info.plist and entitlements before distribution:

```bash
APP_PATH="$(find ~/Library/Developer/Xcode/DerivedData -path '*Build/Products/Release/Hygieia.app' -print -quit)"
plutil -p "$APP_PATH/Contents/Info.plist"
codesign --display --entitlements :- "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
```

Confirm the app icon is present in Finder and `LSApplicationCategoryType` is
`public.app-category.utilities`. The Release build must show Hardened Runtime.

## 3. Sign, archive, and notarize

1. Archive with the distribution signing identity belonging to the registered
   `com.gollardo.Hygieia` App ID.
2. Export a Developer ID-signed artifact and keep the archive, export options,
   signature identity, and SHA-256 digest with the release evidence.
3. Submit the exact exported artifact for notarization; wait for an accepted
   result, then staple the ticket.
4. On a clean macOS account or VM, verify Gatekeeper and the stapled ticket:

   ```bash
   spctl --assess --type execute --verbose=4 /path/to/Hygieia.app
   stapler validate /path/to/Hygieia.app
   ```

Never publish an artifact as notarized without its accepted notarization record.

## 4. Native acceptance gates

On a non-production fixture, manually verify the app's declared support matrix:

- launch, folder selection, scan cancellation, navigation, long names, and dark
  hierarchy;
- VoiceOver labels, keyboard traversal, and Reduce Motion behavior;
- Finder reveal and Move to Trash for a regular file, directory, package, and
  symlink; confirm that a symlink target remains untouched;
- permission denial, read-only and removable-volume behavior where available;
- receipt-confirmed reconciliation and its full-root-rescan fallback.

Do not use personal data or broad filesystem roots as test fixtures. Record any
failed or unrun gate in the release notes.

## 5. Publish and retain evidence

1. Create annotated tag `v<MARKETING_VERSION>` from the verified commit.
2. Create the GitHub Release with the signed, notarized artifact, SHA-256
   digest, release notes, and known open gates.
3. Download the public artifact once and repeat the signature/Gatekeeper check.
4. Retain the build logs, test results, notarization record, checksums, and
   acceptance evidence with the release record.
