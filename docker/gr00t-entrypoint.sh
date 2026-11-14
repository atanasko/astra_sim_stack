#!/usr/bin/env bash
set -euo pipefail
CFG=/workspace/galbot/galbot_config.py
cd /workspace/Isaac-GR00T
mode="${1:---help}"; shift || true

case "$mode" in
  train)
    exec python gr00t/experiment/launch_finetune.py \
      --base-model-path nvidia/GR00T-N1.7-3B \
      --embodiment-tag NEW_EMBODIMENT --modality-config-path "$CFG" "$@" ;;
  openloop)
    exec python gr00t/eval/open_loop_eval.py \
      --embodiment-tag NEW_EMBODIMENT "$@" ;;
  serve)
    exec python gr00t/eval/run_gr00t_server.py \
      --embodiment-tag NEW_EMBODIMENT --host 0.0.0.0 --port 5555 "$@" ;;
  check)
    exec python /workspace/galbot/check_dataset.py --modality-config-path "$CFG" "$@" ;;
  *)
    echo "usage: astra/gr00t {train|openloop|serve|check} [args...]"; exit 0 ;;
esac
