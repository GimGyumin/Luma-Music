#!/bin/bash
# Crashlytics dSYM upload for the iOS app target.
#
# This phase is intentionally inert when:
#   - the destination is native macOS,
#   - the build is Debug (unless explicitly opted in), or
#   - Firebase configuration / the SPM uploader is absent.
# That keeps local development and no-Firebase builds green.
set -euo pipefail

STAMP_DIR="${DERIVED_FILE_DIR:-${TEMP_DIR:-/tmp}}"
STAMP="${STAMP_DIR}/crashlytics-upload.stamp"
mkdir -p "$STAMP_DIR" 2>/dev/null || true
finish() { touch "$STAMP" 2>/dev/null || true; }
trap finish EXIT

case "${PLATFORM_NAME:-}" in
  iphoneos|iphonesimulator) ;;
  *) echo "note: Crashlytics dSYM upload skipped for platform '${PLATFORM_NAME:-unknown}'"; exit 0 ;;
esac

if [[ "${CONFIGURATION:-}" != "Release" && "${LUMA_CRASHLYTICS_DEBUG_UPLOAD:-0}" != "1" ]]; then
  echo "note: Crashlytics dSYM upload skipped for ${CONFIGURATION:-unknown} build"
  exit 0
fi

# Command-line validation builds use CODE_SIGNING_ALLOWED=NO. Do not contact
# Firebase from an unsigned build; an Archive leaves code signing enabled.
if [[ "${CODE_SIGNING_ALLOWED:-YES}" == "NO" && "${LUMA_CRASHLYTICS_UPLOAD:-0}" != "1" ]]; then
  echo "note: Crashlytics dSYM upload skipped for an unsigned build"
  exit 0
fi

BUILT_PLIST="${TARGET_BUILD_DIR:-}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:-}/GoogleService-Info.plist"
SOURCE_PLIST="${SRCROOT:-}/Luma/GoogleService-Info.plist"
if [[ ! -f "$BUILT_PLIST" && ! -f "$SOURCE_PLIST" ]]; then
  echo "note: Crashlytics dSYM upload skipped — GoogleService-Info.plist is not present"
  exit 0
fi

UPLOADER="${BUILD_DIR%Build/*}SourcePackages/checkouts/firebase-ios-sdk/Crashlytics/run"
if [[ ! -x "$UPLOADER" ]]; then
  echo "note: Crashlytics uploader not found at the resolved SPM path; skipping dSYM upload"
  exit 0
fi

echo "Crashlytics: uploading dSYMs for ${PRODUCT_NAME:-Luma}"
if ! "$UPLOADER"; then
  # A missing network or Firebase project must not make an otherwise valid
  # archive unshippable. The checklist verifies symbolication explicitly.
  echo "note: Crashlytics dSYM upload failed; archive remains valid"
  exit 0
fi
