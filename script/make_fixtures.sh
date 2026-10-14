#!/bin/sh
# Regenerates the tiny media files used by the QuickPeekMedia tests.
# Needs ffmpeg (brew install ffmpeg) — a development tool only; QuickPeek never ships or calls it.
set -eu

cd "$(dirname "$0")/.."
out=Tests/QuickPeekMediaTests/Fixtures
mkdir -p "$out"

video="testsrc2=size=160x120:rate=10"
audio="sine=frequency=440:sample_rate=48000"

encode() {
    name=$1
    shift
    ffmpeg -v error -y -f lavfi -i "$video" -f lavfi -i "$audio" -t 1 -map_metadata -1 -fflags +bitexact "$@" "$out/$name"
}

encode h264_aac.mkv   -c:v libx264 -preset veryfast -pix_fmt yuv420p -g 5 -c:a aac -b:a 32k
encode hevc_ac3.mkv   -c:v libx265 -preset veryfast -tag:v hvc1 -pix_fmt yuv420p -x265-params log-level=none -c:a ac3 -b:a 64k
encode vp9_opus.webm  -c:v libvpx-vp9 -deadline realtime -b:v 100k -c:a libopus -b:a 24k
encode av1_flac.mkv   -c:v libsvtav1 -preset 12 -pix_fmt yuv420p -c:a flac

ls -l "$out"
