#!/bin/sh
# Builds the app-package fixtures for QuickPeekFormatsTests: an .ipa with icons and an
# embedded provisioning profile, and an .xcarchive. The profile is CMS-signed with a
# throwaway self-signed certificate (the real ones are signed by Apple); QuickPeek only reads
# the signed content, it does not validate the signature chain.
set -eu

cd "$(dirname "$0")/.."
out=Tests/QuickPeekFormatsTests/Fixtures/apps
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
rm -rf "$out"
mkdir -p "$out"

app="$work/Payload/Demo.app"
mkdir -p "$app"
cat > "$work/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.example.demo</string>
  <key>CFBundleDisplayName</key><string>Demo</string>
  <key>CFBundleName</key><string>DemoApp</string>
  <key>CFBundleExecutable</key><string>Demo</string>
  <key>CFBundleShortVersionString</key><string>2.3</string>
  <key>CFBundleVersion</key><string>45</string>
  <key>MinimumOSVersion</key><string>16.0</string>
  <key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
  <key>CFBundleSupportedPlatforms</key><array><string>iPhoneOS</string></array>
  <key>DTPlatformName</key><string>iphoneos</string>
  <key>DTPlatformVersion</key><string>18.0</string>
  <key>DTXcode</key><string>1600</string>
  <key>CFBundleIcons</key><dict><key>CFBundlePrimaryIcon</key><dict>
    <key>CFBundleIconFiles</key><array><string>AppIcon60x60</string></array>
    <key>CFBundleIconName</key><string>AppIcon</string>
  </dict></dict>
</dict></plist>
PLIST
plutil -convert binary1 -o "$app/Info.plist" "$work/Info.plist"
printf 'not a real executable' > "$app/Demo"

# Two icon sizes; the reader should pick the larger one.
python3 - "$app" <<'PY'
import struct, sys, zlib
def png(path, size, rgb):
    raw = b"".join(b"\x00" + bytes(rgb) * size for _ in range(size))
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    data = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0)) \
        + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
    open(path, "wb").write(data)
png(sys.argv[1] + "/AppIcon60x60@2x.png", 120, (0x34, 0x7A, 0xF6))
png(sys.argv[1] + "/AppIcon60x60@3x.png", 180, (0x34, 0x7A, 0xF6))
PY

cat > "$work/profile.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>AppIDName</key><string>Demo</string>
  <key>Name</key><string>Demo Ad Hoc</string>
  <key>TeamName</key><string>Example Team</string>
  <key>TeamIdentifier</key><array><string>ABCDE12345</string></array>
  <key>UUID</key><string>11111111-2222-3333-4444-555555555555</string>
  <key>CreationDate</key><date>2026-01-02T15:30:00Z</date>
  <key>ExpirationDate</key><date>2027-01-02T15:30:00Z</date>
  <key>Platform</key><array><string>iOS</string></array>
  <key>ProvisionedDevices</key><array><string>00008110-000A1B2C3D4E5F01</string><string>00008110-000A1B2C3D4E5F02</string><string>00008110-000A1B2C3D4E5F03</string></array>
  <key>Entitlements</key><dict>
    <key>application-identifier</key><string>ABCDE12345.com.example.demo</string>
    <key>get-task-allow</key><false/>
    <key>aps-environment</key><string>production</string>
  </dict>
</dict></plist>
PLIST
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$work/key.pem" -out "$work/cert.pem" -days 1 \
    -subj "/CN=QuickPeek test signer" >/dev/null 2>&1
openssl cms -sign -nodetach -binary -outform DER -in "$work/profile.plist" -signer "$work/cert.pem" \
    -inkey "$work/key.pem" -out "$app/embedded.mobileprovision"

(cd "$work" && zip -q -X -r "Demo.ipa" Payload)
cp "$work/Demo.ipa" "$out/"

archive="$out/Demo.xcarchive"
mkdir -p "$archive/Products/Applications"
cp -R "$app" "$archive/Products/Applications/"
cat > "$archive/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>ApplicationProperties</key><dict>
    <key>ApplicationPath</key><string>Applications/Demo.app</string>
    <key>CFBundleIdentifier</key><string>com.example.demo</string>
    <key>CFBundleShortVersionString</key><string>2.3</string>
    <key>CFBundleVersion</key><string>45</string>
    <key>SigningIdentity</key><string>Apple Distribution: Example Team (ABCDE12345)</string>
    <key>Team</key><string>ABCDE12345</string>
  </dict>
  <key>ArchiveVersion</key><integer>2</integer>
  <key>CreationDate</key><date>2026-02-03T10:00:00Z</date>
  <key>Name</key><string>Demo</string>
  <key>SchemeName</key><string>Demo-Release</string>
</dict></plist>
PLIST
ls -lR "$out" | grep -v "^total"
