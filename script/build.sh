#!/bin/sh
# Generates the Xcode project from project.yml and builds a Release QuickPeek.app into build/.
set -eu

cd "$(dirname "$0")/.."

command -v xcodegen >/dev/null || { echo "xcodegen is required: brew install xcodegen" >&2; exit 1; }

swift test
xcodegen generate --quiet
mkdir -p build
if ! xcodebuild \
    -project QuickPeek.xcodeproj \
    -scheme QuickPeek \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -derivedDataPath build/DerivedData \
    build > build/xcodebuild.log 2>&1; then
    grep -E "error:|\*\* BUILD FAILED" build/xcodebuild.log >&2 || tail -30 build/xcodebuild.log >&2
    echo "Build failed; full log: build/xcodebuild.log" >&2
    exit 1
fi

app=build/DerivedData/Build/Products/Release/QuickPeek.app
[ -d "$app" ] || { echo "Build failed: $app not found" >&2; exit 1; }
rm -rf build/QuickPeek.app
ditto "$app" build/QuickPeek.app
# Xcode registers every build product with LaunchServices; an extension registered from
# DerivedData would compete with the installed copy, so forget the intermediate one.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$app" 2>/dev/null || true
echo "Built build/QuickPeek.app"
