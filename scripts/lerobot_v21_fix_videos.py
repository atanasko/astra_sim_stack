"""Make every video in a LeRobot v2.1 dataset hold exactly as many frames as its episode.

GR00T's v3->v2.1 converter cuts videos with ffmpeg stream copy. When a source file holds
several episodes encoded with B-frames (H.264), the cut can leave one extra frame at the end
of an episode: the first frame of the next episode. This script finds those videos and
re-encodes just them, keeping the first <length> frames, so frame k still matches row k.

Usage: python lerobot_v21_fix_videos.py DATASET_DIR [--check-only]
Exit code: 0 when every video matches, 1 when mismatches remain.
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path


def packet_count(path: Path) -> int:
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "v:0", "-count_packets",
         "-show_entries", "stream=nb_read_packets", "-of", "csv=p=0", str(path)],
        check=True, capture_output=True, text=True,
    ).stdout.strip()
    return int(out)


def trim(path: Path, frames: int) -> None:
    """Re-encode path keeping its first `frames` frames, in display order."""
    tmp = path.with_suffix(".fixing.mp4")
    subprocess.run(
        ["ffmpeg", "-v", "error", "-y", "-i", str(path), "-map", "0:v:0",
         "-frames:v", str(frames), "-c:v", "libx264", "-crf", "18", "-preset", "medium",
         "-pix_fmt", "yuv420p", "-movflags", "+faststart", str(tmp)],
        check=True,
    )
    if packet_count(tmp) != frames:
        tmp.unlink()
        raise RuntimeError(f"re-encoding {path} did not give {frames} frames")
    shutil.move(tmp, path)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("dataset", type=Path)
    parser.add_argument("--check-only", action="store_true", help="report, do not change files")
    args = parser.parse_args()

    root = args.dataset
    info = json.loads((root / "meta/info.json").read_text())
    if info["codebase_version"] != "v2.1":
        sys.exit(f"{root} is {info['codebase_version']}, expected v2.1")
    chunk = info["chunks_size"]
    video_keys = [k for k, v in info["features"].items() if v["dtype"] == "video"]
    episodes = [json.loads(line) for line in (root / "meta/episodes.jsonl").read_text().splitlines() if line]

    fixed, remaining = [], []
    for ep in episodes:
        idx, length = ep["episode_index"], ep["length"]
        for key in video_keys:
            video = root / info["video_path"].format(episode_chunk=idx // chunk, video_key=key, episode_index=idx)
            count = packet_count(video)
            if count == length:
                continue
            # Only the known converter artefact is repaired: exactly one trailing frame too many.
            if count == length + 1 and not args.check_only:
                trim(video, length)
                fixed.append(f"episode {idx} {key}: {count} -> {length} frames")
            else:
                remaining.append(f"episode {idx} {key}: {count} video frames, length {length}")

    for line in fixed:
        print(f"  fixed {line}")
    for line in remaining:
        print(f"  MISMATCH {line}")
    print(f"  {len(episodes)} episodes x {len(video_keys)} cameras checked, "
          f"{len(fixed)} videos fixed, {len(remaining)} mismatches")
    return 1 if remaining else 0


if __name__ == "__main__":
    sys.exit(main())
