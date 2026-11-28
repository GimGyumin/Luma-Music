#!/bin/bash
# Cloud device test runner for Luma.
#
# Default behaviour is a dry run. Nothing is built, uploaded, or billed unless
# --execute --confirm-cost is provided AND LUMA_CLOUD_TEST_APPROVAL=YES.
#
# Firebase Test Lab is scheduled to shut down on 2027-09-30. Keep this script
# as a thin provider adapter so it can be replaced by the Developer Device
# Platform without touching the build/test definition.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROJECT="${ROOT}/Luma.xcodeproj"
SCHEME="Luma"
CONFIGURATION="Debug"
DERIVED="${ROOT}/.cloud-test/DerivedData"
ARTIFACT_DIR="${ROOT}/.cloud-test/artifacts"
PROJECT_ID="${LUMA_FIREBASE_PROJECT_ID:-}"
MODEL="${LUMA_CLOUD_TEST_MODEL:-iphone16pro}"
VERSION="${LUMA_CLOUD_TEST_VERSION:-}"
TIMEOUT="30m"
RESULTS_BUCKET="${LUMA_CLOUD_TEST_BUCKET:-}"
RESULTS_DIR="luma-$(date -u +%Y%m%d-%H%M%S)"
EXECUTE=0
CONFIRM_COST=0
BUILD_ONLY=0

usage() {
  cat <<'EOF'
Usage: scripts/cloud-test/run-cloud-tests.sh [options]

  --project ID        Firebase/GCP project (or LUMA_FIREBASE_PROJECT_ID)
  --model MODEL       iOS device model (default: iphone16pro)
  --version VERSION   iOS version (default: latest listed version)
  --timeout VALUE     Test timeout (default: 30m)
  --bucket NAME       GCS bucket for results (optional)
  --execute           Build, upload, and run remotely
  --confirm-cost      Required with --execute; acknowledges possible billing
  --build-only        Run xcodebuild build-for-testing locally, never upload
  --dry-run           Print the plan only (default)
  -h, --help          Show this help

Safety gates for remote execution:
  LUMA_CLOUD_TEST_APPROVAL=YES  and  --execute --confirm-cost

Robo tests are Android-only and are not supported for this iOS app.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT_ID="${2:?}"; shift 2 ;;
    --model) MODEL="${2:?}"; shift 2 ;;
    --version) VERSION="${2:?}"; shift 2 ;;
    --timeout) TIMEOUT="${2:?}"; shift 2 ;;
    --bucket) RESULTS_BUCKET="${2:?}"; shift 2 ;;
    --execute) EXECUTE=1; shift ;;
    --confirm-cost) CONFIRM_COST=1; shift ;;
    --build-only) BUILD_ONLY=1; shift ;;
    --dry-run) EXECUTE=0; BUILD_ONLY=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

echo "Project:      $PROJECT"
echo "Scheme:       $SCHEME"
echo "Device:       ${MODEL}${VERSION:+/$VERSION}"
echo "Timeout:      $TIMEOUT"
echo "Artifacts:    $ARTIFACT_DIR"
echo "Remote run:   $([[ $EXECUTE == 1 ]] && echo yes || echo no)"
echo "Test Lab EOL: 2027-09-30 (migration to Developer Device Platform planned)"

if [[ $EXECUTE == 0 && $BUILD_ONLY == 0 ]]; then
  echo
  echo "DRY RUN. Commands that would run:"
  echo "  xcodebuild build-for-testing -project Luma.xcodeproj -scheme Luma -destination 'generic/platform=iOS' -derivedDataPath $DERIVED"
  echo "  ditto -c -k --sequesterRsrc $DERIVED/Build/Products $ROOT/.cloud-test/LumaTests.zip"
  echo "  gcloud firebase test ios run --project $PROJECT_ID --test $ROOT/.cloud-test/LumaTests.zip --device model=$MODEL${VERSION:+,version=$VERSION} --timeout $TIMEOUT"
  echo
  echo "Nothing was built or uploaded. Pass --build-only or --execute --confirm-cost."
  exit 0
fi

