#!/bin/sh
# Installs build/QuickPeek.app into /Applications and enables its Quick Look extension.
set -eu

cd "$(dirname "$0")/.."

src=build/QuickPeek.app
dst=/Applications/QuickPeek.app
[ -d "$src" ] || { echo "Run script/build.sh first." >&2; exit 1; }

pkill -x QuickPeek 2>/dev/null || true
rm -rf "$dst"
ditto "$src" "$dst"

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f -R "$dst"
pluginkit -a "$dst/Contents/PlugIns/QuickPeekPreview.appex"
pluginkit -e use -i io.github.yinon-mitin.QuickPeek.Preview
qlmanage -r >/dev/null 2>&1
killall -q quicklookd QuickLookUIService 2>/dev/null || true

echo "Installed $dst"
pluginkit -m -v -i io.github.yinon-mitin.QuickPeek.Preview
