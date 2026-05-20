#!/bin/bash
# Build and push NetBox container image using Ubuntu 24.04 as the base.
#
# The upstream netbox-docker Dockerfile uses libxmlsec1 package names
# from older Ubuntu releases that were renamed in 24.04. This script
# patches the Dockerfile before building so it works with 24.04.
#
# Usage: ./build-and-push-24.04.sh <version> [registry_org] [registry]
# Example: ./build-and-push-24.04.sh 4.3.0 my-quay-org mirror.example.com:8443
#
# Prerequisites:
#   - podman installed (podman build/push)
#   - Logged in to registry (podman login $REGISTRY)

set -euo pipefail

NETBOX_VERSION="${1:?Usage: $0 <netbox_version> [registry_org] [registry]}"
REGISTRY_ORG="${2:-your-registry-org}"
REGISTRY="${3:-quay.io}"
BASE_IMAGE="${BASE_IMAGE:-docker.io/ubuntu:24.04}"

IMAGE="${REGISTRY}/${REGISTRY_ORG}/netbox:${NETBOX_VERSION}"

echo "🔧 Building NetBox ${NETBOX_VERSION} (Ubuntu 24.04) -> ${IMAGE}"

# Clone netbox-docker if needed
if [ ! -d "netbox-docker" ]; then
  echo "📦 Cloning netbox-docker..."
  git clone https://github.com/netbox-community/netbox-docker.git
fi

cd netbox-docker

# Checkout the tag/branch
git fetch --tags
git checkout "${NETBOX_VERSION}"

# Clone the actual NetBox source code into .netbox directory
# The Dockerfile expects NETBOX_PATH to point to the NetBox source
if [ ! -d ".netbox" ]; then
  echo "📦 Cloning NetBox source code..."
  git clone --depth 1 --branch "${NETBOX_VERSION}" \
    https://github.com/netbox-community/netbox.git .netbox
fi

# Patch the Dockerfile for Ubuntu 24.04 compatibility
# libxmlsec1-1 -> libxmlsec1t64
# libxmlsec1-openssl1 -> libxmlsec1-openssl
echo "🔨 Patching Dockerfile for Ubuntu 24.04..."
sed -i \
  -e 's/libxmlsec1-1\b/libxmlsec1t64/g' \
  -e 's/libxmlsec1-openssl1\b/libxmlsec1-openssl/g' \
  Dockerfile

echo "   libxmlsec1-1       → libxmlsec1t64"
echo "   libxmlsec1-openssl1 → libxmlsec1-openssl"

# Verify the patch took effect
if grep -q "libxmlsec1-1" Dockerfile; then
  echo "❌ Patch failed! libxmlsec1-1 still present in Dockerfile"
  exit 1
fi

# Build with podman
echo "🏗 Building image with podman..."
podman build \
  --pull \
  --target main \
  -f Dockerfile \
  -t "${IMAGE}" \
  --build-arg "FROM=${BASE_IMAGE}" \
  --build-arg "NETBOX_PATH=.netbox" \
  --label "org.opencontainers.image.version=${NETBOX_VERSION}" \
  --label "org.opencontainers.image.created=$(date -u '+%Y-%m-%dT%H:%M:%S+00:00')" \
  .

echo "📤 Pushing to ${REGISTRY}..."
podman push "${IMAGE}"

echo "✅ Done! Image pushed to ${IMAGE}"
