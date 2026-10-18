#!/bin/bash
# Runs Uno's automated tests.   bash run_tests.sh
# Needs Xcode (free on the App Store); Command Line Tools alone don't include the test framework.
set -uo pipefail
cd "$(dirname "$0")"

if ! xcrun --find xctest >/dev/null 2>&1; then
  echo "Tests need Xcode. Install it from the App Store, open it once, then run:"
  echo "  sudo xcode-select -s /Applications/Xcode.app"
  exit 1
fi

mkdir -p build
echo "▸ Running tests (the first run builds everything and takes a minute)…"
swift test 2>&1 | tee build/test-results.txt
status=${PIPESTATUS[0]}
echo
if [ "$status" -eq 0 ]; then
  echo "✓ All tests passed. Full log: build/test-results.txt"
else
  echo "✗ Some tests failed. Full log: build/test-results.txt"
fi
exit "$status"
