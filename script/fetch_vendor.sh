#!/bin/sh
# Downloads the pinned highlight.js grammars into Vendor/ and verifies their checksums.
# highlight.js runs in JavaScriptCore inside the app; its colours live in CodeTheme.swift.
# The files are committed, so builds never touch the network; run this only to bump versions.
set -eu

cd "$(dirname "$0")/.."

HLJS=11.11.1
HLJS_BASE="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/$HLJS"
HLJS_EXTRA_LANGUAGES="cmake dart dockerfile elixir groovy haskell nginx powershell properties protobuf scala"

fetch() {
    curl --fail --silent --show-error --location "$1" --output "$2"
}

mkdir -p Vendor/languages
fetch "$HLJS_BASE/highlight.min.js" Vendor/highlight.min.js
for language in $HLJS_EXTRA_LANGUAGES; do
    fetch "$HLJS_BASE/languages/$language.min.js" "Vendor/languages/$language.min.js"
done

if [ "${1:-}" = "--update-checksums" ]; then
    (cd Vendor && find . -type f ! -name checksums.sha256 | sort | xargs shasum -a 256 > checksums.sha256)
fi
(cd Vendor && shasum -a 256 --check --quiet checksums.sha256)
echo "Vendor assets verified."
