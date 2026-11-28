#!/bin/bash
# Static privacy audit for the diagnostics layer. Fails on patterns that would
# put free-form media/account data into a telemetry call.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DIAG="${ROOT}/Luma/Services/Diagnostics"
FAIL=0
fail() { echo "FAIL  $1"; FAIL=1; }
pass() { echo "PASS  $1"; }

if grep -RInE 'localizedDescription|absoluteString|request\.url|setUserID|setUserProperty|logEvent' "$DIAG" \
  --include='*.swift' >/tmp/luma-diag-privacy.txt; then
  cat /tmp/luma-diag-privacy.txt
  fail "diagnostics source contains a free-form identifier"
else
  pass "no free-form URL/error/user identifier in diagnostics source"
fi

if grep -RInE 'setUserID|setUserProperty|logEvent|FirebaseAnalytics|FirebaseAuth|Firestore|FirebaseMessaging|AdMob' \
  "$ROOT/Luma" --include='*.swift' >/tmp/luma-analytics.txt; then
  cat /tmp/luma-analytics.txt
  fail "unexpected analytics/user API usage"
else
  pass "no Analytics/Auth/Firestore/Messaging/AdMob API usage"
fi

if grep -RIn 'record(error:' "$DIAG" | grep -vE 'NSError\(domain: "LumaDiagnostics", code:' >/tmp/luma-error-forward.txt; then
  cat /tmp/luma-error-forward.txt
  fail "Crashlytics receives a non-normalized Error"
else
  pass "Crashlytics non-fatals are normalized NSError codes"
fi

for key in FirebaseCrashlyticsCollectionEnabled firebase_performance_collection_enabled firebase_performance_instrumentation_enabled; do
  value="$(plutil -extract "$key" raw -o - "$ROOT/Luma-Info.plist" 2>/dev/null || true)"
  [[ "$value" == "false" ]] && pass "$key=false" || fail "$key is not false"
done

if [[ $FAIL -ne 0 ]]; then exit 1; fi
echo "Privacy audit passed."
