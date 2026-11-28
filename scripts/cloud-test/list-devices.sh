#!/bin/bash
# Read-only device catalog lookup. Never starts a test or incurs test execution cost.
set -euo pipefail
PROJECT_ID="${LUMA_FIREBASE_PROJECT_ID:-}"
DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT_ID="${2:?}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help)
      echo "Usage: scripts/cloud-test/list-devices.sh [--project ID] [--dry-run]"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

if [[ $DRY_RUN == 1 ]]; then
  echo "gcloud firebase test ios models list --project ${PROJECT_ID:-<project>}"
  echo "gcloud firebase test ios versions list --project ${PROJECT_ID:-<project>}"
  exit 0
fi
[[ -n "$PROJECT_ID" ]] || { echo "Missing --project or LUMA_FIREBASE_PROJECT_ID." >&2; exit 3; }
command -v gcloud >/dev/null || { echo "gcloud is required." >&2; exit 2; }
active="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | head -1)"
[[ -n "$active" ]] || { echo "No active gcloud account. Run: gcloud auth login" >&2; exit 3; }

echo "Account: $active"
echo "Models:"
gcloud firebase test ios models list --project "$PROJECT_ID" \
  --format='table(id, name, formFactor)'
echo "Versions:"
gcloud firebase test ios versions list --project "$PROJECT_ID" \
  --format='table(id, majorVersion, supportedXcodeVersionIds)'
