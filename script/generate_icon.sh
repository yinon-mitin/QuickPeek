#!/bin/sh
# Regenerates the app icon from Resources/AppIcon.svg:
#   Resources/AppIcon.png (1024 px, used by the README) and App/Assets.xcassets/AppIcon.appiconset.
set -eu

cd "$(dirname "$0")/.."
set_dir=App/Assets.xcassets/AppIcon.appiconset
mkdir -p "$set_dir"

swift script/render_svg.swift Resources/AppIcon.svg Resources/AppIcon.png 1024

entries=""
for size in 16 32 128 256 512; do
    for scale in 1 2; do
        pixels=$((size * scale))
        suffix=""
        if [ "$scale" = 2 ]; then suffix="@2x"; fi
        name="icon_${size}x${size}${suffix}.png"
        sips -z "$pixels" "$pixels" Resources/AppIcon.png --out "$set_dir/$name" >/dev/null
        entries="$entries{\"idiom\":\"mac\",\"size\":\"${size}x${size}\",\"scale\":\"${scale}x\",\"filename\":\"$name\"},"
    done
done
printf '{"images":[%s],"info":{"author":"xcode","version":1}}\n' "${entries%,}" | python3 -m json.tool > "$set_dir/Contents.json"
printf '{"info":{"author":"xcode","version":1}}\n' > App/Assets.xcassets/Contents.json
echo "Generated $set_dir and Resources/AppIcon.png"
