#!/bin/bash
# Foundation-only tests: no application host, simulator, or UI automation.
set -euo pipefail
native_root="$(cd "$(dirname "$0")/.." && pwd)"
sdk_developer="$(xcode-select -p)/Platforms/MacOSX.platform/Developer"
layout_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/hq-sidebar-tests.XXXXXX")"
trap 'rm -rf "$layout_test_dir"' EXIT
layout_bundle="$layout_test_dir/HQSidebarHeadless.xctest"
mkdir -p "$layout_bundle/Contents/MacOS"
xcrun swiftc -D SIDEBAR_LAYOUT_HEADLESS -emit-library -module-name HQSidebarHeadless \
  -I "$sdk_developer/usr/lib" -L "$sdk_developer/usr/lib" \
  -F "$sdk_developer/Library/Frameworks" \
  -Xlinker -rpath -Xlinker "$sdk_developer/Library/Frameworks" \
  -Xlinker -rpath -Xlinker "$sdk_developer/usr/lib" \
  "$native_root/Sources/Shared/Views/SidebarLayout.swift" \
  "$native_root/Tests/SidebarLayoutTests.swift" \
  -o "$layout_bundle/Contents/MacOS/HQSidebarHeadless"
xcrun xctest "$layout_bundle"
