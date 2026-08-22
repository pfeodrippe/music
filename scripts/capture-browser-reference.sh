#!/bin/sh
set -eu

usage() {
    cat <<'EOF'
usage: scripts/capture-browser-reference.sh OUTPUT.wav [options]

Capture authorized browser/app playback through BlackHole and analyze it.

Options:
  --duration SECONDS    Capture length (default: 60)
  --settle SECONDS      Allow apps to follow the device change (default: 3)
  --device NAME         Loopback device (default: BlackHole 16ch)
  --score PATH          Compare against a MusicXML or MXL score
  --report PATH         Analysis JSON path (default: OUTPUT.analysis.json)
  --no-analyze          Capture only

Start playback immediately after this command reports "CAPTURE READY".
The previous macOS output device is restored on success, failure, or interruption.
Only capture material you are authorized to analyze; keep private references ignored.
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi

if [ "$#" -lt 1 ]; then
    usage >&2
    exit 2
fi

output_path=$1
shift
duration=60
settle=3
capture_device='BlackHole 16ch'
score_path=
report_path=
analyze=1

while [ "$#" -gt 0 ]; do
    case "$1" in
        --duration)
            [ "$#" -ge 2 ] || { usage >&2; exit 2; }
            duration=$2
            shift 2
            ;;
        --device)
            [ "$#" -ge 2 ] || { usage >&2; exit 2; }
            capture_device=$2
            shift 2
            ;;
        --settle)
            [ "$#" -ge 2 ] || { usage >&2; exit 2; }
            settle=$2
            shift 2
            ;;
        --score)
            [ "$#" -ge 2 ] || { usage >&2; exit 2; }
            score_path=$2
            shift 2
            ;;
        --report)
            [ "$#" -ge 2 ] || { usage >&2; exit 2; }
            report_path=$2
            shift 2
            ;;
        --no-analyze)
            analyze=0
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf 'unknown option: %s\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

case "$duration" in
    ''|*[!0-9.]*)
        printf 'duration must be a positive number: %s\n' "$duration" >&2
        exit 2
        ;;
esac
case "$settle" in
    ''|*[!0-9.]*)
        printf 'settle must be a non-negative number: %s\n' "$settle" >&2
        exit 2
        ;;
esac

if [ -e "$output_path" ]; then
    printf 'refusing to overwrite existing capture: %s\n' "$output_path" >&2
    exit 2
fi

command -v ffmpeg >/dev/null 2>&1 || {
    printf 'ffmpeg is required for loopback capture\n' >&2
    exit 3
}
command -v clang >/dev/null 2>&1 || {
    printf 'clang is required to build the CoreAudio device helper\n' >&2
    exit 3
}

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
tool_dir="$project_dir/.zig-cache/reference-tools"
device_tool="$tool_dir/audio-device"
mkdir -p "$tool_dir" "$(dirname -- "$output_path")"

if [ ! -x "$device_tool" ] || [ "$script_dir/audio-device.c" -nt "$device_tool" ]; then
    clang -O2 -Wall -Wextra -framework CoreAudio -framework CoreFoundation \
        "$script_dir/audio-device.c" -o "$device_tool"
fi

original_output=$($device_tool get) || {
    printf 'could not read the current macOS output device\n' >&2
    exit 4
}

restore_output() {
    if [ -n "${original_output:-}" ]; then
        "$device_tool" set "$original_output" >/dev/null 2>&1 || \
            printf 'warning: could not restore output device %s\n' "$original_output" >&2
    fi
}
trap restore_output EXIT HUP INT TERM

device_listing=$(ffmpeg -hide_banner -f avfoundation -list_devices true -i '' 2>&1 || true)
capture_index=$(printf '%s\n' "$device_listing" | awk -v wanted="$capture_device" '
    /AVFoundation audio devices:/ { audio = 1; next }
    audio {
        name = $0
        sub(/^.*\[[0-9][0-9]*\] /, "", name)
        if (name == wanted && match($0, /\[[0-9][0-9]*\]/)) {
            print substr($0, RSTART + 1, RLENGTH - 2)
            exit
        }
    }
')
if [ -z "$capture_index" ]; then
    printf 'AVFoundation input not found for %s\n' "$capture_device" >&2
    printf '%s\n' "$device_listing" >&2
    exit 4
fi

printf 'Original output: %s\n' "$original_output"
printf 'Loopback input: %s (AVFoundation audio %s)\n' "$capture_device" "$capture_index"
"$device_tool" set "$capture_device"
printf 'Waiting %s seconds for audio applications to follow the output change...\n' "$settle"
sleep "$settle"
printf 'CAPTURE READY — start authorized playback now (%s seconds)\n' "$duration"

ffmpeg -hide_banner -loglevel warning \
    -f avfoundation -i ":$capture_index" \
    -t "$duration" \
    -filter_complex '[0:a]pan=stereo|c0=c0|c1=c1[a]' \
    -map '[a]' -ar 44100 -c:a pcm_s24le "$output_path"

restore_output
trap - EXIT HUP INT TERM
printf 'Restored output: %s\n' "$original_output"
printf 'Captured: %s\n' "$output_path"

peak_db=$(ffmpeg -hide_banner -i "$output_path" -af volumedetect -f null - 2>&1 | awk '/max_volume:/ { print $(NF - 1); exit }')
if [ -z "$peak_db" ] || awk -v peak="$peak_db" 'BEGIN { exit !(peak <= -80) }'; then
    printf 'capture contains no usable audio (peak %s dB); keep the file for diagnosis and retry after playback is visibly running\n' "${peak_db:-unknown}" >&2
    exit 5
fi
printf 'Capture peak: %s dB\n' "$peak_db"

if [ "$analyze" -eq 0 ]; then
    exit 0
fi

if [ -z "$report_path" ]; then
    case "$output_path" in
        *.wav) report_path=${output_path%.wav}.analysis.json ;;
        *) report_path=$output_path.analysis.json ;;
    esac
fi
mkdir -p "$(dirname -- "$report_path")"

set -- "$output_path"
if [ -n "$score_path" ]; then
    set -- "$@" --score "$score_path"
fi
set -- "$@" --output "$report_path"

(cd "$project_dir" && zig build audio-analyze -Doptimize=ReleaseFast -- "$@")
printf 'Analysis: %s\n' "$report_path"
