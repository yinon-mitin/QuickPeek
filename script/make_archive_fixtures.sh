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
