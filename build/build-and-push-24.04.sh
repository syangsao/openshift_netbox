#!/bin/bash
# Build and push NetBox container image using Ubuntu 24.04 as the base.
#
# The upstream netbox-docker Dockerfile uses libxmlsec1 package names
# that don't exist on any modern Ubuntu version (22.04, 24.04) — they were
# renamed to libxmlsec1t64 and libxmlsec1-openssl due to the libc6 t64 transition.
# This script auto-patches the Dockerfile and clones the NetBox source code.
#
# Usage: ./build-and-push-24.04.sh <netbox_version> [registry_org] [registry]
# Example: ./build-and-push-24.04.sh 4.3.0 my-quay-org quay.io
#
# Prerequisites:
#   - podman installed (podman build/push)
#   - Logged in to registry (podman login $REGISTRY)

set -euo pipefail

NETBOX_VERSION="${1:?Usage: $0 <netbox_version> [registry_org] [registry]}"
REGISTRY_ORG="${2:-your-registry-org}"
REGISTRY="${3:-quay.io}"
BASE_IMAGE="${BASE_IMAGE:-docker.io/ubuntu:24.04}"
# Override NetBox source tag (netbox-docker version ≠ netbox source version)
NETBOX_SRC_VERSION="${NETBOX_SRC_VERSION:-${NETBOX_VERSION}}"

IMAGE="${REGISTRY}/${REGISTRY_ORG}/netbox:${NETBOX_VERSION}"

echo "🔧 Building NetBox ${NETBOX_VERSION} (Ubuntu 24.04) -> ${IMAGE}"

# Clone netbox-docker if needed
if [ ! -d "netbox-docker" ]; then
  echo "📦 Cloning netbox-docker..."
  git clone https://github.com/netbox-community/netbox-docker.git
fi

cd netbox-docker

# Checkout the netbox-docker tag/branch
git fetch --tags
git checkout "${NETBOX_VERSION}"

# Clone the actual NetBox source code into .netbox directory
# The Dockerfile expects NETBOX_PATH to point to the NetBox source
if [ ! -d ".netbox" ]; then
  echo "📦 Cloning NetBox source code (tag: ${NETBOX_SRC_VERSION})..."

  # Try exact tag, then v-prefixed tag, then fall back to latest
  if git ls-remote --exit-code --tags https://github.com/netbox-community/netbox.git "refs/tags/${NETBOX_SRC_VERSION}" >/dev/null 2>&1; then
    echo "   Found tag ${NETBOX_SRC_VERSION}"
    git clone --depth 1 --branch "${NETBOX_SRC_VERSION}" \
      https://github.com/netbox-community/netbox.git .netbox
  elif git ls-remote --exit-code --tags https://github.com/netbox-community/netbox.git "refs/tags/v${NETBOX_SRC_VERSION}" >/dev/null 2>&1; then
    echo "   Found tag v${NETBOX_SRC_VERSION}"
    git clone --depth 1 --branch "v${NETBOX_SRC_VERSION}" \
      https://github.com/netbox-community/netbox.git .netbox
  else
    echo "   ⚠️  Tag ${NETBOX_SRC_VERSION} not found in netbox source repo"
    echo "   Falling back to latest netbox source"
    echo "   Set NETBOX_SRC_VERSION env var to specify a different version"
    git clone --depth 1 https://github.com/netbox-community/netbox.git .netbox
  fi
fi

# Patch the Dockerfile for Ubuntu compatibility
# libxmlsec1-1 and libxmlsec1-openssl1 don't exist on any modern Ubuntu
# (22.04, 24.04) — renamed to libxmlsec1t64 and libxmlsec1-openssl
# Also fix social-auth-core extras bracket handling
echo "🔨 Patching Dockerfile for Ubuntu 24.04 compatibility..."
sed -i \
  -e 's/libxmlsec1-1\b/libxmlsec1t64/g' \
  -e 's/libxmlsec1-openssl1\b/libxmlsec1-openssl/g' \
  -e 's|social-auth-core/social-auth-core\\[all\\]|social-auth-core\[*\]/social-auth-core[all]|g' \
  Dockerfile

# Fix dependency conflicts between netbox-docker and NetBox source
echo "🔨 Fixing dependency conflicts in requirements files..."

# Fix sentry-sdk: NetBox source pins sentry-sdk==1.11.1 but netbox-docker
# requires sentry-sdk[django]>=2.x. Remove the hard pin from NetBox source.
if grep -q "^sentry-sdk==" .netbox/requirements.txt; then
  sed -i '/^sentry-sdk==/d' .netbox/requirements.txt
  echo "   ✅ Removed sentry-sdk hard pin from NetBox source"
fi

# Fix django-auth-ldap: netbox-docker pins django-auth-ldap==5.2.0 which
# requires django>=4.2, but NetBox 3.4.x source doesn't pin django>=4.2,
# so uv resolves django==4.1.4 causing a conflict. Downgrade to 4.8.0.
if grep -q "^django-auth-ldap==5" requirements-container.txt; then
  sed -i 's/^django-auth-ldap==5.2.0$/django-auth-ldap==4.8.0/' requirements-container.txt
  echo "   ✅ Downgraded django-auth-ldap to 4.8.0 (compatible with django<4.2)"
fi

# Verify the patches took effect
echo "🔍 Verifying patches..."
if grep -q "libxmlsec1-1" Dockerfile; then
  echo "❌ Patch failed! libxmlsec1-1 still present in Dockerfile"
  exit 1
fi
if grep -q "libxmlsec1-openssl1" Dockerfile; then
  echo "❌ Patch failed! libxmlsec1-openssl1 still present in Dockerfile"
  exit 1
fi
echo "   ✅ libxmlsec1 packages: libxmlsec1t64, libxmlsec1-openssl"
echo "   ✅ social-auth-core: fixed bracket handling"

# Build with podman --no-cache to ensure file changes are picked up
echo "🏗 Building image with podman..."
podman build \
  --pull \
  --no-cache \
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
