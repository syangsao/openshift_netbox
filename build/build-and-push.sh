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

# Fix build-time sed delimiter, skip mkdocs, and remove Ubuntu 24.04-only packages
# (use Python heredoc — sed can't match nested quotes)
python3 << 'PYEOF'
with open('Dockerfile') as f:
    lines = f.readlines()

out = []
skip_next = 0
for i, line in enumerate(lines):
    if skip_next > 0:
        skip_next -= 1
        continue
    # Skip unit apt source and GPG key (Ubuntu 24.04-only)
    if 'unit.list' in line or 'nginx-keyring.gpg' in line:
        continue
    # Skip unit package installations (Ubuntu 24.04-only)
    if 'unit-python3' in line or line.strip().startswith('unit='):
        continue
    # Skip unit config copy
    if 'nginx-unit.json' in line:
        continue
    # Skip unit state directory creation
    if '/opt/unit/' in line:
        continue
    # Leave the social-auth-core sed as-is - we already removed the pin from requirements.txt
    # Skip mkdocs build — replace with echo and skip the --config-file continuation
    if '-m mkdocs build' in line:
        line = line.replace(
            'SECRET_KEY="dummyKeyWithMinimumLength-------------------------" /opt/netbox/venv/bin/python -m mkdocs build',
            'echo "Skipping mkdocs build"'
        )
        skip_next = 1  # skip the --config-file line
    out.append(line)

with open('Dockerfile', 'w') as f:
    f.writelines(out)
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

# Django: keep the pinned version for Ubuntu 22.04 (Python 3.10).
# Django 3.2.x / 4.0.x / 4.1.x all work fine with Python 3.10.
# Only remove the pin when targeting Ubuntu 24.04 (Python 3.12).
# IMPORTANT: For NetBox 3.x, removing the Django pin causes uv to resolve
# Django 4.x, which breaks django-filter (requires django.utils.itercompat,
# removed in Django 4.0). Always use Ubuntu 22.04 for NetBox 3.x.
echo "   ✅ Django pin preserved (Python 3.10 compatible)"

# jsonschema: pinned 3.2.0 works fine with Python 3.10 (Ubuntu 22.04).
# Only remove the pin when targeting Ubuntu 24.04 (Python 3.12).
echo "   ✅ jsonschema pin preserved (Python 3.10 compatible)"

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
sed -i '/^social-auth-core/d' .netbox/requirements.txt
echo "lxml>=5.0.0" >> requirements-container.txt
echo "   ✅ Removed --no-binary flags, social-auth-core pin + pinned lxml>=5.0.0 (Python 3.12 wheels)"

# Verify the patches took effect
echo "🔍 Verifying patches..."
if grep -q "libjpeg-dev" Dockerfile; then
  echo "   ✅ libjpeg-dev added for Pillow build"
fi
# social-auth-core sed left as-is in Dockerfile (pin removed from requirements.txt)
# Django and jsonschema pins are preserved for Ubuntu 22.04 (Python 3.10 compatible)
echo "   ✅ Django pin preserved (Python 3.10 compatible)"
echo "   ✅ jsonschema pin preserved (Python 3.10 compatible)"
if grep -q "lxml>=5.0.0" requirements-container.txt; then
  echo "   ✅ lxml>=5.0.0 pinned (Python 3.12 wheels)"
fi
if ! grep -q "^social-auth-core" .netbox/requirements.txt; then
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
