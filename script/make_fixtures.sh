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

# Containers AVFoundation reads, for QuickPeekInfo: metadata, HDR signalling, lossless and MP3 audio.
hdr="-c:v libx265 -preset veryfast -pix_fmt yuv420p10le -x265-params log-level=none:hdr10=1:repeat-headers=1:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1):max-cll=1000,400 \
     -vf setparams=color_primaries=bt2020:color_trc=smpte2084:colorspace=bt2020nc -color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc"
encode h264_aac.mp4   -c:v libx264 -preset veryfast -profile:v high -pix_fmt yuv420p -c:a aac -b:a 64k -ac 2 \
                      -metadata title="QuickPeek Sample" -metadata artist="QuickPeek Tests" -movflags +faststart
# shellcheck disable=SC2086
encode hdr10.mp4      $hdr -tag:v hvc1 -movflags +write_colr -an
# shellcheck disable=SC2086
encode hdr10.mkv      $hdr -an
ffmpeg -v error -y -f lavfi -i "$audio" -t 1 -map_metadata -1 -fflags +bitexact -c:a alac "$out/lossless.m4a"
ffmpeg -v error -y -f lavfi -i "$audio" -t 1 -map_metadata -1 -fflags +bitexact -c:a libmp3lame -b:a 128k -ac 2 "$out/song.mp3"

ls -l "$out"
