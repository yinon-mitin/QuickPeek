#!/bin/sh
# Regenerates the archive fixtures for QuickPeekFormatsTests.
# ZIP/TAR variants are built with the system zip and bsdtar; RAR and 7z samples come from
# libarchive's own test suite (BSD-2-Clause), pinned to one commit.
set -eu

cd "$(dirname "$0")/.."
out=Tests/QuickPeekFormatsTests/Fixtures/archives
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$out"

LIBARCHIVE_COMMIT=76d41c18cf53c888afb2c9477fd595a5d3984192

# A small tree with a nested directory, a UTF-8 name and fixed dates, so listings are stable.
mkdir -p "$work/tree/docs/notes"
printf 'hello\n' > "$work/tree/hello.txt"
printf 'nested file\n' > "$work/tree/docs/notes/todo.md"
printf 'привет\n' > "$work/tree/docs/привет.txt"
head -c 4096 /dev/zero > "$work/tree/docs/zeros.bin"
find "$work/tree" -exec touch -t 202601021530 {} +

(
    cd "$work/tree"
    zip -q -X -r "$work/tree.zip" hello.txt docs
    zip -q -X -P secret "$work/encrypted.zip" hello.txt
    tar --uid 0 --gid 0 --uname "" --gname "" --format ustar -cf "$work/tree.tar" hello.txt docs
    tar --uid 0 --gid 0 --uname "" --gname "" -czf "$work/tree.tar.gz" hello.txt docs
    tar --uid 0 --gid 0 --uname "" --gname "" -cjf "$work/tree.tar.bz2" hello.txt docs
    tar --uid 0 --gid 0 --uname "" --gname "" -cJf "$work/tree.tar.xz" hello.txt docs
    gzip -n -c hello.txt > "$work/hello.txt.gz"
)
cp "$work"/tree.zip "$work"/encrypted.zip "$work"/tree.tar "$work"/tree.tar.gz \
   "$work"/tree.tar.bz2 "$work"/tree.tar.xz "$work"/hello.txt.gz "$out/"

# Hostile archives, a few KB each: a .tar.bz2 whose first entry is 16 GiB of zeros (64 concatenated
# bzip2 streams of 256 MiB) with README.txt behind it, and a ZIP whose two entries each claim
# 2^62 + 1 bytes in their zip64 fields, more than a plain Int64 sum can hold.
head -c 268435456 /dev/zero | bzip2 -9 > "$work/zeros.bz2"
python3 -I - "$work/zeros.bz2" "$out" <<'EOF'
import bz2, io, struct, sys, tarfile, zipfile

zeros, out = open(sys.argv[1], "rb").read(), sys.argv[2]

def header(name, size):
    info = tarfile.TarInfo(name)
    info.size = size
    return info.tobuf(format=tarfile.PAX_FORMAT)

with open(f"{out}/bomb.tar.bz2", "wb") as f:
    f.write(bz2.compress(header("zeros.bin", 64 * 268435456)))
    f.write(zeros * 64)
    f.write(bz2.compress(header("README.txt", 3) + b"hi\n".ljust(512, b"\0") + bytes(1024)))

buffer = io.BytesIO()
with zipfile.ZipFile(buffer, "w") as archive:
    for name in ("d/a.txt", "d/b.txt"):
        with archive.open(zipfile.ZipInfo(name), "w", force_zip64=True) as f:
            f.write(b"x")
data = bytearray(buffer.getvalue())
# Each local header has a zip64 extra field (id 1, 16 bytes): the uncompressed size comes first.
at = 0
while (at := data.find(b"\x01\x00\x10\x00", at)) >= 0:
    data[at + 4:at + 12] = struct.pack("<Q", (1 << 62) + 1)
    at += 4
open(f"{out}/huge-sizes.zip", "wb").write(data)
EOF

base="https://raw.githubusercontent.com/libarchive/libarchive/$LIBARCHIVE_COMMIT/libarchive/test"
for name in \
    test_read_format_rar.rar \
    test_read_format_rar4_encrypted_filenames.rar \
    test_read_format_rar5_multiple_files.rar \
    test_read_format_rar5_unicode.rar \
    test_read_format_rar5_encrypted_filenames.rar \
    test_read_format_7zip_lzma1.7z
do
    curl --fail --silent --show-error --location "$base/$name.uu" --output "$work/$name.uu"
    (cd "$work" && uudecode -o "$name" "$name.uu")
    cp "$work/$name" "$out/${name#test_read_format_}"
done

ls -l "$out"
