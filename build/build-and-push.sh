#!/bin/bash
# Build and push NetBox container image to a container registry using Podman
# Usage: ./build-and-push.sh <netbox_version> [registry_org] [registry]
# Example: ./build-and-push.sh 4.3.0 my-quay-org quay.io
#
# Prerequisites:
#   - podman installed (podman build/push)
#   - Logged in to registry (podman login $REGISTRY)

set -euo pipefail

NETBOX_VERSION="${1:?Usage: $0 <netbox_version> [registry_org] [registry]}"
REGISTRY_ORG="${2:-your-registry-org}"
REGISTRY="${3:-quay.io}"
BASE_IMAGE="${BASE_IMAGE:-docker.io/ubuntu:22.04}"
# Override NetBox source tag (netbox-docker version ≠ netbox source version)
NETBOX_SRC_VERSION="${NETBOX_SRC_VERSION:-${NETBOX_VERSION}}"

IMAGE="${REGISTRY}/${REGISTRY_ORG}/netbox:${NETBOX_VERSION}"

echo "🔧 Building NetBox ${NETBOX_VERSION} -> ${IMAGE}"

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

# Patch the Dockerfile for compatibility
# Add libjpeg-dev for Pillow build
echo "🔨 Patching Dockerfile for compatibility..."
sed -i '/libxslt-dev/i\      libjpeg-dev \\' Dockerfile

# Fix build-time sed delimiter and skip mkdocs build (use Python heredoc — sed can't match nested quotes)
python3 << 'PYEOF'
with open('Dockerfile') as f:
    c = f.read()
# Fix social-auth-core sed: use | delimiter to avoid / conflict with ] in replacement
c = c.replace(
    "sed -i -e 's/social-auth-core/social-auth-core\\[all\\]/g'",
    "sed -i -e 's|social-auth-core|social-auth-core\\[[^]]*\\]/social-auth-core[all]|g'"
)
# Skip mkdocs build — mkdocs-autorefs is incompatible with Python 3.12
c = c.replace(
    'SECRET_KEY="dummyKeyWithMinimumLength-------------------------" /opt/netbox/venv/bin/python -m mkdocs build',
    "echo 'Skipping mkdocs build (incompatible with Python 3.12) #"
)
with open('Dockerfile', 'w') as f:
    f.write(c)
PYEOF

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

# Remove --no-binary flags + fix lxml compatibility:
# social-auth-core 4.3.0 pins lxml<4.7, but lxml 4.6.5 has no Python 3.12 wheel.
# Remove the social-auth-core version pin so uv resolves to 4.4.0+ (supports lxml 5.x).
sed -i '/^--no-binary lxml/d' requirements-container.txt
sed -i '/^--no-binary xmlsec/d' requirements-container.txt
sed -i '/^social-auth-core\[.*\]==/d' .netbox/requirements.txt
echo "lxml>=5.0.0" >> requirements-container.txt
echo "   ✅ Removed --no-binary flags, social-auth-core pin + pinned lxml>=5.0.0 (Python 3.12 wheels)"

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
if grep -q "lxml>=5.0.0" requirements-container.txt; then
  echo "   ✅ lxml>=5.0.0 pinned (Python 3.12 wheels)"
fi
if ! grep -q "^social-auth-core\[.*\]==" .netbox/requirements.txt; then
  echo "   ✅ social-auth-core pin removed (lxml compatibility)"
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
