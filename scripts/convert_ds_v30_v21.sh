#!/usr/bin/env bash
# Convert LeRobot v3.0 recordings into one LeRobot v2.1 dataset for GR00T fine-tuning.
# Runs on the host; no containers.
#   1. (optional) download the recordings from Hugging Face into SRC_DIR
#   2. find every recording zip under SRC_DIR, unzip, check they share one schema
#   3. merge them into one LeRobot v3.0 dataset          (lerobot, Python 3.12)
#   4. convert it to LeRobot v2.1                         (GR00T's converter, Python 3.11)
#   5. check every episode: parquet rows == video frames for each camera
# If the check fails, nothing is moved to OUT_DIR; the results stay in OUT_DIR.work.
# GR00T also needs meta/modality.json; that is written in a separate step.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
converter_dir="${repo_root}/third_party/Isaac-GR00T/scripts/lerobot_conversion"

HF_DATASET="${HF_DATASET:-rocochallenge2025/ecm2027_sim_data}"
HF_INCLUDE="${HF_INCLUDE:-Roco/batch2/*/galbot.zip}"
VENV_DIR="${VENV_DIR:-${repo_root}/.venvs}"
LEROBOT_VERSION="${LEROBOT_VERSION:-0.7.0}"
# Conversion needs no GPU; CPU torch keeps each environment around 1-2 GB instead of 6 GB.
export UV_TORCH_BACKEND="${UV_TORCH_BACKEND:-cpu}"

usage() {
    cat <<USAGE
Usage: scripts/convert_ds_v30_v21.sh [options] SRC_DIR OUT_DIR

Finds every LeRobot v3.0 recording zip under SRC_DIR, merges the recordings and
writes one LeRobot v2.1 dataset to OUT_DIR for GR00T fine-tuning.

  SRC_DIR   folder holding the downloaded dataset (searched recursively; not modified)
  OUT_DIR   folder for the v2.1 dataset; must not exist yet

Options:
  --download        first download the recordings from Hugging Face into SRC_DIR
  --zip-name NAME   file name of a recording zip            [galbot.zip]
  --path GLOB       only use zips whose path matches GLOB, e.g. '*/batch2/*'
  --keep-v3         also keep the merged v3.0 dataset as OUT_DIR_v3.0
  --keep-work       keep intermediate files in OUT_DIR.work
  -h, --help        show this help

Environment (defaults in brackets):
  HF_DATASET        dataset for --download                  [${HF_DATASET}]
  HF_INCLUDE        files fetched by --download             [${HF_INCLUDE}]
  HF_TOKEN          only needed if the dataset is gated
  VENV_DIR          host Python environments                [<repo>/.venvs]
  LEROBOT_VERSION   lerobot used for merging                [${LEROBOT_VERSION}]
  UV_TORCH_BACKEND  torch build for those environments      [cpu]

Examples:
  scripts/convert_ds_v30_v21.sh /ds/ecm2027/ecm2027_sim_data /ds/ecm2027/galbot_v21
  scripts/convert_ds_v30_v21.sh --path '*/batch2/*' ~/data/ecm2027_sim_data ~/data/galbot_v21
  scripts/convert_ds_v30_v21.sh --download ~/data/ecm2027_sim_data ~/data/galbot_v21
USAGE
}

fail() {
    echo "$*" >&2
    exit 1
}

step() {
    echo
    echo "==> $*"
}

download=false
keep_v3=false
keep_work=false
zip_name="galbot.zip"
path_glob="*"
positional=()
while (($# > 0)); do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --download) download=true ;;
        --keep-v3) keep_v3=true ;;
        --keep-work) keep_work=true ;;
        --zip-name) zip_name="${2:?--zip-name needs a value}"; shift ;;
        --path) path_glob="${2:?--path needs a value}"; shift ;;
        -*) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
        *) positional+=("$1") ;;
    esac
    shift
