#!/bin/bash
# Build and push NetBox container image using Ubuntu 24.04 as the base.
#
# This script auto-patches the Dockerfile and clones the NetBox source code.
# All patches are applied automatically before building.
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

# Patch the Dockerfile
# Add libjpeg-dev for Pillow build, fix social-auth-core bracket handling
echo "🔨 Patching Dockerfile for compatibility..."
sed -i '/libxslt-dev/i\      libjpeg-dev \\' Dockerfile
sed -i -e 's|social-auth-core/social-auth-core\\\[all\\\]|social-auth-core\\[[^]]*\\]/social-auth-core[all]|g' Dockerfile

# Fix dependency conflicts between netbox-docker and NetBox source
echo "🔨 Fixing dependency conflicts in requirements files..."

# Fix sentry-sdk: NetBox source pins sentry-sdk==1.11.1 but netbox-docker
# requires sentry-sdk[django]>=2.x. Remove the hard pin from NetBox source.
if grep -q "^sentry-sdk==" .netbox/requirements.txt; then
  sed -i '/^sentry-sdk==/d' .netbox/requirements.txt
  echo "   ✅ Removed sentry-sdk hard pin from NetBox source"
fi

# Fix PyYAML 6.0: cannot build from source with modern setuptools
# (AttributeError: cython_sources). Remove hard pin so uv resolves to wheels.
if grep -q "^PyYAML==" .netbox/requirements.txt; then
  sed -i '/^PyYAML==/d' .netbox/requirements.txt
  echo "   ✅ Removed PyYAML hard pin from NetBox source"
fi

# Fix Pillow: pinned version needs libjpeg-dev to build from source
# Remove hard pin so uv resolves to a version with pre-built wheels.
if grep -q "^Pillow==" .netbox/requirements.txt; then
  sed -i '/^Pillow==/d' .netbox/requirements.txt
  echo "   ✅ Removed Pillow hard pin from NetBox source"
fi

# Fix Django: pinned 4.1.4 does not support Python 3.12 (Ubuntu 24.04).
# Django 4.2 LTS is the first version with Python 3.12 support.
if grep -q "^Django==" .netbox/requirements.txt; then
  sed -i '/^Django==/d' .netbox/requirements.txt
  echo "   ✅ Removed Django hard pin (need 4.2+ for Python 3.12)"
fi

# Fix jsonschema: pinned 3.2.0 uses deprecated distutils removed in Python 3.12.
if grep -q "^jsonschema==" .netbox/requirements.txt; then
  sed -i '/^jsonschema==/d' .netbox/requirements.txt
  echo "   ✅ Removed jsonschema hard pin (3.2.0 incompatible with Python 3.12)"
fi

# Fix django-auth-ldap: netbox-docker pins django-auth-ldap==5.2.0 which
# requires django>=4.2. Downgrade to 4.8.0 (supports django>=3.2).
if grep -q "^django-auth-ldap==5" requirements-container.txt; then
  sed -i 's/^django-auth-ldap==5.2.0$/django-auth-ldap==4.8.0/' requirements-container.txt
  echo "   ✅ Downgraded django-auth-ldap to 4.8.0 (compatible with django<4.2)"
fi

# Remove --no-binary flags: lxml 4.6.5 has Cython code incompatible with
# Python 3.12. Modern lxml/xmlsec have Python 3.12 compatible pre-built wheels.
sed -i '/^--no-binary lxml/d' requirements-container.txt
sed -i '/^--no-binary xmlsec/d' requirements-container.txt
echo "   ✅ Removed --no-binary flags for lxml and xmlsec (Python 3.12 compatibility)"

# Verify the patches took effect
echo "🔍 Verifying patches..."
if grep -q "libjpeg-dev" Dockerfile; then
  echo "   ✅ libjpeg-dev added for Pillow build"
fi
if grep "social-auth-core" Dockerfile | grep -q "\[\^]]"; then
  echo "   ✅ social-auth-core: fixed bracket handling"
else
  echo "   ⚠️  social-auth-core: pattern may not have been updated"
fi
if ! grep -q "^Django==" .netbox/requirements.txt; then
  echo "   ✅ Django pin removed (Python 3.12 compatibility)"
fi
if ! grep -q "^jsonschema==" .netbox/requirements.txt; then
  echo "   ✅ jsonschema pin removed (Python 3.12 compatibility)"
fi

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
