#!/bin/sh
set -e

IMAGE="${IMAGE:-airdcpp-webclient-mod-xl}"

cd "$(dirname "$0")"

# Short form of the pinned daemon commit, read from the Dockerfile
DAEMON_REF="$(sed -nr 's/^ARG daemon_ref="([0-9a-f]+)".*/\1/p' Dockerfile)"
if [ -z "$DAEMON_REF" ]; then
  echo "ERROR: could not read daemon_ref from the Dockerfile"
  exit 1
fi

SHORT_REF="$(printf '%.8s' "$DAEMON_REF")"
TAG="${SHORT_REF}-$(date +%y%m%d-%H%M)"

echo "==> Daemon commit: ${DAEMON_REF}"
echo "==> Building:      ${IMAGE}:${TAG} (also :latest)"

# CACHEBUST only affects the final stage (package/Node.js install), so the slow daemon compile
# is reused from the Docker layer cache when the Dockerfile and patches haven't changed.
docker build \
  --build-arg CACHEBUST="$(date +%s)" \
  -t "${IMAGE}:${TAG}" \
  -t "${IMAGE}:latest" .

echo "==> Done. Built ${IMAGE}:${TAG} and ${IMAGE}:latest (not pushed)."
echo "    Run it with:  docker run ... ${IMAGE}:latest"
