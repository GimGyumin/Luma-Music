#!/bin/bash
# Offline validation for the optional Firebase diagnostics setup.
# Prints presence checks only; never prints API keys, app IDs, project IDs or URLs.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STRICT=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --strict) STRICT=1; shift ;;
    -h|--help) echo "Usage: scripts/firebase/check-setup.sh [--strict]"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

FAIL=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; FAIL=1; }
warn() { echo "WARN  $1"; }
have() { command -v "$1" >/dev/null 2>&1; }

PLIST="${ROOT}/Luma/GoogleService-Info.plist"
if [[ -f "$PLIST" ]]; then
  pass "GoogleService-Info.plist is present (ignored by git)"
  BUNDLE_ID="$(plutil -extract BUNDLE_ID raw -o - "$PLIST" 2>/dev/null || true)"
  APP_ID="$(plutil -extract GOOGLE_APP_ID raw -o - "$PLIST" 2>/dev/null || true)"
  PROJECT_ID="$(plutil -extract PROJECT_ID raw -o - "$PLIST" 2>/dev/null || true)"
  API_KEY="$(plutil -extract API_KEY raw -o - "$PLIST" 2>/dev/null || true)"
  [[ "$BUNDLE_ID" == "com.kyumin.Music.Luma" ]] && pass "BUNDLE_ID matches the app" \
    || fail "BUNDLE_ID does not match com.kyumin.Music.Luma"
  [[ "$APP_ID" == 1:* ]] && pass "GOOGLE_APP_ID is shaped like a Firebase app ID" \
    || fail "GOOGLE_APP_ID is missing or a placeholder"
  [[ -n "$PROJECT_ID" ]] && pass "PROJECT_ID is present" || fail "PROJECT_ID is missing"
  [[ -n "$API_KEY" ]] && pass "API_KEY is present" || fail "API_KEY is missing"
  if git -C "$ROOT" ls-files --error-unmatch "Luma/GoogleService-Info.plist" >/dev/null 2>&1; then
    warn "GoogleService-Info.plist is tracked by git; keep it per environment"
  else
    pass "GoogleService-Info.plist is not tracked by git"
  fi
else
  warn "GoogleService-Info.plist is absent — the app and tests use the No-op/local diagnostics path"
fi

INFO="${ROOT}/Luma-Info.plist"
for key in FirebaseCrashlyticsCollectionEnabled firebase_performance_collection_enabled firebase_performance_instrumentation_enabled FirebaseAppDelegateProxyEnabled; do
  value="$(plutil -extract "$key" raw -o - "$INFO" 2>/dev/null || true)"
  if [[ "$key" == "FirebaseAppDelegateProxyEnabled" ]]; then
    [[ "$value" == "false" ]] && pass "$key is false (Luma owns its AppDelegate)" \
      || fail "$key should be false"
  else
    [[ "$value" == "false" ]] && pass "$key defaults to false" \
      || fail "$key should default to false"
  fi
done

if grep -q 'firebase-ios-sdk' "${ROOT}/Luma.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved" 2>/dev/null; then
  pass "Firebase SPM package is resolved"
else
  fail "Firebase SPM package is not resolved"
fi

if [[ -x "${ROOT}/scripts/firebase/crashlytics-run.sh" ]]; then
  pass "Crashlytics dSYM upload phase script is executable"
else
  fail "Crashlytics dSYM upload phase script is missing or not executable"
fi

if [[ $FAIL -ne 0 && $STRICT -eq 1 ]]; then
  exit 1
fi
echo "Checks complete. FAIL=${FAIL} (non-strict mode exits 0)."
