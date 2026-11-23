#!/usr/bin/env bash
# The three required checks. Run from repo root. CI runs the same script.
set -euo pipefail
cd "$(dirname "$0")/.."
HAS_XCODE=0; [[ "$(xcode-select -p 2>/dev/null)" == *.app/* ]] && HAS_XCODE=1

echo "== 1/3 lint"
swift format lint --strict --recursive Packages/HaloKit/Sources Packages/HaloKit/Tests \
  Packages/HaloKit/Package.swift App/Halo

echo "== 2/3 build + test (HaloKit, macOS host)"
if [ "$HAS_XCODE" = 1 ]; then
  swift test --package-path Packages/HaloKit
else
  echo "!! Xcode not installed: building only; tests run in CI (gh pr checks --watch)."
  swift build --package-path Packages/HaloKit
fi

echo "== 3/3 iOS app build"
if [ "$HAS_XCODE" = 1 ]; then
  command -v xcodegen >/dev/null || { echo "install xcodegen: brew install xcodegen"; exit 1; }
  xcodegen generate --spec App/project.yml --quiet
  xcodebuild -project App/Halo.xcodeproj -scheme Halo -destination 'generic/platform=iOS Simulator' \
    -quiet CODE_SIGNING_ALLOWED=NO build
else
  echo "!! Xcode not installed: iOS app build runs in CI only."
fi
echo "== all checks passed"
