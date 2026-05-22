# Deploy NetBox on OpenShift

A step-by-step guide to build the [NetBox Docker image](https://github.com/netbox-community/netbox-docker), push it to a container registry, and deploy it on OpenShift.

## Architecture

```
Route (TLS/edge)
    │
    ▼
NetBox Service (port 8080)
    │
    ├── NetBox App (Granian, 4 workers)
    ├── NetBox Worker (RQ sidecar)
    │
    ├── PostgreSQL 18 (persistent)
    ├── Redis Sessions (Valkey 9, persistent)
    └── Redis Cache (Valkey 9, persistent)
```

## Prerequisites

- **Podman** installed (`podman build`/`podman push`)
- **Container registry** account with a repository
- **OpenShift** cluster access (`oc` CLI configured)
- **Podman login** to registry: `podman login ${REGISTRY}`

---

## Step 1: Build the Container Image

### Clone the NetBox Docker repo

```bash
git clone https://github.com/netbox-community/netbox-docker.git
cd netbox-docker
```

### Set build variables

```bash
# Container registry (default: quay.io)
export REGISTRY=quay.io

# Choose the NetBox version tag (no "v" prefix — e.g., 4.3.0, 4.2.0, 4.1.0)
export NETBOX_VERSION=4.3.0

# Your registry organization
export REGISTRY_ORG=your-registry-org
```

> **⚠️ NetBox 3.4.x Compatibility Note**: NetBox 3.4.x requires Django 4.1 which is **incompatible with Python 3.12** (Ubuntu 24.04). If deploying NetBox 3.4.x, use **Ubuntu 22.04** as the base image:
>
> ```bash
> export BASE_IMAGE="docker.io/ubuntu:22.04"
> ```
>
> The `build-and-push.sh` script defaults to Ubuntu 22.04. Also remove the `unit` package references from the Dockerfile (replace with `nginx`) since `unit` packages are Ubuntu 24.04-only.
>
> For NetBox 4.x+, Ubuntu 24.04 works without issues.

### Python / Django / Ubuntu Compatibility Matrix

| Base Image | Python | Django Required | NetBox Versions | Patches Needed |
|---|---|---|---|---|
| **Ubuntu 24.04** | 3.12 | ≥ 4.2 | 4.3+ (no patches) | None for 4.3+ |
| **Ubuntu 24.04** | 3.12 | ≥ 4.2 | 3.4.x — **not compatible** | Django 4.1 does not support Python 3.12 |
| **Ubuntu 22.04** | 3.10 | 4.0 — 4.2 | 3.4.x, 4.0 — 4.3 | Minimal patches (see below) |

**Why this matters:** Each Ubuntu release ships a different Python version, and Django dropped support for older Python versions in each major release. NetBox pins Django versions, so the chain is: **Ubuntu → Python → Django → NetBox**.

**Key dependency conflicts by Python version:**

| Package | Python 3.10 (Ubuntu 22.04) | Python 3.12 (Ubuntu 24.04) |
|---|---|---|
| **Django** | 4.0 — 4.2 ✓ | Requires ≥ 4.2 (3.2/4.0/4.1 do NOT support 3.12) |
| **sentry-sdk** | Pin `==1.11.1` works | Pin conflicts with `sentry-sdk[django]>=2.x` — **remove pin** |
| **PyYAML** | Pin `==6.0` builds OK | `cython_sources` attr error — **remove pin**, use ≥ 6.0.2 |
| **Pillow** | Pin works | Source build needs `libjpeg-dev` — **remove pin + add header** |
| **jsonschema** | Pin `==3.2.0` works | 3.2.0 incompatible with 3.12 — **remove pin**, use ≥ 4.0 |
| **django-auth-ldap** | `==5.2.0` requires Django ≥ 4.2 | Same — use `==4.8.0` when Django < 4.2 |
| **lxml** | `--no-binary` builds OK | Cython API changed — **remove `--no-binary`**, pin `>=5.0.0` |
| **social-auth-core** | sed bracket handling OK | Same issue — needs pipe-delimiter fix in Dockerfile sed |

**Rule of thumb:** If `NETBOX_VERSION < 4.3`, always use **Ubuntu 22.04** as the base image. The `build-and-push.sh` script handles this automatically.

### Manual Build Steps

```bash
git clone https://github.com/netbox-community/netbox-docker.git
cd netbox-docker

# 1. Checkout the netbox-docker version
git fetch --tags
git tag -l '5.*' | sort -V | tail -20   # List recent tags
git checkout ${NETBOX_VERSION}

# 2. Clone the NetBox source code (required — Dockerfile needs it)
# The netbox source repo uses v-prefixed tags (v4.0.2, not 4.0.2)
git clone --depth 1 --branch "v${NETBOX_VERSION}" \
  https://github.com/netbox-community/netbox.git .netbox

# 3. Patch the Dockerfile (use Python heredoc — sed can't match nested quotes)
# Add libjpeg-dev for Pillow build
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
    "echo 'Skipping mkdocs build (incompatible with Python 3.12)' #"
)
with open('Dockerfile', 'w') as f:
    f.write(c)
PYEOF

# 4. Remove hard pins from NetBox source requirements (Python 3.12 compatibility)
sed -i '/^sentry-sdk==/d' .netbox/requirements.txt
sed -i '/^PyYAML==/d' .netbox/requirements.txt
sed -i '/^Pillow==/d' .netbox/requirements.txt
sed -i '/^Django==/d' .netbox/requirements.txt
sed -i '/^jsonschema==/d' .netbox/requirements.txt
sed -i '/^social-auth-core\[.*\]==/d' .netbox/requirements.txt

# 5. Fix django-auth-ldap version conflict
sed -i 's/^django-auth-ldap==5.2.0$/django-auth-ldap==4.8.0/' requirements-container.txt

# 6. Remove --no-binary flags + pin lxml for Python 3.12 compatibility
sed -i '/^--no-binary lxml/d' requirements-container.txt
sed -i '/^--no-binary xmlsec/d' requirements-container.txt
echo "lxml>=5.0.0" >> requirements-container.txt

# 7. Verify the patches took effect
grep "libjpeg-dev" Dockerfile
grep "social-auth-core\|[^]]*\|/social-auth-core\[all\]" Dockerfile  # should show pipe delimiters
grep "Skipping mkdocs" Dockerfile  # should exist
grep -E "^(sentry-sdk|PyYAML|Pillow|Django|jsonschema)==[^ ]" .netbox/requirements.txt || echo "All pins removed ✓"
grep "lxml>=5.0.0" requirements-container.txt  # should exist
grep "^--no-binary" requirements-container.txt || echo "--no-binary removed ✓"

# 8. Build (--no-cache prevents podman from using stale cached layers)
podman build \
  --no-cache \
  --pull \
  --target main \
  -f Dockerfile \
  -t "${REGISTRY}/${REGISTRY_ORG}/netbox:${NETBOX_VERSION}" \
  --build-arg "FROM=docker.io/ubuntu:24.04" \
  --build-arg "NETBOX_PATH=.netbox" \
  .
```

This clones both repos, patches the Dockerfile for package name compatibility, builds the image, and tags it. Verify it works:

```bash
podman run --rm ${REGISTRY}/${REGISTRY_ORG}/netbox:${NETBOX_VERSION} --help
```

### Push to Registry

```bash
podman push ${REGISTRY}/${REGISTRY_ORG}/netbox:${NETBOX_VERSION}
```

Or use the convenience scripts which handle everything automatically:

```bash
# Ubuntu 24.04 base (recommended)
./build/build-and-push-24.04.sh ${NETBOX_VERSION} ${REGISTRY_ORG} ${REGISTRY}

# Ubuntu 22.04 base
./build/build-and-push.sh ${NETBOX_VERSION} ${REGISTRY_ORG} ${REGISTRY}
```

### Build Variables Reference

| Variable | Default | Description |
|---|---|---|
| `REGISTRY` | `quay.io` | Container registry host |
| `REGISTRY_ORG` | (required) | Your registry organization |
| `FROM` | `docker.io/ubuntu:24.04` | Base image |

---

## Step 2: Prepare OpenShift

### Create the project

```bash
oc new-project netbox
```

### Create an ImagePullSecret (if registry is private)

**Option A: Use the template manifest** (recommended)

Edit `manifests/netbox-image-pull-secret.yaml` and replace the placeholder `.dockerconfigjson` value with your actual registry credentials, then apply:

```bash
oc apply -f manifests/netbox-image-pull-secret.yaml
```

> ⚠️ The manifest contains a placeholder value — you **must** replace it before deploying.

**Option B: Create from scratch**

```bash
oc create secret docker-registry netbox-image-pull-secret \
  --docker-server=${REGISTRY} \
  --docker-username=YOUR_QUAY_USERNAME \
  --docker-password=YOUR_QUAY_TOKEN \
  --docker-email=you@example.com
```

### OpenShift SCC Compliance

OpenShift 4.x enforces [Security Context Constraints](https://docs.openshift.com/latest/security/securing Applications_and_Projects/configuring-scc.html). All manifests in this repo are configured to work with the `restricted-v2` SCC — each container specifies `securityContext` with `runAsNonRoot`, `allowPrivilegeEscalation: false`, and `capabilities.drop: ["ALL"]`.

If you get `unable to validate against any security context constraint`, check:
- Your ServiceAccount has the correct SCC bound: `oc describe scc restricted-v2`
- No pod-level `fsGroup` is set (use container-level security instead)
- All containers have `securityContext` defined

---

## Step 3: Deploy Manifests

All manifests live in the `manifests/` directory. Apply them in order.

### 3a. Configuration (ConfigMap + Secret + ImagePullSecret)

```bash
oc apply -f manifests/netbox-config.yaml
oc apply -f manifests/netbox-env.yaml
oc apply -f manifests/netbox-image-pull-secret.yaml  # for private registries
```

**Important**: Edit `manifests/netbox-env.yaml` and set **real passwords** and a **strong SECRET_KEY** (minimum 50 characters). The defaults are placeholders.

### 3b. Database and Cache

```bash
# PostgreSQL (with PVC)
oc apply -f manifests/postgres.yaml

# Redis session store (with PVC)
oc apply -f manifests/redis.yaml

# Redis cache (with PVC)
oc apply -f manifests/redis-cache.yaml
```

### 3c. Wait for dependencies

```bash
oc wait --for=condition=ready pod -l app=netbox-postgres -n netbox --timeout=120s
oc wait --for=condition=ready pod -l app=netbox-redis -n netbox --timeout=60s
oc wait --for=condition=ready pod -l app=netbox-redis-cache -n netbox --timeout=60s
```

### 3d. NetBox App + Worker

Edit `manifests/netbox.yaml` and replace `${REGISTRY}/${REGISTRY_ORG}/netbox:${NETBOX_VERSION}` with your actual image path.

```bash
oc apply -f manifests/netbox.yaml
```

### 3e. Route (Ingress)

```bash
oc apply -f manifests/route.yaml
```

### 3f. Verify

```bash
oc get pods -n netbox
oc get route netbox -n netbox -o jsonpath='{.spec.host}'
```

Visit the URL in your browser. The first startup takes ~90 seconds for migrations and superuser creation.

---

## Step 4: Post-Deployment

### Access the UI

```bash
# Get the route URL
oc get route netbox -n netbox -o jsonpath='{.spec.host}'
# e.g., https://netbox-netbox.apps.cluster.example.com
```

Default admin credentials (from `netbox-env.yaml`):
- **Username**: `admin`
- **Password**: whatever you set for `SUPERUSER_PASSWORD`

### Change the Admin Password

If you've lost the admin password or want to change it after deployment:

**Option A: Interactive (prompts for new password)**

```bash
POD=$(oc get pods -n netbox -l app=netbox -o jsonpath='{.items[0].metadata.name}')
oc exec -it $POD -n netbox -c netbox -- python3 /opt/netbox/netbox/manage.py changepassword admin
```

**Option B: One-liner (set password without prompt)**

```bash
POD=$(oc get pods -n netbox -l app=netbox -o jsonpath='{.items[0].metadata.name}')
oc exec $POD -n netbox -c netbox -- python3 -c "
from django.contrib.auth.models import User
u = User.objects.get(username='admin')
u.set_password('YOUR_NEW_PASSWORD')
u.save()
print('Password changed successfully')
"
```

> **Note:** The NetBox Docker image has `manage.py` at `/opt/netbox/netbox/manage.py` — not at the root. Running `python3 manage.py` without the full path will fail with `No such file or directory`.

### Scale the App

To add more replicas of the app (worker stays at 1):

```bash
oc scale deployment netbox -n netbox --replicas=2
```

### Update NetBox Version

1. Rebuild and push a new image tag (Step 1)
2. Update the image in `manifests/netbox.yaml`
3. Apply: `oc apply -f manifests/netbox.yaml`

---

## Directory Structure

```
openshift_netbox/
├── .ggignore                    # GitGuardian ignore (placeholder secrets)
├── README.md                    # This guide
├── build/
│   ├── build-and-push.sh        # Build with Ubuntu 22.04 base
│   └── build-and-push-24.04.sh  # Build with Ubuntu 24.04 base (patches Dockerfile)
└── manifests/
    ├── netbox-config.yaml       # Configuration ConfigMap
    ├── netbox-env.yaml          # Environment variables Secret (placeholders)
    ├── netbox-image-pull-secret.yaml  # Image pull secret template (placeholder)
    ├── postgres.yaml            # PostgreSQL deployment + PVC
    ├── redis.yaml               # Redis session store + PVC
    ├── redis-cache.yaml         # Redis cache + PVC
    ├── netbox.yaml              # NetBox app + worker deployment
    └── route.yaml               # OpenShift Route (TLS ingress)
```

---

## Troubleshooting

### Pod stuck on ImagePullBackOff
Check the ImagePullSecret:
```bash
oc describe pod <netbox-pod> -n netbox | grep -A5 "Failed to pull"
oc get sa default -n netbox -o yaml | grep imagePullSecrets
```

### Pod stuck on CrashLoopBackOff
Check logs:
```bash
oc logs <netbox-pod> -n netbox -c netbox
oc logs <netbox-pod> -n netbox -c netbox-worker
```
Common causes: wrong DB password, invalid SECRET_KEY format, or DB not ready.

### Readiness probe failing
The probe checks `/login/` on port 8080 with a 90-second initial delay. If the first startup takes longer (large migrations), increase `initialDelaySeconds` in `manifests/netbox.yaml`.

### podman build fails with `RequiredDependencyException: jpeg`

Pillow needs `libjpeg-dev` headers to build from source. The Dockerfile doesn't install it.

**Fix:** Add `libjpeg-dev` to the apt-get install list and remove the Pillow pin:

```bash
cd netbox-docker
sed -i '/libxslt-dev/i\      libjpeg-dev \\' Dockerfile
sed -i '/^Pillow==/d' .netbox/requirements.txt
```

### podman build fails with `social-auth-core` double brackets

The upstream Dockerfile sed creates `social-auth-core[[all]]` instead of `social-auth-core[all]`.

**Fix:** Patch the Dockerfile sed command using a Python heredoc:

```bash
cd netbox-docker
python3 << 'PYEOF'
with open('Dockerfile') as f:
    c = f.read()
c = c.replace(
    "sed -i -e 's/social-auth-core/social-auth-core\\[all\\]/g'",
    "sed -i -e 's|social-auth-core|social-auth-core\\[[^]]*\\]/social-auth-core[all]|g'"
)
with open('Dockerfile', 'w') as f:
    f.write(c)
PYEOF
```

### podman build fails with `lxml==4.6.5` build error

```
src/lxml/etree.c:5604:45: error: 'PyThreadState' has no member named 'curexc_type'
```

NetBox 3.4.x `requirements-container.txt` has `--no-binary lxml` which forces
building lxml 4.6.5 from source. Its Cython code uses Python 3.8 APIs removed in
Python 3.12. Remove the `--no-binary` flags to let uv use pre-built wheels:

```bash
cd netbox-docker
sed -i '/^--no-binary lxml/d' requirements-container.txt
sed -i '/^--no-binary xmlsec/d' requirements-container.txt
```

### podman build fails with dependency conflicts

See the [Manual Build Steps](#manual-build-steps) section for all required patches.

**Quick fix** — use the convenience script which handles everything:

```bash
cd netbox-docker
git checkout v${NETBOX_VERSION}

git clone --depth 1 --branch "v${NETBOX_VERSION}" \
  https://github.com/netbox-community/netbox.git .netbox

# Build (--no-cache is critical to avoid stale cached layers)
podman build \
  --pull \
  --no-cache \
  --target main \
  -f Dockerfile \
  -t "${REGISTRY}/${REGISTRY_ORG}/netbox:${NETBOX_VERSION}" \
  --build-arg "FROM=docker.io/ubuntu:24.04" \
  --build-arg "NETBOX_PATH=.netbox" \
  .
```

> Note: netbox-docker 3.4.1+ already uses correct `libxmlsec1` and `libxmlsec1-openssl`
> package names — no renaming patches needed for these versions.

### podman build fails with `sentry-sdk` version conflict
```
Because you require sentry-sdk==1.11.1 and sentry-sdk[django]==2.39.0,
we can conclude that your requirements are unsatisfiable.
```
NetBox source `.netbox/requirements.txt` pins `sentry-sdk==1.11.1` but netbox-docker's
`requirements-container.txt` requires `sentry-sdk[django]>=2.x`. Fix by removing
the hard pin from the NetBox source requirements:

```bash
sed -i '/^sentry-sdk==/d' .netbox/requirements.txt
```

### podman build fails with `django-auth-ldap` version conflict
```
Because django-auth-ldap==5.2.0 depends on django>=4.2 and you require django==4.1.4,
we can conclude that your requirements are unsatisfiable.
```
netbox-docker's `requirements-container.txt` pins `django-auth-ldap==5.2.0` which
requires `django>=4.2`, but NetBox 3.4.x source doesn't pin `django>=4.2` so uv
resolves `django==4.1.4`. Fix by downgrading django-auth-ldap:

```bash
sed -i 's/^django-auth-ldap==5.2.0$/django-auth-ldap==4.8.0/' requirements-container.txt
```

### podman build fails with `pyyaml` build failure
```
AttributeError: 'build_ext' object has no attribute 'cython_sources'
```
PyYAML 6.0 requires Cython to build from source but doesn't declare it as a
build dependency. Remove the hard pin so uv resolves to a newer version with
pre-built wheels:

```bash
sed -i '/^PyYAML==/d' .netbox/requirements.txt
```

### podman build fails with `social-auth-core[all][openidconnect]`
The upstream Dockerfile's sed command creates double brackets when `requirements.txt` already has `social-auth-core[openidconnect]` (NetBox 3.4.x and newer). The build scripts handle this automatically. For manual builds, use the Python heredoc patch shown in [Step 3](#3-patch-the-dockerfile-use-two-separate-sed-calls) or the [Troubleshooting section above](#podman-build-fails-with-social-auth-core-double-brackets).

---

## References

- [NetBox Docker](https://github.com/netbox-community/netbox-docker)
- [NetBox Docs](https://docs.netbox.dev/)
- [Quay.io Docs](https://docs.quay.io/)
- [OpenShift Networking Guide](https://docs.openshift.com/latest/networking/index.html)
