# Option 1: Build NetBox Image from Source

Build a custom NetBox container image using `netbox-docker` + `podman`. This gives you full control over the image and lets you push it to your internal registry.

## Prerequisites

- `podman` installed and configured
- Logged in to your container registry (`podman login <registry>`)
- Git access to clone repos

## Step 1: Clone the Repos

```bash
# Clone netbox-docker (Dockerfile + build scripts)
git clone https://github.com/netbox-community/netbox-docker.git
cd netbox-docker

# Clone NetBox source code into .netbox directory
git clone --depth 1 --branch <version> \
  https://github.com/netbox-community/netbox.git .netbox
```

The Dockerfile expects `NETBOX_PATH` to point to the NetBox source directory.

## Step 2: Patch the Dockerfile

The upstream `netbox-docker` Dockerfile needs patches for OpenShift compatibility:

### For Ubuntu 22.04 (NetBox 3.x)

```bash
# Add libjpeg-dev for Pillow build
sed -i '/libxslt-dev/i\      libjpeg-dev \\' Dockerfile

# Run the fix script (removes 'unit' webserver, fixes sed delimiters)
cp /path/to/fix_dockerfile.py .
python3 fix_dockerfile.py
```

### For Ubuntu 24.04 (NetBox 4.x+)

```bash
# Add libjpeg-dev
sed -i '/libxslt-dev/i\      libjpeg-dev \\' Dockerfile

# Fix social-auth-core bracket handling + skip mkdocs
python3 << 'PYEOF'
with open('Dockerfile') as f:
    c = f.read()
c = c.replace(
    "sed -i -e 's/social-auth-core/social-auth-core\\[all\\]/g'",
    "sed -i -e 's|social-auth-core|social-auth-core\\[[^]]*\\]/social-auth-core[all]|g'"
)
c = c.replace(
    'SECRET_KEY="dummyKeyWithMinimumLength-------------------------" /opt/netbox/venv/bin/python -m mkdocs build',
    "echo 'Skipping mkdocs build (incompatible with Python 3.12)' #"
)
with open('Dockerfile', 'w') as f:
    f.write(c)
PYEOF
```

## Step 3: Fix Dependency Conflicts

Several pinned versions in `requirements.txt` conflict with newer Python/base images:

```bash
# Remove sentry-sdk hard pin (NetBox source pins 1.x, netbox-docker needs 2.x)
sed -i '/^sentry-sdk==/d' .netbox/requirements.txt

# Remove PyYAML hard pin (cannot build from source with modern setuptools)
sed -i '/^PyYAML==/d' .netbox/requirements.txt

# Remove Pillow hard pin (needs libjpeg-dev to build from source)
sed -i '/^Pillow==/d' .netbox/requirements.txt

# Downgrade django-auth-ldap (5.2.0 requires django>=4.2)
sed -i 's/^django-auth-ldap==5.2.0$/django-auth-ldap==4.8.0/' requirements-container.txt

# Remove --no-binary flags + fix lxml compatibility
sed -i '/^--no-binary lxml/d' requirements-container.txt
sed -i '/^--no-binary xmlsec/d' requirements-container.txt
sed -i '/^social-auth-core/d' .netbox/requirements.txt
echo "lxml>=5.0.0" >> requirements-container.txt
```

### Ubuntu 24.04 only (NetBox 4.x+)

```bash
# Remove Django pin (4.1.x does not support Python 3.12)
sed -i '/^Django==/d' .netbox/requirements.txt

# Remove jsonschema pin (3.2.0 uses deprecated distutils)
sed -i '/^jsonschema==/d' .netbox/requirements.txt
```

## Step 4: Build and Push

```bash
podman build \
  --pull \
  --no-cache \
  --target main \
  -f Dockerfile \
  -t "<registry>/<org>/netbox:<version>" \
  --build-arg "FROM=docker.io/ubuntu:22.04" \
  --build-arg "NETBOX_PATH=.netbox" \
  --label "org.opencontainers.image.version=<version>" \
  .

podman push "<registry>/<org>/netbox:<version>"
```

Or use the provided scripts:

```bash
# NetBox 3.x (Ubuntu 22.04)
./build-and-push.sh 3.4.1 openshift registry-quay-quay-enterprise.apps.luke.syangsao.net

# NetBox 4.x+ (Ubuntu 24.04)
./build-and-push-24.04.sh 4.3.0 openshift registry-quay-quay-enterprise.apps.luke.syangsao.net
```

## Automated Build Script

The `build-and-push.sh` script automates all steps:

1. Clones `netbox-docker` if not present
2. Checks out the specified version tag
3. Clones NetBox source into `.netbox/`
4. Patches the Dockerfile
5. Fixes dependency conflicts
6. Builds with `podman`
7. Pushes to the registry

```bash
# Usage
./build-and-push.sh <netbox_version> [registry_org] [registry]

# Examples
./build-and-push.sh 3.4.1 openshift registry-quay-quay-enterprise.apps.luke.syangsao.net
./build-and-push.sh 4.3.0 my-quay-org quay.io
```

## Known Issues

### `django.utils.itercompat` not found (NetBox 3.x on Ubuntu 24.04)
Django 4.0+ removed `django.utils.itercompat`. `django-filter` 22.x still imports it. **Solution:** Use Ubuntu 22.04 for NetBox 3.x, or downgrade `django-filter` to 21.1.

### `pkg_resources` not found
Removing `django_filters` with `rm -rf` can accidentally remove `setuptools` (which provides `pkg_resources`). **Solution:** Use `pip uninstall` instead of `rm -rf`, or reinstall `setuptools`.

### `ZoneInfoNotFoundError`
Missing `tzdata` package. **Solution:** Add `tzdata` to the apt install list in the Dockerfile.

### `unitd: not found`
The `unit` webserver is not available on Ubuntu 22.04. **Solution:** Use `launch-netbox-2204.sh` which launches gunicorn instead.
