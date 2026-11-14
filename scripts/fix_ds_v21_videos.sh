#!/usr/bin/env bash
# Fix LeRobot v2.1 episode videos that hold one frame more than their episode.
# Run by hand when scripts/convert_ds_v30_v21.sh reports
#   "episode N <camera>: L+1 video frames, length L".
# Cause: GR00T's v3->v2.1 converter cuts with ffmpeg stream copy; where a source file held several
# H.264 episodes, an episode can keep the next episode's first frame at its end. Only those videos
# are re-encoded (first L frames kept), so frame k still matches data row k. Other files are untouched.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
worker="${repo_root}/scripts/lerobot_v21_fix_videos.py"

usage() {
    cat <<'USAGE'
Usage: scripts/fix_ds_v21_videos.sh [--check-only] INPUT_DIR [OUTPUT_DIR]

  INPUT_DIR     LeRobot v2.1 dataset (folder with meta/info.json)
  OUTPUT_DIR    optional: copy INPUT_DIR here and fix the copy; INPUT_DIR stays unchanged.
                Must not exist yet. Without it, INPUT_DIR is fixed in place.
  --check-only  only report mismatches; change nothing

Only videos with exactly one trailing frame too many are re-encoded (H.264, CRF 18).
Any other mismatch is reported and left as is.
Exit code: 0 when every video matches its episode length, 1 otherwise.

Examples:
  scripts/fix_ds_v21_videos.sh --check-only /ds/ecm2027/ecm2027_sim_data_v21
  scripts/fix_ds_v21_videos.sh /ds/ecm2027/ecm2027_sim_data_v21
  scripts/fix_ds_v21_videos.sh /ds/ecm2027/converted_v21 /ds/ecm2027/converted_v21_fixed
USAGE
}

fail() {
    echo "$*" >&2
    exit 1
}

check_only=()
positional=()
for arg in "$@"; do
    case "${arg}" in
        -h|--help) usage; exit 0 ;;
        --check-only) check_only=(--check-only) ;;
        -*) echo "Unknown option: ${arg}" >&2; usage >&2; exit 2 ;;
        *) positional+=("${arg}") ;;
    esac
done
((${#positional[@]} == 1 || ${#positional[@]} == 2)) || { usage >&2; exit 2; }

input_dir="$(realpath -m "${positional[0]}")"
[[ -f "${input_dir}/meta/info.json" ]] || fail "Not a LeRobot dataset (no meta/info.json): ${input_dir}"
[[ -f "${worker}" ]] || fail "Missing ${worker}"

# The worker needs only the Python standard library, ffprobe and ffmpeg with libx264.
for cmd in python3 ffprobe ffmpeg; do
    command -v "${cmd}" >/dev/null 2>&1 || fail "Required command is missing: ${cmd}"
done
if ((${#check_only[@]} == 0)); then
    # Read the list first: with pipefail, grep -q closing the pipe early would fail ffmpeg.
    encoders="$(ffmpeg -hide_banner -encoders 2>/dev/null)"
    grep -q ' libx264 ' <<<"${encoders}" \
        || fail "ffmpeg has no libx264 encoder; install an ffmpeg build with libx264."
fi

target="${input_dir}"
if ((${#positional[@]} == 2)); then
    output_dir="$(realpath -m "${positional[1]}")"
    [[ -e "${output_dir}" ]] && fail "OUTPUT_DIR already exists: ${output_dir}"
    if ((${#check_only[@]} == 0)); then
        echo "Copying ${input_dir} -> ${output_dir}"
        mkdir -p "$(dirname "${output_dir}")"
        # A full copy (or copy-on-write where the filesystem supports it), never hard links:
        # later writes to the copy, such as GR00T's meta/stats.json, must not reach INPUT_DIR.
        cp -a --reflink=auto "${input_dir}" "${output_dir}"
        target="${output_dir}"
    fi
fi

echo "Checking ${target}"
exec python3 "${worker}" "${target}" "${check_only[@]}"