if [[ $EXECUTE == 1 ]]; then
  if [[ "${LUMA_CLOUD_TEST_APPROVAL:-}" != "YES" || $CONFIRM_COST != 1 ]]; then
    echo "Refusing remote execution without explicit approval." >&2
    echo "Set LUMA_CLOUD_TEST_APPROVAL=YES and pass --execute --confirm-cost." >&2
    exit 3
  fi
  if [[ -z "$PROJECT_ID" ]]; then
    echo "Missing --project or LUMA_FIREBASE_PROJECT_ID." >&2
    exit 3
  fi
  command -v gcloud >/dev/null || { echo "gcloud is required." >&2; exit 2; }
  active="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | head -1)"
  [[ -n "$active" ]] || { echo "No active gcloud account. Run: gcloud auth login" >&2; exit 3; }
  gcloud projects describe "$PROJECT_ID" --format='value(projectId)' >/dev/null || {
    echo "Project '$PROJECT_ID' is not accessible with the active account." >&2
    exit 3
  }
  echo "Active account: $active"
  echo "Warning: remote device tests can incur Firebase/GCP charges."
fi

xcodebuild -list -project "$PROJECT" | grep -q "$SCHEME" || {
  echo "Scheme '$SCHEME' not found." >&2
  exit 2
}

mkdir -p "$DERIVED" "$ARTIFACT_DIR"
echo "Building for testing…"
xcodebuild build-for-testing \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED" \
  | tee "$ARTIFACT_DIR/build-for-testing.log"

ZIP="${ROOT}/.cloud-test/LumaTests.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc "$DERIVED/Build/Products" "$ZIP"
echo "Test package: $ZIP"

if [[ $BUILD_ONLY == 1 && $EXECUTE == 0 ]]; then
  echo "Build-only requested; no cloud run."
  exit 0
fi

if [[ -z "$VERSION" ]]; then
  VERSION="$(gcloud firebase test ios versions list --project "$PROJECT_ID" --format='value(id)' 2>/dev/null | sort -V | tail -1)"
fi
[[ -n "$VERSION" ]] || { echo "No iOS version listed for project '$PROJECT_ID'." >&2; exit 3; }

MODELS="$(gcloud firebase test ios models list --project "$PROJECT_ID" --format='value(id)' 2>/dev/null || true)"
if ! grep -qx "$MODEL" <<<"$MODELS"; then
  echo "Device model '$MODEL' is not in the project's Test Lab catalog." >&2
  echo "Run scripts/cloud-test/list-devices.sh to choose a supported model." >&2
  exit 3
fi
VERSIONS="$(gcloud firebase test ios versions list --project "$PROJECT_ID" --format='value(id)' 2>/dev/null || true)"
if ! grep -qx "$VERSION" <<<"$VERSIONS"; then
  echo "iOS version '$VERSION' is not in the project's Test Lab catalog." >&2
  echo "Run scripts/cloud-test/list-devices.sh to choose a supported version." >&2
  exit 3
fi

DEVICE_ARGS=(--device="model=${MODEL},version=${VERSION},orientation=portrait")
RUN_ARGS=(
  firebase test ios run
  --project "$PROJECT_ID"
  --test "$ZIP"
  --timeout "$TIMEOUT"
  --num-flaky-test-attempts=0
  --results-dir "$RESULTS_DIR"
  --client-details="matrixLabel=luma-cloud-${RESULTS_DIR}"
)
if [[ -n "$RESULTS_BUCKET" ]]; then
  RUN_ARGS+=(--results-bucket "$RESULTS_BUCKET")
fi

echo "Running: gcloud ${RUN_ARGS[*]} ${DEVICE_ARGS[*]}"
set +e
gcloud "${RUN_ARGS[@]}" "${DEVICE_ARGS[@]}" | tee "$ARTIFACT_DIR/test-lab.log"
STATUS=${PIPESTATUS[0]}
set -e

if [[ -n "$RESULTS_BUCKET" ]]; then
  gsutil -m cp -r "gs://${RESULTS_BUCKET}/${RESULTS_DIR}" "$ARTIFACT_DIR/" \
    || echo "warning: result download failed; open the Test Lab console link above." >&2
fi

if [[ $STATUS -ne 0 ]]; then
  echo "Cloud test exited with $STATUS. See $ARTIFACT_DIR/test-lab.log" >&2
  exit "$STATUS"
fi
echo "Cloud test finished. Artifacts: $ARTIFACT_DIR"

