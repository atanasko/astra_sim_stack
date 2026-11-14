#!/usr/bin/env bash
# Run astra/gr00t in one mode: check, train, openloop, serve, or an interactive shell.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
    cat <<'USAGE'
Usage: scripts/run_gr00t.sh MODE [ARGS...]

Modes (ARGS are passed through to the GR00T script behind each mode):
  check     load a prepared dataset with config/gr00t/galbot_config.py and write its stats
  train     fine-tune GR00T N1.7 (gr00t/experiment/launch_finetune.py)
  openloop  compare predicted and recorded actions (gr00t/eval/open_loop_eval.py)
  serve     policy server on 127.0.0.1:5555 for the policy container (gr00t/eval/run_gr00t_server.py)
  shell     bash inside the image, same mounts

Host data directory, mounted at /data:
  datasets/ checkpoints/ hf_cache/ eval_result/
Paths in ARGS are container paths, e.g. --dataset-path /data/datasets/galbot_v21.

Environment:
  GR00T_DATA       host data directory (default: <repo>/data)
  GR00T_GPUS       value for docker --gpus (default: all; e.g. '"device=0"')
  HF_TOKEN         Hugging Face token; the Cosmos-Reason2-2B backbone is gated.
                   Required by train, openloop and serve unless HF_HUB_OFFLINE=1
                   and the models are already in hf_cache/.
  HF_HUB_OFFLINE   set to 1 to use hf_cache/ only
  WANDB_API_KEY    passed through for train --use-wandb

Examples:
  scripts/run_gr00t.sh check    --dataset-path /data/datasets/galbot_v21
  scripts/run_gr00t.sh train    --dataset-path /data/datasets/galbot_v21 --output-dir /data/checkpoints/run1
  scripts/run_gr00t.sh openloop --dataset-path /data/datasets/galbot_v21 --model-path /data/checkpoints/run1/checkpoint-20000
  scripts/run_gr00t.sh serve    --model-path /data/checkpoints/run1/checkpoint-20000
USAGE
}

fail() {
    echo "$*" >&2
    exit 1
}

mode="${1:-}"
case "${mode}" in
    -h|--help|"") usage; [[ -n "${mode}" ]] && exit 0 || exit 2 ;;
    check|train|openloop|serve|shell) shift ;;
    *) echo "Unknown mode: ${mode}" >&2; usage >&2; exit 2 ;;
esac

# shellcheck source=docker/versions.env
source "${repo_root}/docker/versions.env"
: "${GR00T_IMAGE:?GR00T_IMAGE is not set in docker/versions.env}"

command -v docker >/dev/null 2>&1 || fail "Required command is missing: docker"
docker info >/dev/null 2>&1 || fail "Cannot reach the Docker daemon. Start Docker and check socket access."
docker info --format '{{json .Runtimes}}' | grep -q '"nvidia"' \
    || fail "Docker does not expose the NVIDIA runtime. Install and configure NVIDIA Container Toolkit."
docker image inspect "${GR00T_IMAGE}" >/dev/null 2>&1 \
    || fail "${GR00T_IMAGE} is not built. Run scripts/build_gr00t.sh first."

case "${mode}" in
    train|openloop|serve)
        if [[ -z "${HF_TOKEN:-}" && "${HF_HUB_OFFLINE:-0}" != "1" ]]; then
            fail "HF_TOKEN is not set. GR00T loads the gated nvidia/Cosmos-Reason2-2B backbone.
Export a token with access, or set HF_HUB_OFFLINE=1 if the models are already in hf_cache/."
        fi
        ;;
esac

# The container runs as uid 1000, like the sim and policy containers, and writes here.
data_dir="${GR00T_DATA:-${repo_root}/data}"
mkdir -p "${data_dir}"/{datasets,checkpoints,hf_cache,eval_result}
data_dir="$(realpath "${data_dir}")"
if [[ "$(id -u)" != "1000" ]]; then
    echo "Warning: host uid is $(id -u); the container writes to ${data_dir} as uid 1000." >&2
fi

run_args=(
    --rm
    --gpus "${GR00T_GPUS:-all}"
    --ipc=host
    --ulimit memlock=-1
    --ulimit stack=67108864
    --user 1000:1000
    -e HF_TOKEN
    -e HF_HUB_OFFLINE
    -e WANDB_API_KEY
    -v "${data_dir}:/data"
    # Mounted read-only so config edits need no rebuild; the image holds a copy as a fallback.
    -v "${repo_root}/config/gr00t:/workspace/config:ro"
)
[[ -t 0 && -t 1 ]] && run_args+=(-it)

case "${mode}" in
    serve)
        # Host network, like the sim and policy containers: the policy client reaches 127.0.0.1:5555.
        docker ps --quiet --filter name='^astra-gr00t-serve$' | grep -q . \
            && fail "A GR00T server is already running (container astra-gr00t-serve). Stop it with: docker stop astra-gr00t-serve"
        run_args+=(--network host --name astra-gr00t-serve)
        ;;
    shell)
        exec docker run "${run_args[@]}" --entrypoint bash "${GR00T_IMAGE}" "$@"
        ;;
esac

exec docker run "${run_args[@]}" "${GR00T_IMAGE}" "${mode}" "$@"
