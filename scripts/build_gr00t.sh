#!/usr/bin/env bash
# Build astra/gr00t: GR00T N1.7 fine-tuning, open-loop eval and policy server. No Isaac.
# Safe to rerun; the dependency layer is reused until the submodule's uv.lock changes.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
gr00t_root="${repo_root}/third_party/Isaac-GR00T"
dockerfile="${repo_root}/docker/gr00t.Dockerfile"

# shellcheck source=docker/versions.env
source "${repo_root}/docker/versions.env"

fail() {
    echo "$*" >&2
    exit 1
}

usage() {
    cat <<'USAGE'
Usage: scripts/build_gr00t.sh [--no-cache]

Builds the GR00T image named by GR00T_IMAGE in docker/versions.env from
docker/gr00t.Dockerfile, using third_party/Isaac-GR00T at GR00T_COMMIT.
--no-cache rebuilds every layer, including the dependency install.
USAGE
}

build_args=()
case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    --no-cache) build_args+=(--no-cache) ;;
    "") ;;
    *) usage >&2; exit 2 ;;
esac

: "${GR00T_IMAGE:?GR00T_IMAGE is not set in docker/versions.env}"
: "${GR00T_COMMIT:?GR00T_COMMIT is not set in docker/versions.env}"

command -v docker >/dev/null 2>&1 || fail "Required command is missing: docker"
command -v git >/dev/null 2>&1 || fail "Required command is missing: git"
docker info >/dev/null 2>&1 || fail "Cannot reach the Docker daemon. Start Docker and check socket access."
docker buildx version >/dev/null 2>&1 || fail "Docker Buildx is required."

# Files the Dockerfile copies; checked here so a missing one fails before a long build starts.
for required in \
    "${dockerfile}" \
    "${repo_root}/docker/gr00t-entrypoint.sh" \
    "${repo_root}/config/gr00t/galbot_config.py"; do
    [[ -f "${required}" ]] || fail "Missing ${required#"${repo_root}/"}"
done

# .dockerignore excludes everything not listed; without these the COPY steps find nothing.
for pattern in '!third_party/Isaac-GR00T/' '!config/'; do
    grep -qxF -- "${pattern}" "${repo_root}/.dockerignore" \
        || fail ".dockerignore must contain the line: ${pattern}"
done

# Source only; GR00T's LFS demo data is not needed in the image.
GIT_LFS_SKIP_SMUDGE=1 git -C "${repo_root}" submodule update --init third_party/Isaac-GR00T

# The image installs dependencies from this checkout's uv.lock and copies its source,
# so the checkout must be exactly the pinned commit.
actual_commit="$(git -C "${gr00t_root}" rev-parse HEAD)"
[[ "${actual_commit}" == "${GR00T_COMMIT}" ]] || fail \
    "third_party/Isaac-GR00T is at ${actual_commit}, but versions.env pins ${GR00T_COMMIT}.
Check out the pinned commit, or update GR00T_COMMIT and commit the submodule change."

if [[ -n "$(git -C "${gr00t_root}" status --porcelain)" ]]; then
    echo "Warning: third_party/Isaac-GR00T has local changes; they will be built into the image." >&2
fi

docker build \
    "${build_args[@]}" \
    --file "${dockerfile}" \
    --tag "${GR00T_IMAGE}" \
    --label "org.opencontainers.image.revision=${GR00T_COMMIT}" \
    "${repo_root}"

echo "Built ${GR00T_IMAGE} (Isaac-GR00T ${GR00T_COMMIT:0:7})."
