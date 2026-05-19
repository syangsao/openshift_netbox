#!/bin/bash
# Build and push NetBox container image to Quay.io using Podman
# Usage: ./build-and-push.sh <version> [quay_org]
# Example: ./build-and-push.sh 4.3.0 my-quay-org
#
# Prerequisites:
#   - podman installed (podman build/push)
#   - Logged in to Quay.io (podman login quay.io)

set -euo pipefail

NETBOX_VERSION="${1:?Usage: $0 <netbox_version> [quay_org]}"
QUAY_ORG="${2:-your-quay-org}"

IMAGE="quay.io/${QUAY_ORG}/netbox:${NETBOX_VERSION}"

echo "🔧 Building NetBox ${NETBOX_VERSION} -> ${IMAGE}"

# Clone if needed
if [ ! -d "netbox-docker" ]; then
  echo "📦 Cloning netbox-docker..."
  git clone https://github.com/netbox-community/netbox-docker.git
fi

cd netbox-docker

# Checkout the tag/branch
git fetch --tags
git checkout "${NETBOX_VERSION}"

# Build with podman (podman is docker-compatible for build commands)
echo "🏗 Building image with podman..."
podman build \
  --pull \
  --target main \
  -f Dockerfile \
  -t "${IMAGE}" \
  --build-arg "FROM=docker.io/ubuntu:24.04" \
  --build-arg "NETBOX_PATH=.netbox" \
  --label "org.opencontainers.image.version=${NETBOX_VERSION}" \
  --label "org.opencontainers.image.created=$(date -u '+%Y-%m-%dT%H:%M:%S+00:00')" \
  .

echo "📤 Pushing to Quay.io..."
podman push "${IMAGE}"

echo "✅ Done! Image pushed to ${IMAGE}"
