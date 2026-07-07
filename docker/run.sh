#!/usr/bin/env bash
# Launch the testbox on Linux/macOS. Builds the image on first use, mounts
# this repo checkout, a persistent /work dir for notes, and any cloud
# credential directories found on the host.
#
# Usage: docker/run.sh [--rebuild] [-- <command to run instead of a shell>]
#
# Manual fallback (if this script misbehaves) — the equivalent commands:
#   docker build -t master-ring-testbox docker/
#   docker run -it --rm -v "$(pwd)":/work/repo -v "$HOME/testbox-work":/work \
#     -v "$HOME/.aws":/root/.aws master-ring-testbox
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
IMAGE=master-ring-testbox

command -v docker >/dev/null || { echo "docker not found on PATH" >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "docker daemon not reachable (is it running? do you need sudo?)" >&2; exit 1; }

REBUILD=false
if [[ "${1:-}" == "--rebuild" ]]; then
    REBUILD=true
    shift
fi
if $REBUILD || ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    docker build -t "$IMAGE" "$SCRIPT_DIR"
fi

WORK_DIR="${TESTBOX_WORK_DIR:-$HOME/testbox-work}"
mkdir -p "$WORK_DIR"

MOUNTS=(-v "$WORK_DIR":/work -v "$REPO_ROOT":/work/repo)
for cred in "$HOME/.aws:/root/.aws" "$HOME/.azure:/root/.azure" "$HOME/.config/gcloud:/root/.config/gcloud"; do
    [ -d "${cred%%:*}" ] && MOUNTS+=(-v "$cred")
done

exec docker run -it --rm \
    "${MOUNTS[@]}" \
    -e GH_TOKEN -e HTTP_PROXY -e HTTPS_PROXY -e NO_PROXY \
    -e ANSIBLE_USER -e ANSIBLE_PASSWORD -e ANSIBLE_VAULT_PASSWORD_FILE \
    "$IMAGE" "$@"
