#!/bin/bash
# Build and push NetBox container image to Quay.io
# Usage: ./build-and-push.sh <version> [quay_org]
# Example: ./build-and-push.sh v4.3.0 my-quay-org

set -euo pipefail

NETBOX_VERSION="${1:?Usage: $0 <netbox_version> [quay_org]}"
QUAY_ORG="${2:-your-quay-org}"

echo "🔧 Building NetBox ${NETBOX_VERSION} -> quay.io/${QUAY_ORG}/netbox"

# Clone if needed
if [ ! -d "netbox-docker" ]; then
  echo "📦 Cloning netbox-docker..."
  git clone https://github.com/netbox-community/netbox-docker.git
fi

cd netbox-docker

IMAGE_NAMES="quay.io/${QUAY_ORG}/netbox" \
  DOCKER_FROM=docker.io/ubuntu:24.04 \
  ./build.sh "${NETBOX_VERSION}" --push

echo "✅ Done! Image pushed to quay.io/${QUAY_ORG}/netbox:${NETBOX_VERSION}"