done
((${#positional[@]} == 2)) || { usage >&2; exit 2; }

src_dir="$(realpath -m "${positional[0]}")"
out_dir="$(realpath -m "${positional[1]}")"
[[ -e "${out_dir}" ]] && fail "OUT_DIR already exists: ${out_dir}. Remove it or choose another path."
[[ "${download}" == true || -d "${src_dir}" ]] || fail "SRC_DIR does not exist: ${src_dir}"

# The converter expects <root>/<repo_id>; it runs in a work folder next to OUT_DIR, so the
# final move is a rename on the same filesystem.
work_dir="${out_dir}.work"
name="$(basename "${out_dir}")"
repo_id="local/${name}"
parts_dir="${work_dir}/parts"
merged_dir="${work_dir}/local/${name}"
lerobot_venv="${VENV_DIR}/lerobot"
convert_venv="${VENV_DIR}/convert"

for cmd in uv git unzip ffmpeg ffprobe realpath; do
    command -v "${cmd}" >/dev/null 2>&1 || fail "Required command is missing: ${cmd}"
done
if [[ ! -f "${converter_dir}/convert_v3_to_v2.py" ]]; then
    GIT_LFS_SKIP_SMUDGE=1 git -C "${repo_root}" submodule update --init third_party/Isaac-GR00T
    [[ -f "${converter_dir}/convert_v3_to_v2.py" ]] || fail "GR00T converter not found in ${converter_dir}"
fi

# --- Python environments (created once, reused) ------------------------------------------
step "Python environments in ${VENV_DIR}"
if ! "${lerobot_venv}/bin/python" -c 'import lerobot, datasets' 2>/dev/null \
    || [[ ! -x "${lerobot_venv}/bin/lerobot-edit-dataset" || ! -x "${lerobot_venv}/bin/hf" ]]; then
    uv venv --clear --python 3.12 "${lerobot_venv}"
    uv pip install --python "${lerobot_venv}/bin/python" \
        "lerobot[dataset]==${LEROBOT_VERSION}" "huggingface_hub[cli]"
fi
if ! "${convert_venv}/bin/python" -c 'import lerobot, jsonlines, pyarrow' 2>/dev/null; then
    # The converter needs Python <3.12 and its own pinned lerobot commit (see its pyproject.toml).
    uv venv --clear --python 3.11 "${convert_venv}"
    GIT_LFS_SKIP_SMUDGE=1 uv pip install --python "${convert_venv}/bin/python" "${converter_dir}"
fi
echo "merge: lerobot $("${lerobot_venv}/bin/python" -c 'import lerobot; print(lerobot.__version__)')"
echo "convert: ${converter_dir#"${repo_root}/"}/convert_v3_to_v2.py"

# --- 1. Download (optional) --------------------------------------------------------------
if [[ "${download}" == true ]]; then
    step "Downloading ${HF_DATASET} (${HF_INCLUDE}) into ${src_dir}"
    "${lerobot_venv}/bin/hf" download "${HF_DATASET}" --repo-type dataset \
        --include "${HF_INCLUDE}" --local-dir "${src_dir}"
fi

# --- 2. Find, unzip and check ------------------------------------------------------------
step "Finding ${zip_name} under ${src_dir}"
mapfile -t zips < <(find "${src_dir}" -name "${zip_name}" -path "${path_glob}" \
    -not -path '*/.cache/*' -not -path '*/.git/*' | sort)
((${#zips[@]} > 0)) || fail "No ${zip_name} matching '${path_glob}' under ${src_dir}"
# A git clone without "git lfs pull" leaves small text pointer files instead of the zips.
for zip in "${zips[@]}"; do
    if head -c 40 "${zip}" | grep -q '^version https://git-lfs'; then
        fail "${zip} is a Git LFS pointer, not the zip. Fetch the files first, e.g.:
  git -C ${src_dir} lfs pull --include \"*/${zip_name}\""
    fi
done
printf '  %s\n' "${zips[@]#"${src_dir}/"}"
echo "${#zips[@]} recordings"

rm -rf "${work_dir}"
mkdir -p "${parts_dir}"
# Recordings are named after the folder holding their zip; numbered to keep them unique.
for i in "${!zips[@]}"; do
    unzip -q "${zips[i]}" -d "$(printf '%s/%03d_%s' "${parts_dir}" "${i}" "$(basename "$(dirname "${zips[i]}")")")"
done
# Each zip holds a dataset folder (galbot/ for the Roco data); its root has meta/info.json.
mapfile -t part_roots < <(find "${parts_dir}" -path '*/meta/info.json' | sed 's|/meta/info.json$||' | sort)
((${#part_roots[@]} == ${#zips[@]})) \
    || fail "Expected ${#zips[@]} datasets after unzipping, found ${#part_roots[@]}"

step "Checking that all recordings share one schema"
"${lerobot_venv}/bin/python" - "${parts_dir}" "${part_roots[@]}" <<'PY'
import json, sys
from pathlib import Path

parts = Path(sys.argv[1])

def schema(info):
    feats = {k: (v["dtype"], tuple(v["shape"])) for k, v in info["features"].items()}
    return info["codebase_version"], info["fps"], info.get("robot_type"), feats

reference, total = None, 0
for root in map(Path, sys.argv[2:]):
    info = json.loads((root / "meta/info.json").read_text())
    if info["codebase_version"] != "v3.0":
        sys.exit(f"{root} is {info['codebase_version']}, expected v3.0")
    total += info["total_frames"]
    print(f"  {root.relative_to(parts).parts[0]}: episodes={info['total_episodes']} frames={info['total_frames']}")
    current = schema(info)
    if reference is None:
        reference = current
    elif current != reference:
        sys.exit(f"Schema differs in {root}:\n  {current}\nvs\n  {reference}")
version, fps, robot, feats = reference
print(f"  schema: {version}, {fps} fps, robot_type={robot}")
for name, (dtype, shape) in sorted(feats.items()):
    if not name.endswith("index") and name != "timestamp":
        print(f"    {name}: {dtype} {list(shape)}")
print(f"  total: {len(sys.argv) - 2} recordings, {total} frames ({total / fps / 60:.1f} min)")
PY

# --- 3. Merge ----------------------------------------------------------------------------
step "Merging into one LeRobot v3.0 dataset"
mkdir -p "$(dirname "${merged_dir}")"
repo_ids="$("${lerobot_venv}/bin/python" -c 'import json, sys; print(json.dumps([f"local/part_{i:03d}" for i in range(len(sys.argv) - 1)]))' "${part_roots[@]}")"
roots="$("${lerobot_venv}/bin/python" -c 'import json, sys; print(json.dumps(sys.argv[1:]))' "${part_roots[@]}")"
# One video and data file per recording: the converter cuts videos with ffmpeg stream copy,
# which is only frame-exact when no cut falls inside a file.
HF_HUB_OFFLINE=1 "${lerobot_venv}/bin/lerobot-edit-dataset" \
    --new_repo_id "${repo_id}" \
    --new_root "${merged_dir}" \
    --operation.type merge \
    --operation.repo_ids "${repo_ids}" \
    --operation.roots "${roots}" \
    --operation.concatenate_videos false \
    --operation.concatenate_data false
rm -rf "${parts_dir}"

# --- 4. Convert v3.0 -> v2.1 -------------------------------------------------------------
step "Converting to LeRobot v2.1"
# In place: ${merged_dir} becomes v2.1 and the v3.0 dataset moves to ${merged_dir}_v3.0.
HF_HUB_OFFLINE=1 "${convert_venv}/bin/python" "${converter_dir}/convert_v3_to_v2.py" \
    --repo-id "${repo_id}" --root "${work_dir}"

# --- 5. Verify ---------------------------------------------------------------------------
step "Verifying"
verify_ok=true
"${lerobot_venv}/bin/python" - "${merged_dir}" <<'PY' || verify_ok=false
import json, subprocess, sys
from pathlib import Path
import pyarrow.parquet as pq

root = Path(sys.argv[1])
info = json.loads((root / "meta/info.json").read_text())
if info["codebase_version"] != "v2.1":
    sys.exit(f"Expected v2.1, found {info['codebase_version']}")
episodes = [json.loads(line) for line in (root / "meta/episodes.jsonl").read_text().splitlines() if line]
tasks = [json.loads(line)["task"] for line in (root / "meta/tasks.jsonl").read_text().splitlines() if line]
video_keys = [k for k, v in info["features"].items() if v["dtype"] == "video"]
chunk = info["chunks_size"]

def video_frames(path):
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "v:0", "-count_packets",
         "-show_entries", "stream=nb_read_packets", "-of", "csv=p=0", str(path)],
        check=True, capture_output=True, text=True).stdout.strip()
    return int(out)

problems = []
for ep in episodes:
    idx, length = ep["episode_index"], ep["length"]
    data = root / info["data_path"].format(episode_chunk=idx // chunk, episode_index=idx)
    rows = pq.read_metadata(data).num_rows
    if rows != length:
        problems.append(f"episode {idx}: {rows} parquet rows, length {length}")
    for key in video_keys:
        video = root / info["video_path"].format(episode_chunk=idx // chunk, video_key=key, episode_index=idx)
        frames = video_frames(video)
        if frames != length:
            problems.append(f"episode {idx} {key}: {frames} video frames, length {length}")

print(f"  {info['codebase_version']}: {len(episodes)} episodes, {info['total_frames']} frames, "
      f"{len(video_keys)} cameras")
print(f"  tasks: {tasks}")
if problems:
    print("\n".join("  " + p for p in problems))
    sys.exit(f"{len(problems)} mismatches between data and video")
print("  every episode: parquet rows == video frames for every camera")
PY
if [[ "${verify_ok}" == false ]]; then
    fail "
Verification failed; nothing was moved to ${out_dir}.
The converted v2.1 dataset is in ${merged_dir}
and the merged v3.0 dataset in ${merged_dir}_v3.0."
fi

# --- Move results into place -------------------------------------------------------------
mkdir -p "$(dirname "${out_dir}")"
mv "${merged_dir}" "${out_dir}"
if [[ "${keep_v3}" == true ]]; then
    rm -rf "${out_dir}_v3.0"
    mv "${merged_dir}_v3.0" "${out_dir}_v3.0"
fi
[[ "${keep_work}" == true ]] || rm -rf "${work_dir}"

step "Done"
du -sh "${out_dir}"
if [[ "${keep_v3}" == true ]]; then
    du -sh "${out_dir}_v3.0"
fi
echo
echo "LeRobot v2.1 dataset: ${out_dir}"
echo "GR00T also needs meta/modality.json in it before fine-tuning."
